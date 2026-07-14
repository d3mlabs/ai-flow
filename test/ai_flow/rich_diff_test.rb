# frozen_string_literal: true

require "test_helper"

transform!(RSpock::AST::Transformation)
class AiFlow::RichDiffTest < Minitest::Test
  test "prose changes render as word-level ins/del" do
    Given "a one-word change"
    before = "The carve system uses LOD0 only.\n"
    after = "The carve system uses LOD0 and LOD1.\n"

    When "rendering"
    result = AiFlow::RichDiff.new.render(before: before, after: after)

    Then "ins/del markup and a collapsed source diff are present"
    result.include?("<del>only.</del>")
    result.include?("<ins>and LOD1.</ins>")
    result.include?("<details>")
    result.include?("````diff")

    Cleanup
    nil
  end

  test "changed mermaid blocks re-render whole instead of word-diffing" do
    Given "an edit that changes a mermaid diagram"
    before = "Intro.\n\n```mermaid\nflowchart LR\n  a --> b\n```\n"
    after = "Intro.\n\n```mermaid\nflowchart LR\n  a --> b\n  b --> c\n```\n"

    When "rendering"
    result = AiFlow::RichDiff.new.render(before: before, after: after)

    Then "the new diagram appears as a live mermaid block"
    result.include?("Updated diagram:")
    result.include?("```mermaid\nflowchart LR\n  a --> b\n  b --> c\n```")

    Cleanup
    nil
  end

  test "the collapsed diff fence outlives any fence it contains" do
    Given "a diff containing a three-backtick mermaid fence"
    before = "Text.\n"
    after = "Text.\n\n```mermaid\nflowchart LR\n  a --> b\n```\n"

    When "rendering"
    result = AiFlow::RichDiff.new.render(before: before, after: after)

    Then "the outer fence is four backticks (plan's formatter rule)"
    result.include?("````diff")

    Cleanup
    nil
  end

  test "a backlink text fragment targets the first distinctive prose line" do
    Given
    result = AiFlow::RichDiff.new.render(
      before: "Old text.\n",
      after: "# Heading\n\nRuntime carve operations stay on LOD0.\n",
      backlink_url: "https://github.com/o/r/issues/2",
    )

    Expect
    result.include?("https://github.com/o/r/issues/2#:~:text=Runtime%20carve%20operations%20stay%20on%20LOD0.")

    Cleanup
    nil
  end
end
