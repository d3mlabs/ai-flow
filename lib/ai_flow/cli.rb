# typed: strict
# frozen_string_literal: true

require "stringio"

module AiFlow
  # The `ai-flow` executable's command surface (exe/ai-flow): the one place
  # argv becomes a subcommand, and the one rescue site where a typed error
  # becomes an exit status and a stderr line. A dependency's commands reach
  # a user through its own exe on PATH, not through dev surfacing them
  # (plans#76); this is ai-flow's.
  class Cli
    extend T::Sig

    # argv that names no command this exe has, or names one wrongly.
    class UsageError < StandardError; end

    USAGE = <<~USAGE
      usage: ai-flow <command> [args]

      commands:
        adopt <owner/repo>   converge the derivable steps of adopting ai-flow on a repository
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
    # @param github [AiFlow::GitHub] ambient gh auth by default — the
    #   human's own login, which adopt's org-side steps require
    sig { params(root: String, stdout: Stream, stderr: Stream, github: GitHub).void }
    def initialize(root:, stdout: $stdout, stderr: $stderr, github: GitHub.new(executor: Executor.new))
      @root = root
      @stdout = stdout
      @stderr = stderr
      @github = github
    end

    # @param argv [Array<String>]
    # @return [Integer] the exit status
    sig { params(argv: T::Array[String]).returns(Integer) }
    def run(argv)
      command, *args = argv
      case command
      when "adopt"
        Adopt.new(adoption: Adoption.new(github: @github, root: @root), stdout: @stdout).run(args)
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
