# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "json"

# Captures every stream() argv so tests assert on the exact agent CLI
# invocation; replays a canned NDJSON stream (default: one terminal result
# event) line by line, like the real CLI in stream-json mode.
class RecordingExecutor
  DEFAULT_STREAM = [%({"type":"result","subtype":"success","is_error":false,"result":"ok"})].freeze

  attr_reader :captures

  def initialize(lines: DEFAULT_STREAM, err: "", ok: true)
    @lines = lines
    @err = err
    @ok = ok
    @captures = []
  end

  def stream(*argv, stdin: nil, chdir: nil)
    @captures << argv
    @lines.each { |line| yield "#{line}\n" }
    [@err, @ok]
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

  test "models_used records the resolved model per command, once per command" do
    Given "a config with a default model and two launches of the same command"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models:\n  default: gpt-5\n")
    executor = RecordingExecutor.new
    agent = AiFlow::Agent.new(executor: executor)

    When "launching /ask twice and /build once"
    agent.launch(prompt: "p", workdir: dir, command: "ask")
    agent.launch(prompt: "p", workdir: dir, command: "ask")
    agent.launch(prompt: "p", workdir: dir, command: "build")

    Then
    agent.models_used == { "ask" => "gpt-5", "build" => "gpt-5" }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "models_used records 'cursor default' when no policy resolved" do
    Given "a workdir without a config file"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = RecordingExecutor.new
    agent = AiFlow::Agent.new(executor: executor)

    When "launching /ask"
    agent.launch(prompt: "p", workdir: dir, command: "ask")

    Then
    agent.models_used == { "ask" => "cursor default" }

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

  test "the CLI runs in stream-json mode and the terminal result event is the answer" do
    Given "a stream with assistant chatter, a tool call, and a result event"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = RecordingExecutor.new(lines: [
      %({"type":"system","subtype":"init","model":"Fable 5 High","session_id":"s"}),
      %({"type":"tool_call","subtype":"started","tool_call":{"shellToolCall":{"args":{"command":"rake test"}}}}),
      %({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Working on it."}]}}),
      %({"type":"result","subtype":"success","is_error":false,"result":"THE ANSWER"}),
    ])

    When "launching"
    answer = AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: "ask")

    Then "the result event wins and the argv asked for the streaming format"
    answer == "THE ANSWER"
    executor.captures.fetch(0).each_cons(2).include?(["--output-format", "stream-json"])

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a stream that ends without a result event falls back to the assistant text" do
    Given "a truncated stream (two assistant messages, no terminal event) that still exits 0"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = RecordingExecutor.new(lines: [
      %({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"First."}]}}),
      %({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Second."}]}}),
    ])

    When "launching"
    answer = AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: "ask")

    Then
    answer == "First.\n\nSecond."

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "non-JSON junk and unknown event types degrade to noise, never a crash" do
    Given "a stream with a raw line, an unknown event type, and a result"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = RecordingExecutor.new(lines: [
      "some non-json narration",
      %({"type":"connection","subtype":"reconnecting"}),
      %({"type":"result","subtype":"success","is_error":false,"result":"ok"}),
    ])

    When "launching"
    answer = AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: "ask")

    Then
    answer == "ok"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failed run raises" do
    Given "a failing executor with stderr"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = RecordingExecutor.new(lines: [], err: "boom from the CLI", ok: false)

    When "launching"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: "ask")

    Then
    raises AiFlow::Agent::Error

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a silent failure points at the streamed log" do
    Given "a failing executor with no stderr and an empty stream"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = RecordingExecutor.new(lines: [], err: "", ok: false)

    When "launching and capturing the failure"
    error = begin
      AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: "ask")
      nil
    rescue AiFlow::Agent::Error => e
      e
    end

    Then
    error.message.include?("see the streamed agent log above")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
