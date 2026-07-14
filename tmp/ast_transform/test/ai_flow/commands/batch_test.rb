require("test_helper")
require("support/fakes")

class AiFlow::Commands::BatchTest < Minitest::Test
  (begin
    extend(RSpock::Declarative)
    REPO = "d3mlabs/demo"
    SNAPSHOT = "# Carve system

The carve system uses LOD0 only.

## Streaming

Chunks stream in 64m cells.\n"

    def build_batch(github:, agent:, context:)
      AiFlow::Commands::Batch.new(context:, github:, agent:, rich_diff: AiFlow::RichDiff.new, result_writer: AiFlow::ResultWriter.new(github:), executor: AiFlow::Executor.new, workdir: Dir.pwd)
    end

    def parse(body)
      AiFlow::CommentParser.new.parse(body)
    end
    test("an /edit batch integrates once, PATCHes once, and appends per-segment results") {
      begin
        github = FakeGitHub.new
        github.seed_issue(REPO, 7, title: "Carve system", body: AiFlow::PlanBody.to_issue_body(SNAPSHOT))
        comment = "> The carve system uses LOD0 only.\n\n/edit cover LOD1 too\n\n" "> Chunks stream in 64m cells.\n\n/edit make cells 32m"
        context = ContextBuilder.issue_comment(body: comment)
        new_body = SNAPSHOT.sub("LOD0 only", "LOD0 and LOD1").sub("64m cells", "32m cells")
        agent = FakeAgent.new(["<<<AI-FLOW:BODY>>>\n#{new_body}
<<<AI-FLOW:SEGMENT 1>>>
The carve system uses LOD0 and LOD1.
<<<AI-FLOW:SEGMENT 2>>>
Chunks stream in 32m cells.\n"])
        build_batch(github:, agent:, context:).run(parse(comment))
        assert_equal(1, agent.prompts.size)
        assert_equal(1, github.calls.map(&:first).count(:update_issue_body))
        assert_equal(AiFlow::PlanBody.to_issue_body(new_body), github.issue(REPO, 7).body)
        assert_equal(true, github.comment_edits.fetch(55).include?("/edit cover LOD1 too"), "Expected \"github.comment_edits.fetch(55).include?(\"/edit cover LOD1 too\")\" to be true")
        assert_equal(2, github.comment_edits.fetch(55).scan("✅ **/edit**").size)
        assert_equal(true, github.comment_edits.fetch(55).include?("<ins>"), "Expected \"github.comment_edits.fetch(55).include?(\"<ins>\")\" to be true")
      ensure
        (nil)
      end
    }
    test("a stale quote fails only its own segment") {
      begin
        github = FakeGitHub.new
        github.seed_issue(REPO, 7, title: "Carve system", body: AiFlow::PlanBody.to_issue_body(SNAPSHOT))
        comment = "> This text was edited away meanwhile.\n\n/edit tighten\n\n" "> Chunks stream in 64m cells.\n\n/edit make cells 32m"
        context = ContextBuilder.issue_comment(body: comment)
        new_body = SNAPSHOT.sub("64m cells", "32m cells")
        agent = FakeAgent.new(["<<<AI-FLOW:BODY>>>\n#{new_body}
<<<AI-FLOW:SEGMENT 1>>>
Chunks stream in 32m cells.\n"])
        build_batch(github:, agent:, context:).run(parse(comment))
        assert_equal(AiFlow::PlanBody.to_issue_body(new_body), github.issue(REPO, 7).body)
        edited = github.comment_edits.fetch(55)
        assert_equal(true, edited.include?("⚠️ The quoted text was not found"), "Expected \"edited.include?(\"⚠️ The quoted text was not found\")\" to be true")
        assert_equal(true, edited.include?("✅ **/edit**"), "Expected \"edited.include?(\"✅ **/edit**\")\" to be true")
      ensure
        (nil)
      end
    }
    test("a standalone /ask gets a reply comment, not an in-place edit") {
      begin
        github = FakeGitHub.new
        github.seed_issue(REPO, 7, title: "Carve system", body: AiFlow::PlanBody.to_issue_body(SNAPSHOT))
        context = ContextBuilder.issue_comment(body: "/ask why LOD0 only?")
        agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nBecause carving happens at runtime."])
        build_batch(github:, agent:, context:).run(parse("/ask why LOD0 only?"))
        assert_equal(1, github.comments.size)
        assert_equal(true, github.comments.first.include?("Because carving happens at runtime."), "Expected \"github.comments.first.include?(\"Because carving happens at runtime.\")\" to be true")
        assert_equal(true, github.comment_edits.empty?, "Expected \"github.comment_edits.empty?\" to be true")
        assert_equal(false, github.calls.map(&:first).include?(:update_issue_body), "Expected \"!github.calls.map(&:first).include?(:update_issue_body)\" to be false")
      ensure
        (nil)
      end
    }
    test("an /ask inside a batch lands in place with the other results") {
      begin
        github = FakeGitHub.new
        github.seed_issue(REPO, 7, title: "Carve system", body: AiFlow::PlanBody.to_issue_body(SNAPSHOT))
        comment = "> The carve system uses LOD0 only.\n\n/ask why?\n\n" "> Chunks stream in 64m cells.\n\n/edit make cells 32m"
        context = ContextBuilder.issue_comment(body: comment)
        new_body = SNAPSHOT.sub("64m cells", "32m cells")
        agent = FakeAgent.new(["<<<AI-FLOW:BODY>>>\n#{new_body}
<<<AI-FLOW:SEGMENT 1>>>
Because carving happens at runtime.
<<<AI-FLOW:SEGMENT 2>>>
Chunks stream in 32m cells.\n"])
        build_batch(github:, agent:, context:).run(parse(comment))
        assert_equal(true, github.comments.empty?, "Expected \"github.comments.empty?\" to be true")
        assert_equal(true, github.comment_edits.fetch(55).include?("Because carving happens at runtime."), "Expected \"github.comment_edits.fetch(55).include?(\"Because carving happens at runtime.\")\" to be true")
      ensure
        (nil)
      end
    }
    test("the guarded PATCH refuses when the body moved mid-batch") {
      begin
        github = FakeGitHub.new
        github.seed_issue(REPO, 7, title: "Carve system", body: AiFlow::PlanBody.to_issue_body(SNAPSHOT))
        comment = "> Chunks stream in 64m cells.\n\n/edit make cells 32m"
        context = ContextBuilder.issue_comment(body: comment)
        agent = Class.new {
          def initialize(github)
            @github = github
          end

          def launch(prompt:, workdir:, command:, force: false)
            @github.update_issue_body("d3mlabs/demo", 7, body: "# Changed meanwhile\n\n<!-- ai-flow:plan -->\n")
            "<<<AI-FLOW:BODY>>>\nirrelevant\n<<<AI-FLOW:SEGMENT 1>>>\nirrelevant"
          end
        }.new(github)
        assert_raises(AiFlow::GitHub::Error) {
          build_batch(github:, agent:, context:).run(parse(comment))
        }
      ensure
        (nil)
      end
    }
  rescue StandardError => e
    ::RSpock::BacktraceFilter.new.filter_exception(e)
    raise
  end)
end
