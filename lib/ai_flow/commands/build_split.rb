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
      INTEGRATION_TITLE_PREFIX = "Integration:"

      # @param context [AiFlow::Context]
      # @param github [AiFlow::GitHub]
      # @param build [AiFlow::Commands::Build]
      # @param result_writer [AiFlow::ResultWriter]
      def initialize(context:, github:, build:, result_writer:)
        @context = context
        @github = github
        @build = build
        @result_writer = result_writer
      end

      # @param segment [CommentParser::Segment]
      # @return [void]
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
            pr = @build.build_issue(issue)
            progress[ref_of(issue)] = pr ? { state: :built, detail: pr.fetch("html_url") } : { state: :no_changes }
            publish_checklist(segment, waves, sub_issues, progress)
          end
        end
      end

      private

      # @return [String] "owner/repo#n" — the dependency key (numbers alone
      #   collide across repos now that sub-issues route cross-repo)
      def ref_of(issue)
        "#{issue.repo || @context.owner_repo}##{issue.number}"
      end

      # @return [Array<GitHub::Issue>]
      def open_sub_issues
        @github.sub_issues(@context.owner_repo, @context.number).select { |issue| issue.state == "open" }
      end

      # Pre-mark every node the orchestrator cannot drive, plus everything
      # (transitively) depending on one — those enter the checklist as
      # skipped/blocked and never reach the build loop.
      #
      # @return [Hash{String => Hash}] ref => { state:, detail: }
      def undrivable_progress(parent, sub_issues)
        annotations = SubtasksSection.applied_annotations(parent.body)
        refs = sub_issues.map { |issue| ref_of(issue) }
        progress = {}

        sub_issues.each do |issue|
          ref = ref_of(issue)
          if (intended = issue.body[/^Intended repo:\s*(.+)$/, 1])
            progress[ref] = { state: :skipped, detail: "fallback placeholder — the work lands in #{intended.strip}, " \
                                                       "where the ai-flow App is not installed" }
          elsif (annotation = annotations[ref])
            progress[ref] = { state: :skipped, detail: "#{annotation} external issue — owned outside this plan" }
          end
        end

        propagate_blocked(sub_issues, refs, progress)
        progress
      end

      # A dependent is blocked when any dependency is skipped/blocked, or is
      # an external issue (outside the sub-issue set) still open. Fixpoint
      # loop, since blockage travels along dependency chains.
      def propagate_blocked(sub_issues, refs, progress)
        loop do
          changed = false
          sub_issues.each do |issue|
            ref = ref_of(issue)
            next if progress.key?(ref)

            blocker = dependencies_of(issue).find { |dep| blocking?(dep, refs, progress) }
            next unless blocker

            progress[ref] = { state: :blocked, detail: "blocked until #{blocker} is resolved" }
            changed = true
          end
          break unless changed
        end
      end

      # @return [Boolean]
      def blocking?(dep, refs, progress)
        return %i[skipped blocked].include?(progress.dig(dep, :state)) if refs.include?(dep)

        external_issue_open?(dep)
      end

      # @return [Boolean] whether an out-of-set dependency is still open — a
      #   closed one is satisfied. Unreadable (no App access) counts as open:
      #   fail closed.
      def external_issue_open?(ref)
        repo, number = ref.split("#", 2)
        @github.issue(repo, Integer(number)).state == "open"
      rescue GitHub::Error
        true
      end

      # "Depends on:" refs, fully qualified — bare #n (legacy same-repo form)
      # resolves against the issue's own repo.
      #
      # @return [Array<String>] "owner/repo#n" refs
      def dependencies_of(issue)
        own_repo = issue.repo || @context.owner_repo
        issue.body.scan(/^Depends on:\s*(.+)$/).flatten.flat_map do |line|
          line.scan(%r{([\w.-]+/[\w.-]+)?#(\d+)}).map { |repo, number| "#{repo || own_repo}##{number}" }
        end
      end

      # The integration step must be its own sub-issue, built last. When the
      # split didn't create one, we do — depending on every other sub-issue
      # (so it stays blocked while any skipped node's work is outstanding).
      #
      # @return [Array<GitHub::Issue>] sub-issues including the integration one
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
      def topological_waves(sub_issues, progress)
        remaining = sub_issues.reject { |issue| progress.key?(ref_of(issue)) }
                              .to_h { |issue| [ref_of(issue), issue] }
        dependencies = remaining.transform_values do |issue|
          dependencies_of(issue).select { |dep| remaining.key?(dep) }
        end

        waves = []
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
      def publish_checklist(segment, waves, sub_issues, progress)
        undrivable = sub_issues.select { |issue| %i[skipped blocked].include?(progress.dig(ref_of(issue), :state)) }
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
      def checklist_line(issue, entry)
        status, suffix =
          case entry && entry.fetch(:state)
          when nil then ["[ ]", ""]
          when :no_changes then ["[-]", " — no changes needed"]
          when :built then ["[x]", " — #{entry.fetch(:detail)}"]
          else ["[!]", " — #{entry.fetch(:detail)}"]
          end
        "- #{status} #{ref_of(issue)} #{issue.title}#{suffix}"
      end
    end
  end
end
