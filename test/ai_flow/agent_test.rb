# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "json"

# Captures every capture() argv so tests assert on the exact agent CLI
# invocation; replies with a canned success envelope.
class RecordingExecutor
  attr_reader :captures

  def initialize
    @captures = []
  end

  def capture(*argv, stdin: nil, chdir: nil, env: {})
    @captures << argv
    [JSON.generate({ "result" => "ok" }), "", true]
  end
end unless defined?(RecordingExecutor)

transform!(RSpock::AST::Transformation)
class AiFlow::AgentTest < Minitest::Test
  def write_config(dir, content)
    FileUtils.mkdir_p(File.join(dir, ".github"))
    File.write(File.join(dir, ".github", "ai-flow.yml"), content)
  end

  def model_flag(executor)
    argv = executor.captures.fetch(0)
    index = argv.index("--model")
    index && argv.fetch(index + 1)
  end

  test "no repo config and nil MODELS: no --model flag (CLI account default)" do
    Given "a workdir without .github/ai-flow.yml"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = RecordingExecutor.new

    When "launching"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: "ask")

    Then
    model_flag(executor).nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a per-command model applies to that command only" do
    Given "a config with a build model and nothing else"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models:\n  build: opus\n")
    build_executor = RecordingExecutor.new
    ask_executor = RecordingExecutor.new

    When "launching /build and /ask"
    AiFlow::Agent.new(executor: build_executor).launch(prompt: "p", workdir: dir, command: "build")
    AiFlow::Agent.new(executor: ask_executor).launch(prompt: "p", workdir: dir, command: "ask")

    Then "/build carries the model and /ask stays on the CLI default"
    model_flag(build_executor) == "opus"
    model_flag(ask_executor).nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the command key wins over the default blanket" do
    Given "a config with default and build models"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models:\n  default: gpt-5\n  build: opus\n")
    build_executor = RecordingExecutor.new
    ask_executor = RecordingExecutor.new

    When "launching /build and /ask"
    AiFlow::Agent.new(executor: build_executor).launch(prompt: "p", workdir: dir, command: "build")
    AiFlow::Agent.new(executor: ask_executor).launch(prompt: "p", workdir: dir, command: "ask")

    Then
    model_flag(build_executor) == "opus"
    model_flag(ask_executor) == "gpt-5"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "blank links fall through and never produce --model ''" do
    Given "a config where the command model is blank and default is set"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models:\n  default: gpt-5\n  build: \"\"\n")
    executor = RecordingExecutor.new

    When "launching /build"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: "build")

    Then "the blank command link falls through to the default"
    model_flag(executor) == "gpt-5"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a blank default falls through to the code fallback (nil today)" do
    Given "a config whose only value is a blank default"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models:\n  default: \"\"\n")
    executor = RecordingExecutor.new

    When "launching /ask"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: "ask")

    Then
    model_flag(executor).nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "AI_FLOW_MODEL env is the ops escape hatch and wins over the file" do
    Given "a config with models and a runner-level env override"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models:\n  default: gpt-5\n  build: opus\n")
    ENV["AI_FLOW_MODEL"] = "env-model"
    executor = RecordingExecutor.new

    When "launching /build"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: "build")

    Then
    model_flag(executor) == "env-model"

    Cleanup
    ENV.delete("AI_FLOW_MODEL")
    FileUtils.rm_rf(dir)
  end

  test "invalid YAML in the repo config fails loudly, naming the file" do
    Given "an unparseable .github/ai-flow.yml"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models: [unclosed\n")
    executor = RecordingExecutor.new

    When "launching"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: "ask")

    Then
    raises AiFlow::RepoConfig::Error

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a non-mapping config file fails loudly" do
    Given "a config file that is a YAML list"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "- not\n- a\n- mapping\n")
    executor = RecordingExecutor.new

    When "launching"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: "ask")

    Then
    raises AiFlow::RepoConfig::Error

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a models section that is not a mapping is treated as empty" do
    Given "a config where models is a scalar (user's file, unknown shapes ignored)"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models: everything-on-default\n")
    executor = RecordingExecutor.new

    When "launching /ask"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: "ask")

    Then
    model_flag(executor).nil?

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
