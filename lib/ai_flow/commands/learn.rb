# frozen_string_literal: true

require "tmpdir"

module AiFlow
  module Commands
    # /learn — capture a lesson as a learning (an index line in
    # .cursor/rules/learnings-index.mdc plus a detail skill under
    # .cursor/skills/learnings/<slug>/), landed as a draft PR the human
    # merges. The GitHub-comment twin of dev's capture-learning skill: same
    # distillation rubric, same output shape, one pipeline behind both.
    #
    # Two forms ship here (plans#13, ai-flow#15):
    # - **dictated** (`/learn <statement>`): the human already distilled the
    #   lesson; the agent only formats it into the two-tier shape, dedups
    #   against the existing corpus, and applies the scope rubric. Works from
    #   any comment surface — its source is the single comment, so it opens a
    #   fresh draft each time.
    # - **bare sweep** (`/learn`): distill the surface's feedback — a PR's
    #   description, review threads, and conversation, or an issue's body and
    #   discussion. Re-running on the same surface refines that surface's open
    #   draft (branch ai/learn-<source>) instead of duplicating.
    #
    # `--scan` (survey a codebase) and `--promote <slug>` (move a learning to
    # the org tier) are recognized but deferred to a follow-up; they answer
    # with a pointer, never a silent no-op.
    #
    # Distillation and file-writing are the agent's (it holds the rubric and
    # the corpus); the branch, commit, and draft-PR mechanics are the
    # script's — deterministic, like /build.
    class Learn
      SCAN_FLAG = "--scan"
      PROMOTE_FLAG = "--promote"

      # Learning artifacts live under these trees; the panel names what
      # changed by reading the staged file list, never by trusting agent
      # prose. Index edits and detail skills (learnings + architecture
      # digests, which the scan form also seeds).
      LEARNING_PATHS = [
        %r{\A\.cursor/skills/(?:learnings|architecture)/([^/]+)/},
        %r{\A\.cursor/rules/learnings-index\.mdc\z},
      ].freeze

      # @param context [AiFlow::Context]
      # @param github [AiFlow::GitHub]
      # @param agent [AiFlow::Agent]
      # @param result_writer [AiFlow::ResultWriter]
      # @param executor [AiFlow::Executor]
      # @param workdir [String] the job's repo checkout
      # @param prefix [String] configured command prefix
      # @param org_invariants [AiFlow::OrgInvariants] injected into the prompt
      #   — the learning worktree is fresh, so the rendered org-invariants.mdc
      #   is never present (same reasoning as /build, plans#13)
      def initialize(context:, github:, agent:, result_writer:, executor:, workdir:, prefix: "",
        org_invariants: OrgInvariants.new)
        @context = context
        @github = github
        @agent = agent
        @result_writer = result_writer
        @executor = executor
        @workdir = workdir
        @prefix = prefix
        @org_invariants = org_invariants
      end

      # @param segment [CommentParser::Segment]
      # @return [void]
      def run(segment)
        return deferred(segment, SCAN_FLAG) if segment.flags.include?(SCAN_FLAG)
        return deferred(segment, PROMOTE_FLAG) if segment.flags.include?(PROMOTE_FLAG)

        capture(segment)
      end

      private

      # --scan and --promote parse as flags today (the grammar reserves
      # them) but land in a follow-up — answer with the pointer so the human
      # isn't left wondering whether the command silently did nothing.
      def deferred(segment, flag)
        @result_writer.write(
          @context,
          [[segment, "ℹ️ **/learn #{flag}** — not available yet; #{deferred_hint(flag)} " \
                     "For now, `/learn <statement>` captures a dictated lesson and bare `/learn` " \
                     "sweeps this surface."]],
        )
      end

      # @return [String]
      def deferred_hint(flag)
        case flag
        when SCAN_FLAG then "codebase surveys (`/learn --scan`) are a follow-up in d3mlabs/ai-flow#15."
        else "org-tier promotion (`/learn --promote <slug>`) is a follow-up in d3mlabs/ai-flow#15."
        end
      end

      def capture(segment)
        source = source_descriptor(segment)
        existing = @github.open_pull_request_for_head(@context.owner_repo, source[:branch])

        outcome = in_worktree(source[:branch], refine: !existing.nil?) do |worktree|
          @agent.launch(
            prompt: learn_prompt(segment, source), workdir: worktree, command: "learn", force: true,
          )
          # The agent may have run close to the token's lifetime; the write
          # phase (commit, push, PR) starts on a fresh mint.
          @executor.refresh_auth!
          slugs = commit_learnings(worktree, source)
          next { slugs: [] } if slugs.empty?

          push_branch(worktree, source[:branch])
          pr = existing || open_learning_pr(source, segment)
          { slugs: slugs, pr: pr, refined: !existing.nil? }
        end

        @result_writer.write(@context, [[segment, learn_result(outcome)]])
      end

      # The branch + marker naming per form (the branch is the refine key;
      # the marker records the source surface and form in the PR body).
      #
      # @return [Hash] :branch, :marker, :dictated
      def source_descriptor(segment)
        repo_ref = "#{@context.owner_repo}##{@context.number}"
        if dictated?(segment)
          # Source is the single comment, so each dictation is its own draft.
          { branch: "ai/learn-c#{@context.comment_id}", marker: "learned-from: #{repo_ref} (dictated)",
            dictated: true }
        elsif @context.pull_request?
          { branch: "ai/learn-pr-#{@context.number}", marker: "learned-from: #{repo_ref} (learn-sweep)",
            dictated: false }
        else
          { branch: "ai/learn-issue-#{@context.number}", marker: "learned-from: #{repo_ref} (learn-sweep)",
            dictated: false }
        end
      end

      # @return [Boolean] a statement was dictated (vs a bare surface sweep)
      def dictated?(segment)
        !segment.instruction.empty?
      end

      def learn_prompt(segment, source)
        <<~PROMPT
          You are ai-flow, capturing a durable learning in this repository checkout.

          A learning is one lesson materialized two ways: an index line in `.cursor/rules/learnings-index.mdc` (always-on awareness) and a detail skill at `.cursor/skills/learnings/<slug>/SKILL.md` (loaded on demand). This is the GitHub twin of the capture-learning skill — identical rubric and output.

          #{evidence_section(segment, source)}
          #{org_invariants_section}DISTILLATION RUBRIC — only lessons that generalize beyond the immediate diff or discussion become learnings. Three kinds, one format: coding practices (style/API corrections that recur), architecture knowledge (constraints and shapes of the system — "X must never call Y directly", "this subsystem owns that lifecycle"), and process rules. Diff-local fixes (typos, renames, one-off bugs) are NOT learnings.

          Before writing, DEDUP: read `.cursor/rules/learnings-index.mdc` and skills under `~/.cursor/skills/` (the org tier); if an equivalent learning exists, revise it rather than adding a duplicate; if swept feedback contradicts one, edit or remove it. Revision always beats a contradictory sibling.

          SCOPE: ask whether the lesson is about THIS repo's code or about how we build software. Repo-specific lessons land here. A repo-agnostic lesson (SRP-class principles, universal testing/error-handling posture) belongs in the org knowledge tier — for now, note that in your summary and still draft it repo-local (org promotion is a separate command); borderline calls default to repo-local.

          FORMAT:
          - Index line under a `## <domain>` section: `- [domain/slug] One-sentence trigger. → .cursor/skills/learnings/<slug>/`
          - Detail skill (hard cap ~40 lines): frontmatter `name` matching its folder and an imperative `description` ("MUST be used when …"); the rule in two sentences; one wrong/right pair; a `learned-from:` origin line; a `date:`.
          - Soft cap ~50 index entries: at the cap, propose a retirement, consolidation, or glob-scoped sub-index split alongside any addition.

          If nothing here generalizes into a learning, WRITE NOTHING and say so — an empty capture is a valid, common outcome.

          Rules:
          - Write only learning files (the index and skill files). Do not create commits, branches, or PRs — the surrounding tooling owns git. Work only inside this checkout.
          - In any text destined for GitHub, reference files as GitHub URLs, never as local filesystem paths.

          OUTPUT: a short summary — one line per learning drafted (or "no learning: <why>").
        PROMPT
      end

      # The evidence the pass distills, per form.
      #
      # @return [String]
      def evidence_section(segment, source)
        return "DICTATED LESSON (the human already distilled it — format, dedup, and place it):\n#{dictated_evidence(segment)}\n" if source[:dictated]

        <<~EVIDENCE
          SWEEP THIS SURFACE — distill what generalizes from the #{@context.pull_request? ? "pull request" : "issue"} below. The diff and code are in this checkout; read them for what the feedback is about.
          #{surface_evidence}
        EVIDENCE
      end

      # @return [String]
      def dictated_evidence(segment)
        quote = segment.quote ? "Quoted context:\n#{segment.quote}\n\n" : ""
        "#{quote}#{segment.instruction}"
      end

      # PR: description + unresolved review threads + conversation. Issue:
      # body + comment discussion. Comments carry the lessons; the checkout
      # carries the code they're about.
      #
      # @return [String]
      def surface_evidence
        subject = @github.issue(@context.owner_repo, @context.number)
        blocks = ["#{@context.pull_request? ? "PR" : "ISSUE"} #{@context.owner_repo}##{@context.number}: #{subject.title}",
                  "<<<BODY>>>\n#{subject.body}\n<<<END BODY>>>"]
        blocks.concat(thread_blocks) if @context.pull_request?
        blocks.concat(comment_blocks)
        blocks.join("\n\n")
      end

      # @return [Array<String>]
      def thread_blocks
        @github.unresolved_review_threads(@context.owner_repo, @context.number).map do |thread|
          conversation = thread["comments"].map { |comment| "@#{comment["author"]}: #{comment["body"]}" }.join("\n")
          "REVIEW THREAD (#{thread["path"]})\n#{thread["diff_hunk"]}\n#{conversation}"
        end
      end

      # @return [Array<String>]
      def comment_blocks
        @github.issue_comments(@context.owner_repo, @context.number)
               .reject { |comment| comment["id"] == @context.comment_id }
               .reject { |comment| comment.dig("user", "login") == CommitIdentity.bot_login }
               .map { |comment| "Comment from @#{comment.dig("user", "login")}:\n#{comment["body"]}" }
      end

      # @return [String] org invariants block with trailing blank line, empty
      #   on unconfigured machines
      def org_invariants_section
        block = @org_invariants.prompt_block
        block ? "#{block}\n\n" : ""
      end

      # Stage the agent's learning files and commit them. The learning
      # branch carries only learnings by construction, so a blanket add is
      # safe; .ai-flow is the dispatcher's own nested checkout, never ours.
      #
      # @return [Array<String>] changed learning slugs (skill folders +
      #   "index" for the index edit), empty when the agent wrote nothing
      def commit_learnings(worktree, source)
        run!("git", "add", "-A", "--", ":(exclude).ai-flow", chdir: worktree)
        staged, = @executor.capture("git", "diff", "--cached", "--name-only", chdir: worktree)
        slugs = learning_slugs(staged)
        # Key the "did we capture" decision on learning files, not any staged
        # path: an empty capture (nothing generalized) is the common outcome,
        # and stray non-learning writes are discarded with the worktree.
        return [] if slugs.empty?

        message = CommitIdentity.message_with_requester("ai-flow /learn: capture learnings", @context)
        run!("git", *CommitIdentity.git_flags(@github), "commit", "-m", message, chdir: worktree)
        slugs
      end

      # @param staged [String] git diff --cached --name-only output
      # @return [Array<String>] deduped slugs, "index" standing in for the
      #   index-line edit
      def learning_slugs(staged)
        staged.split("\n").each_with_object([]) do |path, slugs|
          LEARNING_PATHS.each do |pattern|
            match = pattern.match(path)
            next unless match

            slugs << (match[1] || "index")
          end
        end.uniq
      end

      # @return [Hash] the created draft PR
      def open_learning_pr(source, segment)
        requested_by = @context.commenter_login ? "Requested by @#{@context.commenter_login}.\n\n" : ""
        body = <<~BODY
          Draft learning(s) captured from #{source_link}.

          #{requested_by}#{evidence_quote(segment, source)}#{source[:marker]}
        BODY
        @github.create_pull_request(
          @context.owner_repo,
          title: "ai-flow /learn: #{source[:dictated] ? "dictated learning" : "learnings from #{@context.owner_repo}##{@context.number}"}",
          body: body,
          head: source[:branch],
          base: @github.default_branch(@context.owner_repo),
          draft: true,
        )
      end

      # The draft embeds the motivating evidence (a dictation's statement, or
      # a pointer to the swept surface) so it is reviewable without reopening
      # the source.
      #
      # @return [String]
      def evidence_quote(segment, source)
        return "" unless source[:dictated]

        "> #{segment.instruction.gsub("\n", "\n> ")}\n\n"
      end

      # @return [String]
      def source_link
        "#{@context.subject_url} (#{@context.owner_repo}##{@context.number})"
      end

      # @return [String]
      def learn_result(outcome)
        return "ℹ️ **/learn** — no learning: nothing here generalized beyond the immediate change." if outcome[:slugs].empty?

        pr = outcome.fetch(:pr)
        verb = outcome[:refined] ? "refined" : "drafted"
        lines = ["✅ **/learn** — #{verb} #{learning_count(outcome[:slugs])} in a draft PR: #{pr.fetch("html_url")}"]
        named_slugs(outcome[:slugs]).each { |slug| lines << "- `#{slug}`" }
        lines.join("\n")
      end

      # @return [String]
      def learning_count(slugs)
        named = named_slugs(slugs)
        count = named.size
        count.zero? ? "the learnings index" : "#{count} learning#{"s" unless count == 1}"
      end

      # The index edit isn't itself a named learning — drop the "index"
      # sentinel for the human-facing list.
      #
      # @return [Array<String>]
      def named_slugs(slugs)
        slugs.reject { |slug| slug == "index" }
      end

      # An isolated worktree per capture (never disturbs the job's checked-out
      # PR branch, safe under concurrency). Refine bases on the existing
      # draft's branch; a fresh capture bases on the default branch.
      def in_worktree(branch, refine:)
        default = @github.default_branch(@context.owner_repo)
        base_ref = refine ? branch : default
        Dir.mktmpdir("ai-flow-learn-") do |dir|
          worktree = File.join(dir, "worktree")
          run!("git", "fetch", "origin", base_ref, chdir: @workdir)
          run!("git", "worktree", "prune", chdir: @workdir)
          run!("git", "worktree", "add", "--detach", worktree, "origin/#{base_ref}", chdir: @workdir)
          run!("git", "checkout", "-B", branch, chdir: worktree)
          begin
            yield worktree
          ensure
            @executor.capture("git", "worktree", "remove", "--force", worktree, chdir: @workdir)
          end
        end
      end

      def push_branch(worktree, branch)
        _out, err, ok = @executor.capture(
          "git", "push", "-u", "origin", branch, "--force-with-lease", chdir: worktree,
        )
        return if ok

        raise GitHub::Error,
              "git push failed: #{err.strip} — if this repo enforces signed commits, " \
              "see d3mlabs/ai-flow docs/attribution.md (createCommitOnBranch upgrade path)"
      end

      def run!(*argv, chdir:)
        _out, err, ok = @executor.capture(*argv, chdir: chdir)
        raise GitHub::Error, "#{argv.take(2).join(" ")} failed: #{err.strip}" unless ok
      end
    end
  end
end
