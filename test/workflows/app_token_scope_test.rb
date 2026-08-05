# typed: true
# frozen_string_literal: true

require "test_helper"
require "yaml"

transform!(RSpock::AST::Transformation)
class AppTokenScopeTest < Minitest::Test
  WORKFLOWS_DIR = File.join(AI_FLOW_ROOT, ".github", "workflows")

  # Every workflow-level App-token mint must carry a repositories: scope
  # (plans#25): the App key can reach the whole installation, so any mint
  # without an explicit repo list hands a job an org-wide token. The
  # dispatcher's own cross-repo reach comes from in-process minting
  # (TokenProvider), never from these job tokens.
  test "every App-token mint in the shipped workflows is repository-scoped" do
    Given "all mint steps across the shipped workflows"
    mint_steps = Dir.glob(File.join(WORKFLOWS_DIR, "*.yml")).flat_map do |path|
      YAML.safe_load(File.read(path)).fetch("jobs").flat_map do |_name, job|
        job.fetch("steps", []).select { |step| step["uses"].to_s.include?("create-github-app-token") }
      end
    end

    When "reading each step's scope"
    unscoped = mint_steps.reject { |step| step.fetch("with", {}).key?("repositories") }

    Then "there is something to check, and nothing mints installation-wide"
    !mint_steps.empty?
    unscoped.empty?
  end
end
