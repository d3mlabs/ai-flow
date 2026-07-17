# frozen_string_literal: true

require "test_helper"
require "support/fakes"

transform!(RSpock::AST::Transformation)
class AiFlow::ResultWriterTest < Minitest::Test
  test "results append as one numbered section under a horizontal rule" do
    Given "a two-segment batch comment"
    body = "> Q1\n\n/edit tighten\n\n> Q2\n\n/ask why?"
    segments = AiFlow::CommentParser.new.parse(body)
    writer = AiFlow::ResultWriter.new(github: FakeGitHub.new)

    When "rendering results with a batch appendix"
    updated = writer.render(
      body,
      [[segments[0], "RESULT-1\n\nline two"], [segments[1], "RESULT-2"]],
      appendix: "THE-DIFF",
    )

    Then "the human text is untouched, then ---, then the blockquoted section in order"
    updated.start_with?("#{body}\n\n---\n\n")
    updated.index("> **1.** RESULT-1") < updated.index("> **2.** RESULT-2")
    updated.index("> **2.** RESULT-2") < updated.index("> THE-DIFF")
    updated.include?("> **1.** RESULT-1\n>\n> line two")

    Cleanup
    nil
  end

  test "a single result appends without numbering or appendix" do
    Given "a one-segment comment"
    body = "/edit tighten"
    segments = AiFlow::CommentParser.new.parse(body)
    writer = AiFlow::ResultWriter.new(github: FakeGitHub.new)

    When "rendering"
    updated = writer.render(body, [[segments.first, "RESULT"]])

    Then
    updated == "/edit tighten\n\n---\n\n> RESULT"

    Cleanup
    nil
  end

  test "review comments are edited through the pulls namespace" do
    Given "a review-comment context"
    github = FakeGitHub.new
    context = AiFlow::Context.new(
      event_name: "pull_request_review_comment",
      payload: {
        "repository" => { "full_name" => "d3mlabs/demo" },
        "pull_request" => { "number" => 3, "head" => { "ref" => "feature" } },
        "comment" => {
          "id" => 9, "body" => "/edit fix this", "author_association" => "OWNER",
          "html_url" => "https://github.com/d3mlabs/demo/pull/3#discussion_r9",
          "diff_hunk" => "@@ -1 +1 @@", "path" => "a.rb",
        },
      },
    )
    segments = AiFlow::CommentParser.new.parse("/edit fix this")

    When "writing results"
    AiFlow::ResultWriter.new(github: github).write(context, [[segments.first, "DONE"]])

    Then
    github.calls.map(&:first).include?(:update_review_comment)

    Cleanup
    nil
  end
end
