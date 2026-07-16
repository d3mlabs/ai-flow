# frozen_string_literal: true

require "test_helper"
require "support/fakes"

transform!(RSpock::AST::Transformation)
class AiFlow::Commands::BuildTest < Minitest::Test
  REPO = "d3mlabs/demo"

  # Records every subprocess invocation as a joined command line (strings
  # survive RSpock's block-parameter destructuring where arrays don't);
  # `dirty` controls whether `git status --porcelain` reports changes (i.e.
  # whether the agent "wrote" anything).
  class RecordingExecutor
    attr_reader :command_lines

    def initialize(dirty: true)
      @dirty = dirty
      @command_lines = []
    end

    def capture(*argv, stdin: nil, chdir: nil, env: {})
      @command_lines << argv.join(" ")
      out = argv.take(3) == %w[git status --porcelain] && @dirty ? " M lib/thing.rb\n" : ""
      [out, "", true]
    end
  end

  def run_build(github:, executor:, body: "/build")
    context = ContextBuilder.issue_comment(number: 7, body: body)
    segment = AiFlow::CommentParser.new.parse(body).first
    AiFlow::Commands::Build.new(
      context: context,
      github: github,
      agent: FakeAgent.new(["done"]),
      result_writer: AiFlow::ResultWriter.new(github: github),
      executor: executor,
      workdir: Dir.pwd,
    ).run(segment)
  end

  test "/build prunes worktrees, commits as the bot with the requester co-authored, and opens an attributed PR" do
    Given "an issue and a dirty agent run"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: "# Carve system\n")
    executor = RecordingExecutor.new

    When "building"
    run_build(github: github, executor: executor)
    command_lines = executor.command_lines
    commit_line = command_lines.find { |line| line.include?(" commit -m ") }

    Then "worktrees are pruned first, the bot authors the commit with the human co-authored, and the PR is attributed"
    command_lines.include?("git worktree prune")
    command_lines.index("git worktree prune") < command_lines.index { |line| line.include?("worktree add") }
    commit_line.include?("-c user.name=ai-flow[bot]")
    commit_line.include?("-c user.email=424242+ai-flow[bot]@users.noreply.github.com")
    commit_line.include?("ai-flow /build: Carve system")
    commit_line.include?("Co-authored-by: jpduchesne <111+jpduchesne@users.noreply.github.com>")
    github.pull_request_bodies.fetch(0).include?("Requested by @jpduchesne.")
    github.pull_request_bodies.fetch(0).include?("Closes #{REPO}#7")
    github.calls.include?([:add_assignees, REPO, 900, ["jpduchesne"]])
    github.comment_edits.fetch(55).include?("✅ **/build**")

    Cleanup
    nil
  end

  test "/build with no agent changes opens no PR and reports it" do
    Given "an issue and an agent run that changes nothing"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: "# Carve system\n")

    When "building"
    run_build(github: github, executor: RecordingExecutor.new(dirty: false))

    Then "no PR, no assignee, and the comment says so"
    github.calls.map(&:first).none? { |kind| kind == :create_pull_request }
    github.calls.map(&:first).none? { |kind| kind == :add_assignees }
    github.comment_edits.fetch(55).include?("⚠️ **/build**")

    Cleanup
    nil
  end
end
