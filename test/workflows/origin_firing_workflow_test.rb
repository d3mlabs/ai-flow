# typed: true
# frozen_string_literal: true

require "test_helper"
require "yaml"

transform!(RSpock::AST::Transformation)
class OriginFiringWorkflowTest < Minitest::Test
  WORKFLOW_PATH = File.join(AI_FLOW_ROOT, ".github", "workflows", "origin-firing.yml")

  # App names are globally unique, so an adopter's App slug may differ from
  # ours — the login must be derived from the minted token's app-slug output,
  # exactly as ai-commands.yml derives it for the dispatcher.
  BOT_LOGIN_EXPRESSION = "${{ format('{0}[bot]', steps.app-token.outputs.app-slug || 'ai-flow') }}"

  test "the check step derives AI_FLOW_BOT_LOGIN from the App slug" do
    Given "the origin-firing workflow"
    workflow = YAML.safe_load(File.read(WORKFLOW_PATH))

    When "finding the step that runs the check entry point"
    step = workflow.fetch("jobs").fetch("origin-firing").fetch("steps")
                   .find { |candidate| candidate["run"].to_s.include?("origin_firing_check.rb") }

    Then "the bot-comment filter downstream receives the deployment's actual login"
    step.fetch("env", {})["AI_FLOW_BOT_LOGIN"] == BOT_LOGIN_EXPRESSION
  end
end
