require("test_helper")
require("support/fakes")

class AiFlow::DispatcherTest < Minitest::Test
  (begin
    extend(RSpock::Declarative)
    REPO = "d3mlabs/demo"

    def build_dispatcher(github:, agent:, context:)
      AiFlow::Dispatcher.new(context:, workdir: Dir.pwd, github:, agent:)
    end
    test("an unauthorized commenter is ignored entirely") {
      begin
        github = FakeGitHub.new
        context = ContextBuilder.issue_comment(body: "/ask anything?", association: "NONE")
        build_dispatcher(github:, agent: FakeAgent.new([]), context:).run
        assert_equal(true, github.calls.empty?, "Expected \"github.calls.empty?\" to be true")
      ensure
        (nil)
      end
    }
    test("a non-command comment is a clean no-op") {
      begin
        github = FakeGitHub.new
        context = ContextBuilder.issue_comment(body: "looks good, the /build passed earlier")
        build_dispatcher(github:, agent: FakeAgent.new([]), context:).run
        assert_equal(true, github.calls.empty?, "Expected \"github.calls.empty?\" to be true")
      ensure
        (nil)
      end
    }
    test("a command comment is acknowledged with the eyes reaction and routed") {
      begin
        github = FakeGitHub.new
        github.seed_issue(REPO, 7, title: "Plan", body: "# Plan\n\n<!-- ai-flow:plan -->\n")
        context = ContextBuilder.issue_comment(body: "/ask why?")
        agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nBecause."])
        build_dispatcher(github:, agent:, context:).run
        assert_equal([:react_to_comment, 55, "eyes"], github.calls.first)
        assert_equal(1, github.comments.size)
      ensure
        (nil)
      end
    }
  rescue StandardError => e
    ::RSpock::BacktraceFilter.new.filter_exception(e)
    raise
  end)
end
