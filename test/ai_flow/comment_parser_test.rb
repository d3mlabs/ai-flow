# frozen_string_literal: true

require "test_helper"

transform!(RSpock::AST::Transformation)
class AiFlow::CommentParserTest < Minitest::Test
  def parse(body, prefix: "")
    AiFlow::CommentParser.new(prefix: prefix).parse(body)
  end

  test "a standalone command with an inline instruction parses" do
    Given "a bare /ask comment"
    segments = parse("/ask why is the carve system split into two phases?")

    Expect "one unscoped segment with the instruction"
    segments.size == 1
    segments.first.command == "ask"
    segments.first.quote.nil?
    segments.first.instruction == "why is the carve system split into two phases?"

    Cleanup
    nil
  end

  test "a quote binds to the command immediately below it" do
    Given "GitHub's quote-reply shape (quote, blank line, command)"
    body = <<~COMMENT
      > The carve system uses LOD0 only.

      /edit expand this to cover LOD1 streaming too
    COMMENT

    When "parsing"
    segments = parse(body)

    Then "the quote is the de-quoted anchor"
    segments.size == 1
    segments.first.quote == "The carve system uses LOD0 only."
    segments.first.instruction == "expand this to cover LOD1 streaming too"

    Cleanup
    nil
  end

  test "a batch of quote+command pairs parses segment by segment" do
    Given "the review work unit: several highlight+r pairs in one comment"
    body = <<~COMMENT
      > Section A text.

      /edit tighten this

      > Section B text.

      /ask is this still true?
      More context for the question,
      spanning two lines.

      > Section C text.

      /edit rewrite for clarity
    COMMENT

    When "parsing"
    segments = parse(body)

    Then "three segments, each with its own quote and owned free text"
    segments.map(&:command) == ["edit", "ask", "edit"]
    segments[0].quote == "Section A text."
    segments[1].quote == "Section B text."
    segments[1].instruction == "is this still true?\nMore context for the question,\nspanning two lines."
    segments[2].quote == "Section C text."

    Cleanup
    nil
  end

  test "commands are recognized only at the start of a line" do
    Given "prose mentioning a command mid-line"
    segments = parse("I think the /build passes fine, and /edit is unrelated here.")

    Expect "no segments"
    segments.empty?

    Cleanup
    nil
  end

  test "/build --split parses flags apart from the instruction" do
    Given
    segments = parse("/build --split focus on the server-side subtasks first")

    Expect
    segments.first.command == "build"
    segments.first.flags == ["--split"]
    segments.first.instruction == "focus on the server-side subtasks first"

    Cleanup
    nil
  end

  test "a configured prefix shifts the command tokens" do
    Given "an adopter running with the ai- prefix"
    segments = parse("/ai-ask what changed?", prefix: "ai-")
    unprefixed = parse("/ask what changed?", prefix: "ai-")

    Expect "/ai-ask matches and bare /ask does not"
    segments.size == 1
    segments.first.command == "ask"
    unprefixed.empty?

    Cleanup
    nil
  end

  test "lifecycle commands must be a comment's only command" do
    Given "a batch mixing /edit with /build"
    body = <<~COMMENT
      > Section A.

      /edit tighten

      /build
    COMMENT

    When "parsing"
    parse(body)

    Then
    raises AiFlow::CommentParser::ParseError

    Cleanup
    nil
  end

  test "multi-line quotes are captured whole" do
    Given "a quote block spanning lines"
    body = <<~COMMENT
      > First quoted line.
      > Second quoted line.

      /ask does this hold?
    COMMENT

    When "parsing"
    segments = parse(body)

    Then
    segments.first.quote == "First quoted line.\nSecond quoted line."

    Cleanup
    nil
  end

  test "plain quoted comments (deferred feedback) parse to no segments" do
    Given "a quote with no command — the deferred-feedback backlog"
    segments = parse("> This section worries me.\n\nLet's discuss at standup.")

    Expect
    segments.empty?

    Cleanup
    nil
  end
end
