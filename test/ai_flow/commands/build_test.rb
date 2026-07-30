# typed: true
# frozen_string_literal: true

require "test_helper"
require "support/fakes"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class AiFlow::Commands::BuildTest < Minitest::Test
  REPO = "d3mlabs/demo"

  # Records every subprocess invocation as a joined command line (strings
  # survive RSpock's block-parameter destructuring where arrays don't);
  # `dirty` controls whether the staged diff reports changes (i.e. whether
  # the agent "wrote" anything), `workflows_patch` seeds a staged diff under
  # .github/workflows (the exclusion path). Subclasses the real class so
  # sorbet-runtime's sig checks accept it at the injection seam.
  class RecordingExecutor < AiFlow::Executor
    attr_reader :command_lines, :refreshes

    # `capture_patch` seeds a staged diff under the learning paths (build-time
    # capture); `capture_staged` is what the landing worktree stages after
    # `git apply` — the fake flips on the apply call, since the landing
    # worktree's diff must report learning files while the build worktree's
    # reports code. `fail_on` substrings make matching command lines fail,
    # for the capture failure paths.
    def initialize(dirty: true, workflows_patch: "", capture_patch: "", capture_staged: [], fail_on: [])
      @dirty = dirty
      @workflows_patch = workflows_patch
      @capture_patch = capture_patch
      @capture_staged = capture_staged
      @fail_on = fail_on
      @command_lines = []
      @refreshes = 0
    end

    def refresh_auth!
      @refreshes += 1
    end

    def capture(*argv, stdin: nil, chdir: nil, env: {})
      @command_lines << argv.join(" ")
      return ["", "simulated failure", false] if @fail_on.any? { |needle| argv.join(" ").include?(needle) }

      @applied = true if argv.take(2) == %w[git apply]
      out =
        if argv.join(" ").start_with?("git diff --cached -- .github/workflows")
          @workflows_patch
        elsif argv.join(" ").start_with?("git diff --cached --binary -- .cursor/")
          @capture_patch
        elsif argv.take(4) == %w[git diff --cached --name-only]
          @applied ? "#{@capture_staged.join("\n")}\n" : (@dirty ? "lib/thing.rb\n" : "")
        elsif argv.take(2) == %w[git rev-parse]
          "abc1234def5678\n"
        else
          ""
        end
      [out, "", true]
    end
  end

  def run_build(github:, executor:, body: "/build", context: nil, agent: FakeAgent.new(["done"]),
    org_invariants: empty_org_invariants, workdir: Dir.pwd)
    context ||= ContextBuilder.issue_comment(number: 7, body: body)
    segment = AiFlow::CommentParser.new.parse(body).fetch(0)
    AiFlow::Commands::Build.new(
      context: context,
      github: github,
      agent: agent,
      result_writer: AiFlow::ResultWriter.new(github: github),
      executor: executor,
      workdir: workdir,
      org_invariants: org_invariants,
    ).run(segment)
  end

  # A cache dir that doesn't exist: no invariants injected. Tests must never
  # pick up the developer machine's real knowledge cache.
  def empty_org_invariants
    AiFlow::OrgInvariants.new(cache_dir: File.join(Dir.tmpdir, "ai-flow-no-cache-#{object_id}"))
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

  test "/build on an issue targeting another repo clones it instead of adding a worktree" do
    Given "an org-wide issue declaring a Target repos: line for a different repo"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: "# Carve system\nTarget repos: d3mlabs/other\n")
    executor = RecordingExecutor.new

    When "building"
    run_build(github: github, executor: executor)
    command_lines = executor.command_lines

    Then "the target repo is cloned via gh and the PR opens there, not in the issue repo"
    command_lines.any? { |line| line.start_with?("gh repo clone d3mlabs/other") }
    command_lines.none? { |line| line.include?("worktree add") }
    github.calls.include?([:create_pull_request, "d3mlabs/other", "ai/7-carve-system", "main"])

    Cleanup
    nil
  end

  test "/build on a PR iterates on the head branch and replies to swept threads" do
    Given "a PR with an unresolved review thread and a /build with an instruction"
    github = FakeGitHub.new
    github.seed_review_threads(REPO, 7, [
      AiFlow::GitHub::ReviewThread.new(
        path: "lib/thing.rb", diff_hunk: "@@ -1 +1 @@", first_comment_id: 91,
        comments: [AiFlow::GitHub::ReviewThread::Comment.new(
          author: "jpduchesne", body: "this walk is O(n^2)", url: "u",
        )],
      ),
      # A thread a command started is a handled conversation, not feedback.
      AiFlow::GitHub::ReviewThread.new(
        path: "lib/other.rb", diff_hunk: "@@ -2 +2 @@", first_comment_id: 92,
        comments: [AiFlow::GitHub::ReviewThread::Comment.new(
          author: "jpduchesne", body: "/ask why this?", url: "u",
        )],
      ),
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
        number: 12, title: "Server API", body: "",
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
        number: 12, title: "Server API", body: "Part of #{REPO}#7.\n",
        html_url: "https://github.com/#{REPO}/issues/12", state: "open", repo: REPO,
      ),
      AiFlow::GitHub::Issue.new(
        number: 13, title: "Client UI", body: "Part of #{REPO}#7.\n",
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

    Then "workflows are unstaged before the commit, and the panel carries a one-paste apply command"
    lines.include?("git reset -q HEAD -- .github/workflows")
    lines.include?("git checkout -q -- .github/workflows")
    lines.include?("git clean -fdq -- .github/workflows")
    lines.index { |line| line.include?("reset -q HEAD") } < lines.index { |line| line.include?(" commit -m ") }
    github.calls.map(&:first).include?(:create_pull_request)
    github.comment_edits.fetch(55).include?("no `workflows` permission")
    github.comment_edits.fetch(55).include?("gh pr checkout https://github.com/#{REPO}/pull/900 && git apply --index <<'PATCH'")
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

    Then "no commit, no PR — the human gets the bare diff (no branch to apply a command onto)"
    executor.command_lines.none? { |line| line.include?(" commit -m ") }
    github.calls.map(&:first).none? { |kind| kind == :create_pull_request }
    github.comment_edits.fetch(55).include?("⚠️ **/build** — the agent made no changes, so no PR was opened.")
    github.comment_edits.fetch(55).include?("extra: step")
    !github.comment_edits.fetch(55).include?("gh pr checkout")

    Cleanup
    nil
  end

  test "/build in a review summary sweeps the PR like a conversation /build, panel-delivered" do
    Given "a /build inside a submitted review's summary text"
    github = FakeGitHub.new
    context = ContextBuilder.review_summary(number: 3, body: "/build address my review")
    executor = RecordingExecutor.new
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nAddressed."])

    When "building"
    run_build(github: github, executor: executor, body: "/build address my review", context: context, agent: agent)

    Then "the head branch is checked out from the payload ref and the result lands as the review panel"
    executor.command_lines.include?("git fetch origin feature-branch")
    executor.command_lines.include?("git checkout feature-branch")
    github.calls.map(&:first).include?(:post_issue_comment)
    github.comments.first.include?("In reply to jpduchesne's [review]")
    github.comments.first.include?("> /build address my review")
    github.comments.first.include?("✅ **/build** — committed")

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

    Then "the commit excludes workflows and the panel's apply command targets the PR under iteration"
    executor.command_lines.include?("git reset -q HEAD -- .github/workflows")
    executor.command_lines.any? { |line| line.include?(" commit -m ") }
    github.comment_edits.fetch(55).include?("✅ **/build** — committed")
    github.comment_edits.fetch(55).include?("no `workflows` permission")
    github.comment_edits.fetch(55).include?("gh pr checkout https://github.com/#{REPO}/pull/7 && git apply --index <<'PATCH'")
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

  def synced_org_invariants(cache)
    File.write(
      File.join(cache, "index.md"),
      "## Invariants (always-on)\n\n- [design/srp] One reason to change per unit.\n",
    )
    AiFlow::OrgInvariants.new(cache_dir: cache)
  end

  test "issue builds inject the org invariants when the machine cache is synced" do
    Given "an issue and a synced knowledge cache"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: "# Carve system\n")
    cache = Dir.mktmpdir("ai-flow-knowledge-")
    agent = FakeAgent.new(["done"])

    When "building"
    run_build(github: github, executor: RecordingExecutor.new, agent: agent,
      org_invariants: synced_org_invariants(cache))

    Then "the prompt carries the invariants"
    agent.prompts.first.include?("ORG INVARIANTS")
    agent.prompts.first.include?("[design/srp]")

    Cleanup
    FileUtils.rm_rf(cache)
  end

  test "PR iterations inject the org invariants too (the job checkout is fresh)" do
    Given "a PR iteration with an instruction and a synced knowledge cache"
    github = FakeGitHub.new
    context = ContextBuilder.issue_comment(number: 7, body: "/build fix the docs", pull_request: true)
    cache = Dir.mktmpdir("ai-flow-knowledge-")
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nFixed."])

    When "iterating"
    run_build(github: github, executor: RecordingExecutor.new, body: "/build fix the docs",
      context: context, agent: agent, org_invariants: synced_org_invariants(cache))

    Then "the iteration prompt carries the invariants"
    agent.prompts.first.include?("ORG INVARIANTS")
    agent.prompts.first.include?("[design/srp]")

    Cleanup
    FileUtils.rm_rf(cache)
  end

  test "an unconfigured runner (no knowledge cache) injects nothing" do
    Given "an issue and no cache on the machine"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: "# Carve system\n")
    agent = FakeAgent.new(["done"])

    When "building"
    run_build(github: github, executor: RecordingExecutor.new, agent: agent)

    Then "the prompt has no invariants block"
    !agent.prompts.first.include?("ORG INVARIANTS")

    Cleanup
    nil
  end

  # ---- Build-time learning capture ----

  LEARNING_PATCH = <<~PATCH
    diff --git a/.cursor/rules/learnings-index.mdc b/.cursor/rules/learnings-index.mdc
    new file mode 100644
    --- /dev/null
    +++ b/.cursor/rules/learnings-index.mdc
    @@ -0,0 +1 @@
    +- [design/one-seam] One seam to the CLI. → .cursor/skills/learnings/one-seam/
  PATCH

  test "an issue /build carries the capture rubric and lands extracted learnings as a separate draft PR" do
    Given "an issue build whose pass staged both code and learning files"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: "# Carve system\n")
    executor = RecordingExecutor.new(
      capture_patch: LEARNING_PATCH,
      capture_staged: [".cursor/rules/learnings-index.mdc", ".cursor/skills/learnings/one-seam/SKILL.md"],
    )
    agent = FakeAgent.new(["done"])

    When "building"
    run_build(github: github, executor: executor, agent: agent)

    Then "the prompt carried the rubric; the learning diff left the code commit and landed on ai/learn-issue-7"
    agent.prompts.first.include?("LEARNING CAPTURE")
    executor.command_lines.any? { |line| line.start_with?("git reset -q HEAD -- .cursor/") }
    github.calls.include?([:create_pull_request, REPO, "ai/7-carve-system", "main"])
    github.calls.include?([:create_pull_request, REPO, "ai/learn-issue-7", "main"])
    github.pull_request_bodies.fetch(1).include?("learned-from: #{REPO}#7 (build-sweep)")
    github.comment_edits.fetch(55).include?("🧠 drafted 1 learning in a draft learning PR")
    github.comment_edits.fetch(55).include?("`one-seam`")

    Cleanup
    nil
  end

  test "a PR iteration's capture refines the surface's open learning draft (linked update)" do
    Given "a PR iteration with an open ai/learn-pr-7 draft and a pass that re-staged learning files"
    github = FakeGitHub.new
    github.seed_open_pull_request_for_head("ai/learn-pr-7",
      AiFlow::GitHub::PullRequest.new(number: 500, html_url: "https://github.com/#{REPO}/pull/500"))
    context = ContextBuilder.issue_comment(number: 7, body: "/build fix the walk", pull_request: true)
    executor = RecordingExecutor.new(
      capture_patch: LEARNING_PATCH,
      capture_staged: [".cursor/rules/learnings-index.mdc", ".cursor/skills/learnings/one-seam/SKILL.md"],
    )
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nFixed."])

    When "iterating"
    run_build(github: github, executor: executor, body: "/build fix the walk", context: context, agent: agent)

    Then "the draft's files were seeded into the checkout, and the landing refined the draft (no second PR)"
    executor.command_lines.any? { |line| line.start_with?("git checkout origin/ai/learn-pr-7 -- .cursor/") }
    github.calls.map(&:first).none? { |kind| kind == :create_pull_request }
    executor.command_lines.any? { |line| line.include?("push -u origin ai/learn-pr-7") }
    github.comment_edits.fetch(55).include?("🧠 refined 1 learning in a draft learning PR")

    Cleanup
    nil
  end

  test "a pass that deletes the seeded draft files closes the dissolved draft" do
    Given "an open learning draft whose generalization this pass dissolved (no learning diff left)"
    github = FakeGitHub.new
    github.seed_open_pull_request_for_head("ai/learn-pr-7",
      AiFlow::GitHub::PullRequest.new(number: 500, html_url: "https://github.com/#{REPO}/pull/500"))
    context = ContextBuilder.issue_comment(number: 7, body: "/build simplify", pull_request: true)
    executor = RecordingExecutor.new(capture_patch: "")
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nSimplified."])

    When "iterating"
    run_build(github: github, executor: executor, body: "/build simplify", context: context, agent: agent)

    Then "the draft is closed and the panel says why"
    github.calls.include?([:close_pull_request, REPO, 500])
    github.comment_edits.fetch(55).include?("🧠 closed the draft learning PR")
    github.comment_edits.fetch(55).include?("dissolved its generalization")

    Cleanup
    nil
  end

  test "a failed draft-branch fetch forgets the draft so an empty capture stays a no-op" do
    Given "an open learning draft whose branch can't be fetched into the worktree"
    github = FakeGitHub.new
    github.seed_open_pull_request_for_head("ai/learn-pr-7",
      AiFlow::GitHub::PullRequest.new(number: 500, html_url: "https://github.com/#{REPO}/pull/500"))
    context = ContextBuilder.issue_comment(number: 7, body: "/build simplify", pull_request: true)
    executor = RecordingExecutor.new(capture_patch: "", fail_on: ["fetch origin ai/learn-pr-7"])
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nSimplified."])

    When "iterating"
    run_build(github: github, executor: executor, body: "/build simplify", context: context, agent: agent)

    Then "the agent never saw the draft's files, so the empty capture must not close the draft"
    executor.command_lines.none? { |line| line.start_with?("git checkout origin/ai/learn-pr-7") }
    github.calls.map(&:first).none? { |kind| kind == :close_pull_request }

    Cleanup
    nil
  end

  test "a capture landing failure degrades to a panel warning, never failing the code build" do
    Given "a pass that captured a learning but whose learning-branch push fails"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: "# Carve system\n")
    executor = RecordingExecutor.new(
      capture_patch: LEARNING_PATCH,
      capture_staged: [".cursor/rules/learnings-index.mdc", ".cursor/skills/learnings/one-seam/SKILL.md"],
      fail_on: ["push -u origin ai/learn-issue-7"],
    )
    agent = FakeAgent.new(["done"])

    When "building"
    run_build(github: github, executor: executor, agent: agent)

    Then "the code PR still opened; the panel carries the capture warning instead of a learning PR"
    github.calls.include?([:create_pull_request, REPO, "ai/7-carve-system", "main"])
    github.calls.none? { |call| call == [:create_pull_request, REPO, "ai/learn-issue-7", "main"] }
    github.comment_edits.fetch(55).include?("⚠️ learning capture failed (the code change itself is unaffected)")

    Cleanup
    nil
  end

  test "a failed close of a dissolved draft degrades to a warning note" do
    Given "a dissolved draft whose close call errors"
    github = Class.new(FakeGitHub) do
      def close_pull_request(_owner_repo, _number)
        raise AiFlow::GitHub::Error, "boom"
      end
    end.new
    github.seed_open_pull_request_for_head("ai/learn-pr-7",
      AiFlow::GitHub::PullRequest.new(number: 500, html_url: "https://github.com/#{REPO}/pull/500"))
    context = ContextBuilder.issue_comment(number: 7, body: "/build simplify", pull_request: true)
    executor = RecordingExecutor.new(capture_patch: "")
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nSimplified."])

    When "iterating"
    run_build(github: github, executor: executor, body: "/build simplify", context: context, agent: agent)

    Then "the build still delivers; the panel notes the failed close"
    github.comment_edits.fetch(55).include?("⚠️ closing the dissolved learning draft failed: boom")

    Cleanup
    nil
  end

  test "learn.on_build: false switches build-time capture off" do
    Given "a workdir whose ai-flow.yml opts out of build capture"
    dir = Dir.mktmpdir("ai-flow-build-test-")
    FileUtils.mkdir_p(File.join(dir, ".github"))
    File.write(File.join(dir, ".github", "ai-flow.yml"), "learn:\n  on_build: false\n")
    github = FakeGitHub.new
    context = ContextBuilder.issue_comment(number: 7, body: "/build fix the walk", pull_request: true)
    executor = RecordingExecutor.new
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nFixed."])

    When "iterating"
    run_build(github: github, executor: executor, body: "/build fix the walk", context: context,
      agent: agent, workdir: dir)

    Then "no rubric in the prompt, no learning-draft lookup, no learning PR"
    !agent.prompts.first.include?("LEARNING CAPTURE")
    github.calls.map(&:first).none? { |kind| kind == :open_pull_request_for_head }
    github.calls.map(&:first).none? { |kind| kind == :create_pull_request }

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
