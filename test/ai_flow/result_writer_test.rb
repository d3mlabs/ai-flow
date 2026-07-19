# frozen_string_literal: true

require "test_helper"
require "support/fakes"

transform!(RSpock::AST::Transformation)
class AiFlow::ResultWriterTest < Minitest::Test
  test "results interleave under each segment, appendix at the bottom under ---" do
    Given "a two-segment batch comment"
    body = "> Q1\n\n/edit tighten\n\n> Q2\n\n/ask why?"
    segments = AiFlow::CommentParser.new.parse(body)
    writer = AiFlow::ResultWriter.new(github: FakeGitHub.new)

    When "rendering results with a batch appendix"
    updated = writer.render(
      body,
      [[segments[0], "RESULT-1\n\nline two"], [segments[1], "RESULT-2"]],
      appendix: "THE-DIFF\n\ndiff body",
    )

    Then "each result sits under its command; the appendix closes the comment"
    updated.index("> RESULT-1") > updated.index("/edit tighten")
    updated.index("> RESULT-1") < updated.index("> Q2")
    updated.index("> RESULT-2") > updated.index("/ask why?")
    updated.include?("> RESULT-1\n>\n> line two")
    updated.index("> RESULT-2") < updated.index("\n\n---\n\n> THE-DIFF\n>\n> diff body")
    updated.end_with?("> diff body")

    Cleanup
    nil
  end

  test "the run-link footer joins the appendix inside the bottom section" do
    Given "a one-segment comment and an Actions run url"
    body = "/edit tighten"
    segments = AiFlow::CommentParser.new.parse(body)
    writer = AiFlow::ResultWriter.new(github: FakeGitHub.new)

    When "rendering with an appendix and a run url"
    updated = writer.render(
      body,
      [[segments.first, "RESULT"]],
      appendix: "THE-DIFF",
      run_url: "https://github.com/d3mlabs/demo/actions/runs/9",
    )

    Then "one --- section carries the diff, then the footer"
    updated.scan("\n---\n").size == 1
    updated.include?("> THE-DIFF\n>\n> ⚙️ [workflow run](https://github.com/d3mlabs/demo/actions/runs/9)")
    updated.end_with?("(https://github.com/d3mlabs/demo/actions/runs/9)")

    Cleanup
    nil
  end

  test "without an appendix the footer gets its own bottom section" do
    Given "a one-segment comment and an Actions run url"
    body = "/edit tighten"
    segments = AiFlow::CommentParser.new.parse(body)
    writer = AiFlow::ResultWriter.new(github: FakeGitHub.new)

    When "rendering with a run url only"
    updated = writer.render(
      body,
      [[segments.first, "RESULT"]],
      run_url: "https://github.com/d3mlabs/demo/actions/runs/9",
    )

    Then
    updated == "/edit tighten\n\n> RESULT\n\n---\n\n" \
               "> ⚙️ [workflow run](https://github.com/d3mlabs/demo/actions/runs/9)"

    Cleanup
    nil
  end

  test "without an appendix there is no horizontal rule" do
    Given "a one-segment comment"
    body = "/edit tighten"
    segments = AiFlow::CommentParser.new.parse(body)
    writer = AiFlow::ResultWriter.new(github: FakeGitHub.new)

    When "rendering"
    updated = writer.render(body, [[segments.first, "RESULT"]])

    Then
    updated == "/edit tighten\n\n> RESULT"

    Cleanup
    nil
  end

  test "one distinct model collapses to a single footer name, whatever the command mix" do
    Given "an agent whose /ask and /edit both resolved to the same model"
    agent = FakeAgent.new(["out", "out"], model: "claude-fable-5-high")
    agent.launch(prompt: "p", workdir: ".", command: "ask")
    agent.launch(prompt: "p", workdir: ".", command: "edit")
    writer = AiFlow::ResultWriter.new(github: FakeGitHub.new, agent: agent)

    When "rendering the footer"
    footer = writer.footer("https://github.com/d3mlabs/demo/actions/runs/9")

    Then
    footer == "⚙️ [workflow run](https://github.com/d3mlabs/demo/actions/runs/9) · model: `claude-fable-5-high`"

    Cleanup
    nil
  end

  test "distinct model values list out (defensive — a job launches under one policy)" do
    Given "an agent seeded with two distinct models"
    agent = FakeAgent.new([], model: nil)
    agent.models_used["ask"] = "claude-fable-5-high"
    agent.models_used["edit"] = "gpt-5.3-codex"
    writer = AiFlow::ResultWriter.new(github: FakeGitHub.new, agent: agent)

    When "rendering the footer"
    footer = writer.footer("https://github.com/d3mlabs/demo/actions/runs/9")

    Then
    footer == "⚙️ [workflow run](https://github.com/d3mlabs/demo/actions/runs/9) · " \
              "model: `claude-fable-5-high`, `gpt-5.3-codex`"

    Cleanup
    nil
  end

  test "no agent pass leaves the footer run-link-only" do
    Given "an agent that never launched (e.g. /split --apply)"
    agent = FakeAgent.new([])
    writer = AiFlow::ResultWriter.new(github: FakeGitHub.new, agent: agent)

    When "rendering the footer"
    footer = writer.footer("https://github.com/d3mlabs/demo/actions/runs/9")

    Then
    footer == "⚙️ [workflow run](https://github.com/d3mlabs/demo/actions/runs/9)"

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
