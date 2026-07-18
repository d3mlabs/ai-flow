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
      # @param context [AiFlow::Context]
      # @param github [AiFlow::GitHub]
      # @param agent [AiFlow::Agent]
      # @param result_writer [AiFlow::ResultWriter]
      # @param executor [AiFlow::Executor]
      # @param workdir [String] the job's repo checkout
      # @param prefix [String] configured command prefix (to recognize old
      #   command comments during the feedback sweep)
      def initialize(context:, github:, agent:, result_writer:, executor:, workdir:, prefix: "")
        @context = context
        @github = github
        @agent = agent
        @result_writer = result_writer
        @executor = executor
        @workdir = workdir
        @prefix = prefix
      end

      # @param segment [CommentParser::Segment]
      # @return [void]
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
        @result_writer.write(@context, [[segment, [result, open_sub_issues_note].compact.join("\n\n")]])
      end

      # Build one issue end to end. Shared with the --split orchestrator.
      #
      # @param issue [GitHub::Issue]
      # @param extra_instruction [String]
      # @return [Hash, nil] the created PR, or nil when the agent changed nothing
      def build_issue(issue, extra_instruction: "")
        issue_repo = issue.repo || @context.owner_repo
        code_repo = target_repo_for(issue, issue_repo)
        branch = branch_name(issue)

        in_worktree(code_repo) do |worktree|
          create_branch(worktree, branch)
          @agent.launch(
            prompt: build_prompt(issue, extra_instruction), workdir: worktree, command: "build", force: true,
          )
          next nil unless commit_all(worktree, issue)

          push_branch(worktree, branch)
          open_pull_request(code_repo, issue_repo, issue, branch)
        end
      end

      private

      # ---- Split-state guards (issue mode) ----

      # An unapplied /split proposal makes the plan-of-record ambiguous;
      # building past it would silently discard the human's own staging —
      # refuse, naming the next command (never silent).
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
      def refuse_review_thread(segment)
        @result_writer.write(
          @context,
          [[segment, "ℹ️ **/build** — /build runs from the PR conversation, not a review thread. " \
                     "Leave the feedback as a plain comment here and post /build as a top-level " \
                     "comment — the sweep picks this thread up."]],
        )
      end

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

        output = @agent.launch(
          prompt: iteration_prompt(segment, branch, threads, comments),
          workdir: @workdir, command: "build", force: true,
        )
        parsed = AgentOutput.parse(output)
        sha = commit_and_push(segment)
        reply_to_threads(threads, parsed, sha)
        @result_writer.write(@context, [[segment, iteration_result(parsed, threads, sha)]])
      end

      # @return [String] the PR head branch, checked out in the job checkout
      def checkout_head_branch
        branch = @context.pr_head_ref ||
                 @github.api("repos/#{@context.owner_repo}/pulls/#{@context.number}").fetch("head").fetch("ref")
        run!("git", "fetch", "origin", branch, chdir: @workdir)
        run!("git", "checkout", branch, chdir: @workdir)
        branch
      end

      # Unresolved review threads, minus those a command started (a threaded
      # /ask and its answer are a handled conversation, not outstanding
      # feedback).
      #
      # @return [Array<Hash>]
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
      def last_bot_commit_time
        out, _err, ok = @executor.capture(
          "git", "log", "-1", "--format=%cI", "--author=#{CommitIdentity.bot_login}", chdir: @workdir,
        )
        time = out.strip
        ok && !time.empty? ? Time.parse(time) : nil
      end

      # @return [Boolean] whether the body parses to at least one command
      def command_comment?(body)
        CommentParser.new(prefix: @prefix).parse(body).any?
      rescue CommentParser::ParseError
        true
      end

      # Collapsed <details> blocks carry appended word/source diffs — noise
      # describing stale states, not feedback.
      def strip_details(text)
        text.gsub(%r{<details>.*?</details>}m, "(collapsed diff omitted)")
      end

      def iteration_prompt(segment, branch, threads, comments)
        summary_index = threads.size + 1
        <<~PROMPT
          You are ai-flow, iterating on pull request #{@context.owner_repo}##{@context.number} in this checkout (branch `#{branch}`).

          INSTRUCTION: #{segment.instruction.empty? ? "(none — address the outstanding feedback below)" : segment.instruction}
          #{segment.quote ? "Quoted context:\n#{segment.quote}\n" : ""}
          OUTSTANDING FEEDBACK:
          #{feedback_descriptions(threads, comments)}

          Rules:
          - The instruction, when present, is the priority; the feedback items are scope and context.
          - Address each review thread on its merits — a thread may need a code change, or just an explanation of why none is needed.
          - `gh` is available: inspect failing checks with `gh pr checks #{@context.number}` and `gh run view` when CI is part of the feedback.
          - Run the repository's test suite if one is configured.
          - Do not create commits, branches, or PRs — the surrounding tooling owns git. Work only inside this checkout.
          - In any text destined for GitHub, reference files as GitHub URLs (https://github.com/<owner>/<repo>/blob/HEAD/<path>), never as local filesystem paths.

          OUTPUT FORMAT — follow exactly, no other text before or after:
          <<<AI-FLOW:SEGMENT 1>>>
          (one line: what you did about THREAD 1, or why no change was needed)
          (…one block per THREAD, in order)
          <<<AI-FLOW:SEGMENT #{summary_index}>>>
          (a short summary of the whole iteration)
        PROMPT
      end

      # @return [String] numbered THREAD blocks, then the fresh conversation
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
      def iteration_result(parsed, threads, sha)
        summary = parsed.segments[threads.size + 1]
        headline =
          if sha
            "✅ **/build** — committed #{commit_link(sha)}."
          else
            "⚠️ **/build** — the agent made no changes."
          end
        [headline, summary].compact.join("\n\n")
      end

      # @return [String]
      def commit_link(sha)
        "[`#{sha[0, 7]}`](https://github.com/#{@context.owner_repo}/commit/#{sha})"
      end

      # @param segment [CommentParser::Segment]
      # @return [String, nil] the pushed commit sha, nil when nothing changed
      def commit_and_push(segment)
        # The job checks the dispatcher out into .ai-flow inside this
        # workspace — a bare `git add -A` would commit it as a gitlink.
        run!("git", "add", "-A", "--", ":(exclude).ai-flow", chdir: @workdir)
        status, = @executor.capture("git", "status", "--porcelain", "--", ":(exclude).ai-flow", chdir: @workdir)
        return nil if status.strip.empty?

        headline = segment.instruction.lines.first.to_s.strip[0, 60]
        headline = "iterate on PR feedback" if headline.empty?
        message = CommitIdentity.message_with_requester("ai-flow /build: #{headline}", @context)
        run!("git", *CommitIdentity.git_flags(@github), "commit", "-m", message, chdir: @workdir)
        run!("git", "push", chdir: @workdir)
        sha, = @executor.capture("git", "rev-parse", "HEAD", chdir: @workdir)
        sha.strip
      end

      # ---- Issue (plan) mode ----

      # Org-wide issues that target code declare it (Target repos: line);
      # otherwise the code repo is the issue's own repo.
      #
      # @return [String] "owner/repo"
      def target_repo_for(issue, issue_repo)
        target_line = issue.body[/^Target repos?:\s*(.+)$/, 1]
        return issue_repo unless target_line

        first_target = target_line.split(",").first.to_s.strip
        first_target.empty? ? issue_repo : first_target
      end

      # @return [String] ai/<n>-<slug>
      def branch_name(issue)
        slug = issue.title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 40].to_s.sub(/-\z/, "")
        "ai/#{issue.number}-#{slug.empty? ? "build" : slug}"
      end

      # An isolated worktree per build, so concurrent agents never share a
      # workspace. Same-repo builds branch off the job checkout (warm);
      # cross-repo builds (org-wide plans) clone via gh.
      def in_worktree(code_repo)
        Dir.mktmpdir("ai-flow-build-") do |dir|
          worktree = File.join(dir, "worktree")
          if code_repo == @context.owner_repo
            default = @github.default_branch(code_repo)
            run!("git", "fetch", "origin", default, chdir: @workdir)
            # Long-lived runner checkouts accumulate stale worktree metadata
            # (crashed jobs, tmpdirs GC'd from under git); prune or the add
            # eventually fails.
            run!("git", "worktree", "prune", chdir: @workdir)
            run!("git", "worktree", "add", "--detach", worktree, "origin/#{default}", chdir: @workdir)
            begin
              yield worktree
            ensure
              @executor.capture("git", "worktree", "remove", "--force", worktree, chdir: @workdir)
            end
          else
            run!("gh", "repo", "clone", code_repo, worktree, chdir: dir)
            yield worktree
          end
        end
      end

      def create_branch(worktree, branch)
        run!("git", "checkout", "-B", branch, chdir: worktree)
      end

      def build_prompt(issue, extra_instruction)
        <<~PROMPT
          You are ai-flow, implementing a plan in this repository checkout.

          ISSUE #{issue.repo || @context.owner_repo}##{issue.number}: #{issue.title}
          <<<BODY>>>
          #{PlanBody.from_issue_body(issue.body)}
          <<<END BODY>>>

          #{parent_context(issue)}
          #{extra_instruction.empty? ? "" : "Additional instruction: #{extra_instruction}"}

          Implement the issue completely: code, tests, and any documentation it calls for. Follow the repository's conventions and run its test suite if one is configured. Do not create commits, branches, or PRs — the surrounding tooling owns git. Work only inside this checkout. In any text destined for GitHub, reference files as GitHub URLs (https://github.com/<owner>/<repo>/blob/HEAD/<path>), never as local filesystem paths.
        PROMPT
      end

      # Sub-issues are thin tracking shards — the parent plan is the spec.
      # The native parent relationship (never prose) locates it, and the
      # sibling titles bound this subtask's scope so wave-built sub-issues
      # don't overlap.
      #
      # @return [String] empty for parentless issues
      def parent_context(issue)
        issue_repo = issue.repo || @context.owner_repo
        parent = @github.parent_issue(issue_repo, issue.number)
        return "" unless parent

        siblings = @github.sub_issues(parent.repo, parent.number)
                          .reject { |sub| sub.number == issue.number && (sub.repo || parent.repo) == issue_repo }
        sibling_list = siblings.map { |sub| "- #{sub.title}" }.join("\n")
        <<~CONTEXT
          This issue is one subtask of the parent plan #{parent.repo}##{parent.number}: #{parent.title}
          <<<PARENT PLAN>>>
          #{PlanBody.from_issue_body(parent.body)}
          <<<END PARENT PLAN>>>

          Sibling subtasks — OUT OF SCOPE here, implement only this issue's subtask:
          #{sibling_list.empty? ? "(none)" : sibling_list}
        CONTEXT
      end

      # @return [Boolean] whether there was anything to commit
      def commit_all(worktree, issue)
        run!("git", "add", "-A", chdir: worktree)
        status, = @executor.capture("git", "status", "--porcelain", chdir: worktree)
        return false if status.strip.empty?

        message = CommitIdentity.message_with_requester("ai-flow /build: #{issue.title}", @context)
        run!("git", *CommitIdentity.git_flags(@github), "commit", "-m", message, chdir: worktree)
        true
      end

      # /build commits are unsigned (plain git in the worktree), so a repo
      # enforcing signed commits rejects the push — fail with the pointer to
      # the documented upgrade path rather than a bare git error.
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
        if @context.commenter_login
          @github.add_assignees(code_repo, pr.fetch("number"), [@context.commenter_login])
        end
        pr
      end

      def run!(*argv, chdir:)
        _out, err, ok = @executor.capture(*argv, chdir: chdir)
        raise GitHub::Error, "#{argv.take(2).join(" ")} failed: #{err.strip}" unless ok
      end
    end
  end
end
