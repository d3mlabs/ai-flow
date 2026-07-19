# frozen_string_literal: true

require "test_helper"
require "support/fakes"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class AiFlow::DispatcherTest < Minitest::Test
  REPO = "d3mlabs/demo"

  def build_dispatcher(github:, agent:, context:, workdir: Dir.pwd)
    AiFlow::Dispatcher.new(
      context: context, workdir: workdir, github: github, agent: agent,
    )
  end

  test "an unauthorized commenter is ignored entirely" do
    Given "a command comment from a non-member without repo access"
    github = FakeGitHub.new
    context = ContextBuilder.issue_comment(body: "/ask anything?", association: "NONE")

    When "dispatching"
    build_dispatcher(github: github, agent: FakeAgent.new([]), context: context).run

    Then "the only API call is the fail-closed permission probe — no writes"
    github.calls == [[:collaborator_permission, REPO, "jpduchesne"]]

    Cleanup
    nil
  end

  test "an under-reported association falls back to the permission API and runs" do
    Given "a CONTRIBUTOR payload (review-comment under-reporting) whose author has write access"
    github = FakeGitHub.new
    github.seed_permission("jpduchesne", "write")
    context = ContextBuilder.issue_comment(body: "looks good, no command here", association: "CONTRIBUTOR")

    When "dispatching"
    build_dispatcher(github: github, agent: FakeAgent.new([]), context: context).run

    Then "the gate passed via the API (the comment itself is a clean no-op)"
    github.calls == [[:collaborator_permission, REPO, "jpduchesne"]]

    Cleanup
    nil
  end

  test "a non-command comment is a clean no-op" do
    Given "plain conversation"
    github = FakeGitHub.new
    context = ContextBuilder.issue_comment(body: "looks good, the /build passed earlier")

    When "dispatching"
    build_dispatcher(github: github, agent: FakeAgent.new([]), context: context).run

    Then
    github.calls.empty?

    Cleanup
    nil
  end

  ACTIONS_ENV = {
    "GITHUB_SERVER_URL" => "https://github.com",
    "GITHUB_REPOSITORY" => "d3mlabs/demo",
    "GITHUB_RUN_ID" => "42",
  }.freeze
  RUN_URL = "https://github.com/d3mlabs/demo/actions/runs/42"

  test "a parsed command gets the ⏳ status line while running" do
    Given "a batch /edit inside Actions"
    dir = Dir.mktmpdir("ai-flow-dispatcher-test-")
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Plan", body: "# Plan\n\nBody.\n")
    context = ContextBuilder.issue_comment(body: "/edit tighten the plan", env: ACTIONS_ENV)
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nTightened."]) do
      File.write(File.join(dir, "ai-flow-plan-7.md"), "# Plan\n\nTighter body.\n")
    end

    When "dispatching"
    build_dispatcher(github: github, agent: agent, context: context, workdir: dir).run

    Then "the first comment edit is the follow-along line with the predicted model; the results replace it with the footer"
    github.comment_edit_history.first ==
      "/edit tighten the plan\n\n> ⏳ ai-flow is running — [follow the run](#{RUN_URL}) · model: `fake-model`"
    !github.comment_edit_history.last.include?("⏳")
    github.comment_edit_history.last.include?("⚙️ [workflow run](#{RUN_URL})")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "with no model policy the status line predicts the cursor default" do
    Given "an /ask inside Actions with an agent that resolves no model"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Plan", body: "# Plan\n")
    context = ContextBuilder.issue_comment(body: "/ask why?", env: ACTIONS_ENV)
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nBecause."], model: nil)

    When "dispatching"
    build_dispatcher(github: github, agent: agent, context: context).run

    Then
    github.comment_edit_history.first ==
      "/ask why?\n\n> ⏳ ai-flow is running — [follow the run](#{RUN_URL}) · model: `cursor default`"

    Cleanup
    nil
  end

  test "a mixed batch predicts the /edit model — the single pass runs under the edit policy" do
    Given "an /ask + /edit batch with distinct per-command models"
    dir = Dir.mktmpdir("ai-flow-dispatcher-test-")
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Plan", body: "# Plan\n\nBody.\n")
    comment = "/ask why?\n\n/edit tighten the plan"
    context = ContextBuilder.issue_comment(body: comment, env: ACTIONS_ENV)
    models = { "ask" => "cheap-ask-model", "edit" => "strong-edit-model" }
    agent = FakeAgent.new(
      ["<<<AI-FLOW:SEGMENT 1>>>\nBecause.\n<<<AI-FLOW:SEGMENT 2>>>\nTightened."],
      models_by_command: models,
    ) { File.write(File.join(dir, "ai-flow-plan-7.md"), "# Plan\n\nTighter body.\n") }

    When "dispatching"
    build_dispatcher(github: github, agent: agent, context: context, workdir: dir).run

    Then "the ⏳ prediction and the ⚙️ footer both carry the edit model, never the ask model"
    github.comment_edit_history.first ==
      "#{comment}\n\n> ⏳ ai-flow is running — [follow the run](#{RUN_URL}) · model: `strong-edit-model`"
    github.comment_edit_history.last.include?("model: `strong-edit-model`")
    !github.comment_edit_history.last.include?("cheap-ask-model")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a malformed repo config fails as the ⚠️ panel, not a crash" do
    Given "a real Agent over a workdir whose .github/ai-flow.yml is invalid YAML"
    dir = Dir.mktmpdir("ai-flow-dispatcher-test-")
    FileUtils.mkdir_p(File.join(dir, ".github"))
    File.write(File.join(dir, ".github", "ai-flow.yml"), "models: [unclosed\n")
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Plan", body: "# Plan\n")
    context = ContextBuilder.issue_comment(body: "/ask why?", env: ACTIONS_ENV)
    agent = AiFlow::Agent.new

    When "dispatching"
    build_dispatcher(github: github, agent: agent, context: context, workdir: dir).run

    Then "the run goes red and the comment carries the config error"
    raises SystemExit
    github.comment_edits.fetch(55).include?("ai-flow failed")
    github.comment_edits.fetch(55).include?(".github/ai-flow.yml is not valid YAML")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "outside Actions there is no status line" do
    Given "the same command without a run id in the env"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Plan", body: "# Plan\n")
    context = ContextBuilder.issue_comment(body: "/ask why?")
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nBecause."])

    When "dispatching"
    build_dispatcher(github: github, agent: agent, context: context).run

    Then "the command comment was never edited"
    github.comment_edit_history.empty?

    Cleanup
    nil
  end

  test "/build --split on a PR is refused as a parse-style failure" do
    Given "a --split command on a pull request"
    github = FakeGitHub.new
    context = ContextBuilder.issue_comment(body: "/build --split", pull_request: true)

    When "dispatching"
    build_dispatcher(github: github, agent: FakeAgent.new([]), context: context).run

    Then "the run fails and the comment carries the reason"
    raises SystemExit
    github.comment_edits.fetch(55).include?("/build --split runs on plan issues, not pull requests")

    Cleanup
    nil
  end

  test "a command comment is acknowledged with the eyes reaction and routed" do
    Given "a standalone /ask on a plan issue"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Plan", body: "# Plan\n")
    context = ContextBuilder.issue_comment(body: "/ask why?")
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nBecause."])

    When "dispatching"
    build_dispatcher(github: github, agent: agent, context: context).run

    Then "eyes reaction, then the answer reply"
    github.calls.first == [:react_to_comment, 55, "eyes"]
    github.comments.size == 1

    Cleanup
    nil
  end
end
