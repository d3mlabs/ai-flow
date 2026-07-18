# frozen_string_literal: true

require "test_helper"
require "support/fakes"

transform!(RSpock::AST::Transformation)
class AiFlow::Commands::SplitTest < Minitest::Test
  REPO = "d3mlabs/demo"

  def sub_issue(number, title, state: "open", repo: REPO)
    AiFlow::GitHub::Issue.new(
      number: number, title: title, body: "", updated_at: "2026-07-13T00:00:00Z",
      html_url: "https://github.com/#{repo}/issues/#{number}", state: state, repo: repo,
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
    github.comment_edits.fetch(55).include?("created 1, adopted 0, referenced 0, kept 1, closed 1")

    Cleanup
    nil
  end

  test "dependencies land as a fully qualified Depends on line in the created sub-issue" do
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

    Then "the created issue's body carries the dependency, qualified with its repo"
    created = github.issue(REPO, 101)
    created.title == "Client UI"
    created.body.include?("Depends on: #{REPO}#1")

    Cleanup
    nil
  end

  test "subtasks route to their own repos and the section becomes a linked map" do
    Given "a Target repos menu with the App installed on the routed repo"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent plan\n\nTarget repos: d3mlabs/server\n")
    github.seed_app_installed_repos(["d3mlabs/server"])
    agent = FakeAgent.new([<<~JSON])
      [
        {"title": "Server API", "body": "Build the API.", "repo": "d3mlabs/server"},
        {"title": "Docs", "body": "Write the docs."}
      ]
    JSON

    When "splitting (bare = dry + apply in one run)"
    run_split(github: github, agent: agent)

    Then "the routed subtask lives in its repo, the default one on the parent's, and the body holds the applied map"
    github.issue("d3mlabs/server", 101).title == "Server API"
    github.issue(REPO, 102).title == "Docs"
    body = github.issue(REPO, 7).body
    body.include?(AiFlow::SubtasksSection::APPLIED_MARKER)
    body.include?("- d3mlabs/server#101 — Server API")
    body.include?("- #{REPO}#102 — Docs")
    !body.include?("```yaml")

    Cleanup
    nil
  end

  test "a repo without the App falls back to the parent's repo with an Intended repo note and a warning" do
    Given "a proposal routed to a repo where the App is not installed"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent plan\n\nTarget repos: d3mlabs/private\n")
    agent = FakeAgent.new([<<~JSON])
      [{"title": "Private work", "body": "Do it.", "repo": "d3mlabs/private"}]
    JSON

    When "splitting"
    run_split(github: github, agent: agent)

    Then "the sub-issue was created on the parent's repo, notes its intended home, and the panel warns"
    created = github.issue(REPO, 101)
    created.body.include?("Intended repo: d3mlabs/private")
    github.comment_edits.fetch(55).include?("d3mlabs/private has no ai-flow App installation")

    Cleanup
    nil
  end

  test "/split --dry stages the yaml spec without creating any issue" do
    Given "a plan with no sub-issues"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent plan\n\nTarget repos: #{REPO}\n")
    agent = FakeAgent.new([<<~JSON])
      [{"title": "Server API", "body": "Build the API."}]
    JSON

    When "staging"
    run_split(github: github, agent: agent, comment: "/split --dry")

    Then "the body carries the editable spec, nothing was created, and the panel points at --apply"
    body = github.issue(REPO, 7).body
    body.include?(AiFlow::SubtasksSection::SPEC_MARKER)
    body.include?("```yaml")
    body.include?("- title: \"Server API\"")
    github.calls.none? { |kind, _arg| kind == :create_issue }
    github.calls.none? { |kind, arg| kind == :graphql && arg.is_a?(Hash) && arg.key?(:title) }
    github.comment_edits.fetch(55).include?("/split --apply")

    Cleanup
    nil
  end

  test "/split --apply consumes a hand-edited spec without calling the agent" do
    Given "a staged spec whose repo line was hand-edited"
    github = FakeGitHub.new
    github.seed_app_installed_repos(["d3mlabs/server"])
    github.seed_issue(REPO, 7, title: "Parent", body: <<~BODY)
      # Parent plan

      ## Subtasks
      #{AiFlow::SubtasksSection::SPEC_MARKER}

      ```yaml
      - title: "Server API"
        repo: d3mlabs/server
        body: |
          Build the API.
      ```
    BODY
    agent = FakeAgent.new([])

    When "applying"
    run_split(github: github, agent: agent, comment: "/split --apply")

    Then "the agent never ran and the hand-edited routing was honored"
    agent.prompts.empty?
    github.issue("d3mlabs/server", 101).title == "Server API"
    github.issue(REPO, 7).body.include?(AiFlow::SubtasksSection::APPLIED_MARKER)

    Cleanup
    nil
  end

  test "/split --apply without a staged spec refuses with guidance" do
    Given "a plan with no Subtasks section"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent plan\n")

    When "applying"
    run_split(github: github, agent: FakeAgent.new([]), comment: "/split --apply")

    Then
    raises AiFlow::SubtasksSection::Error

    Cleanup
    nil
  end

  test "/split --dry --apply together is a parse-level refusal" do
    Given "a plan"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent plan\n")

    When "running both flags"
    run_split(github: github, agent: FakeAgent.new([]), comment: "/split --dry --apply")

    Then
    raises AiFlow::CommentParser::ParseError

    Cleanup
    nil
  end

  test "existing: adopts a parentless issue and references an already-parented one" do
    Given "a staged spec pointing at two existing issues, one unadoptable"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: <<~BODY)
      # Parent plan

      ## Subtasks
      #{AiFlow::SubtasksSection::SPEC_MARKER}

      ```yaml
      - title: "Adoptable work"
        repo: d3mlabs/demo
        existing: d3mlabs/other#42
        body: ""

      - title: "Owned elsewhere"
        repo: d3mlabs/demo
        existing: d3mlabs/other#43
        body: ""
      ```
    BODY
    github.seed_issue("d3mlabs/other", 42, title: "Adoptable work", body: "")
    github.seed_issue("d3mlabs/other", 43, title: "Owned elsewhere", body: "")
    github.fail_add_sub_issue_for(400_043)

    When "applying"
    run_split(github: github, agent: FakeAgent.new([]), comment: "/split --apply")

    Then "42 was adopted as a native sub-issue, 43 only referenced, both in the linked map"
    github.calls.any? { |kind, _repo, _parent, rest_id| kind == :add_sub_issue && rest_id == 400_042 }
    github.calls.none? { |kind, _repo, _parent, rest_id| kind == :add_sub_issue && rest_id == 400_043 }
    body = github.issue(REPO, 7).body
    body.include?("- d3mlabs/other#42 — Adoptable work (adopted)")
    body.include?("- d3mlabs/other#43 — Owned elsewhere (referenced)")
    github.comment_edits.fetch(55).include?("adopted 1, referenced 1")

    Cleanup
    nil
  end

  test "discovery annotates the dry section with possible existing matches" do
    Given "an open issue in a menu repo whose title overlaps a proposed subtask"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Server API rework plan", body: "# Plan\n\nTarget repos: d3mlabs/server\n")
    github.seed_issue("d3mlabs/server", 31, title: "Server API rework", body: "")
    agent = FakeAgent.new([<<~JSON])
      [{"title": "Server API rework", "body": "Do the rework.", "repo": "d3mlabs/server"}]
    JSON

    When "staging"
    run_split(github: github, agent: agent, comment: "/split --dry")

    Then "the spec carries the suggestion comment and the panel counts it"
    github.issue(REPO, 7).body.include?("# possible match: d3mlabs/server#31")
    github.comment_edits.fetch(55).include?("possible existing match")

    Cleanup
    nil
  end
end
