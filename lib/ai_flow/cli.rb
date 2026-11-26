# typed: strict
# frozen_string_literal: true

require "stringio"

module AiFlow
  # The `ai-flow` executable's command surface (exe/ai-flow): the one place
  # argv becomes a subcommand, and the one rescue site where a typed error
  # becomes an exit status and a stderr line.
  #
  # Three commands, two callers (and `version`, which both read). `dispatch`
  # and `gate` are the job entry points the reusable workflows run on a
  # self-hosted runner; `adopt` is a human's, at a terminal. All share one
  # wiring, built here in
  # order: the TokenProvider first — `from_env` removes the App private key
  # from the process environment, so every subprocess spawned after it
  # (the agent above all) sees only short-lived installation tokens, never
  # the key — then the Executor on it, GitHub and the Agent on that. At a
  # terminal the same env holds no App credentials and the provider is
  # ambient: the human's own gh login, which adopt's org-side steps need.
  class Cli
    extend T::Sig

    # argv that names no command this exe has, or names one wrongly.
    class UsageError < StandardError; end

    USAGE = <<~USAGE
      usage: ai-flow <command> [args]

      commands:
        dispatch             run the slash-command dispatcher on the job's event (the ai-commands workflow)
        gate                 run the origin-firing check on the job's pull request (the origin-firing workflow)
        adopt <owner/repo>   converge the derivable steps of adopting ai-flow on a repository
        version              print this tree's version and the Ruby it runs under (the job log records which release ran)
        help                 this text
    USAGE

    # Where the exe writes: a real IO in use, a StringIO under test —
    # Ruby's two stream types share no ancestor below Object.
    Stream = T.type_alias { T.any(IO, StringIO) }

    # Exit statuses: a usage mistake is 2 (the shell convention), a
    # command that ran but found something to report is 1.
    EXIT_OK = 0
    EXIT_REPORTED = 1
    EXIT_USAGE = 2

    # @param root [String] the ai-flow tree this exe runs from (templates
    #   are read relative to it)
    # @param stdout [IO, StringIO]
    # @param stderr [IO, StringIO]
    # @param env [Hash-like] the process environment — the Actions job's
    #   for dispatch and gate; injectable for tests
    # @param executor [AiFlow::Executor] the one subprocess boundary, on
    #   the credentials the env carries
    # @param github [AiFlow::GitHub]
    # @param agent [AiFlow::Agent]
    sig do
      params(
        root: String, stdout: Stream, stderr: Stream, env: T.untyped, executor: Executor, github: GitHub, agent: Agent,
      ).void
    end
    def initialize(root:, stdout: $stdout, stderr: $stderr, env: ENV,
                   executor: Executor.new(token_provider: TokenProvider.from_env(env: env)),
                   github: GitHub.new(executor: executor), agent: Agent.new(executor: executor))
      @root = root
      @stdout = stdout
      @stderr = stderr
      @env = env
      @executor = executor
      @github = github
      @agent = agent
    end

    # @param argv [Array<String>]
    # @return [Integer] the exit status
    sig { params(argv: T::Array[String]).returns(Integer) }
    def run(argv)
      command, *args = argv
      case command
      when "dispatch"
        Dispatch.new(env: @env, executor: @executor, github: @github, agent: @agent, stdout: @stdout).run(args)
      when "gate"
        checks = ProposalChecks.new(github: @github, agent: @agent, executor: @executor)
        Gate.new(env: @env, checks: checks, stdout: @stdout).run(args)
      when "adopt"
        Adopt.new(adoption: Adoption.new(github: @github, root: @root), stdout: @stdout).run(args)
      when "version", "--version"
        # The version first, as one word: the reusable workflows read it
        # to check the dispatcher is their series. The Ruby is this
        # process's — the tree's own, not the project's.
        @stdout.puts("#{File.read(File.join(@root, Series::VERSION_FILE)).strip} (ruby #{RUBY_VERSION})")
        EXIT_OK
      when nil, "help", "--help", "-h"
        @stdout.print(USAGE)
        EXIT_OK
      else
        raise UsageError, "unknown command: #{command}\n#{USAGE}"
      end
    rescue UsageError => e
      # Every usage message ends in the usage text of the surface it is
      # about — this exe's, or the subcommand's.
      @stderr.puts("ai-flow: #{e.message}")
      EXIT_USAGE
    rescue GitHub::Error, Adoption::NoCheckoutError => e
      @stderr.puts("ai-flow: #{e.message}")
      EXIT_REPORTED
    end
  end
end
