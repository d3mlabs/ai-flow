# frozen_string_literal: true

module AiFlow
  module Commands
    # /build --split — orchestrator: read the sub-issues and their
    # "Depends on: #n" metadata, topologically sort into waves, run /build per
    # sub-issue wave by wave, and ensure a final integration sub-issue exists
    # (created if the split didn't) built last. Progress is a live per-wave
    # checklist edited in place in the command comment — one comment for the
    # whole orchestration.
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
        waves = topological_waves(sub_issues)

        progress = {}
        publish_checklist(segment, waves, progress)

        waves.each do |wave|
          wave.each do |issue|
            pr = @build.build_issue(issue)
            progress[issue.number] = pr ? pr.fetch("html_url") : :no_changes
            publish_checklist(segment, waves, progress)
          end
        end
      end

      private

      # @return [Array<GitHub::Issue>]
      def open_sub_issues
        @github.sub_issues(@context.owner_repo, @context.number).select { |issue| issue.state == "open" }
      end

      # The integration step must be its own sub-issue, built last. When the
      # split didn't create one, we do — depending on every other sub-issue.
      #
      # @return [Array<GitHub::Issue>] sub-issues including the integration one
      def ensure_integration_sub_issue(parent, sub_issues)
        return sub_issues if sub_issues.any? { |issue| issue.title.start_with?(INTEGRATION_TITLE_PREFIX) }

        depends_line = "Depends on: #{sub_issues.map { |issue| "##{issue.number}" }.join(", ")}"
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

      # Kahn's algorithm over the "Depends on: #n" convention, yielding waves
      # (all issues whose dependencies are already built). Dependencies outside
      # the sub-issue set are ignored; a cycle is a hard error.
      #
      # @return [Array<Array<GitHub::Issue>>]
      def topological_waves(sub_issues)
        numbers = sub_issues.map(&:number)
        remaining = sub_issues.to_h { |issue| [issue.number, issue] }
        dependencies = sub_issues.to_h do |issue|
          declared = issue.body.scan(/^Depends on:\s*(.+)$/).flatten.flat_map { |line| line.scan(/#(\d+)/).flatten }
          [issue.number, declared.map(&:to_i) & numbers]
        end

        waves = []
        until remaining.empty?
          ready = remaining.values.select { |issue| (dependencies.fetch(issue.number) - built(waves)).empty? }
          raise GitHub::Error, "dependency cycle among sub-issues: #{remaining.keys.join(", ")}" if ready.empty?

          waves << ready.sort_by(&:number)
          ready.each { |issue| remaining.delete(issue.number) }
        end
        waves
      end

      # @return [Array<Integer>] numbers already placed in earlier waves
      def built(waves)
        waves.flatten.map(&:number)
      end

      # The live checklist: one in-place edit per completed build.
      def publish_checklist(segment, waves, progress)
        lines = ["🔄 **/build --split** — building #{waves.flatten.size} sub-issues in #{waves.size} waves"]
        waves.each_with_index do |wave, index|
          lines << "\nWave #{index + 1}:"
          wave.each do |issue|
            status =
              case progress[issue.number]
              when nil then "[ ]"
              when :no_changes then "[-]"
              else "[x]"
              end
            suffix = progress[issue.number].is_a?(String) ? " — #{progress[issue.number]}" : ""
            suffix = " — no changes needed" if progress[issue.number] == :no_changes
            lines << "- #{status} ##{issue.number} #{issue.title}#{suffix}"
          end
        end
        done = progress.size == waves.flatten.size
        lines[0] = "✅ **/build --split** — built #{waves.flatten.size} sub-issues in #{waves.size} waves" if done
        @result_writer.write(@context, [[segment, lines.join("\n")]])
      end
    end
  end
end
