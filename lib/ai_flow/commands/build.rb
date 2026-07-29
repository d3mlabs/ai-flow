# typed: strict
# frozen_string_literal: true

require "fileutils"
require "time"
require "tmpdir"

module AiFlow
  module Commands
    # /build — the code command, on both lifecycle ends.
    #
    # On a plan issue: run the headless agent in an isolated worktree on
    # branch ai/<n>-<slug>, then push and open the PR ourselves (`gh pr
    # create` equivalent) with the closing reference and the ai-flow marker
    # in the body — deterministic because the script authors the PR, not
    # the agent.
    #
    # On a PR (top-level conversation comment only): iterate on the head
    # branch. Bare /build sweeps the outstanding feedback — unresolved
    # review threads plus conversation comments newer than the last ai-flow
    # commit — and addresses it; an instruction takes priority with the
    # sweep as context. Each swept thread gets a threaded reply with its
    # disposition and the commit link; resolving stays with the human.
    class Build
      extend T::Sig

      # The App deliberately lacks the `workflows` permission (see
      # docs/attribution.md): GitHub rejects any App push touching workflow
      # files wholesale, and a workflow pushed to a branch could execute on
      # pull_request events before any human merges it. Excluded from every
      # commit; the diff surfaces in the result panel as a suggested patch.
      WORKFLOWS_DIR = ".github/workflows"

      # @param context [AiFlow::Context]
      # @param github [AiFlow::GitHub]
      # @param agent [AiFlow::Agent]
      # @param result_writer [AiFlow::ResultWriter]
      # @param executor [AiFlow::Executor]
      # @param workdir [String] the job's repo checkout
      # @param prefix [String] configured command prefix (to recognize old
      #   command comments during the feedback sweep)
      # @param org_invariants [AiFlow::OrgInvariants] the always-on org rules
      #   injected into both prompts — /build checkouts are fresh, so the
      #   dev-rendered org-invariants.mdc is never present (see plans#13)
      # @param learn [AiFlow::Commands::Learn] owns build-time learning
      #   capture (the rubric section, the seed/extract/land mechanics)
      sig do
        params(
          context: Context,
          github: GitHub,
          agent: Agent,
          result_writer: ResultWriter,
          executor: Executor,
          workdir: String,
          prefix: String,
          org_invariants: OrgInvariants,
          learn: Learn,
        ).void
      end
      def initialize(context:, github:, agent:, result_writer:, executor:, workdir:, prefix: "",
        org_invariants: OrgInvariants.new,
        learn: Learn.new(
          context: context, github: github, agent: agent, result_writer: result_writer,
          executor: executor, workdir: workdir, prefix: prefix, org_invariants: org_invariants,
        ))
        @context = context
        @github = github
        @agent = agent
        @result_writer = result_writer
        @executor = executor
        @workdir = workdir
        @prefix = prefix
        @org_invariants = org_invariants
        @learn = learn
        # Per-run panel notes, reset at the top of each build (a Build
        # instance is reused across --split sub-issue builds).
        @capture_note = T.let(nil, T.nilable(String))
        @workflows_patch = T.let(nil, T.nilable(String))
      end

      # @param segment [CommentParser::Segment]
      # @return [void]
      sig { params(segment: CommentParser::Segment).void }
      def run(segment)
        return refuse_review_thread(segment) if @context.review_comment?
        return iterate_on_pull_request(segment) if @context.pull_request?

        issue = @github.issue(@context.owner_repo, @context.number)
        return refuse_staged_spec(segment) if SubtasksSection.spec?(issue.body)

        pr = build_issue(issue, extra_instruction: segment.instruction)
        result =
          if pr
            "✅ **/build** — opened #{pr.fetch("html_url")}"
          else
            "⚠️ **/build** — the agent made no changes, so no PR was opened."
          end
        @result_writer.write(
          @context,
          [[segment,
            [result, @capture_note, workflows_note(pr&.fetch("html_url")), open_sub_issues_note].compact.join("\n\n")]],
        )
      end

      # Build one issue end to end. Shared with the --split orchestrator.
      #
      # @param issue [GitHub::Issue]
      # @param extra_instruction [String]
      # @return [Hash, nil] the created PR, or nil when the agent changed nothing
      sig do
        params(issue: GitHub::Issue, extra_instruction: String)
          .returns(T.nilable(T::Hash[String, T.untyped]))
      end
      def build_issue(issue, extra_instruction: "")
        issue_repo = issue.repo || @context.owner_repo
        code_repo = target_repo_for(issue, issue_repo)
        branch = branch_name(issue)
        @capture_note = nil

        in_worktree(code_repo) do |worktree|
          create_branch(worktree, branch)
          capture = capture_learnings?(code_repo, worktree)
          @learn.seed_capture(worktree, issue_capture_source(issue, issue_repo)) if capture
          @agent.launch(
            prompt: build_prompt(issue, extra_instruction, capture: capture),
            workdir: worktree, command: Command::Build.new, force: true,
          )
          # The agent may have run for close to the token's lifetime; the
          # write phase (commit, push, PR) starts on a fresh mint.
          @executor.refresh_auth!
          committed = commit_all(worktree, issue, capture: capture)
          unless committed
            # A pass may yield learnings without code changes — land them
            # even though no code PR opens.
            @capture_note = @learn.land_capture if capture
            next nil
          end

          push_branch(worktree, branch)
          pr = open_pull_request(code_repo, issue_repo, issue, branch)
          @capture_note = @learn.land_capture if capture
          pr
        end
      end

      private

      # ---- Split-state guards (issue mode) ----

      # An unapplied /split proposal makes the plan-of-record ambiguous;
      # building past it would silently discard the human's own staging —
      # refuse, naming the next command (never silent).
      #
      # @return [void]
      sig { params(segment: CommentParser::Segment).void }
      def refuse_staged_spec(segment)
        @result_writer.write(
          @context,
          [[segment, "ℹ️ **/build** — this plan has a staged /split proposal. `/split --apply` it " \
                     "or delete the `#{SubtasksSection::HEADER}` section, then re-run /build."]],
        )
      end

      # Applied sub-issues are a committed valid state: building the whole
      # plan across them is a legitimate deliberate call, so the human is
      # informed, never blocked.
      #
      # @return [String, nil]
      sig { returns(T.nilable(String)) }
      def open_sub_issues_note
        open_subs = @github.sub_issues(@context.owner_repo, @context.number)
                           .select { |issue| issue.state == "open" }
        return nil if open_subs.empty?

        listing = open_subs.map { |issue| "#{issue.repo || @context.owner_repo}##{issue.number}" }.join(", ")
        "ℹ️ This plan has #{open_subs.size} open sub-issue(s) (#{listing}) — this /build covered the " \
          "whole plan; close or /build them individually if they were meant to scope the work."
      end

      # ---- PR-iteration mode ----

      # /build is PR-scoped (the sweep), so firing it from one review thread
      # would look thread-scoped and act PR-scoped — refuse at the point of
      # use, without failing the run.
      #
      # @return [void]
      sig { params(segment: CommentParser::Segment).void }
      def refuse_review_thread(segment)
        @result_writer.write(
          @context,
          [[segment, "ℹ️ **/build** — /build runs from the PR conversation, not a review thread. " \
                     "Leave the feedback as a plain comment here and post /build as a top-level " \
                     "comment — the sweep picks this thread up."]],
        )
      end

      # @param segment [CommentParser::Segment]
      # @return [void]
      sig { params(segment: CommentParser::Segment).void }
      def iterate_on_pull_request(segment)
        branch = checkout_head_branch
        threads = sweepable_threads
        comments = fresh_conversation_comments
        if segment.instruction.empty? && threads.empty? && comments.empty?
          @result_writer.write(
            @context,
            [[segment, "ℹ️ **/build** — nothing to address: no instruction, no unresolved review " \
                       "threads, and no new discussion since the last ai-flow commit."]],
          )
          return
        end

        capture = RepoConfig.load(@workdir).learn_on_build?
        @learn.seed_capture(@workdir, pr_capture_source) if capture
        output = @agent.launch(
          prompt: iteration_prompt(segment, branch, threads, comments, capture: capture),
          workdir: @workdir, command: Command::Build.new, force: true,
        )
        parsed = AgentOutput.parse(output)
        # The agent may have run for close to the token's lifetime; the
        # write phase (push + replies + panel) starts on a fresh mint.
        @executor.refresh_auth!
        sha = commit_and_push(segment, capture: capture)
        capture_note = capture ? @learn.land_capture : nil
        reply_to_threads(threads, parsed, sha)
        @result_writer.write(@context, [[segment, iteration_result(parsed, threads, sha, capture_note)]])
      end

      # @return [String] the PR head branch, checked out in the job checkout
      sig { returns(String) }
      def checkout_head_branch
        branch = @context.pr_head_ref ||
                 @github.api("repos/#{@context.owner_repo}/pulls/#{@context.number}").fetch("head").fetch("ref")
        run!(["git", "fetch", "origin", branch], chdir: @workdir)
        run!(["git", "checkout", branch], chdir: @workdir)
        branch
      end

      # Unresolved review threads, minus those a command started (a threaded
      # /ask and its answer are a handled conversation, not outstanding
      # feedback).
      #
      # @return [Array<Hash>]
      sig { returns(T::Array[T::Hash[String, T.untyped]]) }
      def sweepable_threads
        @github.unresolved_review_threads(@context.owner_repo, @context.number)
               .reject { |thread| command_comment?(thread["comments"].first&.fetch("body", nil).to_s) }
      end

      # Conversation comments have no resolved state, so "unaddressed" is a
      # heuristic: comments newer than the last ai-flow commit on the branch
      # (all of them when the bot never committed), excluding the command
      # comment itself, the bot's own comments, and earlier command comments
      # (their own runs already handled them).
      #
      # @return [Array<Hash>]
      sig { params(since: T.nilable(Time)).returns(T::Array[T::Hash[String, T.untyped]]) }
      def fresh_conversation_comments(since: last_bot_commit_time)
        @github.issue_comments(@context.owner_repo, @context.number)
               .reject { |comment| comment["id"] == @context.comment_id }
               .reject { |comment| comment.dig("user", "login") == CommitIdentity.bot_login }
               .reject { |comment| since && Time.parse(comment["created_at"].to_s) <= since }
               .reject { |comment| command_comment?(comment["body"].to_s) }
               .map { |comment| comment.merge("body" => strip_details(comment["body"].to_s)) }
      end

      # @return [Time, nil] committer time of the bot's last commit on the
      #   checked-out branch, nil when the bot never committed
      sig { returns(T.nilable(Time)) }
      def last_bot_commit_time
        out, _err, ok = @executor.capture(
          "git", "log", "-1", "--format=%cI", "--author=#{CommitIdentity.bot_login}", chdir: @workdir,
        )
        time = out.strip
        ok && !time.empty? ? Time.parse(time) : nil
      end

      # @return [Boolean] whether the body parses to at least one command
      sig { params(body: String).returns(T::Boolean) }
      def command_comment?(body)
        CommentParser.new(prefix: @prefix).parse(body).any?
      rescue CommentParser::ParseError
        true
      end

      # Collapsed <details> blocks carry appended word/source diffs — noise
      # describing stale states, not feedback.
      #
      # @return [String]
      sig { params(text: String).returns(String) }
      def strip_details(text)
        text.gsub(%r{<details>.*?</details>}m, "(collapsed diff omitted)")
      end

      # @return [String] the PR-iteration pass's prompt
      sig do
        params(
          segment: CommentParser::Segment,
          branch: String,
          threads: T::Array[T::Hash[String, T.untyped]],
          comments: T::Array[T::Hash[String, T.untyped]],
          capture: T::Boolean,
        ).returns(String)
      end
      def iteration_prompt(segment, branch, threads, comments, capture: false)
        summary_index = threads.size + 1
        <<~PROMPT
          You are ai-flow, iterating on pull request #{@context.owner_repo}##{@context.number} in this checkout (branch `#{branch}`).

          INSTRUCTION: #{segment.instruction.empty? ? "(none — address the outstanding feedback below)" : segment.instruction}
          #{segment.quote ? "Quoted context:\n#{segment.quote}\n" : ""}
          OUTSTANDING FEEDBACK:
          #{feedback_descriptions(threads, comments)}

          #{org_invariants_section}Rules:
          - The instruction, when present, is the priority; the feedback items are scope and context.
          - Address each review thread on its merits — a thread may need a code change, or just an explanation of why none is needed.
          - `gh` is available: inspect failing checks with `gh pr checks #{@context.number}` and `gh run view` when CI is part of the feedback.
          - Run the repository's test suite if one is configured.
          - Do not create commits, branches, or PRs — the surrounding tooling owns git. Work only inside this checkout.
          - In any text destined for GitHub, reference files as GitHub URLs (https://github.com/<owner>/<repo>/blob/HEAD/<path>), never as local filesystem paths.
          #{capture_section(capture)}
          OUTPUT FORMAT — follow exactly, no other text before or after:
          <<<AI-FLOW:SEGMENT 1>>>
          (one line: what you did about THREAD 1, or why no change was needed)
          (…one block per THREAD, in order)
          <<<AI-FLOW:SEGMENT #{summary_index}>>>
          (a short summary of the whole iteration)
        PROMPT
      end

      # @return [String] the learning-capture rubric block (blank line
      #   padded), empty when capture is off for this pass
      sig { params(capture: T::Boolean).returns(String) }
      def capture_section(capture)
        capture ? "\n#{@learn.capture_prompt_section}\n" : ""
      end

      # @return [String] numbered THREAD blocks, then the fresh conversation
      sig do
        params(
          threads: T::Array[T::Hash[String, T.untyped]],
          comments: T::Array[T::Hash[String, T.untyped]],
        ).returns(String)
      end
      def feedback_descriptions(threads, comments)
        thread_blocks = threads.each_with_index.map do |thread, index|
          conversation = thread["comments"].map { |comment| "@#{comment["author"]}: #{comment["body"]}" }.join("\n")
          "<<<THREAD #{index + 1}>>> (#{thread["path"]})\n#{thread["diff_hunk"]}\n#{conversation}"
        end
        comment_blocks = comments.map do |comment|
          "Conversation comment from @#{comment.dig("user", "login")}:\n#{comment["body"]}"
        end
        blocks = thread_blocks + comment_blocks
        blocks.empty? ? "(none — the instruction is the whole scope)" : blocks.join("\n\n")
      end

      # Every swept thread gets its disposition (a generic note when the
      # agent skipped its block) — never resolved by the bot, and a failed
      # reply never fails the iteration.
      #
      # @return [void]
      sig do
        params(
          threads: T::Array[T::Hash[String, T.untyped]],
          parsed: AgentOutput::Parsed,
          sha: T.nilable(String),
        ).void
      end
      def reply_to_threads(threads, parsed, sha)
        threads.each_with_index do |thread, index|
          anchor = thread["first_comment_id"]
          next unless anchor

          disposition = parsed.segments[index + 1] || "Considered in this iteration."
          body = [disposition, sha && "Addressed in #{commit_link(sha)}."].compact.join("\n\n")
          begin
            @github.reply_to_review_comment(@context.owner_repo, @context.number, anchor, body)
          rescue GitHub::Error => e
            warn "ai-flow: reply to review thread (comment #{anchor}) failed: #{e.message}"
          end
        end
      end

      # @return [String]
      sig do
        params(
          parsed: AgentOutput::Parsed,
          threads: T::Array[T::Hash[String, T.untyped]],
          sha: T.nilable(String),
          capture_note: T.nilable(String),
        ).returns(String)
      end
      def iteration_result(parsed, threads, sha, capture_note = nil)
        summary = parsed.segments[threads.size + 1]
        headline =
          if sha
            "✅ **/build** — committed #{commit_link(sha)}."
          else
            "⚠️ **/build** — the agent made no changes."
          end
        [headline, summary, capture_note, workflows_note(pull_request_url)].compact.join("\n\n")
      end

      # @return [String] the PR under iteration — this mode only runs on PR
      #   comments, so the context number is the PR number
      sig { returns(String) }
      def pull_request_url
        "https://github.com/#{@context.owner_repo}/pull/#{@context.number}"
      end

      # ---- Workflow-file exclusion (both modes) ----

      # Capture the staged #{WORKFLOWS_DIR} diff, then unstage and revert
      # those files so the commit never carries them. Ordered checkout-last:
      # the diff must be read before the working tree is restored.
      #
      # @return [void]
      sig { params(dir: String).void }
      def extract_workflows_patch(dir)
        # Reset first: a Build instance is reused across --split sub-issue
        # builds, and one sub-issue's patch must not haunt the next panel.
        @workflows_patch = nil
        patch, = @executor.capture(
          "git", "diff", "--cached", "--", WORKFLOWS_DIR, chdir: dir,
        )
        return if patch.strip.empty?

        @workflows_patch = patch
        # Always in the run log too — the --split orchestrator's checklist
        # panel doesn't carry per-build notes, so the log is the guaranteed
        # surface.
        $stdout.puts "::group::ai-flow: excluded workflow changes (App has no workflows permission)"
        $stdout.puts patch
        $stdout.puts "::endgroup::"
        run!(["git", "reset", "-q", "HEAD", "--", WORKFLOWS_DIR], chdir: dir)
        # Working-tree restore is hygiene (the commit reads the index only)
        # and best-effort: checkout errors when the agent only *added*
        # workflow files (no tracked paths match), which clean covers.
        @executor.capture("git", "checkout", "-q", "--", WORKFLOWS_DIR, chdir: dir)
        @executor.capture("git", "clean", "-fdq", "--", WORKFLOWS_DIR, chdir: dir)
      end

      # @param pr_url [String, nil] the PR the patch applies onto; nil when
      #   no PR exists (the agent changed nothing outside workflow files)
      # @return [String, nil] the suggested-patch panel block, nil when the
      #   agent never touched workflow files
      sig { params(pr_url: T.nilable(String)).returns(T.nilable(String)) }
      def workflows_note(pr_url)
        patch = @workflows_patch
        return nil unless patch

        pr_url ? workflows_apply_note(pr_url, patch) : workflows_diff_note(patch)
      end

      # A copy-paste command that lands the patch on the PR branch under the
      # human's own credentials — the workflows restriction is on who pushes,
      # not whose PR it is. The heredoc delimiter can't collide with the diff
      # body: every unified-diff line carries a prefix character, so a bare
      # PATCH line never occurs. --index stages new files too, which
      # `commit -a` would miss.
      #
      # @return [String]
      sig { params(pr_url: String, patch: String).returns(String) }
      def workflows_apply_note(pr_url, patch)
        <<~NOTE.strip
          #{workflows_intro} Paste this in your clone to apply them onto the PR under your own credentials:

          <details><summary>apply the workflow patch (one paste)</summary>

          ```bash
          gh pr checkout #{pr_url} && git apply --index <<'PATCH' && git commit -m "Apply ai-flow's proposed workflow changes" && git push
          #{patch.strip}
          PATCH
          ```

          </details>
        NOTE
      end

      # No PR to apply onto — the bare diff is all there is to offer.
      #
      # @return [String]
      sig { params(patch: String).returns(String) }
      def workflows_diff_note(patch)
        <<~NOTE.strip
          #{workflows_intro} Apply them yourself if wanted:

          <details><summary>suggested workflow patch</summary>

          ```diff
          #{patch.strip}
          ```

          </details>
        NOTE
      end

      # @return [String]
      sig { returns(String) }
      def workflows_intro
        "⚠️ The agent proposed changes under `#{WORKFLOWS_DIR}/` — the ai-flow App has no `workflows` " \
          "permission (by design; see d3mlabs/ai-flow docs/attribution.md), so they were left out of the commit."
      end

      # @return [String]
      sig { params(sha: String).returns(String) }
      def commit_link(sha)
        "[`#{sha[0, 7]}`](https://github.com/#{@context.owner_repo}/commit/#{sha})"
      end

      # @return [String] the invariants block ready to splice into a prompt
      #   (trailing blank line included), empty on unconfigured machines
      sig { returns(String) }
      def org_invariants_section
        block = @org_invariants.prompt_block
        block ? "#{block}\n\n" : ""
      end

      # @param segment [CommentParser::Segment]
      # @return [String, nil] the pushed commit sha, nil when nothing changed
      sig { params(segment: CommentParser::Segment, capture: T::Boolean).returns(T.nilable(String)) }
      def commit_and_push(segment, capture: false)
        # The job checks the dispatcher out into .ai-flow inside this
        # workspace — a bare `git add -A` would commit it as a gitlink.
        run!(["git", "add", "-A", "--", ":(exclude).ai-flow"], chdir: @workdir)
        @learn.extract_capture(@workdir) if capture
        extract_workflows_patch(@workdir)
        status, = @executor.capture("git", "diff", "--cached", "--name-only", chdir: @workdir)
        return nil if status.strip.empty?

        # The trailing to_s narrows the slice's T.nilable(String): a slice
        # starting at 0 never returns nil.
        headline = segment.instruction.lines.first.to_s.strip[0, 60].to_s
        headline = "iterate on PR feedback" if headline.empty?
        message = CommitIdentity.message_with_requester("ai-flow /build: #{headline}", @context)
        run!(["git", *CommitIdentity.git_flags(@github), "commit", "-m", message], chdir: @workdir)
        run!(["git", "push"], chdir: @workdir)
        sha, = @executor.capture("git", "rev-parse", "HEAD", chdir: @workdir)
        sha.strip
      end

      # ---- Issue (plan) mode ----

      # Org-wide issues that target code declare it (Target repos: line);
      # otherwise the code repo is the issue's own repo.
      #
      # @return [String] "owner/repo"
      sig { params(issue: GitHub::Issue, issue_repo: String).returns(String) }
      def target_repo_for(issue, issue_repo)
        target_line = issue.body[/^Target repos?:\s*(.+)$/, 1]
        return issue_repo unless target_line

        first_target = target_line.split(",").first.to_s.strip
        first_target.empty? ? issue_repo : first_target
      end

      # @return [String] ai/<n>-<slug>
      sig { params(issue: GitHub::Issue).returns(String) }
      def branch_name(issue)
        slug = issue.title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 40].to_s.sub(/-\z/, "")
        "ai/#{issue.number}-#{slug.empty? ? "build" : slug}"
      end

      # An isolated worktree per build, so concurrent agents never share a
      # workspace. Same-repo builds branch off the job checkout (warm);
      # cross-repo builds (org-wide plans) clone via gh.
      #
      # @yieldparam worktree [String] the worktree's path
      # @return [Object] the block's value
      sig do
        type_parameters(:Result)
          .params(
            code_repo: String,
            blk: T.proc.params(worktree: String).returns(T.type_parameter(:Result)),
          ).returns(T.type_parameter(:Result))
      end
      def in_worktree(code_repo, &blk)
        Dir.mktmpdir("ai-flow-build-") do |dir|
          worktree = File.join(dir, "worktree")
          if code_repo == @context.owner_repo
            default = @github.default_branch(code_repo)
            run!(["git", "fetch", "origin", default], chdir: @workdir)
            # Long-lived runner checkouts accumulate stale worktree metadata
            # (crashed jobs, tmpdirs GC'd from under git); prune or the add
            # eventually fails.
            run!(["git", "worktree", "prune"], chdir: @workdir)
            run!(["git", "worktree", "add", "--detach", worktree, "origin/#{default}"], chdir: @workdir)
            begin
              yield worktree
            ensure
              @executor.capture("git", "worktree", "remove", "--force", worktree, chdir: @workdir)
            end
          else
            run!(["gh", "repo", "clone", code_repo, worktree], chdir: dir)
            yield worktree
          end
        end
      end

      # @param worktree [String]
      # @param branch [String]
      # @return [void]
      sig { params(worktree: String, branch: String).void }
      def create_branch(worktree, branch)
        run!(["git", "checkout", "-B", branch], chdir: worktree)
      end

      # @return [String] the issue-mode pass's prompt
      sig do
        params(issue: GitHub::Issue, extra_instruction: String, capture: T::Boolean)
          .returns(String)
      end
      def build_prompt(issue, extra_instruction, capture: false)
        <<~PROMPT
          You are ai-flow, implementing a plan in this repository checkout.

          ISSUE #{issue.repo || @context.owner_repo}##{issue.number}: #{issue.title}
          <<<BODY>>>
          #{PlanBody.from_issue_body(issue.body)}
          <<<END BODY>>>

          #{parent_context(issue)}
          #{extra_instruction.empty? ? "" : "Additional instruction: #{extra_instruction}"}

          #{org_invariants_section}Implement the issue completely: code, tests, and any documentation it calls for. Follow the repository's conventions and run its test suite if one is configured. Do not create commits, branches, or PRs — the surrounding tooling owns git. Work only inside this checkout. In any text destined for GitHub, reference files as GitHub URLs (https://github.com/<owner>/<repo>/blob/HEAD/<path>), never as local filesystem paths.
          #{capture_section(capture)}
        PROMPT
      end

      # Build-time learning capture runs for same-repo builds unless the repo
      # switched it off (learn.on_build in .github/ai-flow.yml, default on).
      # Cross-repo builds (org-wide plans) skip it: the capture's branches and
      # panel are keyed to the command's own repo, not the code repo.
      #
      # @return [Boolean]
      sig { params(code_repo: String, config_dir: String).returns(T::Boolean) }
      def capture_learnings?(code_repo, config_dir)
        code_repo == @context.owner_repo && RepoConfig.load(config_dir).learn_on_build?
      end

      # @return [Hash] the built issue as a capture source — keyed on the
      #   issue (not the comment surface) so --split sub-builds each get
      #   their own learning draft
      sig { params(issue: GitHub::Issue, issue_repo: String).returns(T::Hash[Symbol, T.untyped]) }
      def issue_capture_source(issue, issue_repo)
        {
          branch: "ai/learn-issue-#{issue.number}",
          ref: "#{issue_repo}##{issue.number}",
          url: issue.html_url,
        }
      end

      # @return [Hash] the iterated PR as a capture source — the same branch
      #   a bare /learn sweep uses on this PR, so either pass refines the
      #   other's draft (the linked-update rule)
      sig { returns(T::Hash[Symbol, T.untyped]) }
      def pr_capture_source
        {
          branch: "ai/learn-pr-#{@context.number}",
          ref: "#{@context.owner_repo}##{@context.number}",
          url: pull_request_url,
        }
      end

      # Sub-issues are thin tracking shards — the parent plan is the spec.
      # The native parent relationship (never prose) locates it, and the
      # sibling titles bound this subtask's scope so wave-built sub-issues
      # don't overlap.
      #
      # @return [String] empty for parentless issues
      sig { params(issue: GitHub::Issue).returns(String) }
      def parent_context(issue)
        issue_repo = issue.repo || @context.owner_repo
        parent = @github.parent_issue(issue_repo, issue.number)
        return "" unless parent

        # GraphQL always reports the parent's repository (nameWithOwner); the
        # issue's own repo is a defensive fallback, never expected to apply.
        parent_repo = parent.repo || issue_repo
        siblings = @github.sub_issues(parent_repo, parent.number)
                          .reject { |sub| sub.number == issue.number && (sub.repo || parent_repo) == issue_repo }
        sibling_list = siblings.map { |sub| "- #{sub.title}" }.join("\n")
        <<~CONTEXT
          This issue is one subtask of the parent plan #{parent_repo}##{parent.number}: #{parent.title}
          <<<PARENT PLAN>>>
          #{PlanBody.from_issue_body(parent.body)}
          <<<END PARENT PLAN>>>

          Sibling subtasks — OUT OF SCOPE here, implement only this issue's subtask:
          #{sibling_list.empty? ? "(none)" : sibling_list}
        CONTEXT
      end

      # @return [Boolean] whether there was anything to commit
      sig { params(worktree: String, issue: GitHub::Issue, capture: T::Boolean).returns(T::Boolean) }
      def commit_all(worktree, issue, capture: false)
        run!(["git", "add", "-A"], chdir: worktree)
        @learn.extract_capture(worktree) if capture
        extract_workflows_patch(worktree)
        status, = @executor.capture("git", "diff", "--cached", "--name-only", chdir: worktree)
        return false if status.strip.empty?

        message = CommitIdentity.message_with_requester("ai-flow /build: #{issue.title}", @context)
        run!(["git", *CommitIdentity.git_flags(@github), "commit", "-m", message], chdir: worktree)
        true
      end

      # /build commits are unsigned (plain git in the worktree), so a repo
      # enforcing signed commits rejects the push — fail with the pointer to
      # the documented upgrade path rather than a bare git error.
      #
      # @return [void]
      sig { params(worktree: String, branch: String).void }
      def push_branch(worktree, branch)
        _out, err, ok = @executor.capture(
          "git", "push", "-u", "origin", branch, "--force-with-lease", chdir: worktree,
        )
        return if ok

        raise GitHub::Error,
              "git push failed: #{err.strip} — if this repo enforces signed commits, " \
              "see d3mlabs/ai-flow docs/attribution.md (createCommitOnBranch upgrade path)"
      end

      # Back-references always use the full `Closes owner/repo#n` form (valid
      # same-repo too, so no branching between repo-scoped and org-wide plans).
      # The PR is the bot's proposal; the accountable human is named in the
      # body and assigned to the PR (see docs/attribution.md).
      #
      # @return [Hash] the created PR
      sig do
        params(code_repo: String, issue_repo: String, issue: GitHub::Issue, branch: String)
          .returns(T::Hash[String, T.untyped])
      end
      def open_pull_request(code_repo, issue_repo, issue, branch)
        requested_by = @context.commenter_login ? "Requested by @#{@context.commenter_login}.\n\n" : ""
        body = <<~BODY
          Implements #{issue.html_url}.

          #{requested_by}Closes #{issue_repo}##{issue.number}

          <!-- ai-flow:build ##{issue.number} -->
        BODY
        pr = @github.create_pull_request(
          code_repo,
          title: issue.title,
          body: body,
          head: branch,
          base: @github.default_branch(code_repo),
        )
        requester = @context.commenter_login
        @github.add_assignees(code_repo, pr.fetch("number"), [requester]) if requester
        pr
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
end
