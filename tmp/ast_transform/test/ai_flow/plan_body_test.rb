require("test_helper")

class AiFlow::PlanBodyTest < Minitest::Test
  (begin
    extend(RSpock::Declarative)
    BODY = <<-HEREDOC
\# Carve system

The carve system uses **LOD0 only** for runtime operations.

\#\# Streaming

Chunks stream in `64m` cells around the player.

\#\# Persistence

Carves persist as deltas against the base terrain.
HEREDOC
    test("marker round-trip") {
      begin
        assert_equal(true, AiFlow::PlanBody.managed?(AiFlow::PlanBody.to_issue_body("# T\n")))
        assert_equal("# T\n", AiFlow::PlanBody.from_issue_body(AiFlow::PlanBody.to_issue_body("# T\n")))
        assert_equal(false, AiFlow::PlanBody.managed?("# plain issue"))
      ensure
        (nil)
      end
    }
    test("an exact quote resolves to its paragraph") {
      begin
        (assert_equal("Carves persist as deltas against the base terrain.", AiFlow::PlanBody.locate_quote(BODY, "Carves persist as deltas against the base terrain.")))
      ensure
        (nil)
      end
    }
    test("a rendered quote (markdown stripped) still resolves") {
      begin
        quote = "The carve system uses LOD0 only for runtime operations."
        assert_equal("The carve system uses **LOD0 only** for runtime operations.", AiFlow::PlanBody.locate_quote(BODY, quote))
      ensure
        (nil)
      end
    }
    test("a multi-paragraph quote resolves to the minimal spanning region") {
      begin
        quote = "Streaming\nChunks stream in 64m cells around the player."
        assert_equal("## Streaming\n\nChunks stream in `64m` cells around the player.", AiFlow::PlanBody.locate_quote(BODY, quote))
      ensure
        (nil)
      end
    }
    test("a stale quote returns nil") {
      begin
        (assert_equal(true, AiFlow::PlanBody.locate_quote(BODY, "This sentence was edited away.").nil?, "Expected \"AiFlow::PlanBody.locate_quote(BODY, \"This sentence was edited away.\").nil?\" to be true"))
      ensure
        (nil)
      end
    }
  rescue StandardError => e
    ::RSpock::BacktraceFilter.new.filter_exception(e)
    raise
  end)
end
