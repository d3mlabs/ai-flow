# typed: strict
# frozen_string_literal: true

require "ai_flow/executor"
require "ai_flow/github"

module AiFlow
  # A rebase of the checked-out branch onto its base, as git has it: one
  # operation that either applied, or stopped on conflicts and is waiting
  # in the working tree to be continued or aborted. Build starts one for a
  # PR GitHub reports as not mergeable (ai-flow#148), hands a stopped one's
  # unmerged paths to the agent, and continues it after the pass; the
  # policy is Build's, the git is here.
  #
  # Runs as the given identity (the App), so replayed commits keep their
  # author and carry the bot as committer, and with no editor, so a
  # `--continue` never waits on a message prompt. Every failure aborts the
  # rebase first: a rebase this class raises out of leaves the branch as
  # it was.
  class Rebase
    extend T::Sig

    # `git rebase` stopped for a reason other than conflicts — a dirty
    # tree, an unknown ref. Aborted.
    class FailedError < GitHub::Error; end

    # `continue!` found paths still unmerged: the agent left markers.
    # Aborted.
    class UnresolvedError < GitHub::Error; end

    # `continue!` stopped on a later commit of the branch — a second
    # resolution this run cannot take. Aborted.
    class StoppedAgainError < GitHub::Error; end

    # `rebase --continue` would open an editor for the replayed message.
    NO_EDITOR = T.let({ "GIT_EDITOR" => "true" }.freeze, T::Hash[String, String])

    # The base branch the head is rebased onto.
    sig { returns(String) }
    attr_reader :base

    # The paths the rebase stopped on; empty when it applied cleanly.
    sig { returns(T::Array[String]) }
    attr_reader :conflicts

    class << self
      extend T::Sig

      # Fetch the base and start the rebase.
      #
      # @param base [String] the base branch name
      # @param executor [Executor] process seam
      # @param workdir [String] the checkout, the branch checked out
      # @param identity [Array<String>] git's `-c user.name=… -c user.email=…` flags
      # @return [Rebase] applied (no conflicts) or stopped (its conflicts)
      # @raise [FailedError] stopped for any reason but conflicts; aborted
      sig { params(base: String, executor: Executor, workdir: String, identity: T::Array[String]).returns(Rebase) }
      def onto(base, executor:, workdir:, identity:)
        rebase = new(base: base, executor: executor, workdir: workdir, identity: identity)
        rebase.send(:start!)
        rebase
      end
    end

    # @param base [String]
    # @param executor [Executor]
    # @param workdir [String]
    # @param identity [Array<String>]
    sig { params(base: String, executor: Executor, workdir: String, identity: T::Array[String]).void }
    def initialize(base:, executor:, workdir:, identity:)
      @base = base
      @executor = executor
      @workdir = workdir
      @identity = identity
      @conflicts = T.let([], T::Array[String])
      @in_progress = T.let(false, T::Boolean)
    end

    # Whether the rebase is waiting in the working tree: it stopped on
    # conflicts and has been neither continued nor aborted. The object that
    # started it is the one that finishes it, so the state is its own.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def in_progress?
      @in_progress
    end

    # Finish a stopped rebase whose markers were resolved in the working
    # tree and staged.
    #
    # @return [void]
    # @raise [UnresolvedError] paths still unmerged; aborted
    # @raise [StoppedAgainError] a later commit conflicted; aborted
    sig { void }
    def continue!
      unresolved = unmerged_paths
      unless unresolved.empty?
        abort!
        raise UnresolvedError, "the rebase onto #{@base} was left unresolved (#{unresolved.join(", ")}) — " \
                               "aborted; the branch is as it was"
      end

      _out, err, ok = git("rebase", "--continue")
      if ok
        @in_progress = false
        return
      end

      abort!
      raise StoppedAgainError, "the rebase onto #{@base} stopped again on a later commit (#{err.strip}) — " \
                               "aborted; squash the branch or resolve it by hand, then /build again"
    end

    # @return [void]
    sig { void }
    def abort!
      git("rebase", "--abort")
      @in_progress = false
    end

    private

    # Fetch the base and run the rebase; a stop with unmerged paths is a
    # stopped rebase, any other failure is aborted and raised.
    #
    # @return [void]
    # @raise [FailedError]
    sig { void }
    def start!
      run!("git", "fetch", "origin", @base)
      _out, err, ok = git("rebase", "origin/#{@base}")
      return if ok

      conflicts = unmerged_paths
      if conflicts.empty?
        abort!
        raise FailedError, "git rebase origin/#{@base} failed: #{err.strip}"
      end

      @conflicts = conflicts
      @in_progress = true
    end

    # @return [Array<String>] the working tree's unmerged paths
    sig { returns(T::Array[String]) }
    def unmerged_paths
      out, = @executor.capture("git", "diff", "--name-only", "--diff-filter=U", chdir: @workdir)
      out.split("\n").map(&:strip).reject(&:empty?)
    end

    # `git <identity> rebase …`, no editor.
    #
    # @param args [Array<String>]
    # @return [Array(String, String, Boolean)] stdout, stderr, success
    sig { params(args: String).returns([String, String, T::Boolean]) }
    def git(*args)
      # T.unsafe: splatting a runtime-built argv into capture's rest param
      # is beyond Sorbet's static splat support (srb.help/7019).
      T.unsafe(@executor).capture("git", *@identity, *args, chdir: @workdir, env: NO_EDITOR)
    end

    # @param argv [Array<String>]
    # @return [void]
    # @raise [GitHub::Error] when the command fails
    sig { params(argv: String).void }
    def run!(*argv)
      _out, err, ok = T.unsafe(@executor).capture(*argv, chdir: @workdir)
      raise GitHub::Error, "#{argv.take(2).join(" ")} failed: #{err.strip}" unless ok
    end
  end
end
