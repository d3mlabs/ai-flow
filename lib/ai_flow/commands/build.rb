# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module AiFlow
  module Commands
    # /build — run the headless agent in an isolated worktree on branch
    # ai/<n>-<slug>, then push and open the PR ourselves (`gh pr create`
    # equivalent) with the closing reference and the ai-flow marker in the
    # body — deterministic because the script authors the PR, not the agent.
    class Build
      # @param context [AiFlow::Context]
      # @param github [AiFlow::GitHub]
      # @param agent [AiFlow::Agent]
      # @param result_writer [AiFlow::ResultWriter]
      # @param executor [AiFlow::Executor]
      # @param workdir [String] the job's repo checkout
      def initialize(context:, github:, agent:, result_writer:, executor:, workdir:)
        @context = context
        @github = github
        @agent = agent
        @result_writer = result_writer
        @executor = executor
        @workdir = workdir
      end

      # @param segment [CommentParser::Segment]
      # @return [void]
      def run(segment)
        issue = @github.issue(@context.owner_repo, @context.number)
        pr = build_issue(issue, extra_instruction: segment.instruction)
        result =
          if pr
            "✅ **/build** — opened #{pr.fetch("html_url")}"
          else
            "⚠️ **/build** — the agent made no changes, so no PR was opened."
          end
        @result_writer.write(@context, [[segment, result]])
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

          #{extra_instruction.empty? ? "" : "Additional instruction: #{extra_instruction}"}

          Implement the issue completely: code, tests, and any documentation it calls for. Follow the repository's conventions and run its test suite if one is configured. Do not create commits, branches, or PRs — the surrounding tooling owns git. Work only inside this checkout.
        PROMPT
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
