# frozen_string_literal: true

require "test_helper"
require "support/fakes"

transform!(RSpock::AST::Transformation)
class AiFlow::ContextTest < Minitest::Test
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
