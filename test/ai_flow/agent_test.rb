# typed: true
# frozen_string_literal: true

require "test_helper"
require "support/acp"
require "tmpdir"
require "fileutils"
require "stringio"

# Reports an isolation posture without real sudo or env, so the launch's
# spawn-user log line and the prompt contract are observable.
class IsolationReportingAcpExecutor < AcpFakeExecutor
  def isolation
    AiFlow::AgentIsolation.new(user: "ai-agent", group: "ai", home: "/tmp")
  end
end unless defined?(IsolationReportingAcpExecutor)

# Overrides the agent's auth overlay with a recognizable marker, so the
# launch's env plumbing is observable without real minting.
class ReadOnlyAcpExecutor < AcpFakeExecutor
  def agent_auth_env
    { "GH_TOKEN" => "read-only-marker" }
  end
end unless defined?(ReadOnlyAcpExecutor)

# The transport-failure double: duplex fails before the conversation ever
# starts (the popen3 ENOENT path), so the block never runs.
class EnoentAcpExecutor < AcpFakeExecutor
  def duplex(*argv, chdir: nil, env: {}, isolate: false, reap_timeout: 10)
    ["No such file or directory - agent", false]
  end
end unless defined?(EnoentAcpExecutor)

transform!(RSpock::AST::Transformation)
class AiFlow::AgentTest < Minitest::Test
  def write_config(dir, content)
    FileUtils.mkdir_p(File.join(dir, ".github"))
    File.write(File.join(dir, ".github", "ai-flow.yml"), content)
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

  test "no repo config: no session/set_model (CLI account default)" do
    Given "a workdir without .github/ai-flow.yml"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = AcpFakeExecutor.new

    When "launching"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then "the session rides the account default"
    !executor.server.requests.include?("session/set_model")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a per-command model applies to that command only" do
    Given "a config with a build model and nothing else"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models:\n  build: opus\n")
    build_executor = AcpFakeExecutor.new
    ask_executor = AcpFakeExecutor.new

    When "launching /build and /ask"
    AiFlow::Agent.new(executor: build_executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Build.new)
    AiFlow::Agent.new(executor: ask_executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then "/build selects the model through the catalog and /ask stays on the CLI default"
    build_executor.server.set_model_ids == ["opus[test]"]
    ask_executor.server.set_model_ids.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the command key wins over the default blanket" do
    Given "a config with default and build models"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models:\n  default: gpt-5\n  build: opus\n")
    build_executor = AcpFakeExecutor.new
    ask_executor = AcpFakeExecutor.new

    When "launching /build and /ask"
    AiFlow::Agent.new(executor: build_executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Build.new)
    AiFlow::Agent.new(executor: ask_executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then
    build_executor.server.set_model_ids == ["opus[test]"]
    ask_executor.server.set_model_ids == ["gpt-5[test]"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "blank links fall through and never select a blank model" do
    Given "a config where the command model is blank and default is set"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models:\n  default: gpt-5\n  build: \"\"\n")
    executor = AcpFakeExecutor.new

    When "launching /build"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Build.new)

    Then "the blank command link falls through to the default"
    executor.server.set_model_ids == ["gpt-5[test]"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a blank default falls through to the CLI account default" do
    Given "a config whose only value is a blank default"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models:\n  default: \"\"\n")
    executor = AcpFakeExecutor.new

    When "launching /ask"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then
    executor.server.set_model_ids.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "AI_FLOW_MODEL env is the ops escape hatch and wins over the file" do
    Given "a config with models and a runner-level env override"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models:\n  default: gpt-5\n  build: opus\n")
    ENV["AI_FLOW_MODEL"] = "env-model"
    executor = AcpFakeExecutor.new

    When "launching /build"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Build.new)

    Then
    executor.server.set_model_ids == ["env-model[test]"]

    Cleanup
    ENV.delete("AI_FLOW_MODEL")
    FileUtils.rm_rf(dir)
  end

  test "invalid YAML in the repo config fails loudly, naming the file" do
    Given "an unparseable .github/ai-flow.yml"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models: [unclosed\n")
    executor = AcpFakeExecutor.new

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
    executor = AcpFakeExecutor.new

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
    executor = AcpFakeExecutor.new
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
    agent = AiFlow::Agent.new(executor: AcpFakeExecutor.new)

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
    executor = AcpFakeExecutor.new
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
    executor = AcpFakeExecutor.new

    When "launching in the clone under the source's policy"
    AiFlow::Agent.new(executor: executor)
      .launch(prompt: "p", workdir: clone, command: AiFlow::Command::Learn.new, policy_root: source)

    Then "the launch carries the source's model and the session opens in the clone"
    executor.server.set_model_ids == ["gpt-5[test]"]
    executor.chdirs == [clone]

    Cleanup
    FileUtils.rm_rf(source)
    FileUtils.rm_rf(clone)
  end

  test "a models section that is not a mapping is treated as empty" do
    Given "a config where models is a scalar (user's file, unknown shapes ignored)"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    write_config(dir, "models: everything-on-default\n")
    executor = AcpFakeExecutor.new

    When "launching /ask"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then
    executor.server.set_model_ids.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the launch speaks ACP and the message chunks are the answer" do
    Given "a server scripted with an answer"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = AcpFakeExecutor.new(server: FakeAcpServer.new(result_text: "THE ANSWER"))

    When "launching"
    answer = AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then "the accumulated chunks are the answer and the argv is the ACP subcommand"
    answer == "THE ANSWER"
    executor.captures == [["agent", "acp"]]
    executor.server.prompt_texts == ["p"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "message chunks concatenate in stream order" do
    Given "a server streaming the answer in two chunks"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    server = FakeAcpServer.new(updates: [
      { "sessionUpdate" => "agent_message_chunk", "content" => { "type" => "text", "text" => "First. " } },
      { "sessionUpdate" => "agent_message_chunk", "content" => { "type" => "text", "text" => "Second." } },
    ])
    executor = AcpFakeExecutor.new(server: server)

    When "launching"
    answer = AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then
    answer == "First. Second."

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "unknown update kinds degrade to nothing, never a crash" do
    Given "a stream with an unrecognized update kind"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    server = FakeAcpServer.new(updates: [
      { "sessionUpdate" => "something_new", "payload" => { "x" => 1 } },
      { "sessionUpdate" => "agent_message_chunk", "content" => { "type" => "text", "text" => "ok" } },
    ])
    executor = AcpFakeExecutor.new(server: server)

    When "launching"
    answer = AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then
    answer == "ok"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "skill and rule reads render as knowledge lines and accumulate deduped" do
    Given "a stream reading a skill twice, a rules file, and a plain file"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    skill_read = {
      "sessionUpdate" => "tool_call", "kind" => "read", "title" => "Read SKILL.md",
      "locations" => [{ "path" => "/Users/ci/.cursor/skills/typed-errors/SKILL.md" }],
    }
    server = FakeAcpServer.new(updates: [
      skill_read,
      skill_read,
      { "sessionUpdate" => "tool_call", "kind" => "read", "title" => "Read learnings-index.mdc",
        "locations" => [{ "path" => ".cursor/rules/learnings-index.mdc" }] },
      { "sessionUpdate" => "tool_call", "kind" => "read", "title" => "Read thing.rb",
        "locations" => [{ "path" => "lib/thing.rb" }] },
    ])
    executor = AcpFakeExecutor.new(server: server)
    agent = AiFlow::Agent.new(executor: executor)

    When "launching and capturing the progress lines"
    output = capture_agent_stdout { agent.launch(prompt: "p", workdir: dir, command: AiFlow::Command::Build.new) }

    Then "knowledge reads get their own line, plain reads stay generic, and the accumulator dedupes"
    output.include?("[/build] knowledge: typed-errors")
    output.include?("[/build] knowledge: learnings-index")
    output.include?("[/build] → Read thing.rb")
    agent.knowledge_applied == ["typed-errors", "learnings-index"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "non-read tool calls under knowledge-looking paths stay generic" do
    Given "a shell command that merely mentions a skill path"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    server = FakeAcpServer.new(updates: [
      { "sessionUpdate" => "tool_call", "kind" => "execute",
        "title" => "$ ls ~/.cursor/skills/typed-errors/",
        "rawInput" => { "path" => "~/.cursor/skills/typed-errors/" } },
    ])
    executor = AcpFakeExecutor.new(server: server)
    agent = AiFlow::Agent.new(executor: executor)

    When "launching"
    output = capture_agent_stdout { agent.launch(prompt: "p", workdir: dir, command: AiFlow::Command::Build.new) }

    Then "no knowledge line, nothing accumulated"
    output.include?("[/build] → $ ls ~/.cursor/skills/typed-errors/")
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
    executor = ReadOnlyAcpExecutor.new

    When "launching"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then "the spawn env carries the agent overlay, not the dispatcher's default"
    executor.envs.fetch(0) == { "GH_TOKEN" => "read-only-marker" }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a turn that stops on anything but end_turn raises" do
    Given "a server whose turn ends in refusal"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = AcpFakeExecutor.new(server: FakeAcpServer.new(stop_reason: "refusal"))

    When "launching"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then
    raises AiFlow::Agent::Error

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a missing agent CLI raises the install pointer" do
    Given "an executor that fails the spawn with ENOENT"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = EnoentAcpExecutor.new

    When "launching and capturing the failure"
    error = begin
      AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)
      nil
    rescue AiFlow::Agent::Error => e
      e
    end

    Then
    T.must(error).message.include?("agent CLI not found")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "launch runs the agent through the isolation seam" do
    Given "an agent over the fake ACP executor"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = AcpFakeExecutor.new

    When "launching"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then "the one duplex call asked for isolation (a no-op when it is off)"
    executor.isolates == [true]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the spawn posture line names the agent user when isolated, the dispatcher otherwise" do
    Given "one executor reporting an isolation and one bare"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    isolated = IsolationReportingAcpExecutor.new
    bare = AcpFakeExecutor.new

    When "launching under both"
    isolated_out = capture_agent_stdout do
      AiFlow::Agent.new(executor: isolated).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)
    end
    bare_out = capture_agent_stdout do
      AiFlow::Agent.new(executor: bare).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)
    end

    Then "the run log states who executed the pass"
    isolated_out.include?("ai-flow agent spawn (/ask): user=ai-agent (plans#26) transport=acp")
    bare_out.include?("ai-flow agent spawn (/ask): user=(dispatcher) transport=acp")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a silent failure points at the streamed log" do
    Given "a cancelled turn with no text and no stderr"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = AcpFakeExecutor.new(server: FakeAcpServer.new(result_text: "", stop_reason: "cancelled"))

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

  # ---- permission policy (plans#33, decision 2) ----

  test "a force launch answers allow to a mutating permission request" do
    Given "a server that asks permission for an execute tool"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    server = FakeAcpServer.new(permission_requests: [
      { "toolCall" => { "title" => "$ rake test", "kind" => "execute" },
        "options" => FakeAcpServer::DEFAULT_PERMISSION_OPTIONS },
    ])
    executor = AcpFakeExecutor.new(server: server)

    When "launching with force"
    AiFlow::Agent.new(executor: executor)
      .launch(prompt: "p", workdir: dir, command: AiFlow::Command::Edit.new, force: true)

    Then "the boundary is the OS user, not the tool gate"
    server.permission_answers == ["allow-once"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a non-force launch rejects mutating kinds and allows reads" do
    Given "a server asking for an execute and a read"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    server = FakeAcpServer.new(permission_requests: [
      { "toolCall" => { "title" => "$ rm -rf build", "kind" => "execute" },
        "options" => FakeAcpServer::DEFAULT_PERMISSION_OPTIONS },
      { "toolCall" => { "title" => "Read secrets.yml", "kind" => "read" },
        "options" => FakeAcpServer::DEFAULT_PERMISSION_OPTIONS },
    ])
    executor = AcpFakeExecutor.new(server: server)

    When "launching without force"
    AiFlow::Agent.new(executor: executor).launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then
    server.permission_answers == ["reject-once", "allow-once"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  # ---- denial surfacing (plans#33) ----

  test "an isolated launch appends the WANTED contract to the prompt" do
    Given "an isolation-reporting executor"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = IsolationReportingAcpExecutor.new

    When "launching"
    AiFlow::Agent.new(executor: executor).launch(prompt: "do the task", workdir: dir, command: AiFlow::Command::Ask.new)

    Then "the session prompt carries the task and the contract"
    T.must(executor.server.prompt_texts.fetch(0)).start_with?("do the task")
    T.must(executor.server.prompt_texts.fetch(0)).include?("WANTED: <path or capability>")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a non-isolated launch sends the prompt untouched" do
    Given "a plain executor (no isolation)"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = AcpFakeExecutor.new

    When "launching"
    AiFlow::Agent.new(executor: executor).launch(prompt: "do the task", workdir: dir, command: AiFlow::Command::Ask.new)

    Then "the prompt is exactly the caller's"
    executor.server.prompt_texts == ["do the task"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "WANTED lines in the result collect as wants and are stripped from the returned text" do
    Given "a result carrying a want between answer lines"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    server = FakeAcpServer.new(
      result_text: "done the work\nWANTED: /etc/hosts — needed to inspect DNS overrides\nall tests pass",
    )
    executor = AcpFakeExecutor.new(server: server)
    agent = AiFlow::Agent.new(executor: executor)

    When "launching"
    text = agent.launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then "the want is collected and the returned text no longer carries it"
    agent.wants.map(&:subject) == ["/etc/hosts"]
    agent.wants.map(&:reason) == ["needed to inspect DNS overrides"]
    agent.wants.map(&:channel) == [:declared]
    text == "done the work\nall tests pass"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "wants accumulate deduped across launches" do
    Given "two launches declaring the same want"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    executor = AcpFakeExecutor.new(server: FakeAcpServer.new(result_text: "WANTED: jq — parse"))
    agent = AiFlow::Agent.new(executor: executor)

    When "launching twice"
    agent.launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)
    agent.launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then "one want survives"
    agent.wants.length == 1

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "denial signatures in tool output collect as observed wants" do
    Given "a tool_call_update whose output hit a permission wall"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    server = FakeAcpServer.new(updates: [
      { "sessionUpdate" => "tool_call_update", "toolCallId" => "t1", "status" => "completed",
        "content" => [{ "type" => "content",
                        "content" => { "type" => "text", "text" => "ls: /Users/Shared/dev/ddc: Permission denied" } }] },
      { "sessionUpdate" => "agent_message_chunk", "content" => { "type" => "text", "text" => "done" } },
    ])
    executor = AcpFakeExecutor.new(server: server)
    agent = AiFlow::Agent.new(executor: executor)

    When "launching"
    text = agent.launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then "the denial is an observed want and the answer is untouched"
    agent.wants.map(&:subject) == ["/Users/Shared/dev/ddc"]
    agent.wants.map(&:channel) == [:observed]
    text == "done"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an observed denial never duplicates a declared want on the same subject" do
    Given "the same path denied in tool output and declared WANTED"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    server = FakeAcpServer.new(
      updates: [
        { "sessionUpdate" => "tool_call_update", "toolCallId" => "t1", "status" => "completed",
          "content" => [{ "type" => "content",
                          "content" => { "type" => "text", "text" => "cat: /etc/hosts: Permission denied" } }] },
        { "sessionUpdate" => "agent_message_chunk",
          "content" => { "type" => "text", "text" => "WANTED: /etc/hosts — DNS overrides\ndone" } },
      ],
    )
    executor = AcpFakeExecutor.new(server: server)
    agent = AiFlow::Agent.new(executor: executor)

    When "launching"
    agent.launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then "one want per subject; the declared channel wins the slot"
    agent.wants.map(&:subject) == ["/etc/hosts"]
    agent.wants.map(&:channel) == [:declared]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a rejected permission request records as an observed want with the request's context" do
    Given "a non-force launch that gets asked for a mutating tool"
    dir = Dir.mktmpdir("ai-flow-agent-test-")
    server = FakeAcpServer.new(permission_requests: [
      { "toolCall" => { "title" => "$ chmod 777 /etc", "kind" => "execute" },
        "options" => FakeAcpServer::DEFAULT_PERMISSION_OPTIONS },
    ])
    executor = AcpFakeExecutor.new(server: server)
    agent = AiFlow::Agent.new(executor: executor)

    When "launching without force"
    agent.launch(prompt: "p", workdir: dir, command: AiFlow::Command::Ask.new)

    Then "the deny-with-context is a WANTED carrier"
    server.permission_answers == ["reject-once"]
    agent.wants.map(&:subject) == ["$ chmod 777 /etc"]
    agent.wants.map(&:channel) == [:observed]
    agent.wants.map(&:reason) == ["permission request rejected (non-force pass)"]

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
