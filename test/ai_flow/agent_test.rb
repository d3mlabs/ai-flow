# typed: true
# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"

# Captures every stream() argv so tests assert on the exact agent CLI
# invocation; replays a canned NDJSON stream (default: one terminal result
# event) line by line, like the real CLI in stream-json mode. Subclasses the
# real class so sorbet-runtime's sig checks accept it at the injection seam.
class RecordingExecutor < AiFlow::Executor
  DEFAULT_STREAM = [%({"type":"result","subtype":"success","is_error":false,"result":"ok"})].freeze

  attr_reader :captures, :envs, :isolates

  def initialize(lines: DEFAULT_STREAM, err: "", ok: true)
    @envs = []
    @lines = lines
    @err = err
    @ok = ok
    @captures = []
    @isolates = []
  end

  def stream(*argv, stdin: nil, chdir: nil, env: {}, isolate: false)
    @captures << argv
    @envs << env
    @isolates << isolate
    @lines.each { |line| yield "#{line}\n" }
    [@err, @ok]
  end
end unless defined?(RecordingExecutor)

# Reports an isolation posture without real sudo or env, so the launch's
# spawn-user log line is observable.
class IsolationReportingExecutor < RecordingExecutor
  def isolation
    AiFlow::AgentIsolation.new(user: "ai-agent", group: "ai", home: "/tmp")
  end
end unless defined?(IsolationReportingExecutor)

# Overrides the agent's auth overlay with a recognizable marker, so the
# launch's env plumbing is observable without real minting.
class ReadOnlyRecordingExecutor < RecordingExecutor
  def agent_auth_env
    { "GH_TOKEN" => "read-only-marker" }
  end
