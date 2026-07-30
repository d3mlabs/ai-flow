# typed: strict
# frozen_string_literal: true

module AiFlow
  module Commands
    # /build --split — orchestrator: read the sub-issues and their
    # "Depends on: owner/repo#n" metadata, topologically sort into waves, run
    # /build per sub-issue wave by wave, and ensure a final integration
    # sub-issue exists (created if the split didn't) built last. Progress is
    # a live per-wave checklist edited in place in the command comment — one
    # comment for the whole orchestration.
    #
    # Nodes the orchestrator cannot drive — adopted/referenced external
    # issues (owned by another effort or a human) and intended-repo
    # fallbacks (App not installed where the work must land) — are skipped
    # with an explicit warning, and their dependents are reported as blocked
    # until those issues close. No silent skips.
    class BuildSplit
      extend T::Sig

      INTEGRATION_TITLE_PREFIX = "Integration:"

      # One sub-issue's orchestration state, rendered exhaustively by
      # checklist_line. Absence from the progress map means "not built yet".
      module Progress
        extend T::Helpers
        include Kernel # is_a? for srb without the experimental requires_ancestor
        sealed!

        # /build opened a PR for the sub-issue.
        class Built
          extend T::Sig
          include Progress

          sig { returns(String) }
          attr_reader :url

          # @param url [String]
          sig { params(url: String).void }
          def initialize(url:)
            @url = url
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

        # A dependency is skipped, blocked, or an open external issue.
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
      # @param build [AiFlow::Commands::Build]
      # @param result_writer [AiFlow::ResultWriter]
      sig { params(context: Context, github: GitHub, build: Build, result_writer: ResultWriter).void }
      def initialize(context:, github:, build:, result_writer:)
        @context = context
        @github = github
        @build = build
        @result_writer = result_writer
      end

      # @param segment [CommentParser::Segment]
      # @return [void]
      sig { params(segment: CommentParser::Segment).void }
      def run(segment)
        parent = @github.issue(@context.owner_repo, @context.number)
        sub_issues = open_sub_issues
        raise GitHub::Error, "no open sub-issues — run /split first" if sub_issues.empty?

        sub_issues = ensure_integration_sub_issue(parent, sub_issues)
        progress = undrivable_progress(parent, sub_issues)
        waves = topological_waves(sub_issues, progress)
        publish_checklist(segment, waves, sub_issues, progress)

        waves.each do |wave|
          wave.each do |issue|
            progress[ref_of(issue)] =
              case (outcome = @build.build_issue(issue))
              when Build::Outcome::PrOpened then Progress::Built.new(url: outcome.url)
              when Build::Outcome::NothingToBuild then Progress::NoChanges.new
              else T.absurd(outcome)
              end
            publish_checklist(segment, waves, sub_issues, progress)
          end
        end
      end

      private

      # @return [String] "owner/repo#n" — the dependency key (numbers alone
      #   collide across repos now that sub-issues route cross-repo)
      sig { params(issue: GitHub::Issue).returns(String) }
      def ref_of(issue)
        "#{issue.repo}##{issue.number}"
      end

      # @return [Array<GitHub::Issue>]
      sig { returns(T::Array[GitHub::Issue]) }
      def open_sub_issues
        @github.sub_issues(@context.owner_repo, @context.number).select { |issue| issue.state == "open" }
      end

      # Pre-mark every node the orchestrator cannot drive, plus everything
      # (transitively) depending on one — those enter the checklist as
      # skipped/blocked and never reach the build loop.
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
          if (intended = issue.body[/^Intended repo:\s*(.+)$/, 1])
            progress[ref] = Progress::Skipped.new(
              reason: "fallback placeholder — the work lands in #{intended.strip}, " \
                      "where the ai-flow App is not installed",
            )
          elsif (annotation = annotations[ref])
            progress[ref] = Progress::Skipped.new(reason: "#{annotation} external issue — owned outside this plan")
          end
        end

        propagate_blocked(sub_issues, refs, progress)
        progress
      end

      # A dependent is blocked when any dependency is skipped/blocked, or is
      # an external issue (outside the sub-issue set) still open. Fixpoint
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
        entry.is_a?(Progress::Skipped) || entry.is_a?(Progress::Blocked)
      end

      # @return [Boolean] whether an out-of-set dependency is still open — a
      #   closed one is satisfied. Unreadable (no App access) counts as open:
      #   fail closed.
      sig { params(ref: String).returns(T::Boolean) }
      def external_issue_open?(ref)
        # T.must: a "owner/repo#n" ref always splits into two parts (refs come
        # from dependencies_of, which builds them fully qualified).
        repo, number = ref.split("#", 2)
        @github.issue(T.must(repo), Integer(T.must(number))).state == "open"
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
                "(cross-cutting wiring, shared refactors, end-to-end verification).\n\n#{depends_line}\n",
        )
        sub_issue_id = @github.api("repos/#{@context.owner_repo}/issues/#{created.number}").fetch("id")
        @github.add_sub_issue(@context.owner_repo, @context.number, sub_issue_id)
        sub_issues + [created]
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

      # The live checklist: one in-place edit per completed build. Skipped
      # and blocked nodes are listed under the waves with their reasons —
      # visible, never silent.
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
        undrivable = sub_issues.select { |issue| undrivable?(progress[ref_of(issue)]) }
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
        done = buildable.all? { |issue| progress.key?(ref_of(issue)) }
        suffix = undrivable.empty? ? "" : " (#{undrivable.size} skipped/blocked)"
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
          when Progress::Built then ["[x]", " — #{entry.url}"]
          when Progress::Skipped then ["[!]", " — #{entry.reason}"]
          when Progress::Blocked then ["[!]", " — #{entry.reason}"]
          else T.absurd(entry)
          end
        "- #{status} #{ref_of(issue)} #{issue.title}#{suffix}"
      end
    end
  end
end
