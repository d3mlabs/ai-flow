# frozen_string_literal: true

require "test_helper"
require "json"

transform!(RSpock::AST::Transformation)
class AiFlow::GitHubTest < Minitest::Test
  # Plays back one canned `gh` response; GitHub's real argv construction and
  # JSON parsing run for real (the executor is the class's one seam).
  class CannedExecutor
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
    pr.fetch("number") == 12

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
end
