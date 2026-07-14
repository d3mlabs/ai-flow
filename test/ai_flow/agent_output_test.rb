# frozen_string_literal: true

require "test_helper"

transform!(RSpock::AST::Transformation)
class AiFlow::AgentOutputTest < Minitest::Test
  test "parses the body and numbered segment blocks" do
    Given "a delimited agent output"
    output = <<~OUTPUT
      <<<AI-FLOW:BODY>>>
      # New document

      Rewritten content.
      <<<AI-FLOW:SEGMENT 1>>>
      The rewritten section text.
      <<<AI-FLOW:SEGMENT 2>>>
      An answer to the question.
    OUTPUT

    When "parsing"
    parsed = AiFlow::AgentOutput.parse(output)

    Then
    parsed.body == "# New document\n\nRewritten content."
    parsed.segments[1] == "The rewritten section text."
    parsed.segments[2] == "An answer to the question."

    Cleanup
    nil
  end

  test "an ask-only output has segments but no body" do
    Given
    parsed = AiFlow::AgentOutput.parse("<<<AI-FLOW:SEGMENT 1>>>\nJust an answer.")

    Expect
    parsed.body.nil?
    parsed.segments == { 1 => "Just an answer." }

    Cleanup
    nil
  end

  test "text outside any delimiter is ignored" do
    Given "an agent that chatted before the envelope"
    parsed = AiFlow::AgentOutput.parse("Sure! Here you go:\n<<<AI-FLOW:SEGMENT 1>>>\nAnswer.")

    Expect
    parsed.segments == { 1 => "Answer." }

    Cleanup
    nil
  end
end
