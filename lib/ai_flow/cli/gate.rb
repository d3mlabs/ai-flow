# typed: strict
# frozen_string_literal: true

module AiFlow
  class Cli
    # `ai-flow gate`: the origin-firing check, the origin-firing workflow's
    # entry point on a learning repo's pull requests. The job's payload
    # supplies only the PR's identity (repo, number, base ref); the check
    # reads the PR body live, so reruns and post-edit runs verify the
    # current marker, not the event's snapshot. Re-runs retrieval against
    # the proposal's origin context and fails the job when a changed
    # learning's cue does not fire (ProposalChecks).
    #
    # This boundary owns the CI verdict and every human-facing sentence:
    # the result type carries only facts. Out-of-scope results are green
    # (out-of-scope PRs must not block), and only checked results carry
    # the slug listings.
    class Gate
      extend T::Sig

      USAGE = T.let(<<~USAGE.freeze, String)
        usage: ai-flow gate

        Runs under an Actions job on a pull request: GITHUB_EVENT_PATH names the
        event, AI_FLOW_WORKDIR the PR checkout (default: the working directory).
        The verdict goes to stdout and the step summary. Exit 1 when a changed
        learning did not fire on its origin context.
      USAGE

      # @param env [Hash-like] the job's environment
      # @param checks [AiFlow::ProposalChecks]
      # @param stdout [IO, StringIO] the run log
      sig { params(env: T.untyped, checks: ProposalChecks, stdout: Stream).void }
      def initialize(env:, checks:, stdout:)
        @job = T.let(Job.new(env: env, usage: USAGE), Job)
        @checks = checks
        @stdout = stdout
      end

      # @param args [Array<String>] everything after `gate`
      # @return [Integer] EXIT_OK on a pass or an out-of-scope PR,
      #   EXIT_REPORTED on a fail
      # @raise [UsageError] on arguments, or outside an Actions job
      sig { params(args: T::Array[String]).returns(Integer) }
      def run(args)
        raise UsageError, "gate takes no arguments\n#{USAGE}" unless args.empty?

        @stdout.sync = true
        event = @job.event_payload
        pull_request = event.fetch("pull_request")
        result = @checks.origin_firing(
          workdir: @job.workdir,
          owner_repo: event.fetch("repository").fetch("full_name"),
          number: pull_request.fetch("number"),
          base_ref: pull_request.fetch("base").fetch("ref"),
        )

        lines, green = render(result)
        report = lines.join("\n")
        @stdout.puts(report)
        @job.append_step_summary(report)
        green ? EXIT_OK : EXIT_REPORTED
      end

      private

      # @param result [ProposalChecks::Result]
      # @return [Array(Array<String>, Boolean)] the report's lines and
      #   whether the check is green
      sig { params(result: ProposalChecks::Result).returns([T::Array[String], T::Boolean]) }
      def render(result)
        case result
        when ProposalChecks::Result::Pass
          [["✅ origin-firing (pass): every changed learning fired on its origin context",
            "changed learnings: #{result.new_slugs.join(", ")}",
            "fired on origin: #{result.fired.join(", ")}"], true]
        when ProposalChecks::Result::Fail
          [["❌ origin-firing (fail): did not fire on the origin context: " \
            "#{result.missing.map { |slug| "`#{slug}`" }.join(", ")} — " \
            "reword the index cue so the situation that produced the learning triggers it",
            "changed learnings: #{result.new_slugs.join(", ")}",
            "fired on origin: #{result.fired.empty? ? "(none)" : result.fired.join(", ")}"], false]
        when ProposalChecks::Result::StructureOnly
          [["ℹ️ origin-firing (skip): no skill files added or edited — structure-only " \
            "or removal diff, origin-firing not applicable"], true]
        when ProposalChecks::Result::Unmarked
          [["ℹ️ origin-firing (skip): no `learned-from:` marker in the PR body — not a captured " \
            "proposal (migration or manual PR), origin-firing not applicable"], true]
        else
          T.absurd(result)
        end
      end
    end
  end
end
