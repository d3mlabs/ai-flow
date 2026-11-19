# typed: true
# frozen_string_literal: true

require "test_helper"

transform!(RSpock::AST::Transformation)
class AiFlow::HostPostureTest < Minitest::Test
  test "a workflow that reports no posture is read as converged (local runs, callers predating the check)" do
    Given "an env without the posture variable"
    env = { "RUNNER_NAME" => "mac1-agent" }

    When "reading the posture"
    posture = AiFlow::HostPosture.from_env(env)

    Then "the host is converged"
    posture.drifted? == false
  end

  test "the workflow's converged verdict is read as converged" do
    When "reading a converged verdict"
    posture = AiFlow::HostPosture.from_env("AI_FLOW_HOST_POSTURE" => "converged", "RUNNER_NAME" => "mac1-agent")

    Then "the host is converged"
    posture.drifted? == false
  end

  test "the workflow's drifted verdict names the runner the check ran on" do
    When "reading a drifted verdict"
    posture = AiFlow::HostPosture.from_env("AI_FLOW_HOST_POSTURE" => "drifted", "RUNNER_NAME" => "box-agent-2")

    Then "the host is drifted, on that runner"
    posture.drifted? == true
    posture.runner_name == "box-agent-2"
  end

  test "a verdict the workflow contract does not define is a broken caller, not a preference" do
    When "reading an unknown verdict"
    read = -> { AiFlow::HostPosture.from_env("AI_FLOW_HOST_POSTURE" => "failure", "RUNNER_NAME" => "mac1-agent") }

    Then "it fails closed, naming the variable"
    error = assert_raises(AiFlow::HostPosture::InvalidPostureError) { read.call }
    error.message.include?("AI_FLOW_HOST_POSTURE=failure")
  end

  test "a drifted verdict from a job that names no runner still reads as drifted" do
    When "reading a drifted verdict with no RUNNER_NAME"
    posture = AiFlow::HostPosture.from_env("AI_FLOW_HOST_POSTURE" => "drifted")

    Then "the runner is the unknown one"
    posture.drifted? == true
    posture.runner_name == AiFlow::HostPosture::UNKNOWN_RUNNER
  end
end
