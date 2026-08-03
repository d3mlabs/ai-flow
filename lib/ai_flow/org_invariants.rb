# typed: strict
# frozen_string_literal: true

module AiFlow
  # The org invariants block a /build or /learn prompt carries into fresh
  # checkouts.
  #
  # In IDE sessions and long-lived checkouts, dev renders the always-on
  # invariants into .cursor/rules/org-invariants.mdc (dev's hooks own that
  # render). A /build worktree is created fresh — gitignored files don't
  # ride `git worktree add` — so the rendered rule is never there; the
  # prompt is the one surface we fully control, and this class splices the
  # block in.
  #
  # The block comes from `dev learnings invariants` — the read path's
  # command seam. Where invariants live (a git cache today, a derived cache
  # tomorrow) is dev's concern; ai-flow never reads dev's cache layout.
  # A machine where the command declines — no knowledge repo configured,
  # cache never synced, dev not provisioned — injects nothing: dev ships
  # only the mechanism, and a machine without the knowledge repo has no
  # invariants to carry.
  class OrgInvariants
    extend T::Sig

    # @param executor [AiFlow::Executor] the subprocess boundary the dev CLI
    #   is driven through (same standing as gh/git/agent)
    sig { params(executor: Executor).void }
    def initialize(executor: Executor.new)
      @executor = executor
    end

    # @return [String, nil] the prompt section carrying the invariants, nil
    #   when the command reports there is nothing to inject
    sig { returns(T.nilable(String)) }
    def prompt_block
      # The dev child resolves its own toolchain, never the dispatcher's
      # bundler env (#44 — the leak crashed dev and this method's graceful
      # nil hid the broken read path for every runner /build).
      out, err, ok = @executor.capture("dev", "learnings", "invariants", env: HarnessEnv.scrub)
      unless ok
        # Degrading is still right (a machine without the knowledge repo has
        # no invariants to carry), but the decline is named in the run log so
        # genuine breakage is visible.
        $stderr.puts "ai-flow: org invariants not injected — `dev learnings invariants` failed: #{err.strip}"
        return nil
      end

      body = out.strip
      return nil if body.empty?

      <<~BLOCK.strip
        ORG INVARIANTS — always-on engineering rules for this organization (this fresh checkout has no generated .cursor/rules/org-invariants.mdc render):

        #{body}

        Each → pointer is an on-demand skill installed under ~/.cursor/skills/ — read it before working in that entry's territory.
      BLOCK
    end
  end
end
