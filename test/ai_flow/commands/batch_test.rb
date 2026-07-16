# frozen_string_literal: true

require "test_helper"
require "support/fakes"

transform!(RSpock::AST::Transformation)
class AiFlow::Commands::BatchTest < Minitest::Test
  REPO = "d3mlabs/demo"

  SNAPSHOT = <<~BODY
    # Carve system

    The carve system uses LOD0 only.

    ## Streaming

    Chunks stream in 64m cells.
  BODY

  def build_batch(github:, agent:, context:)
    AiFlow::Commands::Batch.new(
      context: context,
      github: github,
      agent: agent,
      rich_diff: AiFlow::RichDiff.new,
      result_writer: AiFlow::ResultWriter.new(github: github),
      executor: AiFlow::Executor.new,
      workdir: Dir.pwd,
    )
  end

  def parse(body)
    AiFlow::CommentParser.new.parse(body)
  end

  test "an /edit batch integrates once, PATCHes once, and appends per-segment results" do
    Given "a managed plan issue and a two-segment edit batch"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: AiFlow::PlanBody.to_issue_body(SNAPSHOT))
    comment = "> The carve system uses LOD0 only.\n\n/edit cover LOD1 too\n\n" \
              "> Chunks stream in 64m cells.\n\n/edit make cells 32m"
    context = ContextBuilder.issue_comment(body: comment)
    new_body = SNAPSHOT.sub("LOD0 only", "LOD0 and LOD1").sub("64m cells", "32m cells")
    agent = FakeAgent.new([<<~OUTPUT])
      <<<AI-FLOW:BODY>>>
      #{new_body}
      <<<AI-FLOW:SEGMENT 1>>>
      The carve system uses LOD0 and LOD1.
      <<<AI-FLOW:SEGMENT 2>>>
      Chunks stream in 32m cells.
    OUTPUT

    When "running the batch"
    build_batch(github:, agent:, context:).run(parse(comment))

    Then "one agent pass, one body PATCH, and both results edited in place"
    agent.prompts.size == 1
    github.calls.map(&:first).count(:update_issue_body) == 1
    github.issue(REPO, 7).body == AiFlow::PlanBody.to_issue_body(new_body)
    github.comment_edits.fetch(55).include?("/edit cover LOD1 too")
    github.comment_edits.fetch(55).scan("> ✅ **/edit** — [view the edited section](").size == 2
    github.comment_edits.fetch(55).include?("<summary>Word diff</summary>")
    github.comment_edits.fetch(55).include?("<summary>Source diff</summary>")
    github.comment_edits.fetch(55).include?("<ins>")

    Cleanup
    nil
  end

  test "anchored edits splice into the body even when the agent echoes the snapshot as BODY" do
    Given "an agent whose BODY output is the unintegrated snapshot (observed in the wild)"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: AiFlow::PlanBody.to_issue_body(SNAPSHOT))
    comment = "> The carve system uses LOD0 only.\n\n/edit cover LOD1 too"
    context = ContextBuilder.issue_comment(body: comment)
    agent = FakeAgent.new([<<~OUTPUT])
      <<<AI-FLOW:BODY>>>
      #{SNAPSHOT}
      <<<AI-FLOW:SEGMENT 1>>>
      The carve system uses LOD0 and LOD1.
    OUTPUT

    When "running the batch"
    build_batch(github:, agent:, context:).run(parse(comment))

    Then "the PATCH carries the spliced rewrite, not the echoed snapshot"
    github.calls.map(&:first).count(:update_issue_body) == 1
    github.issue(REPO, 7).body.include?("The carve system uses LOD0 and LOD1.")
    !github.issue(REPO, 7).body.include?("LOD0 only")

    Cleanup
    nil
  end

  test "a rewrite that cannot be integrated reports ⚠️ instead of a ✅ diff" do
    Given "two quotes in one paragraph — the first splice invalidates the second span"
    github = FakeGitHub.new
    body = "# Doc\n\nAlpha sentence here. Beta sentence here.\n"
    github.seed_issue(REPO, 7, title: "Doc", body: AiFlow::PlanBody.to_issue_body(body))
    comment = "> Alpha sentence here.\n\n/edit improve alpha\n\n" \
              "> Beta sentence here.\n\n/edit improve beta"
    context = ContextBuilder.issue_comment(body: comment)
    agent = FakeAgent.new([<<~OUTPUT])
      <<<AI-FLOW:BODY>>>
      #{body}
      <<<AI-FLOW:SEGMENT 1>>>
      Alpha improved. Beta sentence here.
      <<<AI-FLOW:SEGMENT 2>>>
      Alpha sentence here. Beta improved.
    OUTPUT

    When "running the batch"
    build_batch(github:, agent:, context:).run(parse(comment))

    Then "the landed edit gets its ✅ diff and the dropped one is loud"
    github.issue(REPO, 7).body.include?("Alpha improved.")
    !github.issue(REPO, 7).body.include?("Beta improved.")
    edited = github.comment_edits.fetch(55)
    edited.scan("✅ **/edit**").size == 1
    edited.include?("⚠️ **/edit** — the rewrite was produced but could not be integrated")

    Cleanup
    nil
  end

  test "a stale quote fails only its own segment" do
    Given "a batch where one quote no longer matches the body"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: AiFlow::PlanBody.to_issue_body(SNAPSHOT))
    comment = "> This text was edited away meanwhile.\n\n/edit tighten\n\n" \
              "> Chunks stream in 64m cells.\n\n/edit make cells 32m"
    context = ContextBuilder.issue_comment(body: comment)
    new_body = SNAPSHOT.sub("64m cells", "32m cells")
    agent = FakeAgent.new([<<~OUTPUT])
      <<<AI-FLOW:BODY>>>
      #{new_body}
      <<<AI-FLOW:SEGMENT 1>>>
      Chunks stream in 32m cells.
    OUTPUT

    When "running the batch"
    build_batch(github:, agent:, context:).run(parse(comment))

    Then "the live segment applied and the stale one reports staleness"
    github.issue(REPO, 7).body == AiFlow::PlanBody.to_issue_body(new_body)
    edited = github.comment_edits.fetch(55)
    edited.include?("⚠️ The quoted text was not found")
    edited.include?("✅ **/edit**")

    Cleanup
    nil
  end

  test "a standalone /ask gets a reply comment, not an in-place edit" do
    Given "a plan issue and a bare question"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: AiFlow::PlanBody.to_issue_body(SNAPSHOT))
    context = ContextBuilder.issue_comment(body: "/ask why LOD0 only?")
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nBecause carving happens at runtime."])

    When "running"
    build_batch(github:, agent:, context:).run(parse("/ask why LOD0 only?"))

    Then "the answer is a reply and the body was never PATCHed"
    github.comments.size == 1
    github.comments.first.include?("Because carving happens at runtime.")
    github.comment_edits.empty?
    !github.calls.map(&:first).include?(:update_issue_body)

    Cleanup
    nil
  end

  test "an /ask inside a batch lands in place with the other results" do
    Given "a batch mixing /ask and /edit"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: AiFlow::PlanBody.to_issue_body(SNAPSHOT))
    comment = "> The carve system uses LOD0 only.\n\n/ask why?\n\n" \
              "> Chunks stream in 64m cells.\n\n/edit make cells 32m"
    context = ContextBuilder.issue_comment(body: comment)
    new_body = SNAPSHOT.sub("64m cells", "32m cells")
    agent = FakeAgent.new([<<~OUTPUT])
      <<<AI-FLOW:BODY>>>
      #{new_body}
      <<<AI-FLOW:SEGMENT 1>>>
      Because carving happens at runtime.
      <<<AI-FLOW:SEGMENT 2>>>
      Chunks stream in 32m cells.
    OUTPUT

    When "running the batch"
    build_batch(github:, agent:, context:).run(parse(comment))

    Then "the answer is in the edited comment, not a reply"
    github.comments.empty?
    github.comment_edits.fetch(55).include?("Because carving happens at runtime.")

    Cleanup
    nil
  end

  test "the guarded PATCH refuses when the body moved mid-batch" do
    Given "a batch whose issue is edited between snapshot and PATCH"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: AiFlow::PlanBody.to_issue_body(SNAPSHOT))
    comment = "> Chunks stream in 64m cells.\n\n/edit make cells 32m"
    context = ContextBuilder.issue_comment(body: comment)
    agent = Class.new do
      def initialize(github) = @github = github

      def launch(prompt:, workdir:, command:, force: false)
        # Simulate a remote edit racing the batch.
        @github.update_issue_body("d3mlabs/demo", 7, body: "# Changed meanwhile\n\n<!-- ai-flow:plan -->\n")
        "<<<AI-FLOW:BODY>>>\nirrelevant\n<<<AI-FLOW:SEGMENT 1>>>\nirrelevant"
      end
    end.new(github)

    When "running the batch"
    build_batch(github:, agent:, context:).run(parse(comment))

    Then
    raises AiFlow::GitHub::Error

    Cleanup
    nil
  end
end
