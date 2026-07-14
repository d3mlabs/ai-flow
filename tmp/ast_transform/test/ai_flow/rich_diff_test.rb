require("test_helper")

class AiFlow::RichDiffTest < Minitest::Test
  (begin
    extend(RSpock::Declarative)
    test("prose changes render as word-level ins/del") {
      begin
        before = "The carve system uses LOD0 only.\n"
        after = "The carve system uses LOD0 and LOD1.\n"
        result = AiFlow::RichDiff.new.render(before:, after:)
        assert_equal(true, result.include?("<del>only.</del>"), "Expected \"result.include?(\"<del>only.</del>\")\" to be true")
        assert_equal(true, result.include?("<ins>and LOD1.</ins>"), "Expected \"result.include?(\"<ins>and LOD1.</ins>\")\" to be true")
        assert_equal(true, result.include?("<details>"), "Expected \"result.include?(\"<details>\")\" to be true")
        assert_equal(true, result.include?("````diff"), "Expected \"result.include?(\"````diff\")\" to be true")
      ensure
        (nil)
      end
    }
    test("changed mermaid blocks re-render whole instead of word-diffing") {
      begin
        before = "Intro.\n\n```mermaid\nflowchart LR\n  a --> b\n```\n"
        after = "Intro.\n\n```mermaid\nflowchart LR\n  a --> b\n  b --> c\n```\n"
        result = AiFlow::RichDiff.new.render(before:, after:)
        assert_equal(true, result.include?("Updated diagram:"), "Expected \"result.include?(\"Updated diagram:\")\" to be true")
        assert_equal(true, result.include?("```mermaid\nflowchart LR\n  a --> b\n  b --> c\n```"), "Expected \"result.include?(\"```mermaid\\nflowchart LR\\n  a --> b\\n  b --> c\\n```\")\" to be true")
      ensure
        (nil)
      end
    }
    test("the collapsed diff fence outlives any fence it contains") {
      begin
        before = "Text.\n"
        after = "Text.\n\n```mermaid\nflowchart LR\n  a --> b\n```\n"
        result = AiFlow::RichDiff.new.render(before:, after:)
        assert_equal(true, result.include?("````diff"), "Expected \"result.include?(\"````diff\")\" to be true")
      ensure
        (nil)
      end
    }
    test("a backlink text fragment targets the first distinctive prose line") {
      begin
        result = AiFlow::RichDiff.new.render(before: "Old text.\n", after: "# Heading\n\nRuntime carve operations stay on LOD0.\n", backlink_url: "https://github.com/o/r/issues/2")
        assert_equal(true, result.include?("https://github.com/o/r/issues/2#:~:text=Runtime%20carve%20operations%20stay%20on%20LOD0."), "Expected \"result.include?(\"https://github.com/o/r/issues/2#:~:text=Runtime%20carve%20operations%20stay%20on%20LOD0.\")\" to be true")
      ensure
        (nil)
      end
    }
  rescue StandardError => e
    ::RSpock::BacktraceFilter.new.filter_exception(e)
    raise
  end)
end
