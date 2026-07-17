# frozen_string_literal: true

require "test_helper"
require "support/fakes"

transform!(RSpock::AST::Transformation)
class AiFlow::Commands::SplitTest < Minitest::Test
  REPO = "d3mlabs/demo"

  def sub_issue(number, title, state: "open")
    AiFlow::GitHub::Issue.new(
      number: number, title: title, body: "", updated_at: "2026-07-13T00:00:00Z",
      html_url: "https://github.com/#{REPO}/issues/#{number}", state: state, repo: REPO,
    )
  end

  def run_split(github:, agent:, comment: "/split")
    context = ContextBuilder.issue_comment(number: 7, body: comment)
    segment = AiFlow::CommentParser.new.parse(comment).first
    AiFlow::Commands::Split.new(
      context: context, github: github, agent: agent,
      result_writer: AiFlow::ResultWriter.new(github: github), workdir: Dir.pwd,
    ).run(segment)
  end

  test "reconciliation creates missing, closes stale, keeps matching" do
    Given "an existing sub-issue set and a proposal that reshapes it"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent plan\n")
    kept = sub_issue(1, "Server API")
    stale = sub_issue(2, "Old approach")
    github.seed_issue(REPO, 1, title: "Server API", body: "")
    github.seed_issue(REPO, 2, title: "Old approach", body: "")
    github.seed_sub_issues(REPO, 7, [kept, stale])
    agent = FakeAgent.new([<<~JSON])
      [
        {"title": "Server API", "body": "Build the API.", "depends_on": []},
        {"title": "Client UI", "body": "Build the UI.", "depends_on": [0]}
      ]
    JSON

    When "splitting"
    run_split(github: github, agent: agent)

    Then "Client UI was created via GraphQL, Old approach closed (never deleted), Server API kept"
    github.calls.any? { |kind, arg| kind == :graphql && arg.is_a?(Hash) && arg[:title] == "Client UI" }
    github.calls.none? { |kind, arg| kind == :graphql && arg.is_a?(Hash) && arg[:title] == "Server API" }
    github.issue(REPO, 2).state == "closed"
    github.calls.any? { |kind, _repo, number| kind == :close_issue && number == 2 }
    github.comment_edits.fetch(55).include?("created 1, closed 1, kept 1")

    Cleanup
    nil
  end

  test "dependencies land as a Depends on line in the created sub-issue" do
    Given "a proposal where the second subtask depends on the first (existing) one"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent plan\n")
    existing = sub_issue(1, "Server API")
    github.seed_issue(REPO, 1, title: "Server API", body: "")
    github.seed_sub_issues(REPO, 7, [existing])
    agent = FakeAgent.new([<<~JSON])
      [
        {"title": "Server API", "body": "Build the API.", "depends_on": []},
        {"title": "Client UI", "body": "Build the UI.", "depends_on": [0]}
      ]
    JSON

    When "splitting"
    run_split(github: github, agent: agent)

    Then "the created issue's body was patched with the dependency convention"
    created_number = github.calls.find { |kind, _repo, _number| kind == :update_issue_body }&.fetch(2)
    github.issue(REPO, created_number).body.include?("Depends on: #1")

    Cleanup
    nil
  end
end
