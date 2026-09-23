# typed: strict
# frozen_string_literal: true

require "fileutils"

module AiFlow
  # The durable named workspace a repo opts into with `workspace:
  # persistent` (RepoConfig): one stable checkout per repo, reused across
  # /build runs so gitignored build state (e.g. Unreal's Intermediate/,
  # Binaries/) stays warm — the warm-machine philosophy applied to the
  # agent lane. Disposable tmpdir worktrees stay the default for every
  # repo that doesn't opt in.
  #
  # Two properties make reuse safe:
  #
  # - Every entry resyncs git state cold (fetch, reset --hard, detach on
  #   origin/<default>, clean -fd — deliberately not -x, ignored files are
  #   the warmth). Git rewrites only content-changed files, so mtimes stay
  #   old for untouched sources and incremental builds rebuild only what
  #   the branch touches. The stable absolute path keeps build tools'
  #   embedded-path records (UBT makefiles/action history) valid.
  # - A non-blocking flock serializes writers ("one workspace, one
  #   writer"): the GH concurrency group is queueing politeness, this lock
  #   is the correctness mechanism — it also guards against manual on-box
  #   resets mid-run. The lockfile lives *beside* the workspace so a full
  #   workspace nuke can never delete a held lock. True deadlock is
  #   impossible (single lock, all acquisitions non-blocking, the kernel
  #   releases flock on holder death); Ruby's default FD_CLOEXEC means
  #   spawned children never inherit the lock, so its lifetime is exactly
  #   this process's.
  class PersistentWorkspace
    extend T::Sig

    # Another holder (a run in flight, or an on-box reset) owns the
    # workspace — fail loudly rather than wait or corrupt.
    class BusyError < StandardError; end

    # Overrides the workspace root (ops escape hatch on the runner box).
    ROOT_ENV = "AI_FLOW_WORKSPACE_ROOT"

    # The isolated default. /tmp (the tmpdir base) is deliberately NOT
    # reused here: macOS purges /tmp on reboot and after ~3 days without
    # access, which would silently evict the warmth this class exists to
    # keep. /Users/Shared is the org's durable shared-machine root — world
    # -traversable like /tmp, so the agent user reaches the group-shared
    # leaf. (Linux isolated hosts set AI_FLOW_WORKSPACE_ROOT; today's only
    # persistent-workspace lane is the cb3d Mac.)
    ISOLATED_ROOT = "/Users/Shared/ai-flow/workspaces"

    # @param repo [String] "owner/repo" whose checkout persists
    # @param job_checkout [String] the runner's own repo checkout — the
    #   git dir the persistent worktree attaches to
    # @param executor [AiFlow::Executor]
    sig { params(repo: String, job_checkout: String, executor: Executor).void }
    def initialize(repo:, job_checkout:, executor:)
      @repo = repo
      @job_checkout = job_checkout
      @executor = executor
    end

    # The workspace root: env override, else the durable per-posture
    # default.
    #
    # @return [String]
    sig { returns(String) }
    def root
      override = ENV[ROOT_ENV].to_s.strip
      return override unless override.empty?

      @executor.isolation ? ISOLATED_ROOT : File.join(Dir.home, ".ai-flow", "workspaces")
    end

    # @return [String] the stable checkout path
    sig { returns(String) }
    def path
      File.join(root, @repo.tr("/", "-"))
    end

    # @return [String] the lockfile, beside the workspace (never inside)
    sig { returns(String) }
    def lock_path
      "#{path}.lock"
    end

    # Hold the workspace for one run: take the lock, create or resync the
    # checkout onto origin/<default_branch> (detached — the caller cuts
    # its branch, same contract as the tmpdir worktree flow), yield the
    # path. The lock releases when the block exits (or this process dies —
    # kernel semantics, no stale-lock ritual).
    #
    # @param default_branch [String]
    # @yieldparam path [String] the synced checkout
    # @return [Object] the block's value
    # @raise [BusyError] when another holder owns the workspace
    sig do
      type_parameters(:Result)
        .params(
          default_branch: String,
          blk: T.proc.params(path: String).returns(T.type_parameter(:Result)),
        ).returns(T.type_parameter(:Result))
    end
    def acquire(default_branch:, &blk)
      FileUtils.mkdir_p(root)
      # Group-shared root (setgid + 2770 under isolation, no-op without):
      # the worktree leaf created inside inherits the shared group, same
      # boundary the tmpdir flow puts on its parent.
      @executor.share_workspace(root)
      File.open(lock_path, File::CREAT | File::RDWR) do |lockfile|
        unless lockfile.flock(File::LOCK_EX | File::LOCK_NB)
          raise BusyError,
            "persistent workspace for #{@repo} is busy — another run or an on-box reset holds " \
            "#{lock_path}; run `lsof #{lock_path}` on the runner box to find the holder"
        end

        prepare(default_branch)
        yield path
      end
    end

    private

    # Create or resync the checkout. Unhealthy residue (a crashed run, a
    # reprovisioned job checkout that orphaned the worktree's git link) is
    # healed by recreating; healthy residue is resynced in place so
    # ignored build state survives.
    #
    # @param default_branch [String]
    # @return [void]
    sig { params(default_branch: String).void }
    def prepare(default_branch)
      run!(["git", "fetch", "origin", default_branch], chdir: @job_checkout)
      FileUtils.rm_rf(path) unless healthy?
      # After any removal, so a just-nuked registration is forgotten
      # before the re-add.
      run!(["git", "worktree", "prune"], chdir: @job_checkout)
      if File.exist?(path)
        resync(default_branch)
      else
        run!(["git", "worktree", "add", "--detach", path, "origin/#{default_branch}"], chdir: @job_checkout)
        @executor.share_workspace(path)
      end
    end

    # A prior run's git state, whatever it left behind, back to a clean
    # detached origin/<default>: reset heals index/merge residue against
    # the old HEAD, the detach moves off any stale branch, clean -fd drops
    # untracked files — never -x, gitignored build state is the point.
    #
    # @param default_branch [String]
    # @return [void]
    sig { params(default_branch: String).void }
    def resync(default_branch)
      run!(["git", "reset", "--hard"], chdir: path)
      run!(["git", "checkout", "--detach", "origin/#{default_branch}"], chdir: path)
      run!(["git", "clean", "-fd"], chdir: path)
    end

    # Whether the existing checkout is a live git worktree (its gitdir
    # link can be severed by a reprovisioned runner checkout).
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def healthy?
      return false unless File.exist?(path)

      _out, _err, ok = @executor.capture("git", "rev-parse", "--git-dir", chdir: path)
      ok
    end

    # @param argv [Array<String>] command and arguments
    # @param chdir [String] working directory
    # @raise [GitHub::Error] when the command fails
    sig { params(argv: T::Array[String], chdir: String).void }
    def run!(argv, chdir:)
      # T.unsafe: splatting a runtime-built argv into capture's rest param
      # is beyond Sorbet's static splat support (srb.help/7019).
      _out, err, ok = T.unsafe(@executor).capture(*argv, chdir: chdir)
      raise GitHub::Error, "#{argv.take(2).join(" ")} failed: #{err.strip}" unless ok
    end
  end
end