end unless defined?(ReadOnlyRecordingExecutor)

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

  test "no repo config: no --model flag (CLI account default)" do
    Given "a workdir without .github/ai-flow.yml"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = RecordingExecutor.new

    When "launching"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

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
    AiFlow::Agent.new(executor: build_executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Build.new)
    AiFlow::Agent.new(executor: ask_executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

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
    AiFlow::Agent.new(executor: build_executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Build.new)
    AiFlow::Agent.new(executor: ask_executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

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
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Build.new)

    Then "the blank command link falls through to the default"
    model_flag(executor) == "gpt-5"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a blank default falls through to the CLI account default" do
    Given "a config whose only value is a blank default"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models:\n  default: \"\"\n")
    executor = RecordingExecutor.new

    When "launching /ask"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

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
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Build.new)

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
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

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
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then
    raises AiFlow::RepoConfig::Error

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "models_used records every launch's resolved model, grouped per command" do
    Given "a config with a default model and two launches of the same command"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models:\n  default: gpt-5\n")
    executor = RecordingExecutor.new
    agent = AiFlow::Agent.new(executor: executor)

    When "launching /ask twice and /build once"
    agent.launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)
    agent.launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)
    agent.launch(prompt: "p", workdir: dir, command: AiFlow::Command::Build.new)

    Then
    agent.models_used == {
      AiFlow::Command::Ask.new => [AiFlow::ModelSelection::Named.new("gpt-5")] * 2,
      AiFlow::Command::Build.new => [AiFlow::ModelSelection::Named.new("gpt-5")],
    }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a later launch under the same command never erases an earlier selection (#49)" do
    Given "a configured source checkout and a bare clone, both launched under /learn"
    source = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(source, "models:\n  default: gpt-5\n")
    clone = Dir.mktmpdir("ai-flow-agent-test-")
    agent = AiFlow::Agent.new(executor: RecordingExecutor.new)

    When "launching in the source, then in the unconfigured clone"
    agent.launch(prompt: "p", workdir: source, command: AiFlow::Command::Learn.new)
    agent.launch(prompt: "p", workdir: clone, command: AiFlow::Command::Learn.new)

    Then "both selections survive, in launch order"
    agent.models_used == {
      AiFlow::Command::Learn.new => [
        AiFlow::ModelSelection::Named.new("gpt-5"),
        AiFlow::ModelSelection::AccountDefault.new,
      ],
    }

    Cleanup
    FileUtils.rm_rf(source)
    FileUtils.rm_rf(clone)
  end

  test "models_used records AccountDefault when no policy resolved" do
    Given "a workdir without a config file"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = RecordingExecutor.new
    agent = AiFlow::Agent.new(executor: executor)

    When "launching /ask"
    agent.launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then
    agent.models_used == { AiFlow::Command::Ask.new => [AiFlow::ModelSelection::AccountDefault.new] }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "policy_root resolves the model from the source checkout, not the execution workdir (#49)" do
    Given "a configured source checkout and a bare clone to execute in"
    source = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(source, "models:\n  default: gpt-5\n")
    clone = Dir.mktmpdir("ai-flow-agent-test-")
    executor = RecordingExecutor.new

    When "launching in the clone under the source's policy"
    AiFlow::Agent.new(executor: executor)
      .launch(prompt: "p", workdir: clone, command: AiFlow::Command::Learn.new, policy_root: source)

    Then "the launch carries the source's model"
    model_flag(executor) == "gpt-5"

    Cleanup
    FileUtils.rm_rf(source)
    FileUtils.rm_rf(clone)
  end

  test "a models section that is not a mapping is treated as empty" do
    Given "a config where models is a scalar (user's file, unknown shapes ignored)"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models: everything-on-default\n")
    executor = RecordingExecutor.new

    When "launching /ask"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

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
    answer = AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

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
    answer = AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

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
    answer = AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then
    answer == "ok"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # Swap $stdout for a StringIO around the launch — the progress lines are
  # the observable behavior here, and the agent writes them directly.
  def capture_agent_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  test "skill and rule reads render as knowledge lines and accumulate deduped" do
    Given "a stream reading a skill twice, a rules file, and a plain file"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    skill_read = %({"type":"tool_call","subtype":"started","tool_call":) +
      %({"readToolCall":{"args":{"path":"/Users/ci/.cursor/skills/typed-errors/SKILL.md"}}}})
    executor = RecordingExecutor.new(lines: [
      skill_read,
      skill_read,
      %({"type":"tool_call","subtype":"started","tool_call":{"readToolCall":{"args":{"path":".cursor/rules/learnings-index.mdc"}}}}),
      %({"type":"tool_call","subtype":"started","tool_call":{"readToolCall":{"args":{"path":"lib/thing.rb"}}}}),
      %({"type":"result","subtype":"success","is_error":false,"result":"ok"}),
    ])
    agent = AiFlow::Agent.new(executor: executor)

    When "launching and capturing the progress lines"
    output = capture_agent_stdout { agent.launch(prompt: "p", workdir: dir, command: AiFlow::Command::Build.new) }

    Then "knowledge reads get their own line, plain reads stay generic, and the accumulator dedupes"
    output.include?("[/build] knowledge: typed-errors")
    output.include?("[/build] knowledge: learnings-index")
    output.include?("[/build] → read: lib/thing.rb")
    !output.include?("→ read: /Users/ci/.cursor/skills")
    agent.knowledge_applied == ["typed-errors", "learnings-index"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "non-read tool calls under knowledge-looking args stay generic" do
    Given "a shell command that merely mentions a skill path"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = RecordingExecutor.new(lines: [
      %({"type":"tool_call","subtype":"started","tool_call":{"shellToolCall":{"args":{"command":"ls ~/.cursor/skills/typed-errors/"}}}}),
      %({"type":"result","subtype":"success","is_error":false,"result":"ok"}),
    ])
    agent = AiFlow::Agent.new(executor: executor)

    When "launching"
    output = capture_agent_stdout { agent.launch(prompt: "p", workdir: dir, command: AiFlow::Command::Build.new) }

    Then "no knowledge line, nothing accumulated"
    output.include?("[/build] → shell: ls ~/.cursor/skills/typed-errors/")
    agent.knowledge_applied.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # The agent's spawn-env hygiene (ai-flow#38) is Executor's job now (#46):
  # every spawn gets HarnessEnv.scrub at the seam, asserted with real
  # subprocesses in executor_test.

  test "the launch spawns the agent under the read-only auth overlay (plans#25)" do
    Given "an executor whose agent overlay is a recognizable marker"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = ReadOnlyRecordingExecutor.new

    When "launching"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then "the spawn env carries the agent overlay, not the dispatcher's default"
    executor.envs.fetch(0) == { "GH_TOKEN" => "read-only-marker" }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failed run raises" do
    Given "a failing executor with stderr"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = RecordingExecutor.new(lines: [], err: "boom from the CLI", ok: false)

    When "launching"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then
    raises AiFlow::Agent::Error

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "launch streams the agent through the isolation seam" do
    Given "an agent over a recording executor"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = RecordingExecutor.new

    When "launching"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then "the one stream call asked for isolation (a no-op when it is off)"
    executor.isolates == [true]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the spawn posture line names the agent user when isolated, the dispatcher otherwise" do
    Given "one executor reporting an isolation and one bare"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    isolated = IsolationReportingExecutor.new
    bare = RecordingExecutor.new

    When "launching under both"
    isolated_out, = capture_io do
      AiFlow::Agent.new(executor: isolated).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)
    end
    bare_out, = capture_io do
      AiFlow::Agent.new(executor: bare).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)
    end

    Then "the run log states who executed the pass"
    isolated_out.include?("ai-flow agent spawn (/ask): user=ai-agent (plans#26)")
    bare_out.include?("ai-flow agent spawn (/ask): user=(dispatcher)")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a silent failure points at the streamed log" do
    Given "a failing executor with no stderr and an empty stream"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = RecordingExecutor.new(lines: [], err: "", ok: false)

    When "launching and capturing the failure"
    error = begin
      AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)
      nil
    rescue AiFlow::Agent::Error => e
      e
    end

    Then
    T.must(error).message.include?("see the streamed agent log above")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
