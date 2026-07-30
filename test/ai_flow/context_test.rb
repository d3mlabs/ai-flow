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
end
