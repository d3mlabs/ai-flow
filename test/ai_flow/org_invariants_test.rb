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

  test "a machine where the command reports unavailability injects nothing, and says so on stderr" do
    Given "a dev CLI declining — unconfigured, never synced, or crashing under a leaked env (#44)"
    executor = FakeInvariantsExecutor.new(stderr: "cannot load such file -- cli/ui", ok: false)
    invariants = AiFlow::OrgInvariants.new(executor: executor)

    When "building the block"
    block = T.let(nil, T.nilable(String))
    _out, err = capture_io { block = invariants.prompt_block }

    Then "nothing injected, but the run log names the declining command and its error"
    block.nil?
    err.include?("dev learnings invariants")
    err.include?("cannot load such file -- cli/ui")

    Cleanup
    nil
  end

  test "the dev child gets the harness scrub, never the dispatcher's bundler env" do
    Given "a planted harness toolchain env"
    saved = ENV["RBENV_VERSION"]
    ENV["RBENV_VERSION"] = "3.3.10"
    executor = FakeInvariantsExecutor.new(stdout: "#{INVARIANTS_BODY}\n")

    When "building the block"
    AiFlow::OrgInvariants.new(executor: executor).prompt_block

    Then "the capture env unsets the toolchain key instead of inheriting it"
    executor.envs.fetch(0).fetch("RBENV_VERSION", :missing).nil?

    Cleanup
    saved.nil? ? ENV.delete("RBENV_VERSION") : ENV["RBENV_VERSION"] = saved
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
