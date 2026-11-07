# typed: strict
# frozen_string_literal: true

module AiFlow
  module Commands
    # /build --split — orchestrator: read the sub-issues and their
    # "Depends on: owner/repo#n" metadata, topologically sort into waves,
    # fan each wave out as one /build per sub-issue, and ensure a final
    # integration sub-issue exists (created if the split didn't) built last.
    # Progress is a live per-wave checklist edited in place in the command
    # comment — one comment for the whole orchestration, one writer.
    #
    # A child is a `/build` comment this App posts on the sub-issue
    # (ai-flow#115) — `--base=<pr urls>` for the dependency PRs it stacks
    # on, `--for=<login>` for the human whose run this is — which the
    # workflow dispatches like a human's command (the authorize gate admits
    # comments performed via this App). The children of a wave run at once
    # on whatever runner slots their repos see; this job holds its own slot
    # and polls their comments for the outcome trailer each /build panel
    # ends in (Build::Outcome::Trailer), then moves to the next wave. The
    # orchestrator never builds in-process: without the App there is no
    # identity to post as, and the run refuses.
    #
    # Nodes the orchestrator cannot drive — adopted/referenced external
    # issues (owned by another effort or a human) and intended-repo
    # fallbacks (App not installed where the work must land) — are skipped
    # with an explicit warning, and their dependents are reported as blocked
    # until those issues close. No silent skips.
    class BuildSplit
      extend T::Sig

      INTEGRATION_TITLE_PREFIX = "Integration:"

      # Seconds between polls of a wave's children. Each poll is one API
      # read per running child; a child run is minutes long.
      DEFAULT_INTERVAL = 30

      class Error < StandardError; end

      # No App in the job env: the children would have to be posted as
      # github-actions[bot], whose comments the workflow never dispatches.
      class NoAppError < Error; end

      # One sub-issue's orchestration state, rendered exhaustively by
      # checklist_line. Absence from the progress map means "not built yet".
      module Progress
        extend T::Helpers
        include Kernel # is_a? for srb without the experimental requires_ancestor
        sealed!

        # /build opened PRs for the sub-issue (one per changed target;
        # multi-target sub-issues open several, plans#30). The PR objects
        # (not just urls) are kept: dependents stack on their repo/head
        # pairs.
        class Built
          extend T::Sig
          include Progress

          sig { returns(T::Array[GitHub::PullRequest]) }
          attr_reader :prs

          # @param prs [Array<GitHub::PullRequest>] non-empty, primary first
          sig { params(prs: T::Array[GitHub::PullRequest]).void }
          def initialize(prs:)
            @prs = prs
          end
        end

        # /build ran but the pass produced no code changes.
        class NoChanges
          include Progress
        end

        # The orchestrator cannot drive this node (external issue or
        # intended-repo fallback) — never enters a wave.
        class Skipped
          extend T::Sig
          include Progress

          sig { returns(String) }
          attr_reader :reason

          # @param reason [String]
          sig { params(reason: String).void }
          def initialize(reason:)
            @reason = reason
          end
        end

        # A human step (`manual: true` in the spec, `(manual)` in the applied
        # map): a ruleset, a grant, an App install. Not failure, not an
        # external owner — just not /build's to do. Never enters a wave;
        # dependents wait until the human closes it.
        class Manual
          include Progress
        end

        # /build found the repo's persistent workspace held by another run
        # and did not start (Build::Outcome::Busy — ai-flow#116). Not done,
        # not failed: a later `/build --split` drives it; dependents wait.
        class Deferred
          extend T::Sig
          include Progress

          sig { returns(String) }
          attr_reader :reason

          # @param reason [String] the hold, in the workspace's words
          sig { params(reason: String).void }
          def initialize(reason:)
            @reason = reason
          end
        end

        # The child /build is posted and has not reported yet.
        class Running
          extend T::Sig
          include Progress

          sig { returns(String) }
          attr_reader :repo

          sig { returns(Integer) }
          attr_reader :comment_id

          sig { returns(String) }
          attr_reader :comment_url

          # @param repo [String] the sub-issue's repo (the comment's)
          # @param comment_id [Integer] the posted /build comment
          # @param comment_url [String]
          sig { params(repo: String, comment_id: Integer, comment_url: String).void }
          def initialize(repo:, comment_id:, comment_url:)
            @repo = repo
            @comment_id = comment_id
            @comment_url = comment_url
          end
        end

        # The child /build failed (its panel is the ⚠️ one). Blocks
        # dependents like any undrivable node; the rest of the plan goes on.
        class Failed
          extend T::Sig
          include Progress

          sig { returns(String) }
          attr_reader :comment_url

          # @param comment_url [String] the child's command comment, where
          #   the failure reads
          sig { params(comment_url: String).void }
          def initialize(comment_url:)
            @comment_url = comment_url
          end
        end

        # A dependency is skipped, manual, blocked, deferred, failed, or an
        # open external issue.
        class Blocked
          extend T::Sig
          include Progress

          sig { returns(String) }
          attr_reader :reason

          # @param reason [String]
          sig { params(reason: String).void }
          def initialize(reason:)
            @reason = reason
          end
        end
      end

      # @param context [AiFlow::Context]
      # @param github [AiFlow::GitHub]
      # @param result_writer [AiFlow::ResultWriter]
      # @param interval [Integer] seconds between polls
      # @param sleeper [#call] what waits `interval` seconds — Kernel#sleep,
      #   or a recorder in tests
      sig do
        params(
          context: Context,
          github: GitHub,
          result_writer: ResultWriter,
          interval: Integer,
          sleeper: T.proc.params(seconds: Integer).void,
        ).void
      end
      def initialize(context:, github:, result_writer:, interval: DEFAULT_INTERVAL, sleeper: ->(seconds) { sleep(seconds) })
        @context = context
        @github = github
        @result_writer = result_writer
        @interval = interval
        @sleeper = sleeper
      end

      # @param segment [CommentParser::Segment]
      # @return [void]
      sig { params(segment: CommentParser::Segment).void }
      def run(segment)
        unless @context.app_configured?
          raise NoAppError, "/build --split fans out as /build comments posted by the ai-flow App, " \
                            "and this run has no App (allow_token_fallback) — register the App to use it."
        end

        parent = @github.issue(@context.owner_repo, @context.number)
        sub_issues = open_sub_issues
        raise GitHub::Error, "no open sub-issues — run /split first" if sub_issues.empty?

        sub_issues = ensure_integration_sub_issue(parent, sub_issues)
        progress = undrivable_progress(parent, sub_issues)
        waves = topological_waves(sub_issues, progress)
        publish_checklist(segment, waves, sub_issues, progress)

        waves.each do |wave|
          wave.each do |issue|
            progress[ref_of(issue)] = blocked_by_run(issue, progress) || post_child(issue, progress)
          end
          publish_checklist(segment, waves, sub_issues, progress)
          await_wave(segment, wave, waves, sub_issues, progress)
        end
      end

      private

      # Post one sub-issue's child /build, carrying its dependencies' PRs
      # and the requesting human.
      #
      # @param issue [GitHub::Issue]
      # @param progress [Hash{String => Progress}] ref => progress so far
      # @return [Progress::Running]
      sig { params(issue: GitHub::Issue, progress: T::Hash[String, Progress]).returns(Progress::Running) }
      def post_child(issue, progress)
        comment = @github.post_issue_comment(issue.repo, issue.number, child_command(issue, progress))
        Progress::Running.new(repo: issue.repo, comment_id: comment.id, comment_url: comment.html_url)
      end

      # @param issue [GitHub::Issue]
      # @param progress [Hash{String => Progress}]
      # @return [String] the child's command line
      sig { params(issue: GitHub::Issue, progress: T::Hash[String, Progress]).returns(String) }
      def child_command(issue, progress)
        urls = base_prs_for(issue, progress).map(&:html_url)
        words = ["/build"]
        words << "--base=#{urls.join(",")}" unless urls.empty?
        words << "--for=#{@context.commenter_login}" if @context.commenter_login
        words.join(" ")
      end

      # Poll the wave's running children until every one has reported,
      # re-publishing the checklist after each poll — one writer, reading
      # the children's own comments rather than trusting memory.
      #
      # @return [void] mutates `progress` in place
      sig do
        params(
          segment: CommentParser::Segment,
          wave: T::Array[GitHub::Issue],
          waves: T::Array[T::Array[GitHub::Issue]],
          sub_issues: T::Array[GitHub::Issue],
          progress: T::Hash[String, Progress],
        ).void
      end
      def await_wave(segment, wave, waves, sub_issues, progress)
        loop do
          running = wave.select { |issue| progress[ref_of(issue)].is_a?(Progress::Running) }
          break if running.empty?

          @sleeper.call(@interval)
          running.each do |issue|
            entry = T.cast(progress.fetch(ref_of(issue)), Progress::Running)
            progress[ref_of(issue)] = read_child(entry)
          end
          publish_checklist(segment, waves, sub_issues, progress)
        end
      end

      # Read a child's comment: no trailer yet means still running;
      # otherwise the trailer's kind is the node's progress.
      #
      # @param entry [Progress::Running]
      # @return [Progress]
      sig { params(entry: Progress::Running).returns(Progress) }
      def read_child(entry)
        trailer = Build::Outcome::Trailer.parse(@github.issue_comment(entry.repo, entry.comment_id).body)
        return entry unless trailer

        case (kind = trailer.kind)
        when Build::Outcome::Trailer::Kind::PrOpened
          Progress::Built.new(prs: trailer.pr_urls.map { |url| @github.pull_request(*GitHub.parse_pull_request_url(url)) })
        when Build::Outcome::Trailer::Kind::NothingToBuild then Progress::NoChanges.new
        when Build::Outcome::Trailer::Kind::Busy
          Progress::Deferred.new(reason: "its persistent workspace was held by another run (#{entry.comment_url})")
        when Build::Outcome::Trailer::Kind::Failed then Progress::Failed.new(comment_url: entry.comment_url)
        else T.absurd(kind)
        end
      end

      # Blockage that arose during this run — a dependency deferred by a
      # held workspace, or failed — which the pre-run pass
      # (undrivable_progress) could not know. Same reason text as the
      # pre-run blocking, so a reader sees one notion.
      #
      # @param issue [GitHub::Issue]
      # @param progress [Hash{String => Progress}] ref => progress so far
      # @return [Progress::Blocked, nil]
      sig { params(issue: GitHub::Issue, progress: T::Hash[String, Progress]).returns(T.nilable(Progress::Blocked)) }
      def blocked_by_run(issue, progress)
        blocker = dependencies_of(issue).find { |dep| undrivable?(progress[dep]) }
        blocker && Progress::Blocked.new(reason: "blocked until #{blocker} is resolved")
      end

      # The dependency PRs a stacked build cuts its branches from: every
      # already-built dependency contributes its PRs, dependency order
      # preserved. Satisfied externals and no-change builds have no PRs —
      # a dependent left with none forks from the default branch (Build
      # owns that fallback, per target repo).
      #
      # @param issue [GitHub::Issue]
      # @param progress [Hash{String => Progress}] ref => progress so far
      # @return [Array<GitHub::PullRequest>]
      sig do
        params(issue: GitHub::Issue, progress: T::Hash[String, Progress])
          .returns(T::Array[GitHub::PullRequest])
      end
      def base_prs_for(issue, progress)
        dependencies_of(issue).flat_map do |dep|
          entry = progress[dep]
          entry.is_a?(Progress::Built) ? entry.prs : []
        end
      end

      # @return [String] "owner/repo#n" — the dependency key (numbers alone
      #   collide across repos now that sub-issues route cross-repo)
      sig { params(issue: GitHub::Issue).returns(String) }
      def ref_of(issue)
        "#{issue.repo}##{issue.number}"
      end

      # @return [Array<GitHub::Issue>]
      sig { returns(T::Array[GitHub::Issue]) }
      def open_sub_issues
        @github.sub_issues(@context.owner_repo, @context.number).select(&:open?)
      end

      # Pre-mark every node the orchestrator does not drive (external owner,
      # fallback placeholder, human step), plus everything (transitively)
      # depending on one — those enter the checklist under "not driven" and
      # never reach the build loop. A manual node is a human's regardless of
      # who owns the issue, so `manual` wins over adopted/referenced.
      #
      # @return [Hash{String => Progress}] ref => progress
      sig do
        params(parent: GitHub::Issue, sub_issues: T::Array[GitHub::Issue])
          .returns(T::Hash[String, Progress])
      end
      def undrivable_progress(parent, sub_issues)
        annotations = SubtasksSection.applied_annotations(parent.body)
        refs = sub_issues.map { |issue| ref_of(issue) }
        progress = T.let({}, T::Hash[String, Progress])

        sub_issues.each do |issue|
          ref = ref_of(issue)
          tokens = annotations.fetch(ref, [])
          if tokens.include?("manual")
            progress[ref] = Progress::Manual.new
          elsif (intended = issue.body[/^Intended repo:\s*(.+)$/, 1])
            progress[ref] = Progress::Skipped.new(
              reason: "fallback placeholder — the work lands in #{intended.strip}, " \
                      "where the ai-flow App is not installed",
            )
          elsif (disposition = tokens.first)
            progress[ref] = Progress::Skipped.new(reason: "#{disposition} external issue — owned outside this plan")
          end
        end

        propagate_blocked(sub_issues, refs, progress)
        progress
      end

      # A dependent is blocked when any dependency is not driven (skipped,
      # manual, blocked), or is an external issue (outside the sub-issue
      # set) still open. A closed manual step is not in the open sub-issue
      # set at all, so its dependents are free on the next run. Fixpoint
      # loop, since blockage travels along dependency chains.
      #
      # @return [void] mutates `progress` in place
      sig do
        params(
          sub_issues: T::Array[GitHub::Issue],
          refs: T::Array[String],
          progress: T::Hash[String, Progress],
        ).void
      end
      def propagate_blocked(sub_issues, refs, progress)
        loop do
          changed = T.let(false, T::Boolean)
          sub_issues.each do |issue|
            ref = ref_of(issue)
            next if progress.key?(ref)

            blocker = dependencies_of(issue).find { |dep| blocking?(dep, refs, progress) }
            next unless blocker

            progress[ref] = Progress::Blocked.new(reason: "blocked until #{blocker} is resolved")
            changed = true
          end
          break unless changed
        end
      end

      # @return [Boolean]
      sig do
        params(dep: String, refs: T::Array[String], progress: T::Hash[String, Progress])
          .returns(T::Boolean)
      end
      def blocking?(dep, refs, progress)
        return undrivable?(progress[dep]) if refs.include?(dep)

        external_issue_open?(dep)
      end

      # @return [Boolean] whether the entry marks a node the orchestration
      #   will not build
      sig { params(entry: T.nilable(Progress)).returns(T::Boolean) }
      def undrivable?(entry)
        entry.is_a?(Progress::Skipped) || entry.is_a?(Progress::Manual) || entry.is_a?(Progress::Blocked) ||
          entry.is_a?(Progress::Deferred) || entry.is_a?(Progress::Failed)
      end

      # @return [Boolean] whether an out-of-set dependency is still open — a
      #   closed one is satisfied. Unreadable (no App access) counts as open:
      #   fail closed.
      sig { params(ref: String).returns(T::Boolean) }
      def external_issue_open?(ref)
        # T.must: a "owner/repo#n" ref always splits into two parts (refs come
        # from dependencies_of, which builds them fully qualified).
        repo, number = ref.split("#", 2)
        @github.issue(T.must(repo), Integer(T.must(number))).open?
      rescue GitHub::Error
        true
      end

      # "Depends on:" refs, fully qualified — bare #n (legacy same-repo form)
      # resolves against the issue's own repo.
      #
      # @return [Array<String>] "owner/repo#n" refs
      sig { params(issue: GitHub::Issue).returns(T::Array[String]) }
      def dependencies_of(issue)
        own_repo = issue.repo
        # T.cast: grouped scans yield capture arrays, but the stdlib RBI
        # types them as a union the block destructuring can't see through.
        depends_lines = T.cast(issue.body.scan(/^Depends on:\s*(.+)$/), T::Array[T::Array[String]])
        depends_lines.flat_map do |captures|
          refs = T.cast(
            captures.fetch(0).scan(%r{([\w.-]+/[\w.-]+)?#(\d+)}),
            T::Array[T::Array[T.nilable(String)]],
          )
          refs.map { |repo, number| "#{repo || own_repo}##{number}" }
        end
      end

      # The integration step must be its own sub-issue, built last. When the
      # split didn't create one, we do — depending on every other sub-issue
      # (so it stays blocked while any skipped node's work is outstanding).
      #
      # @return [Array<GitHub::Issue>] sub-issues including the integration one
      sig do
        params(parent: GitHub::Issue, sub_issues: T::Array[GitHub::Issue])
          .returns(T::Array[GitHub::Issue])
      end
      def ensure_integration_sub_issue(parent, sub_issues)
        return sub_issues if sub_issues.any? { |issue| issue.title.start_with?(INTEGRATION_TITLE_PREFIX) }

        depends_line = "Depends on: #{sub_issues.map { |issue| ref_of(issue) }.join(", ")}"
        created = @github.create_issue(
          @context.owner_repo,
          title: "#{INTEGRATION_TITLE_PREFIX} #{parent.title}",
          body: "Integrate the sub-issue builds of ##{parent.number} into a coherent whole " \
                "(cross-cutting wiring, shared refactors, end-to-end verification).\n\n" \
                "#{integration_targets_line(parent, sub_issues)}#{depends_line}\n",
        )
        sub_issue_id = @github.api("repos/#{@context.owner_repo}/issues/#{created.number}").fetch("id")
        @github.add_sub_issue(@context.owner_repo, @context.number, sub_issue_id)
        sub_issues + [created]
      end

      # The integration build must check out the code the siblings landed
      # in, not this (possibly code-less) planning repo: inherit the
      # parent's Target repos: line, else declare the sub-issues' own
      # repos. Same-repo plans keep an unadorned body — the issue's repo is
      # the implicit target.
      #
      # @return [String] a "Target repos: …\n" line, "" when the parent's
      #   repo is the only target
      sig { params(parent: GitHub::Issue, sub_issues: T::Array[GitHub::Issue]).returns(String) }
      def integration_targets_line(parent, sub_issues)
        declared = parent.body[/^Target repos?:\s*(.+)$/, 1]
        return "Target repos: #{declared.strip}\n" if declared

        repos = sub_issues.map(&:repo).uniq
        repos == [@context.owner_repo] ? "" : "Target repos: #{repos.join(", ")}\n"
      end

      # Kahn's algorithm over the "Depends on:" convention, yielding waves
      # (all issues whose dependencies are already built). Skipped/blocked
      # nodes never enter a wave; satisfied external dependencies (closed
      # issues) are ignored; a cycle is a hard error.
      #
      # @return [Array<Array<GitHub::Issue>>]
      sig do
        params(sub_issues: T::Array[GitHub::Issue], progress: T::Hash[String, Progress])
          .returns(T::Array[T::Array[GitHub::Issue]])
      end
      def topological_waves(sub_issues, progress)
        remaining = sub_issues.reject { |issue| progress.key?(ref_of(issue)) }
                              .to_h { |issue| [ref_of(issue), issue] }
        dependencies = remaining.transform_values do |issue|
          dependencies_of(issue).select { |dep| remaining.key?(dep) }
        end

        waves = T.let([], T::Array[T::Array[GitHub::Issue]])
        until remaining.empty?
          built = waves.flatten.map { |issue| ref_of(issue) }
          ready = remaining.values.select { |issue| (dependencies.fetch(ref_of(issue)) - built).empty? }
          raise GitHub::Error, "dependency cycle among sub-issues: #{remaining.keys.join(", ")}" if ready.empty?

          waves << ready.sort_by(&:number)
          ready.each { |issue| remaining.delete(ref_of(issue)) }
        end
        waves
      end

      # The live checklist: one in-place edit per wave posted and per poll.
      # Nodes the run does not drive (skipped, manual, blocked) are listed
      # under the waves with their reasons — visible, never silent.
      #
      # @return [void]
      sig do
        params(
          segment: CommentParser::Segment,
          waves: T::Array[T::Array[GitHub::Issue]],
          sub_issues: T::Array[GitHub::Issue],
          progress: T::Hash[String, Progress],
        ).void
      end
      def publish_checklist(segment, waves, sub_issues, progress)
        # Nodes the run marked mid-way (deferred, blocked on a deferral)
        # stay on their wave line; this section is for the pre-run set.
        scheduled = waves.flatten
        undrivable = sub_issues.select { |issue| undrivable?(progress[ref_of(issue)]) && !scheduled.include?(issue) }
        lines = [checklist_headline(waves, undrivable, progress)]
        waves.each_with_index do |wave, index|
          lines << "\nWave #{index + 1}:"
          wave.each { |issue| lines << checklist_line(issue, progress[ref_of(issue)]) }
        end
        unless undrivable.empty?
          lines << "\n⚠️ Not driven by this orchestration:"
          undrivable.each { |issue| lines << checklist_line(issue, progress[ref_of(issue)]) }
        end
        @result_writer.write(@context, [[segment, lines.join("\n")]])
      end

      # @return [String]
      sig do
        params(
          waves: T::Array[T::Array[GitHub::Issue]],
          undrivable: T::Array[GitHub::Issue],
          progress: T::Hash[String, Progress],
        ).returns(String)
      end
      def checklist_headline(waves, undrivable, progress)
        buildable = waves.flatten
        done = buildable.all? { |issue| progress.key?(ref_of(issue)) && !progress[ref_of(issue)].is_a?(Progress::Running) }
        suffix = undrivable.empty? ? "" : " (#{undrivable.size} not driven by this run)"
        if done
          "#{undrivable.empty? ? "✅" : "⚠️"} **/build --split** — built #{buildable.size} sub-issues " \
            "in #{waves.size} waves#{suffix}"
        else
          "🔄 **/build --split** — building #{buildable.size} sub-issues in #{waves.size} waves#{suffix}"
        end
      end

      # @return [String]
      sig { params(issue: GitHub::Issue, entry: T.nilable(Progress)).returns(String) }
      def checklist_line(issue, entry)
        status, suffix =
          case entry
          when nil then ["[ ]", ""]
          when Progress::NoChanges then ["[-]", " — no changes needed"]
          when Progress::Built then ["[x]", " — #{entry.prs.map(&:html_url).join(", ")}"]
          when Progress::Skipped then ["[!]", " — #{entry.reason}"]
          when Progress::Manual then ["[ ]", " — manual: a human does this step; close it when done"]
          when Progress::Deferred then ["[ ]", " — deferred: #{entry.reason}; re-run `/build --split` when it is free"]
          when Progress::Running then ["[ ]", " — running: #{entry.comment_url}"]
          when Progress::Failed then ["[!]", " — failed: #{entry.comment_url}"]
          when Progress::Blocked then ["[!]", " — #{entry.reason}"]
          else T.absurd(entry)
          end
        "- #{status} #{ref_of(issue)} #{issue.title}#{suffix}"
      end
    end
  end
end
