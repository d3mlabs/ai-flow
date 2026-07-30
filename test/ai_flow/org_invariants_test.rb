# typed: true
# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class AiFlow::OrgInvariantsTest < Minitest::Test
  INDEX = <<~INDEX
    # Org learnings

    ## Invariants (always-on)

    - [design/single-responsibility] One reason to change per unit.
      → skills/single-responsibility/
    - [testing/test-hygiene] Real files in temp dirs, never mock the filesystem.
      → skills/test-hygiene/

    ## Knowledge (on-demand)

    - [ruby/typed-errors] Typed errors over strings.
  INDEX

  test "prompt_block carries the invariants section and nothing past it" do
    Given "a synced cache whose index has invariants and on-demand entries"
    dir = Dir.mktmpdir("ai-flow-invariants-")
    File.write(File.join(dir, "index.md"), INDEX)

    When "building the block"
    block = T.must(AiFlow::OrgInvariants.new(cache_dir: dir).prompt_block)

    Then "invariant lines are in, the on-demand section is cut off"
    block.include?("[design/single-responsibility]")
    block.include?("[testing/test-hygiene]")
    !block.include?("typed-errors")
    block.include?("ORG INVARIANTS")
    block.include?("~/.cursor/skills/")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an unconfigured machine (no cache) injects nothing" do
    Given "a cache dir that does not exist"
    dir = Dir.mktmpdir("ai-flow-invariants-")
    missing = File.join(dir, "never-cloned")

    When "building the block"
    block = AiFlow::OrgInvariants.new(cache_dir: missing).prompt_block

    Then
    block.nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an index without an invariants section injects nothing" do
    Given "a cache whose index has only on-demand entries"
    dir = Dir.mktmpdir("ai-flow-invariants-")
    File.write(File.join(dir, "index.md"), "# Org learnings\n\n## Knowledge (on-demand)\n\n- [ruby/typed-errors] x\n")

    When "building the block"
    block = AiFlow::OrgInvariants.new(cache_dir: dir).prompt_block

    Then
    block.nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an empty invariants section injects nothing" do
    Given "a cache whose invariants section has no entries yet"
    dir = Dir.mktmpdir("ai-flow-invariants-")
    File.write(File.join(dir, "index.md"), "## Invariants (always-on)\n\n## Knowledge (on-demand)\n")

    When "building the block"
    block = AiFlow::OrgInvariants.new(cache_dir: dir).prompt_block

    Then
    block.nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the default cache dir follows XDG_DATA_HOME, mirroring dev's cache" do
    Given "a temp data home carrying a synced cache at dev/knowledge"
    previous = ENV["XDG_DATA_HOME"]
    data_home = Dir.mktmpdir("ai-flow-data-home-")
    cache = File.join(data_home, "dev", "knowledge")
    FileUtils.mkdir_p(cache)
    File.write(File.join(cache, "index.md"), INDEX)
    ENV["XDG_DATA_HOME"] = data_home

    When "building the block without an explicit cache dir"
    block = T.must(AiFlow::OrgInvariants.new.prompt_block)

    Then
    block.include?("[design/single-responsibility]")

    Cleanup
    previous ? ENV["XDG_DATA_HOME"] = previous : ENV.delete("XDG_DATA_HOME")
    FileUtils.rm_rf(data_home)
  end
end
