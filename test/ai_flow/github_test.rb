# typed: true
# frozen_string_literal: true

require "test_helper"
require "json"

transform!(RSpock::AST::Transformation)
class AiFlow::GitHubTest < Minitest::Test
  # Plays back one canned `gh` response; GitHub's real argv construction and
  # JSON parsing run for real (the executor is the class's one seam).
  # Subclasses the real class so sorbet-runtime's sig checks accept it.
  class CannedExecutor < AiFlow::Executor
    attr_reader :command_lines, :stdins

    def initialize(out: "")
      @out = out
      @command_lines = []
      @stdins = []
    end

    def capture(*argv, stdin: nil, chdir: nil, env: {})
      @command_lines << argv.join(" ")
      @stdins << stdin
      [@out, "", true]
    end
  end

  test "open_pull_request_for_head filters by owner:branch and returns the first open PR" do
    Given "one open PR on the branch"
    executor = CannedExecutor.new(out: JSON.generate([{ "number" => 12, "html_url" => "u" }]))
    github = AiFlow::GitHub.new(executor: executor)

    When "looking the branch up"
    pr = github.open_pull_request_for_head("d3mlabs/demo", "ai/learn-pr-7")

    Then "the query carried the owner-qualified head filter and the PR came back"
    executor.command_lines.first == "gh api repos/d3mlabs/demo/pulls?state=open&head=d3mlabs:ai/learn-pr-7"
    T.must(pr).fetch("number") == 12

    Cleanup
    nil
  end

  test "open_pull_request_for_head returns nil when no PR is open on the branch" do
    Given "an empty listing"
    github = AiFlow::GitHub.new(executor: CannedExecutor.new(out: "[]"))

    Expect
    github.open_pull_request_for_head("d3mlabs/demo", "ai/learn-scan").nil?

    Cleanup
    nil
  end

  test "close_pull_request patches the PR state to closed" do
    Given "a PR to retire"
    executor = CannedExecutor.new
    github = AiFlow::GitHub.new(executor: executor)

    When "closing"
    github.close_pull_request("d3mlabs/demo", 500)

    Then "a PATCH with the closed state went to the pulls endpoint"
    executor.command_lines.first == "gh api -X PATCH --input - repos/d3mlabs/demo/pulls/500"
    executor.stdins.first == JSON.generate({ state: "closed" })

    Cleanup
    nil
  end

  test "create_pull_request POSTs the branch pair and returns the created PR" do
    Given "an API that answers with the created PR"
    executor = CannedExecutor.new(out: JSON.generate({ "number" => 7, "html_url" => "u" }))
    github = AiFlow::GitHub.new(executor: executor)

    When "opening a PR"
    pr = github.create_pull_request(
      "d3mlabs/demo", title: "t", body: "b", head: "ai/7-x", base: "main",
    )

    Then "the payload carried the branch pair and the PR came back"
    executor.command_lines.first == "gh api -X POST --input - repos/d3mlabs/demo/pulls"
    executor.stdins.first ==
      JSON.generate({ title: "t", body: "b", head: "ai/7-x", base: "main", draft: false })
    pr.fetch("number") == 7

    Cleanup
    nil
  end

  test "react_to_comment posts the reaction to the surface's namespace" do
    Given "a plain issue comment to acknowledge"
    executor = CannedExecutor.new
    github = AiFlow::GitHub.new(executor: executor)

    When "reacting"
    github.react_to_comment("d3mlabs/demo", 55, "eyes")

    Then "the reaction went to the issues namespace"
    executor.command_lines.first == "gh api -X POST --input - repos/d3mlabs/demo/issues/comments/55/reactions"
    executor.stdins.first == JSON.generate({ content: "eyes" })

    Cleanup
    nil
  end

  test "graphql flags string variables -f and non-strings -F, returning data" do
    Given "an API that answers a mutation"
    executor = CannedExecutor.new(out: JSON.generate({ "data" => { "ok" => true } }))
    github = AiFlow::GitHub.new(executor: executor)

    When "running a query with mixed variable types"
    data = github.graphql("query($id: Int!, $name: String!) {}", id: 12, name: "x")

    Then "typed flags per variable, and the data object came back"
    executor.command_lines.first ==
      "gh api graphql -f query=query($id: Int!, $name: String!) {} -F id=12 -f name=x"
    data == { "ok" => true }

    Cleanup
    nil
  end
end
