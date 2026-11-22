# typed: strict
# frozen_string_literal: true

module AiFlow
  class Cli
    # `ai-flow dispatch`: the ai-commands workflow's entry point on the
    # self-hosted runner. Reads the webhook payload the job was started
    # for, expands it into the comments it carries, and runs a Dispatcher
    # over each. The exit decision is here: a job may run several
    # dispatches (ReviewUnit), every one runs even when an earlier one
    # failed, and any failure turns the run red at the end.
    class Dispatch
      extend T::Sig

      USAGE = T.let(<<~USAGE.freeze, String)
        usage: ai-flow dispatch

        Runs under an Actions job: GITHUB_EVENT_NAME and GITHUB_EVENT_PATH name the
        event, AI_FLOW_WORKDIR the target checkout (default: the working directory),
        AI_FLOW_COMMAND_PREFIX the caller's prefix (default: none). Exit 1 when any
        dispatched command failed.
      USAGE

      # The caller workflow's `command_prefix` input, for orgs with
      # clashing slash-command bots.
      PREFIX_KEY = "AI_FLOW_COMMAND_PREFIX"

      # @param env [Hash-like] the job's environment
      # @param executor [AiFlow::Executor]
      # @param github [AiFlow::GitHub]
      # @param agent [AiFlow::Agent]
      # @param stdout [IO, StringIO] the run log
      sig { params(env: T.untyped, executor: Executor, github: GitHub, agent: Agent, stdout: Stream).void }
      def initialize(env:, executor:, github:, agent:, stdout:)
        @job = T.let(Job.new(env: env, usage: USAGE), Job)
        @executor = executor
        @github = github
        @agent = agent
        @stdout = stdout
      end

      # @param args [Array<String>] everything after `dispatch`
      # @return [Integer] EXIT_OK when every dispatched command succeeded
      #   (clean no-ops included), EXIT_REPORTED otherwise
      # @raise [UsageError] on arguments, or outside an Actions job
      sig { params(args: T::Array[String]).returns(Integer) }
      def run(args)
        raise UsageError, "dispatch takes no arguments\n#{USAGE}" unless args.empty?

        # The Actions run page live-streams a running step's stdout;
        # unbuffered writes are what make the agent's progress lines
        # appear as they happen.
        @stdout.sync = true

        context = Context.from_event_file(event_name: @job.event_name, event_path: @job.event_path, env: @job.env)

        # Group-rw from creation: under the OS-user split (plans#26) the
        # dispatcher's own writes into shared checkouts and workspaces must
        # stay readable and writable across the UID boundary.
        File.umask(0o002) if @executor.isolation

        prefix = @job.env.fetch(PREFIX_KEY, "")
        # The workflow ran `dev runner status --check` before this and wrote
        # its verdict; drift reaches the command's reply, never fails the run.
        host_posture = HostPosture.from_env(@job.env.to_h)

        # A submitted review is one command surface carrying N comment bodies
        # (ai-flow#73): expand it into per-comment dispatches and run them
        # all in this one job — sequential, so the per-PR concurrency group
        # can no longer evict sibling commands.
        contexts = ReviewUnit.new(context: context, github: @github, prefix: prefix).contexts
        results = contexts.map do |dispatch_context|
          Dispatcher.new(
            context: dispatch_context,
            workdir: @job.workdir,
            prefix: prefix,
            executor: @executor,
            github: @github,
            agent: @agent,
            host_posture: host_posture,
          ).run
        end
        results.all? ? EXIT_OK : EXIT_REPORTED
      end
    end
  end
end
