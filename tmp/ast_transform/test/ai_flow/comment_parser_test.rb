require("test_helper")

class AiFlow::CommentParserTest < Minitest::Test
  (begin
    extend(RSpock::Declarative)

    def parse(body, prefix: "")
      AiFlow::CommentParser.new(prefix:).parse(body)
    end
    test("a standalone command with an inline instruction parses") {
      begin
        segments = parse("/ask why is the carve system split into two phases?")
        assert_equal(1, segments.size)
        assert_equal("ask", segments.first.command)
        assert_equal(true, segments.first.quote.nil?, "Expected \"segments.first.quote.nil?\" to be true")
        assert_equal("why is the carve system split into two phases?", segments.first.instruction)
      ensure
        (nil)
      end
    }
    test("a quote binds to the command immediately below it") {
      begin
        body = "> The carve system uses LOD0 only.

/edit expand this to cover LOD1 streaming too\n"
        segments = parse(body)
        assert_equal(1, segments.size)
        assert_equal("The carve system uses LOD0 only.", segments.first.quote)
        assert_equal("expand this to cover LOD1 streaming too", segments.first.instruction)
      ensure
        (nil)
      end
    }
    test("a batch of quote+command pairs parses segment by segment") {
      begin
        body = <<-HEREDOC
> Section A text.

/edit tighten this

> Section B text.

/ask is this still true?
More context for the question,
spanning two lines.

> Section C text.

/edit rewrite for clarity
HEREDOC
        segments = parse(body)
        assert_equal(["edit", "ask", "edit"], segments.map(&:command))
        assert_equal("Section A text.", segments.[](0).quote)
        assert_equal("Section B text.", segments.[](1).quote)
        assert_equal("is this still true?\nMore context for the question,\nspanning two lines.", segments.[](1).instruction)
        assert_equal("Section C text.", segments.[](2).quote)
      ensure
        (nil)
      end
    }
    test("commands are recognized only at the start of a line") {
      begin
        segments = parse("I think the /build passes fine, and /edit is unrelated here.")
        assert_equal(true, segments.empty?, "Expected \"segments.empty?\" to be true")
      ensure
        (nil)
      end
    }
    test("/build --split parses flags apart from the instruction") {
      begin
        segments = parse("/build --split focus on the server-side subtasks first")
        assert_equal("build", segments.first.command)
        assert_equal(["--split"], segments.first.flags)
        assert_equal("focus on the server-side subtasks first", segments.first.instruction)
      ensure
        (nil)
      end
    }
    test("a configured prefix shifts the command tokens") {
      begin
        segments = parse("/ai-ask what changed?", prefix: "ai-")
        unprefixed = parse("/ask what changed?", prefix: "ai-")
        assert_equal(1, segments.size)
        assert_equal("ask", segments.first.command)
        assert_equal(true, unprefixed.empty?, "Expected \"unprefixed.empty?\" to be true")
      ensure
        (nil)
      end
    }
    test("lifecycle commands must be a comment's only command") {
      begin
        body = "> Section A.

/edit tighten

/build\n"
        assert_raises(AiFlow::CommentParser::ParseError) {
          parse(body)
        }
      ensure
        (nil)
      end
    }
    test("multi-line quotes are captured whole") {
      begin
        body = "> First quoted line.
> Second quoted line.

/ask does this hold?\n"
        segments = parse(body)
        assert_equal("First quoted line.\nSecond quoted line.", segments.first.quote)
      ensure
        (nil)
      end
    }
    test("end_line marks the last line each segment owns") {
      begin
        body = "> Q1\n\n/edit tighten\nplus this line\n\n> Q2\n\n/ask why?"
        segments = parse(body)
        assert_equal(3, segments.[](0).end_line)
        assert_equal(7, segments.[](1).end_line)
      ensure
        (nil)
      end
    }
    test("plain quoted comments (deferred feedback) parse to no segments") {
      begin
        segments = parse("> This section worries me.\n\nLet's discuss at standup.")
        assert_equal(true, segments.empty?, "Expected \"segments.empty?\" to be true")
      ensure
        (nil)
      end
    }
  rescue StandardError => e
    ::RSpock::BacktraceFilter.new.filter_exception(e)
    raise
  end)
end
