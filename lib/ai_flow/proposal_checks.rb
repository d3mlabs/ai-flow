# typed: strict
# frozen_string_literal: true

module AiFlow
  # Automated verification of corpus proposals (docs/paper.md §6.2): the
  # checks that run against a proposal PR before the human gate adjudicates
  # admission. Verification informs admission and never performs it — a
  # failed check is a failed PR status, and the proposal stays open for
  # rewording. One home because the checks change for the same reason: the
  # verification policy per diff class. Today that is the origin-firing
  # check; the retrieval-equivalence suite (structure proposals) and the
  # non-inferiority outcome check (content proposals) group in here as
  # §15.6 builds them out.
  #
  # Origin-firing (content proposals; the cheapest check): a learning distilled
  # from thread X must actually load when retrieval re-runs against X's
  # context — if the new cue does not fire on the very situation that
  # produced it, the proposal fails before any outcome measurement. Runs as a
  # PR-status job (workflows/origin-firing.yml): one agent pass is handed
  # the PR's own index (as a session would see it) plus the origin thread's
  # conversation replayed as a fresh task, and must declare which learnings
  # it would consult. Every skill the PR adds or edits must be in that set.
  #
  # Deliberately v0-cheap (single-shot): cue firing is stochastic (§6.2), so
  # a marginal cue can flake — re-run the job for a second opinion; the
  # statistical form (n replicates, TOST margins) is the §15.6 follow-up and
  # belongs to the retrieval-equivalence suite.
  class ProposalChecks
    extend T::Sig

    class Error < StandardError; end

    # The provenance marker every capture form writes into its proposal PR body.
    ORIGIN_MARKER = T.let(%r{learned-from:\s*([\w.-]+/[\w.-]+)#(\d+)}, Regexp)

    # Learning index files, org layout first (the knowledge repo) then the
    # per-repo layout — the checks are layout-agnostic so any
    # learnings-bearing repo can adopt them.
    INDEX_PATHS = T.let(["index.md", ".cursor/rules/learnings-index.mdc"].freeze, T::Array[String])

    # Diff paths that identify a changed *skill* (the content half of a
    # learning; capture group = slug). Index-only edits are structure
    # proposals and outside the origin-firing check's scope.
    SKILL_PATHS = T.let(
      [
        %r{\Askills/([^/]+)/},
        %r{\A\.cursor/skills/(?:learnings|architecture)/([^/]+)/},
      ].freeze,
      T::Array[Regexp],
    )

    # The declarative output contract the prompt imposes on the agent pass.
    FIRED_LINE = T.let(/^FIRED:\s*(.+?)\s*$/, Regexp)

    # The origin thread a captured proposal names in its learned-from marker.
    class OriginRef < T::Struct
      const :owner_repo, String
      const :number, Integer
    end

    # What one check concluded — facts only, sealed so the CI entry point
    # dispatches exhaustively. All human-facing wording (and the exit-code
    # policy: out-of-scope results are green) belongs to that boundary,
    # never to the type.
    class Result
      extend T::Helpers
      abstract!
      sealed!

      # Every changed learning fired on its origin context.
      class Pass < Result
        extend T::Sig

        # @return [Array<String>] slugs the PR adds or edits
        sig { returns(T::Array[String]) }
        attr_reader :new_slugs

        # @return [Array<String>] slugs the retrieval pass declared
        sig { returns(T::Array[String]) }
        attr_reader :fired

        # @param new_slugs [Array<String>]
        # @param fired [Array<String>]
        sig { params(new_slugs: T::Array[String], fired: T::Array[String]).void }
        def initialize(new_slugs:, fired:)
          @new_slugs = new_slugs
          @fired = fired
        end
      end

      # At least one changed learning stayed silent on its origin context.
      class Fail < Result
        extend T::Sig

        # @return [Array<String>] slugs the PR adds or edits
        sig { returns(T::Array[String]) }
        attr_reader :new_slugs

        # @return [Array<String>] slugs the retrieval pass declared
        sig { returns(T::Array[String]) }
        attr_reader :fired

        # @param new_slugs [Array<String>]
        # @param fired [Array<String>]
        sig { params(new_slugs: T::Array[String], fired: T::Array[String]).void }
        def initialize(new_slugs:, fired:)
          @new_slugs = new_slugs
          @fired = fired
        end

        # Derived here, not at the boundary, so the check's one piece of
        # verdict arithmetic has one home.
        #
        # @return [Array<String>] the changed slugs that stayed silent
        sig { returns(T::Array[String]) }
        def missing = new_slugs - fired
      end

      # No skill files added or edited — a structure-only diff (index
      # rewording, or a paired promotion removal), outside the origin-firing
      # check's scope.
      class StructureOnly < Result; end

      # No learned-from: marker in the PR body — a migration/manual PR,
      # not a captured proposal.
      class Unmarked < Result; end
    end

    # @param github [AiFlow::GitHub] origin-thread reads (cross-repo capable)
    # @param agent [AiFlow::Agent] the retrieval re-run
    # @param executor [AiFlow::Executor] git diff against the PR base
    sig { params(github: GitHub, agent: Agent, executor: Executor).void }
    def initialize(github:, agent:, executor:)
      @github = github
      @agent = agent
      @executor = executor
    end

    # The origin-firing check for one proposal PR.
    #
    # @param workdir [String] the PR checkout (merge ref, full history)
    # @param owner_repo [String] the proposal PR's repo ("owner/name")
    # @param number [Integer] the proposal PR's number
    # @param base_ref [String] the PR's base branch name
    # @return [Result]
    sig { params(workdir: String, owner_repo: String, number: Integer, base_ref: String).returns(Result) }
    def origin_firing(workdir:, owner_repo:, number:, base_ref:)
      slugs = changed_skill_slugs(workdir, base_ref)
      return Result::StructureOnly.new if slugs.empty?

      # The proposal body is read live (the PR is an issue to this API), never
      # taken from the triggering event's snapshot: the learned-from marker is
      # this check's input, and a body edited after the event — a marker
      # repair — must drive reruns and later verdicts.
      origin = origin_ref(@github.issue(owner_repo, number).body)
      return Result::Unmarked.new unless origin

      fired = rerun_retrieval(workdir, origin)
      if (slugs - fired).empty?
        Result::Pass.new(new_slugs: slugs, fired: fired)
      else
        Result::Fail.new(new_slugs: slugs, fired: fired)
      end
    end

    private

    # The skills the PR adds or edits, from the merge-base diff (three-dot,
    # so a stale base branch never pollutes the file list). Deletions are
    # filtered out (--diff-filter=d): a paired promotion removal deletes the
    # skill and its index cue, so its cue can never fire here — the removed
    # content's verification belongs to the paired org proposal (#56).
    #
    # @param workdir [String]
    # @param base_ref [String]
    # @return [Array<String>] slugs
    # @raise [Error] when the diff itself fails
    sig { params(workdir: String, base_ref: String).returns(T::Array[String]) }
    def changed_skill_slugs(workdir, base_ref)
      out, err, ok = @executor.capture(
        "git", "diff", "--name-only", "--diff-filter=d", "origin/#{base_ref}...HEAD", chdir: workdir,
      )
      raise Error, "git diff against origin/#{base_ref} failed: #{err.strip}" unless ok

      out.split("\n").filter_map { |path| slug_for(path) }.uniq
    end

    # @param path [String] one diff path
    # @return [String, nil] the skill slug the path belongs to
    sig { params(path: String).returns(T.nilable(String)) }
    def slug_for(path)
      SKILL_PATHS.each do |pattern|
        match = pattern.match(path)
        return match[1] if match
      end
      nil
    end

    # @param pr_body [String]
    # @return [OriginRef, nil] nil when the body carries no capture provenance
    sig { params(pr_body: String).returns(T.nilable(OriginRef)) }
    def origin_ref(pr_body)
      match = ORIGIN_MARKER.match(pr_body)
      return nil unless match

      # T.must: both groups are unconditional in ORIGIN_MARKER, so a match
      # always captures them.
      OriginRef.new(owner_repo: T.must(match[1]), number: Integer(T.must(match[2])))
    end

    # One declarative agent pass: the PR's index as the always-on context,
    # the origin thread replayed as the task. Parsing keys on the FIRED
    # contract line, never on prose.
    #
    # @param workdir [String]
    # @param origin [OriginRef]
    # @return [Array<String>] slugs the pass declared it would load
    # @raise [Error] when the pass never declares the contract line
    sig { params(workdir: String, origin: OriginRef).returns(T::Array[String]) }
    def rerun_retrieval(workdir, origin)
      result = @agent.launch(
        prompt: retrieval_prompt(workdir, origin), workdir: workdir, command: Command::Learn.new, force: false,
      )
      # The last declaration wins when the pass rambles through several.
      match = result.lines.reverse_each.filter_map { |line| FIRED_LINE.match(line) }.first
      raise Error, "the retrieval pass produced no FIRED: line — see the agent log" unless match

      # T.must: the group is unconditional in FIRED_LINE, so a match always
      # captures it.
      T.must(match[1]).split(",").map { |slug| slug.gsub(/[`\s]/, "") }.reject { |slug| slug.empty? || slug == "(none)" }
    end

    # @param workdir [String]
    # @param origin [OriginRef]
    # @return [String] the retrieval pass's prompt
    sig { params(workdir: String, origin: OriginRef).returns(String) }
    def retrieval_prompt(workdir, origin)
      <<~PROMPT
        You are an engineering agent about to start a task in an organization that keeps a learnings corpus. In a real session the corpus index below is always in your context; the detail skills load on demand when an index cue matches the work at hand.

        THE LEARNINGS INDEX:
        <<<INDEX>>>
        #{index_content(workdir)}
        <<<END INDEX>>>

        THE TASK CONTEXT (a discussion replayed as if it just happened — treat it as the work you are being asked to pick up):
        <<<CONTEXT>>>
        #{origin_evidence(origin)}
        <<<END CONTEXT>>>

        #{Provenance::FENCE_RULE}

        Decide which learnings you would consult before working on this task: read the index cues and select every entry whose trigger matches this context — you may open skill files in this checkout to confirm relevance. Do NOT solve the task, and do NOT write any files.

        OUTPUT: exactly one final line — `FIRED: slug-one, slug-two` (the skill folder names you would load) or `FIRED: (none)`.
      PROMPT
    end

    # @param workdir [String]
    # @return [String] the checked-out PR's own index — the corpus as merged
    # @raise [Error] when no index exists in either layout
    sig { params(workdir: String).returns(String) }
    def index_content(workdir)
      path = INDEX_PATHS.map { |candidate| File.join(workdir, candidate) }.find { |candidate| File.exist?(candidate) }
      raise Error, "no learnings index found (looked for #{INDEX_PATHS.join(", ")})" unless path

      File.read(path)
    end

    # The origin thread, shaped like Learn's sweep evidence: title + body +
    # human conversation. Bot comments (ai-flow's own panels) are noise the
    # capture pass never distilled from. v0 omits line-anchored review
    # threads — the conversation carries the lesson's trigger in practice,
    # and the issue surface has no threads at all.
    #
    # Provenance (plans#24): this replay is fully automatic — no human
    # pointed a command at the origin thread for this run — so both the body
    # and the comments filter to write-authorized authors, judged against the
    # ORIGIN repo (a knowledge-repo proposal replays a thread from the repo
    # the lesson came from).
    #
    # @param origin [OriginRef]
    # @return [String]
    sig { params(origin: OriginRef).returns(String) }
    def origin_evidence(origin)
      provenance = Provenance.new(github: @github, owner_repo: origin.owner_repo)
      subject = @github.issue(origin.owner_repo, origin.number)
      body =
        if provenance.trusted?(subject.author)
          subject.body
        else
          "(body omitted — its author has no write access on #{origin.owner_repo})"
        end
      blocks = ["#{origin.owner_repo}##{origin.number}: #{subject.title}", "<<<BODY>>>\n#{body}\n<<<END BODY>>>"]
      blocks.concat(
        @github.issue_comments(origin.owner_repo, origin.number)
               .reject { |comment| comment.author == CommitIdentity.bot_login }
               .select { |comment| provenance.trusted?(comment.author) }
               .map { |comment| "Comment from @#{comment.author}:\n#{comment.body}" },
      )
      blocks.join("\n\n")
    end
  end
end
