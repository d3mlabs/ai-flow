# typed: true
# frozen_string_literal: true

require "test_helper"
require "support/fakes"
require "fileutils"
require "json"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class AiFlow::ContextTest < Minitest::Test
  test "from_event_file reads the payload file and routes to the surface leaf" do
    Given "a pull_request_review payload written where GITHUB_EVENT_PATH would point"
    dir = Dir.mktmpdir("ai-flow-test-")
    path = File.join(dir, "event.json")
    File.write(path, JSON.generate(
      "repository" => { "full_name" => "d3mlabs/demo" },
      "pull_request" => { "number" => 3, "head" => { "ref" => "feature-branch" } },
      "review" => {
        "id" => 77, "body" => "/build address my review", "author_association" => "OWNER",
        "html_url" => "https://github.com/d3mlabs/demo/pull/3#pullrequestreview-77",
      },
    ))

    When "loading the context from the file"
    context = AiFlow::Context.from_event_file(event_name: "pull_request_review", event_path: path)

    Then "it is the review-summary leaf with the payload's fields"
    context.is_a?(AiFlow::Context::ReviewSummary)
    context.comment_body == "/build address my review"
    context.subject_url == "https://github.com/d3mlabs/demo/pull/3"

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "run_url points at the Actions run described by the job env" do
    Given "a context with the standard Actions env"
    context = ContextBuilder.issue_comment(
      body: "/ask why?",
      env: {
        "GITHUB_SERVER_URL" => "https://github.com",
        "GITHUB_REPOSITORY" => "d3mlabs/demo",
        "GITHUB_RUN_ID" => "123456",
      },
    )

    When "reading the run url"
    url = context.run_url

    Then
    url == "https://github.com/d3mlabs/demo/actions/runs/123456"

    Cleanup
    nil
  end

  test "a review summary normalizes review.* into the comment fields" do
    Given "a pull_request_review payload (the command lives under review, not comment)"
    context = ContextBuilder.review_summary(body: "/build address my review")

    When "reading the normalized surface"
    nil

    Then "it is a PR surface with the review's body, author, and head ref"
    context.review_summary? == true
    context.review_comment? == false
    context.pull_request? == true
    context.number == 3
    context.pr_head_ref == "feature-branch"
    context.comment_body == "/build address my review"
    context.commenter_login == "jpduchesne"
    context.subject_url == "https://github.com/d3mlabs/demo/pull/3"

    Cleanup
    nil
  end

  test "a plain approval (empty review body) parses as an empty command body" do
    Given "a review submitted with no summary text"
    context = ContextBuilder.review_summary(body: nil)

    When "reading the body"
    nil

    Then "empty string, never nil — the parser sees no command"
    context.comment_body == ""

    Cleanup
    nil
  end

  test "run_url is nil without a run id (local runs)" do
    Given "a context outside Actions"
    context = ContextBuilder.issue_comment(body: "/ask why?")

    When "reading the run url"
    url = context.run_url

    Then
    url.nil?

    Cleanup
    nil
  end

  # A command comment the ai-flow App itself authored — the --split
  # orchestrator's child /build (ai-flow#115). Only the dispatcher holds the
  # App key, so a comment performed via *this* App is an orchestrator's,
  # and it authorizes on that fact alone; any other App's comment, or ours
  # on a host that does not know the App id, is a stranger's.
  test "a comment performed via this App is app-authored and authorized without an association" do
    Given "the App's comment, association NONE, the App id in the job env"
    context = ContextBuilder.issue_comment(
      body: "/build", association: "NONE", app_id: 424_242, env: { "AI_FLOW_APP_ID" => "424242" },
    )

    Expect
    context.app_authored?
    context.authorized?

    Cleanup
    nil
  end

  test "another App's comment, or ours where the App id is unknown, is not app-authored" do
    Given
    other_app = ContextBuilder.issue_comment(body: "/build", association: "NONE", app_id: 1, env: { "AI_FLOW_APP_ID" => "424242" })
    no_env = ContextBuilder.issue_comment(body: "/build", association: "NONE", app_id: 424_242, env: {})
    human = ContextBuilder.issue_comment(body: "/build", association: "NONE", env: { "AI_FLOW_APP_ID" => "424242" })
    garbage_env = ContextBuilder.issue_comment(body: "/build", association: "NONE", app_id: 424_242, env: { "AI_FLOW_APP_ID" => "not-a-number" })

    Expect
    !other_app.app_authored?
    !other_app.authorized?
    !no_env.app_authored?
    !no_env.authorized?
    !human.app_authored?
    !human.authorized?
    !garbage_env.app_authored?
    !garbage_env.authorized?

    Cleanup
    nil
  end

  test "an app-authored comment re-points the requesting human; a human's comment refuses" do
    Given
    delegated = ContextBuilder.issue_comment(
      body: "/build --for=jane", association: "NONE", app_id: 424_242, env: { "AI_FLOW_APP_ID" => "424242" },
    )
    human = ContextBuilder.issue_comment(body: "/build --for=jane")

    When
    delegated.on_behalf_of!(login: "jane", id: 777)
    refused = assert_raises(AiFlow::Context::DelegationError) { human.on_behalf_of!(login: "jane", id: 777) }

    Then "the delegated comment's requester is the human it names; the other keeps its author"
    delegated.commenter_login == "jane"
    delegated.commenter_id == 777
    human.commenter_login == "jpduchesne"
    refused.message.include?("jpduchesne")

    Cleanup
    nil
  end
end
