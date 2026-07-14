# frozen_string_literal: true

require "test_helper"
require "support/fakes"

transform!(RSpock::AST::Transformation)
class AiFlow::Commands::BuildSplitTest < Minitest::Test
  REPO = "d3mlabs/demo"

  # A build stand-in recording the order sub-issues were built in.
  class RecordingBuild
    attr_reader :built

    def initialize
      @built = []
    end

    def build_issue(issue, extra_instruction: "")
      @built << issue.number
      { "html_url" => "https://github.com/d3mlabs/demo/pull/#{issue.number}" }
    end
  end

  def sub_issue(number, title, body)
    AiFlow::GitHub::Issue.new(
      number: number, title: title, body: body, updated_at: "2026-07-13T00:00:00Z",
      html_url: "https://github.com/#{REPO}/issues/#{number}", state: "open", repo: REPO,
    )
  end

  test "builds waves in dependency order and finishes with the integration sub-issue" do
    Given "sub-issues where 3 depends on 1 and 2, plus an existing integration issue depending on all"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "Server API", "Build the API.\n"),
      sub_issue(2, "Client UI", "Build the UI.\n"),
      sub_issue(3, "Wiring", "Wire them.\n\nDepends on: #1, #2\n"),
      sub_issue(4, "Integration: Parent", "Integrate.\n\nDepends on: #1, #2, #3\n"),
    ])
    build = RecordingBuild.new
    context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
    segment = AiFlow::CommentParser.new.parse("/build --split").first

    When "orchestrating"
    AiFlow::Commands::BuildSplit.new(
      context: context, github: github, build: build,
      result_writer: AiFlow::ResultWriter.new(github: github),
    ).run(segment)

    Then "waves respect Depends on and integration is last"
    build.built == [1, 2, 3, 4]
    github.comment_edits.fetch(55).include?("✅ **/build --split**")
    github.comment_edits.fetch(55).include?("[x] #4 Integration: Parent")

    Cleanup
    nil
  end

  test "creates the integration sub-issue when the split didn't" do
    Given "two independent sub-issues and no integration issue"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "Server API", "Build the API.\n"),
      sub_issue(2, "Client UI", "Build the UI.\n"),
    ])
    build = RecordingBuild.new
    context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
    segment = AiFlow::CommentParser.new.parse("/build --split").first

    When "orchestrating"
    AiFlow::Commands::BuildSplit.new(
      context: context, github: github, build: build,
      result_writer: AiFlow::ResultWriter.new(github: github),
    ).run(segment)

    Then "an integration issue was created, attached as a sub-issue, and built last"
    github.calls.any? { |kind, _repo, title| kind == :create_issue && title.to_s.start_with?("Integration:") }
    github.calls.map(&:first).include?(:add_sub_issue)
    build.built.size == 3
    build.built.last > 100

    Cleanup
    nil
  end

  test "a dependency cycle is a hard error" do
    Given "sub-issues depending on each other"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "A", "Depends on: #2\n"),
      sub_issue(2, "B", "Depends on: #1\n"),
      sub_issue(3, "Integration: Parent", "Depends on: #1, #2\n"),
    ])
    context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
    segment = AiFlow::CommentParser.new.parse("/build --split").first

    When "orchestrating"
    AiFlow::Commands::BuildSplit.new(
      context: context, github: github, build: RecordingBuild.new,
      result_writer: AiFlow::ResultWriter.new(github: github),
    ).run(segment)

    Then
    raises AiFlow::GitHub::Error

    Cleanup
    nil
  end
end
