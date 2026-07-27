# frozen_string_literal: true

module AiFlow
  # The origin-firing check (docs/paper.md §6.2/§15.6): the cheapest gate on
  # a draft learning PR. A learning distilled from thread X must actually
  # load when retrieval re-runs against X's context — if the new cue does not
  # fire on the very situation that produced it, the draft fails before any
  # outcome measurement.
  #
  # Runs as a PR-status job (workflows/origin-firing.yml): one agent pass is
  # handed the PR's own index (as a session would see it) plus the origin
  # thread's conversation replayed as a fresh task, and must declare which
  # learnings it would consult. Every skill the PR adds or edits must be in
  # that set.
  #
  # Deliberately v0-cheap (single-shot): cue firing is stochastic (§6.2), so
  # a marginal cue can flake — re-run the job for a second opinion; the
  # statistical form (n replicates, TOST margins) is the §15.6 follow-up and
  # belongs to the retrieval-equivalence suite.
  class OriginFiringCheck
    # The provenance marker every capture form writes into its draft PR body.
    ORIGIN_MARKER = %r{learned-from:\s*([\w.-]+/[\w.-]+)#(\d+)}

    # Learning index files, org layout first (the knowledge repo) then the
    # per-repo layout — the check is layout-agnostic so any learnings-bearing
    # repo can adopt it.
    INDEX_PATHS = ["index.md", ".cursor/rules/learnings-index.mdc"].freeze

    # Diff paths that identify a changed *skill* (the content half of a
    # learning; capture group = slug). Index-only edits are structure diffs
    # and out of this check's scope.
    SKILL_PATHS = [
      %r{\Askills/([^/]+)/},
      %r{\A\.cursor/skills/(?:learnings|architecture)/([^/]+)/},
    ].freeze

    # The declarative output contract the prompt imposes on the agent pass.
    FIRED_LINE = /^FIRED:\s*(.+?)\s*$/

    Result = Struct.new(:status, :detail, :new_slugs, :fired, keyword_init: true) do
      # A skip is a pass for CI purposes: structure-only and unmarked
      # (migration/manual) PRs are legitimately outside the check's scope.
      def pass?
        status != :fail
      end
    end

    # @param github [AiFlow::GitHub] origin-thread reads (cross-repo capable)
    # @param agent [AiFlow::Agent] the retrieval re-run
    # @param executor [AiFlow::Executor] git diff against the PR base
    # @param workdir [String] the PR checkout (merge ref, full history)
    # @param pr_body [String] the draft PR's body (carries the origin marker)
    # @param base_ref [String] the PR's base branch name
    def initialize(github:, agent:, executor:, workdir:, pr_body:, base_ref:)
      @github = github
      @agent = agent
      @executor = executor
      @workdir = workdir
      @pr_body = pr_body
      @base_ref = base_ref
    end

    # @return [Result]
    def run
      slugs = new_learning_slugs
      return skip("no skill files changed — structure-only diff, origin-firing not applicable") if slugs.empty?

      origin = origin_ref
      unless origin
        return skip("no `learned-from:` marker in the PR body — not a captured draft " \
                    "(migration or manual PR), origin-firing not applicable")
      end

      fired = rerun_retrieval(origin)
      missing = slugs - fired
      if missing.empty?
        Result.new(status: :pass, new_slugs: slugs, fired: fired,
                   detail: "every changed learning fired on its origin context")
      else
        Result.new(status: :fail, new_slugs: slugs, fired: fired,
                   detail: "did not fire on the origin context: #{missing.map { |slug| "`#{slug}`" }.join(", ")} — " \
                           "reword the index cue so the situation that produced the learning triggers it")
      end
    end

    private

    def skip(reason)
      Result.new(status: :skip, detail: reason, new_slugs: [], fired: [])
    end

    # The skills this PR adds or edits, from the merge-base diff (three-dot,
    # so a stale base branch never pollutes the file list).
    #
    # @return [Array<String>] slugs
    def new_learning_slugs
      out, err, ok = @executor.capture(
        "git", "diff", "--name-only", "origin/#{@base_ref}...HEAD", chdir: @workdir,
      )
      raise Error, "git diff against origin/#{@base_ref} failed: #{err.strip}" unless ok

      out.split("\n").filter_map { |path| slug_for(path) }.uniq
    end

    # @return [String, nil] the skill slug a diff path belongs to
    def slug_for(path)
      SKILL_PATHS.each do |pattern|
        match = pattern.match(path)
        return match[1] if match
      end
      nil
    end

    # @return [Array(String, Integer), nil] ["owner/repo", number], nil when
    #   the body carries no capture provenance
    def origin_ref
      match = ORIGIN_MARKER.match(@pr_body)
      match && [match[1], Integer(match[2])]
    end

    # One declarative agent pass: the PR's index as the always-on context,
    # the origin thread replayed as the task. Parsing keys on the FIRED
    # contract line, never on prose.
    #
    # @return [Array<String>] slugs the pass declared it would load
    def rerun_retrieval(origin)
      result = @agent.launch(
        prompt: retrieval_prompt(origin), workdir: @workdir, command: "learn", force: false,
      )
      line = result.scan(FIRED_LINE).last
      raise Error, "the retrieval pass produced no FIRED: line — see the agent log" unless line

      line.first.split(",").map { |slug| slug.gsub(/[`\s]/, "") }.reject { |slug| slug.empty? || slug == "(none)" }
    end

    def retrieval_prompt(origin)
      <<~PROMPT
        You are an engineering agent about to start a task in an organization that keeps a learnings corpus. In a real session the corpus index below is always in your context; the detail skills load on demand when an index cue matches the work at hand.

        THE LEARNINGS INDEX:
        <<<INDEX>>>
        #{index_content}
        <<<END INDEX>>>

        THE TASK CONTEXT (a discussion replayed as if it just happened — treat it as the work you are being asked to pick up):
        <<<CONTEXT>>>
        #{origin_evidence(origin)}
        <<<END CONTEXT>>>

        Decide which learnings you would consult before working on this task: read the index cues and select every entry whose trigger matches this context — you may open skill files in this checkout to confirm relevance. Do NOT solve the task, and do NOT write any files.

        OUTPUT: exactly one final line — `FIRED: slug-one, slug-two` (the skill folder names you would load) or `FIRED: (none)`.
      PROMPT
    end

    # @return [String] the checked-out PR's own index — the corpus as merged
    def index_content
      path = INDEX_PATHS.map { |candidate| File.join(@workdir, candidate) }.find { |candidate| File.exist?(candidate) }
      raise Error, "no learnings index found (looked for #{INDEX_PATHS.join(", ")})" unless path

      File.read(path)
    end

    # The origin thread, shaped like Learn's sweep evidence: title + body +
    # human conversation. Bot comments (ai-flow's own panels) are noise the
    # capture pass never distilled from. v0 omits line-anchored review
    # threads — the conversation carries the lesson's trigger in practice,
    # and the issue surface has no threads at all.
    #
    # @return [String]
    def origin_evidence(origin)
      owner_repo, number = origin
      subject = @github.issue(owner_repo, number)
      blocks = ["#{owner_repo}##{number}: #{subject.title}", "<<<BODY>>>\n#{subject.body}\n<<<END BODY>>>"]
      blocks.concat(
        @github.issue_comments(owner_repo, number)
               .reject { |comment| comment.dig("user", "login") == CommitIdentity.bot_login }
               .map { |comment| "Comment from @#{comment.dig("user", "login")}:\n#{comment["body"]}" },
      )
      blocks.join("\n\n")
    end

    class Error < StandardError; end
  end
end
