# frozen_string_literal: true

require "test_helper"

transform!(RSpock::AST::Transformation)
class AiFlow::PlanBodyTest < Minitest::Test
  BODY = <<~BODY
    # Carve system

    The carve system uses **LOD0 only** for runtime operations.

    ## Streaming

    Chunks stream in `64m` cells around the player.

    ## Persistence

    Carves persist as deltas against the base terrain.
  BODY

  test "from_issue_body normalizes CRLF and trailing whitespace" do
    Expect
    AiFlow::PlanBody.from_issue_body("# T\r\n\r\ncontent\r\n") == "# T\n\ncontent\n"
    AiFlow::PlanBody.from_issue_body("# T\n\ncontent\n\n\n") == "# T\n\ncontent\n"
    AiFlow::PlanBody.from_issue_body(nil) == "\n"

    Cleanup
    nil
  end

  test "an exact quote resolves to its paragraph" do
    Expect
    AiFlow::PlanBody.locate_quote(BODY, "Carves persist as deltas against the base terrain.") ==
      "Carves persist as deltas against the base terrain."

    Cleanup
    nil
  end

  test "a rendered quote (markdown stripped) still resolves" do
    Given "a quote as GitHub renders it — no ** or backticks"
    quote = "The carve system uses LOD0 only for runtime operations."

    Expect "normalized matching finds the source paragraph"
    AiFlow::PlanBody.locate_quote(BODY, quote) ==
      "The carve system uses **LOD0 only** for runtime operations."

    Cleanup
    nil
  end

  test "a multi-paragraph quote resolves to the minimal spanning region" do
    Given "a quote covering the Streaming heading and its paragraph"
    quote = "Streaming\nChunks stream in 64m cells around the player."

    Expect
    AiFlow::PlanBody.locate_quote(BODY, quote) ==
      "## Streaming\n\nChunks stream in `64m` cells around the player."

    Cleanup
    nil
  end

  test "a stale quote returns nil" do
    Expect
    AiFlow::PlanBody.locate_quote(BODY, "This sentence was edited away.").nil?

    Cleanup
    nil
  end
end
