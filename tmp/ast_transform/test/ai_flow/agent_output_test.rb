require("test_helper")

class AiFlow::AgentOutputTest < Minitest::Test
  (begin
    extend(RSpock::Declarative)
    test("parses the body and numbered segment blocks") {
      begin
        output = <<-HEREDOC
<<<AI-FLOW:BODY>>>
\# New document

Rewritten content.
<<<AI-FLOW:SEGMENT 1>>>
The rewritten section text.
<<<AI-FLOW:SEGMENT 2>>>
An answer to the question.
HEREDOC
        parsed = AiFlow::AgentOutput.parse(output)
        assert_equal("# New document\n\nRewritten content.", parsed.body)
        assert_equal("The rewritten section text.", parsed.segments.[](1))
        assert_equal("An answer to the question.", parsed.segments.[](2))
      ensure
        (nil)
      end
    }
    test("an ask-only output has segments but no body") {
      begin
        parsed = AiFlow::AgentOutput.parse("<<<AI-FLOW:SEGMENT 1>>>\nJust an answer.")
        assert_equal(true, parsed.body.nil?, "Expected \"parsed.body.nil?\" to be true")
        assert_equal({ 1 => "Just an answer." }, parsed.segments)
      ensure
        (nil)
      end
    }
    test("text outside any delimiter is ignored") {
      begin
        parsed = AiFlow::AgentOutput.parse("Sure! Here you go:\n<<<AI-FLOW:SEGMENT 1>>>\nAnswer.")
        assert_equal({ 1 => "Answer." }, parsed.segments)
      ensure
        (nil)
      end
    }
  rescue StandardError => e
    ::RSpock::BacktraceFilter.new.filter_exception(e)
    raise
  end)
end
