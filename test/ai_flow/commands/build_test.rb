# frozen_string_literal: true

require "test_helper"
require "support/fakes"

transform!(RSpock::AST::Transformation)
class AiFlow::Commands::BuildTest < Minitest::Test
  REPO = "d3mlabs/demo"

  # Records every subprocess invocation as a joined command line (strings
  # survive RSpock's block-parameter destructuring where arrays don't);
  # `dirty` controls whether the staged diff reports changes (i.e. whether
  # the agent "wrote" anything), `workflows_patch` seeds a staged diff under
  # .github/workflows (the exclusion path).
  class RecordingExecutor
    attr_reader :command_lines, :refreshes

    def initialize(dirty: true, workflows_patch: "")
      @dirty = dirty
      @workflows_patch = workflows_patch
      @command_lines = []
      @refreshes = 0
    end

    def refresh_auth!
      @refreshes += 1
    end

    def capture(*argv, stdin: nil, chdir: nil, env: {})
      @command_lines << argv.join(" ")
      out =
        if argv.join(" ").start_with?("git diff --cached -- .github/workflows")
          @workflows_patch
        elsif argv.take(4) == %w[git diff --cached --name-only] && @dirty
          "lib/thing.rb\n"
        elsif argv.take(2) == %w[git rev-parse]
          "abc1234def5678\n"
        else
          ""
        end
      [out, "", true]
    end
  end

  def run_build(github:, executor:, body: "/build", context: nil, agent: FakeAgent.new(["done"]))
    context ||= ContextBuilder.issue_comment(number: 7, body: body)
    segment = AiFlow::CommentParser.new.parse(body).first
    AiFlow::Commands::Build.new(
      context: context,
      github: github,
      agent: agent,
      result_writer: AiFlow::ResultWriter.new(github: github),
      executor: executor,
      workdir: Dir.pwd,
    ).run(segment)
  end

  test "/build prunes worktrees, commits as the bot with the requester co-authored, and opens an attributed PR" do
    Given "an issue and a dirty agent run"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: "# Carve system\n")
    executor = RecordingExecutor.new

    When "building"
    run_build(github: github, executor: executor)
    command_lines = executor.command_lines
    commit_line = command_lines.find { |line| line.include?(" commit -m ") }

    Then "worktrees are pruned first, the bot authors the commit with the human co-authored, and the PR is attributed"
    command_lines.include?("git worktree prune")
    command_lines.index("git worktree prune") < command_lines.index { |line| line.include?("worktree add") }
    commit_line.include?("-c user.name=ai-flow[bot]")
    commit_line.include?("-c user.email=424242+ai-flow[bot]@users.noreply.github.com")
    commit_line.include?("ai-flow /build: Carve system")
    commit_line.include?("Co-authored-by: jpduchesne <111+jpduchesne@users.noreply.github.com>")
    github.pull_request_bodies.fetch(0).include?("Requested by @jpduchesne.")
    github.pull_request_bodies.fetch(0).include?("Closes #{REPO}#7")
    github.calls.include?([:add_assignees, REPO, 900, ["jpduchesne"]])
    github.comment_edits.fetch(55).include?("✅ **/build**")

    Cleanup
    nil
  end

  test "/build on a PR iterates on the head branch and replies to swept threads" do
    Given "a PR with an unresolved review thread and a /build with an instruction"
    github = FakeGitHub.new
    github.seed_review_threads(REPO, 7, [
      {
        "path" => "lib/thing.rb", "diff_hunk" => "@@ -1 +1 @@",
        "first_comment_id" => 91,
        "comments" => [{ "author" => "jpduchesne", "body" => "this walk is O(n^2)", "url" => "u" }],
      },
      # A thread a command started is a handled conversation, not feedback.
      {
        "path" => "lib/other.rb", "diff_hunk" => "@@ -2 +2 @@",
        "first_comment_id" => 92,
        "comments" => [{ "author" => "jpduchesne", "body" => "/ask why this?", "url" => "u" }],
      },
    ])
    context = ContextBuilder.issue_comment(number: 7, body: "/build fix the failing CI", pull_request: true)
    executor = RecordingExecutor.new
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nRewrote the walk as a single pass.\n" \
                           "<<<AI-FLOW:SEGMENT 2>>>\nFixed CI and the quadratic walk."])

    When "iterating"
    run_build(github: github, executor: executor, body: "/build fix the failing CI", context: context, agent: agent)

    Then "head branch checked out, feedback in the prompt, commit pushed, thread and panel updated"
    executor.command_lines.include?("git fetch origin feature-branch")
    executor.command_lines.include?("git checkout feature-branch")
    agent.prompts.first.include?("INSTRUCTION: fix the failing CI")
    agent.prompts.first.include?("<<<THREAD 1>>> (lib/thing.rb)")
    agent.prompts.first.include?("this walk is O(n^2)")
    executor.command_lines.any? { |line| line.include?("commit -m") && line.include?("ai-flow /build: fix the failing CI") }
    executor.command_lines.include?("git add -A -- :(exclude).ai-flow")
    executor.command_lines.include?("git push")
    github.calls.map(&:first).none? { |kind| kind == :create_pull_request }
    github.calls.include?([:reply_to_review_comment, REPO, 7, 91])
    !github.calls.include?([:reply_to_review_comment, REPO, 7, 92])
    !agent.prompts.first.include?("/ask why this?")
    github.comments.first.include?("Rewrote the walk as a single pass.")
    github.comments.first.include?("abc1234")
    github.comment_edits.fetch(55).include?("✅ **/build** — committed")
    github.comment_edits.fetch(55).include?("Fixed CI and the quadratic walk.")

    Cleanup
    nil
  end

  test "a bare /build sweeps fresh conversation comments as feedback" do
    Given "a PR with a plain feedback comment and no review threads"
    github = FakeGitHub.new
    github.seed_issue_comment(REPO, 7, id: 40, body: "please also update the README")
    context = ContextBuilder.issue_comment(number: 7, body: "/build", pull_request: true)
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nUpdated the README."])

    When "iterating"
    run_build(github: github, executor: RecordingExecutor.new, body: "/build", context: context, agent: agent)

    Then "the comment is the sweep's scope and the iteration commits"
    agent.prompts.first.include?("Conversation comment from @jpduchesne:")
    agent.prompts.first.include?("please also update the README")
    github.comment_edits.fetch(55).include?("✅ **/build** — committed")

    Cleanup
    nil
  end

  test "a bare /build with nothing outstanding is a friendly no-op" do
    Given "a PR with no threads, no fresh comments, and no instruction"
    github = FakeGitHub.new
    context = ContextBuilder.issue_comment(number: 7, body: "/build", pull_request: true)
    agent = FakeAgent.new([])

    When "iterating"
    run_build(github: github, executor: RecordingExecutor.new, body: "/build", context: context, agent: agent)

    Then "no agent run, no commit, an ℹ️ panel"
    agent.prompts.empty?
    github.comment_edits.fetch(55).include?("ℹ️ **/build** — nothing to address")

    Cleanup
    nil
  end

  test "/build in a review thread is refused with a pointer to the conversation" do
    Given "a /build posted inside a review thread"
    github = FakeGitHub.new
    context = ContextBuilder.review_comment(number: 3, body: "/build fix this")
    executor = RecordingExecutor.new
    agent = FakeAgent.new([])

    When "running"
    run_build(github: github, executor: executor, body: "/build fix this", context: context, agent: agent)

    Then "no agent, no git, an in-thread panel pointing at top-level /build"
    agent.prompts.empty?
    executor.command_lines.empty?
    github.comment_edits.fetch(9).include?("ℹ️ **/build** — /build runs from the PR conversation")
    github.calls.map(&:first).include?(:update_review_comment)

    Cleanup
    nil
  end

  test "/build refuses on a plan with a staged /split proposal" do
    Given "an issue whose body carries an unapplied Subtasks spec"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: <<~BODY)
      # Carve system

      ## Subtasks
      #{AiFlow::SubtasksSection::SPEC_MARKER}

      ```yaml
      - title: "Server API"
        repo: #{REPO}
      ```
    BODY
    executor = RecordingExecutor.new
    agent = FakeAgent.new([])

    When "building"
    run_build(github: github, executor: executor, agent: agent)

    Then "no agent, no git, an ℹ️ panel naming /split --apply"
    agent.prompts.empty?
    executor.command_lines.empty?
    github.comment_edits.fetch(55).include?("staged /split proposal")
    github.comment_edits.fetch(55).include?("/split --apply")

    Cleanup
    nil
  end

  test "/build on a plan with open sub-issues proceeds and notes them" do
    Given "an issue with applied sub-issues still open"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: "# Carve system\n")
    github.seed_sub_issues(REPO, 7, [
      AiFlow::GitHub::Issue.new(
        number: 12, title: "Server API", body: "", updated_at: "2026-07-13T00:00:00Z",
        html_url: "https://github.com/#{REPO}/issues/12", state: "open", repo: REPO,
      ),
    ])

    When "building"
    run_build(github: github, executor: RecordingExecutor.new)

    Then "the whole-plan PR opened and the panel names the open sub-issues"
    github.calls.map(&:first).include?(:create_pull_request)
    github.comment_edits.fetch(55).include?("✅ **/build**")
    github.comment_edits.fetch(55).include?("open sub-issue(s) (#{REPO}#12)")

    Cleanup
    nil
  end

  test "/build on a sub-issue carries the parent plan and sibling scope in the prompt" do
    Given "a thin sub-issue whose native parent is the plan, with a sibling subtask"
    github = FakeGitHub.new
    github.seed_issue(REPO, 12, title: "Server API", body: "Part of #{REPO}#7.\n")
    github.seed_issue(REPO, 7, title: "Carve system", body: "# Carve system\n\nThe full spec lives here.\n")
    github.seed_parent(REPO, 12, github.issue(REPO, 7))
    github.seed_sub_issues(REPO, 7, [
      AiFlow::GitHub::Issue.new(
        number: 12, title: "Server API", body: "Part of #{REPO}#7.\n", updated_at: "2026-07-13T00:00:00Z",
        html_url: "https://github.com/#{REPO}/issues/12", state: "open", repo: REPO,
      ),
      AiFlow::GitHub::Issue.new(
        number: 13, title: "Client UI", body: "Part of #{REPO}#7.\n", updated_at: "2026-07-13T00:00:00Z",
        html_url: "https://github.com/#{REPO}/issues/13", state: "open", repo: REPO,
      ),
    ])
    agent = FakeAgent.new(["done"])
    context = ContextBuilder.issue_comment(number: 12, body: "/build")

    When "building the sub-issue"
    run_build(github: github, executor: RecordingExecutor.new, context: context, agent: agent)

    Then "the prompt holds the parent plan body and fences the sibling out of scope"
    agent.prompts.first.include?("subtask of the parent plan #{REPO}#7: Carve system")
    agent.prompts.first.include?("<<<PARENT PLAN>>>")
    agent.prompts.first.include?("The full spec lives here.")
    agent.prompts.first.include?("OUT OF SCOPE")
    agent.prompts.first.include?("- Client UI")
    !agent.prompts.first.include?("- Server API")

    Cleanup
    nil
  end

  test "workflow-file changes are excluded from the commit and panelled as a suggested patch" do
    Given "an agent run that edited a workflow file alongside code"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: "# Carve system\n")
    patch = "diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml\n+    extra: step\n"
    executor = RecordingExecutor.new(workflows_patch: patch)

    When "building"
    run_build(github: github, executor: executor)
    lines = executor.command_lines

    Then "workflows are unstaged before the commit, and the panel carries the patch"
    lines.include?("git reset -q HEAD -- .github/workflows")
    lines.include?("git checkout -q -- .github/workflows")
    lines.include?("git clean -fdq -- .github/workflows")
    lines.index { |line| line.include?("reset -q HEAD") } < lines.index { |line| line.include?(" commit -m ") }
    github.calls.map(&:first).include?(:create_pull_request)
    github.comment_edits.fetch(55).include?("no `workflows` permission")
    github.comment_edits.fetch(55).include?("extra: step")

    Cleanup
    nil
  end

  test "an agent run that only touched workflow files commits nothing but still surfaces the patch" do
    Given "a staged diff living entirely under .github/workflows"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: "# Carve system\n")
    patch = "diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml\n+    extra: step\n"
    executor = RecordingExecutor.new(dirty: false, workflows_patch: patch)

    When "building"
    run_build(github: github, executor: executor)

    Then "no commit, no PR — but the human still gets the patch to apply"
    executor.command_lines.none? { |line| line.include?(" commit -m ") }
    github.calls.map(&:first).none? { |kind| kind == :create_pull_request }
    github.comment_edits.fetch(55).include?("⚠️ **/build** — the agent made no changes, so no PR was opened.")
    github.comment_edits.fetch(55).include?("extra: step")

    Cleanup
    nil
  end

  test "PR iteration excludes workflow files the same way" do
    Given "a PR iteration whose agent touched a workflow file"
    github = FakeGitHub.new
    context = ContextBuilder.issue_comment(number: 7, body: "/build tweak CI", pull_request: true)
    patch = "diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml\n+    extra: step\n"
    executor = RecordingExecutor.new(workflows_patch: patch)
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nDone."])

    When "iterating"
    run_build(github: github, executor: executor, body: "/build tweak CI", context: context, agent: agent)

    Then "the commit excludes workflows and the panel carries the patch"
    executor.command_lines.include?("git reset -q HEAD -- .github/workflows")
    executor.command_lines.any? { |line| line.include?(" commit -m ") }
    github.comment_edits.fetch(55).include?("✅ **/build** — committed")
    github.comment_edits.fetch(55).include?("no `workflows` permission")
    github.comment_edits.fetch(55).include?("extra: step")

    Cleanup
    nil
  end

  test "the write phase re-mints auth after the agent run — both build modes" do
    Given "an issue build and a PR iteration"
    issue_github = FakeGitHub.new
    issue_github.seed_issue(REPO, 7, title: "Carve system", body: "# Carve system\n")
    issue_executor = RecordingExecutor.new
    pr_github = FakeGitHub.new
    pr_context = ContextBuilder.issue_comment(number: 7, body: "/build fix", pull_request: true)
    pr_executor = RecordingExecutor.new
    pr_agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nFixed."])

    When "running both"
    run_build(github: issue_github, executor: issue_executor)
    run_build(github: pr_github, executor: pr_executor, body: "/build fix", context: pr_context, agent: pr_agent)

    Then "each ran exactly one unconditional refresh before its writes"
    issue_executor.refreshes == 1
    pr_executor.refreshes == 1

    Cleanup
    nil
  end

  test "/build with no agent changes opens no PR and reports it" do
    Given "an issue and an agent run that changes nothing"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: "# Carve system\n")

    When "building"
    run_build(github: github, executor: RecordingExecutor.new(dirty: false))

    Then "no PR, no assignee, and the comment says so"
    github.calls.map(&:first).none? { |kind| kind == :create_pull_request }
    github.calls.map(&:first).none? { |kind| kind == :add_assignees }
    github.comment_edits.fetch(55).include?("⚠️ **/build**")

    Cleanup
    nil
  end
end
