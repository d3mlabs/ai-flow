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
      out =
        if argv.take(3) == %w[git status --porcelain] && @dirty
          " M lib/thing.rb\n"
        elsif argv.take(2) == %w[git rev-parse]
          "abc1234def5678\n"
        else
          ""
        end
      [out, "", true]
    end
  end

  def run_build(github:, executor:, body: "/build", context: nil, agent: FakeAgent.new(["done"]))
    context ||= ContextBuilder.issue_comment(number: 7, body: body)
    segment = AiFlow::CommentParser.new.parse(body).first
    AiFlow::Commands::Build.new(
      context: context,
      github: github,
      agent: agent,
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

  test "/build on a PR iterates on the head branch and replies to swept threads" do
    Given "a PR with an unresolved review thread and a /build with an instruction"
    github = FakeGitHub.new
    github.seed_review_threads(REPO, 7, [{
      "path" => "lib/thing.rb", "diff_hunk" => "@@ -1 +1 @@",
      "first_comment_id" => 91,
      "comments" => [{ "author" => "jpduchesne", "body" => "this walk is O(n^2)", "url" => "u" }],
    }])
    context = ContextBuilder.issue_comment(number: 7, body: "/build fix the failing CI", pull_request: true)
    executor = RecordingExecutor.new
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nRewrote the walk as a single pass.\n" \
                           "<<<AI-FLOW:SEGMENT 2>>>\nFixed CI and the quadratic walk."])

    When "iterating"
    run_build(github: github, executor: executor, body: "/build fix the failing CI", context: context, agent: agent)

    Then "head branch checked out, feedback in the prompt, commit pushed, thread and panel updated"
    executor.command_lines.include?("git fetch origin feature-branch")
    executor.command_lines.include?("git checkout feature-branch")
    agent.prompts.first.include?("INSTRUCTION: fix the failing CI")
    agent.prompts.first.include?("<<<THREAD 1>>> (lib/thing.rb)")
    agent.prompts.first.include?("this walk is O(n^2)")
    executor.command_lines.any? { |line| line.include?("commit -m") && line.include?("ai-flow /build: fix the failing CI") }
    executor.command_lines.include?("git add -A -- :(exclude).ai-flow")
    executor.command_lines.include?("git push")
    github.calls.map(&:first).none? { |kind| kind == :create_pull_request }
    github.calls.include?([:reply_to_review_comment, REPO, 7, 91])
    github.comments.first.include?("Rewrote the walk as a single pass.")
    github.comments.first.include?("abc1234")
    github.comment_edits.fetch(55).include?("✅ **/build** — committed")
    github.comment_edits.fetch(55).include?("Fixed CI and the quadratic walk.")

    Cleanup
    nil
  end

  test "a bare /build sweeps fresh conversation comments as feedback" do
    Given "a PR with a plain feedback comment and no review threads"
    github = FakeGitHub.new
    github.seed_issue_comment(REPO, 7, id: 40, body: "please also update the README")
    context = ContextBuilder.issue_comment(number: 7, body: "/build", pull_request: true)
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nUpdated the README."])

    When "iterating"
    run_build(github: github, executor: RecordingExecutor.new, body: "/build", context: context, agent: agent)

    Then "the comment is the sweep's scope and the iteration commits"
    agent.prompts.first.include?("Conversation comment from @jpduchesne:")
    agent.prompts.first.include?("please also update the README")
    github.comment_edits.fetch(55).include?("✅ **/build** — committed")

    Cleanup
    nil
  end

  test "a bare /build with nothing outstanding is a friendly no-op" do
    Given "a PR with no threads, no fresh comments, and no instruction"
    github = FakeGitHub.new
    context = ContextBuilder.issue_comment(number: 7, body: "/build", pull_request: true)
    agent = FakeAgent.new([])

    When "iterating"
    run_build(github: github, executor: RecordingExecutor.new, body: "/build", context: context, agent: agent)

    Then "no agent run, no commit, an ℹ️ panel"
    agent.prompts.empty?
    github.comment_edits.fetch(55).include?("ℹ️ **/build** — nothing to address")

    Cleanup
    nil
  end

  test "/build in a review thread is refused with a pointer to the conversation" do
    Given "a /build posted inside a review thread"
    github = FakeGitHub.new
    context = ContextBuilder.review_comment(number: 3, body: "/build fix this")
    executor = RecordingExecutor.new
    agent = FakeAgent.new([])

    When "running"
    run_build(github: github, executor: executor, body: "/build fix this", context: context, agent: agent)

    Then "no agent, no git, an in-thread panel pointing at top-level /build"
    agent.prompts.empty?
    executor.command_lines.empty?
    github.comment_edits.fetch(9).include?("ℹ️ **/build** — /build runs from the PR conversation")
    github.calls.map(&:first).include?(:update_review_comment)

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
