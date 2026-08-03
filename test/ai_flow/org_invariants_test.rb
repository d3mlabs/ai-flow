# typed: true
# frozen_string_literal: true

require "test_helper"
require "support/fakes"

transform!(RSpock::AST::Transformation)
class AiFlow::OrgInvariantsTest < Minitest::Test
  INVARIANTS_BODY = <<~BODY.strip
    - [design/single-responsibility] One reason to change per unit.
      → skills/single-responsibility/
    - [testing/test-hygiene] Real files in temp dirs, never mock the filesystem.
      → skills/test-hygiene/
  BODY

  test "prompt_block wraps what dev learnings invariants prints" do
    Given "a dev CLI printing the Tier-0 block"
    executor = FakeInvariantsExecutor.new(stdout: "#{INVARIANTS_BODY}\n")

    When "building the block"
    block = T.must(AiFlow::OrgInvariants.new(executor: executor).prompt_block)

    Then "the body rides inside ai-flow's framing, fetched via the command seam"
    block.include?("[design/single-responsibility]")
    block.include?("[testing/test-hygiene]")
    block.include?("ORG INVARIANTS")
    block.include?("~/.cursor/skills/")
    executor.argvs == [["dev", "learnings", "invariants"]]

    Cleanup
    nil
  end

  test "a machine where the command reports unavailability injects nothing" do
    Given "a dev CLI declining — unconfigured, never synced, or no invariants section"
    executor = FakeInvariantsExecutor.new(stderr: "dev: no knowledge repo configured", ok: false)

    When "building the block"
    block = AiFlow::OrgInvariants.new(executor: executor).prompt_block

    Then
    block.nil?

    Cleanup
    nil
  end

  test "a blank success injects nothing" do
    Given "a dev CLI printing only whitespace"
    executor = FakeInvariantsExecutor.new(stdout: "\n")

    When "building the block"
    block = AiFlow::OrgInvariants.new(executor: executor).prompt_block

    Then
    block.nil?

    Cleanup
    nil
  end
end
