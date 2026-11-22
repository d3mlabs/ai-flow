# typed: true
# frozen_string_literal: true

require "test_helper"

transform!(RSpock::AST::Transformation)
class AiFlow::AgentOutputTest < Minitest::Test
  test "parses numbered segment blocks" do
    Given "a delimited agent output"
    output = <<~OUTPUT
      <<<AI-FLOW:SEGMENT 1>>>
      Extended the carve system to LOD1.
      <<<AI-FLOW:SEGMENT 2>>>
      An answer to the question,
      over two lines.
    OUTPUT

    When "parsing"
    parsed = AiFlow::AgentOutput.parse(output)

    Then
    parsed.segments[1] == "Extended the carve system to LOD1."
    parsed.segments[2] == "An answer to the question,\nover two lines."

    Cleanup
    nil
  end

  test "FIX declarations are protocol, not segment text: dropped from the segments (ai-flow#169)" do
    Given "a segment that interleaves prose and FIX lines"
    output = <<~OUTPUT
      <<<AI-FLOW:SEGMENT 1>>>
      Fixed the walk.
      FIX: lib/a.rb — inject the clock
      Rubocop is clean.
      FIX: lib/b.rb — drop the sleep
    OUTPUT

    When "parsing"
    parsed = AiFlow::AgentOutput.parse(output)

    Then "the prose stays, the declarations go"
    parsed.segments[1] == "Fixed the walk.\nRubocop is clean."

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

  test "a delimiter run into mid-line narration still parses" do
    Given "the agent CLI's result field concatenating narration into the delimiter (observed in the wild)"
    output = "I'll apply those edits in smaller chunks.<<<AI-FLOW:SEGMENT 1>>>\nMade the root configurable."

    When "parsing"
    parsed = AiFlow::AgentOutput.parse(output)

    Then
    parsed.segments == { 1 => "Made the root configurable." }

    Cleanup
    nil
  end
end
