# frozen_string_literal: true

require "test_helper"
require "support/fakes"

transform!(RSpock::AST::Transformation)
class AiFlow::DispatcherTest < Minitest::Test
  REPO = "d3mlabs/demo"

  def build_dispatcher(github:, agent:, context:)
    AiFlow::Dispatcher.new(
      context: context, workdir: Dir.pwd, github: github, agent: agent,
    )
  end

  test "an unauthorized commenter is ignored entirely" do
    Given "a command comment from a non-member"
    github = FakeGitHub.new
    context = ContextBuilder.issue_comment(body: "/ask anything?", association: "NONE")

    When "dispatching"
    build_dispatcher(github: github, agent: FakeAgent.new([]), context: context).run

    Then "no API call was made at all"
    github.calls.empty?

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

  test "a command comment is acknowledged with the eyes reaction and routed" do
    Given "a standalone /ask on a plan issue"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Plan", body: "# Plan\n\n<!-- ai-flow:plan -->\n")
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
