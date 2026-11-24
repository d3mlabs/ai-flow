# typed: strict
# frozen_string_literal: true

require "json"

module AiFlow
  class Cli
    # The Actions job a job entry point (`dispatch`, `gate`) runs in, read
    # from its environment: which event fired and where its payload is,
    # the checkout the job made, and the run page's step summary. The one
    # place the job env's keys are spelled, and the one place a run
    # outside a job is named — a terminal gets a usage error, not a
    # KeyError from deep inside a command.
    class Job
      extend T::Sig

      # The env carries no event: this is a terminal, not an Actions job.
      class NotUnderActionsError < UsageError; end

      EVENT_NAME_KEY = "GITHUB_EVENT_NAME"
      EVENT_PATH_KEY = "GITHUB_EVENT_PATH"
      # The reusable workflow's checkout of the target repo; the job's
      # working directory when the caller set none.
      WORKDIR_KEY = "AI_FLOW_WORKDIR"
      STEP_SUMMARY_KEY = "GITHUB_STEP_SUMMARY"

      # @return [Hash-like] the job's environment, for the collaborators
      #   that read their own keys from it (Context, HostPosture)
      sig { returns(T.untyped) }
      attr_reader :env

      # @param env [Hash-like] the process environment; injectable for tests
      # @param usage [String] the entry point's usage text, which a run
      #   outside a job ends in
      sig { params(env: T.untyped, usage: String).void }
      def initialize(env:, usage:)
        @env = env
        @usage = usage
      end

      # @return [String] GITHUB_EVENT_NAME
      # @raise [NotUnderActionsError]
      sig { returns(String) }
      def event_name
        job_value(EVENT_NAME_KEY)
      end

      # @return [String] GITHUB_EVENT_PATH
      # @raise [NotUnderActionsError]
      sig { returns(String) }
      def event_path
        job_value(EVENT_PATH_KEY)
      end

      # @return [Hash] the webhook payload the job was started for
      # @raise [NotUnderActionsError]
      sig { returns(T::Hash[String, T.untyped]) }
      def event_payload
        JSON.parse(File.read(event_path))
      end

      # @return [String] the checkout the job's commands run against
      sig { returns(String) }
      def workdir
        @env.fetch(WORKDIR_KEY, Dir.pwd)
      end

      # Add a report to the run page's step summary; nothing outside a job.
      #
      # @param report [String]
      # @return [void]
      sig { params(report: String).void }
      def append_step_summary(report)
        step_summary = @env[STEP_SUMMARY_KEY]
        File.write(step_summary, "#{report}\n", mode: "a") if step_summary
      end

      private

      # @param key [String] a key every Actions job sets
      # @return [String]
      # @raise [NotUnderActionsError]
      sig { params(key: String).returns(String) }
      def job_value(key)
        value = @env[key].to_s
        return value unless value.empty?

        raise NotUnderActionsError,
          "#{key} is not set — this command runs under an Actions job (the reusable workflows run it)\n#{@usage}"
      end
    end
  end
end
