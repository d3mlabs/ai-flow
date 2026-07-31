# typed: strict
# frozen_string_literal: true

require "json"

module AiFlow
  module Commands
    # /split — plan/apply over sub-issues, like Terraform. The agent
    # participates only in the propose phase; the execute phase is a
    # deterministic parse of the frozen artifact.
    #
    # `--dry` runs the agent once and stages the proposal as a fenced-yaml
    # `## Subtasks` section in the plan body (human-editable escrow).
    # `--apply` never calls the agent: it parses the section as it exists at
    # apply time and reconciles sub-issues against it — create missing
    # (routed per subtask to its repo), adopt or reference `existing:`
    # issues, close stale, keep matching (title is the reconciliation key).
    # Bare /split does both phases in one run. At apply, canonicity
    # transfers to the created sub-issues and the section is rewritten into
    # a linked map.
    #
    # Sub-issues are thin tracking shards of the plan — the parent plan body
    # is the spec, so the staged entries carry no bodies (titles must be
    # self-explanatory) and created sub-issues get a templated body: a
    # human-facing `Part of owner/repo#n.` line plus the `Depends on:` /
    # `Intended repo:` conventions. /build reconstructs a sub-issue's scope
    # from the parent plan via the native parent relationship.
    class Split
      extend T::Sig

      # How a staged entry resolved against reality at apply time.
      module Disposition
        extend T::Helpers
        include Kernel # is_a? for srb without the experimental requires_ancestor
        sealed!

        # The entry matched an existing sub-issue (by title or `existing:`).
        class Kept
          include Disposition
        end

        # A parentless `existing:` issue became a native sub-issue.
        class Adopted
          include Disposition
        end

        # An `existing:` issue already owned by another parent — linked in
        # the map without adoption.
        class Referenced
          include Disposition
        end

        # A sub-issue was created this run; only these carry the templated
        # body (the annotate_dependencies rewrite builds on it).
        class Created
          extend T::Sig
          include Disposition

          sig { returns(String) }
          attr_reader :body

          # @param body [String]
          sig { params(body: String).void }
          def initialize(body:)
            @body = body
          end
        end
      end

      # Where a staged entry resolved to: an issue plus its disposition.
      class IssueRef < T::Struct
        const :repo, String
        const :number, Integer
        const :url, String
        const :disposition, Disposition
      end

      # The reconciliation report /split renders as its panel: rows grouped
      # by disposition, plus the stale closures and routing warnings.
      class Report
        extend T::Sig

        # One reconciled entry: the staged subtask and where it resolved.
        class Row < T::Struct
          const :entry, SubtasksSection::Entry
          const :ref, IssueRef
        end

        sig { returns(T::Array[Row]) }
        attr_reader :created

        sig { returns(T::Array[Row]) }
        attr_reader :adopted

        sig { returns(T::Array[Row]) }
        attr_reader :referenced

        sig { returns(T::Array[Row]) }
        attr_reader :kept

        sig { returns(T::Array[GitHub::Issue]) }
        attr_reader :closed

        sig { returns(T::Array[String]) }
        attr_reader :warnings

        sig { void }
        def initialize
          @created = T.let([], T::Array[Row])
          @adopted = T.let([], T::Array[Row])
          @referenced = T.let([], T::Array[Row])
          @kept = T.let([], T::Array[Row])
          @closed = T.let([], T::Array[GitHub::Issue])
          @warnings = T.let([], T::Array[String])
        end

        # @param row [Row]
        # @return [void]
        sig { params(row: Row).void }
        def record(row)
          disposition = row.ref.disposition
          case disposition
          when Disposition::Created then @created << row
          when Disposition::Adopted then @adopted << row
          when Disposition::Referenced then @referenced << row
          when Disposition::Kept then @kept << row
          else T.absurd(disposition)
          end
        end
      end

      # Per-entry-index possible-match suggestion lines.
      Matches = T.type_alias { T::Hash[Integer, T::Array[String]] }

      REPOSITORY_ID_QUERY = <<~GRAPHQL
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) { id }
        }
      GRAPHQL

      ISSUE_ID_QUERY = <<~GRAPHQL
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) { issue(number: $number) { id } }
        }
      GRAPHQL

      CREATE_SUB_ISSUE_MUTATION = <<~GRAPHQL
        mutation($repositoryId: ID!, $title: String!, $body: String!, $parentIssueId: ID!) {
          createIssue(input: { repositoryId: $repositoryId, title: $title, body: $body, parentIssueId: $parentIssueId }) {
            issue { number url }
          }
        }
      GRAPHQL

      # The discovery pool stays bounded so the propose prompt cannot balloon
      # on issue-heavy orgs.
      DISCOVERY_POOL_LIMIT = 30

      # @param context [AiFlow::Context]
      # @param github [AiFlow::GitHub]
      # @param agent [AiFlow::Agent]
      # @param result_writer [AiFlow::ResultWriter]
      # @param workdir [String]
      sig do
        params(
          context: Context,
          github: GitHub,
          agent: Agent,
          result_writer: ResultWriter,
          workdir: String,
        ).void
      end
      def initialize(context:, github:, agent:, result_writer:, workdir:)
        @context = context
        @github = github
        @agent = agent
        @result_writer = result_writer
        @workdir = workdir
        # Memoized GraphQL node-id lookups (see repository_node_id /
        # parent_node_id) — read once per created sub-issue.
        @repository_node_ids = T.let({}, T::Hash[String, String])
        @parent_node_id = T.let(nil, T.nilable(String))
      end

      # @param segment [CommentParser::Segment]
      # @return [void]
      sig { params(segment: CommentParser::Segment).void }
      def run(segment)
        dry = segment.flags.include?("--dry")
        apply_flag = segment.flags.include?("--apply")
        raise CommentParser::ParseError, "/split takes --dry or --apply, not both." if dry && apply_flag

        parent = @github.issue(@context.owner_repo, @context.number)
        existing = @github.sub_issues(@context.owner_repo, @context.number)

        result =
          if apply_flag
            apply_summary(apply(parent, SubtasksSection.parse_spec(parent.body), existing))
          elsif dry
            entries, matches = propose(parent, existing, segment)
            stage_spec(parent, entries, matches)
            dry_summary(entries, matches)
          else
            entries, matches = propose(parent, existing, segment)
            stage_spec(parent, entries, matches)
            staged = @github.issue(@context.owner_repo, @context.number)
            apply_summary(apply(staged, entries, existing))
          end

        @result_writer.write(@context, [[segment, result]])
      end

      private

      # ---- Propose phase (the only agent call) ----

      # @return [Array(Array<SubtasksSection::Entry>, Hash)] normalized
      #   entries and per-index possible-match suggestion lines
      sig do
        params(parent: GitHub::Issue, existing: T::Array[GitHub::Issue], segment: CommentParser::Segment)
          .returns([T::Array[SubtasksSection::Entry], Matches])
      end
      def propose(parent, existing, segment)
        menu = repo_menu(parent)
        pool = discovery_pool(menu, parent, existing)
        output = @agent.launch(
          prompt: propose_prompt(parent, existing, segment, menu, pool),
          workdir: @workdir, command: Command::Split.new,
        )
        entries = parse_proposal(output)
        [entries, possible_matches(entries, pool)]
      end

      # @return [String] the propose pass's prompt
      sig do
        params(
          parent: GitHub::Issue,
          existing: T::Array[GitHub::Issue],
          segment: CommentParser::Segment,
          menu: T::Array[String],
          pool: T::Array[GitHub::Issue],
        ).returns(String)
      end
      def propose_prompt(parent, existing, segment, menu, pool)
        existing_list = existing.map { |issue| "- #{issue.repo}##{issue.number} #{issue.title} (#{issue.state})" }.join("\n")
        <<~PROMPT
          You are ai-flow, splitting a plan into well-isolated subtasks.

          PARENT ISSUE: #{parent.title}
          <<<BODY>>>
          #{PlanBody.from_issue_body(parent.body)}
          <<<END BODY>>>

          EXISTING SUB-ISSUES:
          #{existing_list.empty? ? "(none)" : existing_list}

          REPOSITORIES (route each subtask to the repo its work lands in):
          #{menu_descriptions(menu)}

          POSSIBLY RELATED OPEN ISSUES (a subtask already tracked by one of these should carry "existing" instead of being re-created):
          #{pool_descriptions(pool)}

          #{segment.instruction.empty? ? "" : "Additional instruction: #{segment.instruction}"}

          Propose the FULL desired set of subtasks (not a delta): well-isolated, independently buildable where possible. Do NOT write subtask bodies — the parent plan is the spec, and sub-issues are thin tracking shards of it, so each title must be self-explanatory about its scope. Route each subtask to the repository its work lands in ("repo"). When a subtask depends on another, reference it by its 0-based index in your list. Reuse the exact title of any existing sub-issue that should stay — titles are the reconciliation key. If integration work across subtasks is needed, include a final integration subtask depending on the others.

          OUTPUT FORMAT — exactly one JSON array, no other text ("depends_on" and "existing" are optional):
          [{"title": "…", "repo": "owner/repo", "depends_on": [0, 2], "existing": "owner/repo#12"}, …]
        PROMPT
      end

      # The full menu, never a blindfolded subset: repos without the App are
      # shown with the consequence spelled out, and deterministic Ruby
      # enforces the fallback at apply time.
      #
      # @return [String]
      sig { params(menu: T::Array[String]).returns(String) }
      def menu_descriptions(menu)
        installed = installed_repos
        menu.map do |repo|
          note = installed.include?(repo) ? "" : " (ai-flow App not installed — a subtask routed here is created on the parent's repo with an `Intended repo:` note)"
          "- #{repo}#{note}"
        end.join("\n")
      end

      # @return [String]
      sig { params(pool: T::Array[GitHub::Issue]).returns(String) }
      def pool_descriptions(pool)
        return "(none)" if pool.empty?

        pool.map { |issue| "- #{issue.repo}##{issue.number} #{issue.title}" }.join("\n")
      end

      # A `Target repos:` line narrows the menu (declared scope); otherwise
      # every repo of the parent's owner is on it. The parent's repo is
      # always present — it is the routing fallback.
      #
      # @return [Array<String>]
      sig { params(parent: GitHub::Issue).returns(T::Array[String]) }
      def repo_menu(parent)
        targets = (parent.body[/^Target repos?:\s*(.+)$/, 1] || "")
                  .split(",").map(&:strip).reject(&:empty?)
        return targets | [@context.owner_repo] unless targets.empty?

        owner = T.must(@context.owner_repo.split("/", 2).first)
        @github.owner_repos(owner) | [@context.owner_repo]
      end

      # Repos sub-issues can actually be created in. The parent's repo is
      # always routable (we are acting on it right now), which also keeps
      # local token-mode runs functional when the installation listing is
      # unavailable.
      #
      # @return [Array<String>]
      sig { returns(T::Array[String]) }
      def installed_repos
        @github.app_installed_repos | [@context.owner_repo]
      end

      # Open issues from the menu repos that share a keyword with the plan —
      # the pool the agent (and the post-proposal matcher) checks before
      # minting duplicates.
      #
      # @return [Array<GitHub::Issue>]
      sig do
        params(menu: T::Array[String], parent: GitHub::Issue, existing: T::Array[GitHub::Issue])
          .returns(T::Array[GitHub::Issue])
      end
      def discovery_pool(menu, parent, existing)
        existing_refs = existing.map { |issue| [issue.repo, issue.number] }
        keywords = discovery_keywords(parent)
        menu.flat_map { |repo| readable_open_issues(repo) }
            .reject { |issue| issue.repo == @context.owner_repo && issue.number == @context.number }
            .reject { |issue| existing_refs.include?([issue.repo, issue.number]) }
            .select { |issue| keywords.any? { |keyword| issue.title.downcase.include?(keyword) } }
            .first(DISCOVERY_POOL_LIMIT)
      end

      # The menu shows every owner repo, but the token may not read all of
      # them (App not installed there) — an unreadable pool repo is skipped,
      # not fatal.
      #
      # @return [Array<GitHub::Issue>]
      sig { params(repo: String).returns(T::Array[GitHub::Issue]) }
      def readable_open_issues(repo)
        @github.open_issues(repo)
      rescue GitHub::Error
        []
      end

      # Keywords come from the plan's title and headings — the body prose
      # would match everything.
      #
      # @return [Array<String>]
      sig { params(parent: GitHub::Issue).returns(T::Array[String]) }
      def discovery_keywords(parent)
        headings = parent.body.scan(/^#+\s+(.+)$/).flatten
        # T.cast: a group-free scan always yields strings, but the stdlib RBI
        # types it for the grouped case too.
        T.cast(
          [parent.title, *headings].join(" ").downcase.scan(/[a-z0-9][a-z0-9-]{3,}/),
          T::Array[String],
        ).uniq
      end

      # @return [Array<SubtasksSection::Entry>] entries normalized through
      #   the section schema (same shape a hand-edited spec parses to), repo
      #   defaulted to the parent's
      sig { params(output: String).returns(T::Array[SubtasksSection::Entry]) }
      def parse_proposal(output)
        json = output[/\[.*\]/m]
        raise Agent::Error, "the agent returned no subtask JSON:\n#{output}" unless json

        JSON.parse(json).map do |raw|
          entry = SubtasksSection.validate_entry(raw)
          entry.repo = @context.owner_repo if entry.repo.empty?
          entry
        end
      end

      # Deterministic second discovery pass: title-similarity suggestions the
      # human resolves during the body review — annotations, never decisions.
      #
      # @return [Hash{Integer => Array<String>}]
      sig do
        params(entries: T::Array[SubtasksSection::Entry], pool: T::Array[GitHub::Issue]).returns(Matches)
      end
      def possible_matches(entries, pool)
        entries.each_with_index.with_object({}) do |(entry, index), matches|
          next if entry.existing

          similar = pool.select { |issue| similar_title?(entry.title, issue.title) }
          next if similar.empty?

          matches[index] = similar.first(3).map { |issue| "#{issue.repo}##{issue.number} #{issue.title.to_json}" }
        end
      end

      # @return [Boolean] whether two titles overlap enough to flag
      sig { params(title: String, candidate: String).returns(T::Boolean) }
      def similar_title?(title, candidate)
        title_words = PlanBody.normalize(title).split.uniq
        candidate_words = PlanBody.normalize(candidate).split.uniq
        overlap = (title_words & candidate_words).size
        overlap >= 2 && overlap >= ([title_words.size, candidate_words.size].min * 0.6).ceil
      end

      # ---- Staging (the --dry write) ----

      # @return [void]
      sig do
        params(parent: GitHub::Issue, entries: T::Array[SubtasksSection::Entry], matches: Matches).void
      end
      def stage_spec(parent, entries, matches)
        snapshot = PlanBody.from_issue_body(parent.body)
        section = SubtasksSection.render_spec(entries, possible_matches: matches)
        guarded_patch(snapshot, SubtasksSection.replace(snapshot, section))
      end

      # One guarded PATCH, same race window as Batch: refetch and refuse when
      # the body moved since the snapshot.
      #
      # @return [void]
      sig { params(snapshot: String, new_body: String).void }
      def guarded_patch(snapshot, new_body)
        current = @github.issue(@context.owner_repo, @context.number)
        if PlanBody.from_issue_body(current.body) != snapshot
          raise GitHub::Error,
            "the plan body changed while /split was running — nothing was written; retry"
        end

        @github.update_issue_body(@context.owner_repo, @context.number, body: new_body)
      end

      # ---- Apply phase (no agent — pure Ruby over the frozen spec) ----

      # @return [Report] the reconciliation report
      sig do
        params(
          parent: GitHub::Issue,
          entries: T::Array[SubtasksSection::Entry],
          existing: T::Array[GitHub::Issue],
        ).returns(Report)
      end
      def apply(parent, entries, existing)
        snapshot = PlanBody.from_issue_body(parent.body)
        report = Report.new
        refs = entries.each_with_index.to_h do |entry, index|
          [index, resolve_entry(entry, existing, report)]
        end

        annotate_dependencies(entries, refs)
        close_stale(entries, existing, refs, report)
        rewrite_section(snapshot, entries, refs)
        report
      end

      # @return [IssueRef] where the entry resolved to
      sig do
        params(entry: SubtasksSection::Entry, existing: T::Array[GitHub::Issue], report: Report)
          .returns(IssueRef)
      end
      def resolve_entry(entry, existing, report)
        ref =
          if entry.existing
            adopt_or_reference(entry, existing)
          elsif (match = existing.find { |issue| issue.title == entry.title })
            IssueRef.new(repo: match.repo, number: match.number,
              url: match.html_url, disposition: Disposition::Kept.new)
          else
            create_sub_issue(entry, report)
          end
        report.record(Report::Row.new(entry: entry, ref: ref))
        ref
      end

      # A parentless `existing:` issue is adopted as a native sub-issue; one
      # already owned by another parent (GitHub allows one parent per issue)
      # is referenced in the linked map without adoption.
      #
      # @return [IssueRef] the ref with its disposition
      sig { params(entry: SubtasksSection::Entry, existing: T::Array[GitHub::Issue]).returns(IssueRef) }
      def adopt_or_reference(entry, existing)
        # T.must: resolve_entry only routes here when `existing:` is present.
        repo, number = parse_issue_ref(T.must(entry.existing))
        disposition =
          if existing.any? { |issue| issue.repo == repo && issue.number == number }
            Disposition::Kept.new
          else
            begin
              rest_id = @github.api("repos/#{repo}/issues/#{number}").fetch("id")
              @github.add_sub_issue(@context.owner_repo, @context.number, rest_id)
              Disposition::Adopted.new
            rescue GitHub::Error
              Disposition::Referenced.new
            end
          end
        IssueRef.new(
          repo: repo, number: number,
          url: "https://github.com/#{repo}/issues/#{number}", disposition: disposition,
        )
      end

      # Reality enforcement, never judgment: a repo without the App cannot
      # receive the issue, so it is created on the parent's repo with an
      # `Intended repo:` note and a panel warning — never a silent reroute.
      # The body is a thin template (the parent plan is the spec): the
      # `Part of` line is human-facing decoration — /build trusts the native
      # parent relationship, not prose. Bespoke context belongs on the
      # created sub-issue, added after apply.
      #
      # @return [IssueRef] the created issue's ref
      sig { params(entry: SubtasksSection::Entry, report: Report).returns(IssueRef) }
      def create_sub_issue(entry, report)
        target = entry.repo
        body = "Part of #{@context.owner_repo}##{@context.number}.\n"
        unless installed_repos.include?(target)
          report.warnings << "#{target} has no ai-flow App installation — created #{entry.title.inspect} " \
                             "on #{@context.owner_repo} instead (`Intended repo: #{target}`); " \
                             "install the App there and re-run /split to move it."
          body = "#{body.rstrip}\n\nIntended repo: #{target}\n"
          target = @context.owner_repo
        end

        data = @github.graphql(CREATE_SUB_ISSUE_MUTATION, {
          repositoryId: repository_node_id(target),
          title: entry.title,
          body: body,
          parentIssueId: parent_node_id,
        })
        issue = data.fetch("createIssue").fetch("issue")
        IssueRef.new(
          repo: target, number: issue.fetch("number"), url: issue.fetch("url"),
          disposition: Disposition::Created.new(body: body),
        )
      end

      # Second pass, once every index has a number: dependencies always
      # render fully qualified (`Depends on: owner/repo#n`) — GitHub
      # autolinks the full form everywhere and shortens it visually for
      # same-repo, so one format, no branching. Only issues created this run
      # are annotated; adopted/kept bodies are not ours to rewrite.
      #
      # @return [void]
      sig do
        params(entries: T::Array[SubtasksSection::Entry], refs: T::Hash[Integer, IssueRef]).void
      end
      def annotate_dependencies(entries, refs)
        entries.each_with_index do |entry, index|
          ref = refs.fetch(index)
          disposition = ref.disposition
          next unless disposition.is_a?(Disposition::Created)

          dependencies = entry.depends_on.filter_map { |dep_index| refs[dep_index] }
          next if dependencies.empty?

          depends_line = "Depends on: #{dependencies.map { |dep| "#{dep.repo}##{dep.number}" }.join(", ")}"
          @github.update_issue_body(
            ref.repo, ref.number,
            body: "#{disposition.body.rstrip}\n\n#{depends_line}\n",
          )
        end
      end

      # Close-with-comment, never delete: open sub-issues absent from the
      # spec are stale. Repo-aware — a cross-repo sub-issue closes in its own
      # repo.
      #
      # @return [void]
      sig do
        params(
          entries: T::Array[SubtasksSection::Entry],
          existing: T::Array[GitHub::Issue],
          refs: T::Hash[Integer, IssueRef],
          report: Report,
        ).void
      end
      def close_stale(entries, existing, refs, report)
        specified = refs.values.map { |ref| [ref.repo, ref.number] }
        stale = existing.select do |issue|
          issue.open? && !specified.include?([issue.repo, issue.number])
        end
        stale.each do |issue|
          @github.close_issue(
            issue.repo, issue.number,
            comment: "Closed by /split reconciliation: no longer part of the parent plan's subtask set.",
          )
        end
        report.closed.concat(stale)
      end

      # Canonicity transfer: the spec section becomes the linked map, so the
      # sub-issues are the single source of truth from here on.
      #
      # @return [void]
      sig do
        params(
          snapshot: String,
          entries: T::Array[SubtasksSection::Entry],
          refs: T::Hash[Integer, IssueRef],
        ).void
      end
      def rewrite_section(snapshot, entries, refs)
        lines = entries.each_with_index.map do |entry, index|
          ref = refs.fetch(index)
          "#{ref.repo}##{ref.number} — #{entry.title}#{map_annotation(ref.disposition)}"
        end
        guarded_patch(snapshot, SubtasksSection.replace(snapshot, SubtasksSection.render_applied(lines)))
      end

      # Only external-issue dispositions are annotated in the linked map —
      # /build --split reads them to know which nodes it cannot drive.
      #
      # @return [String]
      sig { params(disposition: Disposition).returns(String) }
      def map_annotation(disposition)
        case disposition
        when Disposition::Adopted then " (adopted)"
        when Disposition::Referenced then " (referenced)"
        when Disposition::Kept, Disposition::Created then ""
        else T.absurd(disposition)
        end
      end

      # ---- Result panels ----

      # @return [String]
      sig { params(report: Report).returns(String) }
      def apply_summary(report)
        sections = [
          ["created", report.created], ["adopted", report.adopted],
          ["referenced", report.referenced], ["kept", report.kept]
        ]
        counts = (sections.map { |label, rows| "#{label} #{rows.size}" } +
                  ["closed #{report.closed.size}"]).join(", ")
        lines = ["✅ **/split** — applied the subtask spec (#{counts})"]
        sections.each do |label, rows|
          rows.each do |row|
            lines << "- #{label} [#{row.ref.repo}##{row.ref.number} #{row.entry.title}](#{row.ref.url})"
          end
        end
        report.closed.each { |issue| lines << "- closed #{issue.repo}##{issue.number} #{issue.title} (stale)" }
        report.warnings.each { |warning| lines << "\n⚠️ #{warning}" }
        lines.join("\n")
      end

      # @return [String]
      sig { params(entries: T::Array[SubtasksSection::Entry], matches: Matches).returns(String) }
      def dry_summary(entries, matches)
        lines = ["📋 **/split --dry** — staged #{entries.size} subtasks in the `#{SubtasksSection::HEADER}` section"]
        entries.each { |entry| lines << "- #{entry.repo} — #{entry.title}" }
        unless matches.empty?
          lines << "\n#{matches.values.sum(&:size)} possible existing match(es) annotated in the section — promote them into `existing:` or delete the comments."
        end
        lines << "\nReview and edit the section, then comment `/split --apply`."
        lines.join("\n")
      end

      # @return [Array(String, Integer)]
      sig { params(ref: String).returns([String, Integer]) }
      def parse_issue_ref(ref)
        # T.must: an `existing:` ref passed validate_entry's owner/repo#n
        # shape check, so both parts are present.
        repo, number = ref.split("#", 2)
        [T.must(repo), Integer(T.must(number))]
      end

      # @return [String] GraphQL node id, memoized per repo
      sig { params(owner_repo: String).returns(String) }
      def repository_node_id(owner_repo)
        @repository_node_ids[owner_repo] ||= begin
          owner, name = owner_repo.split("/", 2)
          @github.graphql(REPOSITORY_ID_QUERY, { owner: owner, name: name }).fetch("repository").fetch("id")
        end
      end

      # @return [String] the parent issue's GraphQL node id
      sig { returns(String) }
      def parent_node_id
        @parent_node_id ||= begin
          owner, name = @context.owner_repo.split("/", 2)
          @github.graphql(ISSUE_ID_QUERY, { owner: owner, name: name, number: @context.number })
                 .fetch("repository").fetch("issue").fetch("id")
        end
      end
    end
  end
end
