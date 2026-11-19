# typed: strict
# frozen_string_literal: true

module AiFlow
  # The host's posture as the job found it: whether today's host still
  # satisfies the running dev's contract — users, sudoers edge, tooling
  # (`dev runner status --check`, dev#571). Posture is `dev runner
  # register`'s to converge (root); a job only inspects it, and refuses to
  # be quiet about drift: the workflow runs the check after installing the
  # dispatcher's dependencies and hands the verdict in as
  # AI_FLOW_HOST_POSTURE, and the command's reply carries one line naming
  # the runner, so a human sees it where they read results (ai-flow#140).
  #
  # The verdict is the workflow's vocabulary, not Actions' (a step outcome
  # of `failure` would say how the check was run, not what it found); the
  # workflow converts at its boundary and this class reads only the two
  # words. No verdict reads as converged: callers predating the check, and
  # local runs, say nothing about the host.
  class HostPosture
    extend T::Sig

    # The variable the workflow writes with the check's verdict.
    ENV_KEY = "AI_FLOW_HOST_POSTURE"

    # The runner's own name, set by the runner service in every job.
    RUNNER_NAME_KEY = "RUNNER_NAME"

    CONVERGED = "converged"
    DRIFTED = "drifted"

    # What the reply names when a drifted job carries no RUNNER_NAME —
    # never the case under Actions, so the line stays readable rather than
    # failing closed over a label.
    UNKNOWN_RUNNER = "an unnamed runner"

    # The workflow wrote the verdict, so a word outside the contract is a
    # broken caller, not a preference — fail closed.
    class InvalidPostureError < StandardError; end

    # @return [String] the runner the check ran on
    sig { returns(String) }
    attr_reader :runner_name

    class << self
      extend T::Sig

      # @param env [Hash{String => String, nil}] process env (injectable)
      # @return [HostPosture] the verdict the workflow recorded; converged
      #   when it recorded none
      # @raise [InvalidPostureError] when the verdict is neither word
      sig { params(env: T::Hash[String, T.nilable(String)]).returns(HostPosture) }
      def from_env(env = ENV.to_h)
        verdict = env[ENV_KEY].to_s.strip
        runner_name = env[RUNNER_NAME_KEY].to_s.strip
        runner_name = UNKNOWN_RUNNER if runner_name.empty?

        case verdict
        when "", CONVERGED then new(drifted: false, runner_name: runner_name)
        when DRIFTED then new(drifted: true, runner_name: runner_name)
        else
          raise InvalidPostureError,
            "#{ENV_KEY}=#{verdict} is not a posture verdict (#{CONVERGED} or #{DRIFTED})"
        end
      end
    end

    # @param drifted [Boolean] whether the check found a red fact
    # @param runner_name [String]
    sig { params(drifted: T::Boolean, runner_name: String).void }
    def initialize(drifted:, runner_name:)
      @drifted = drifted
      @runner_name = runner_name
    end

    # @return [Boolean] whether the host is behind the running dev's contract
    sig { returns(T::Boolean) }
    def drifted?
      @drifted
    end
  end
end
