# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "support/value_semantics_assertions"

transform!(RSpock::AST::Transformation)
class AiFlow::Adoption::ReusableWorkflowRefTest < Minitest::Test
  include ValueSemanticsAssertions

  USES = "d3mlabs/ai-flow/.github/workflows/ai-commands.yml@v1"

  test "a uses: value parses into the workflow's repository, path and ref, and prints back the same" do
    When
    ref = AiFlow::Adoption::ReusableWorkflowRef.parse(USES)

    Then
    ref.repository == "d3mlabs/ai-flow"
    ref.path == ".github/workflows/ai-commands.yml"
    ref.ref == "v1"
    ref.to_s == USES
  end

  test "text that is not owner/repo/path@ref is refused: #{text.inspect}" do
    When
    AiFlow::Adoption::ReusableWorkflowRef.parse(text)

    Then
    raises AiFlow::Adoption::ReusableWorkflowRef::InvalidReferenceError

    Where
    text
    "./.github/workflows/local.yml"
    "d3mlabs/ai-flow@v1"
    "d3mlabs/ai-flow/.github/workflows/ai-commands.yml"
    "d3mlabs/ai-flow/.github/workflows/ai-commands.yml@"
  end

  test "the same workflow at another ref is the same workflow; another repo's or file is not" do
    Given
    ref = AiFlow::Adoption::ReusableWorkflowRef.parse(USES)

    Expect
    ref.at("main") == AiFlow::Adoption::ReusableWorkflowRef.parse("d3mlabs/ai-flow/.github/workflows/ai-commands.yml@main")
    ref.same_workflow?(ref.at("main"))
    !ref.same_workflow?(AiFlow::Adoption::ReusableWorkflowRef.parse("acme/ai-flow/.github/workflows/ai-commands.yml@v1"))
    !ref.same_workflow?(AiFlow::Adoption::ReusableWorkflowRef.parse("d3mlabs/ai-flow/.github/workflows/origin-firing.yml@v1"))
  end

  test "a reference is a value" do
    Expect
    assert_value_semantics(
      AiFlow::Adoption::ReusableWorkflowRef.parse(USES),
      equal_to: AiFlow::Adoption::ReusableWorkflowRef.parse(USES),
      unequal_to: [AiFlow::Adoption::ReusableWorkflowRef.parse(USES).at("v2")],
    )
  end
end
