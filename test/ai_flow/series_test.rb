# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "support/value_semantics_assertions"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class AiFlow::SeriesTest < Minitest::Test
  include ValueSemanticsAssertions

  test "the series of #{version.inspect} spells its tag #{tag} and its range #{requirement}" do
    When
    series = AiFlow::Series.parse(version)

    Then "one constraint, two doors"
    series.major == major
    series.tag == tag
    series.requirement == requirement

    Where
    version          | major | tag   | requirement
    "1.0.0"          | 1     | "v1"  | "^1"
    "1.1.0\n"        | 1     | "v1"  | "^1"
    "2.0.0-rc.1"     | 2     | "v2"  | "^2"
    "12.3.4+build.7" | 12    | "v12" | "^12"
  end

  test "text that is not a MAJOR.MINOR.PATCH version is refused: #{text.inspect}" do
    When
    AiFlow::Series.parse(text)

    Then
    e = raises AiFlow::Series::InvalidVersionError
    e.message.include?("is not a MAJOR.MINOR.PATCH version")

    Where
    text
    ""
    "v1"
    "1"
    "1.2"
    "main"
  end

  test "the tree's series is read from its VERSION file" do
    Given "a tree at 3.2.1"
    root = Dir.mktmpdir("ai-flow-series-")
    File.write(File.join(root, AiFlow::Series::VERSION_FILE), "3.2.1\n")

    Expect
    AiFlow::Series.of_tree(root) == AiFlow::Series.new(major: 3)

    Cleanup
    FileUtils.rm_rf(root)
  end

  test "this checkout's VERSION is a series: the shipped templates and caller are tested against it" do
    Expect
    AiFlow::Series.of_tree(AI_FLOW_ROOT).major >= 1
  end

  test "a series is a value" do
    Expect
    assert_value_semantics(
      AiFlow::Series.new(major: 1),
      equal_to: AiFlow::Series.parse("1.9.9"),
      unequal_to: [AiFlow::Series.new(major: 2)],
    )
  end
end
