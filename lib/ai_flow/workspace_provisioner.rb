# typed: strict
# frozen_string_literal: true

module AiFlow
  # Equips a checkout before an agent pass runs in it: a dev project (one
  # carrying dev.yml) gets its locked toolchain and gems through `dev deps
  # install`, dispatcher-side, so the agent never meets a half-equipped
  # workspace and a missing pin is a `WANTED:` rather than a brew edge the
  # agent no longer has (ai-flow#99, plans#26 scenario G). It runs
  # dispatcher-side, as the runner user — the user whose brew prefix the
  # box was converged for — so the agent's own later `dev up` finds
  # everything installed and has nothing to write. Every command that
  # spawns the agent in a checkout provisions it the same way — /build its
  # worktrees and clones, /edit the job checkout, /learn its worktree and
  # clone (ai-flow#140). A checkout without dev.yml is not a dev project
  # and needs nothing.
  class WorkspaceProvisioner
    extend T::Sig

    DEV_PROJECT_FILE = "dev.yml"

    # `dev deps install` failed; the agent must not run on what is left.
    class ProvisionError < StandardError; end

    # @param executor [AiFlow::Executor] the process boundary
    sig { params(executor: Executor).void }
    def initialize(executor:)
      @executor = executor
    end

    # dev's install output streams to stdout as it happens: the job log is
    # ai-flow's observability surface and the run page follows stdout.
    #
    # @param repo [String] owner/repo, for the error message
    # @param checkout [String]
    # @return [void]
    # @raise [ProvisionError] when the install fails, carrying dev's stderr
    sig { params(repo: String, checkout: String).void }
    def provision(repo, checkout)
      return unless File.exist?(File.join(checkout, DEV_PROJECT_FILE))

      $stdout.puts "ai-flow provision: dev deps install (#{repo})"
      err, ok = @executor.stream("dev", "deps", "install", chdir: checkout) { |line| $stdout.puts(line) }
      return if ok

      raise ProvisionError, "#{repo} could not be provisioned — dev deps install failed: #{err.strip}"
    end
  end
end
