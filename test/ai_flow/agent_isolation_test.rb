# typed: true
# frozen_string_literal: true

require "test_helper"
require "etc"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class AiFlow::AgentIsolationTest < Minitest::Test
  # A user and group guaranteed to exist on any test host: the test's own.
  # share_workspace chgrps to a group the test user already belongs to, per
  # test-hygiene (real files, no fs mocks, no root).
  CURRENT_USER = T.must(Etc.getpwuid(Process.uid)).name
  PRIMARY_GROUP = T.must(Etc.getgrgid(Process.gid)).name

  test "from_env is nil when AI_FLOW_AGENT_USER is unset — feature off by absence" do
    Given "an env without the agent user"
    saved = ENV.delete("AI_FLOW_AGENT_USER")

    When "reading the isolation config"
    isolation = AiFlow::AgentIsolation.from_env

    Then
    isolation.nil?

    Cleanup
    ENV["AI_FLOW_AGENT_USER"] = saved if saved
  end

  test "from_env resolves the agent user's home from the passwd database" do
    Given "the agent user set to a user that exists on this host"
    saved_user = ENV["AI_FLOW_AGENT_USER"]
    saved_group = ENV.delete("AI_FLOW_AGENT_GROUP")
    ENV["AI_FLOW_AGENT_USER"] = CURRENT_USER

    When "reading the isolation config"
    isolation = T.must(AiFlow::AgentIsolation.from_env)

    Then "user comes from env, home from passwd, group defaults to ai"
    isolation.user == CURRENT_USER
    isolation.redirect_env.fetch("GEM_HOME") == File.join(T.must(Etc.getpwuid(Process.uid)).dir, ".gem")

    Cleanup
    saved_user ? ENV["AI_FLOW_AGENT_USER"] = saved_user : ENV.delete("AI_FLOW_AGENT_USER")
    ENV["AI_FLOW_AGENT_GROUP"] = saved_group if saved_group
  end

  test "a configured agent user that does not exist on the host fails closed" do
    Given "an agent user no host has"
    saved = ENV["AI_FLOW_AGENT_USER"]
    ENV["AI_FLOW_AGENT_USER"] = "ai-flow-no-such-user"

    When "reading the isolation config"
    AiFlow::AgentIsolation.from_env

    Then
    raises AiFlow::AgentIsolation::UnknownAgentUserError

    Cleanup
    saved ? ENV["AI_FLOW_AGENT_USER"] = saved : ENV.delete("AI_FLOW_AGENT_USER")
  end

  test "spawn_prefix is the sudo invocation with the env allowlist on the command" do
    Given "an isolation config"
    isolation = AiFlow::AgentIsolation.new(user: "ai-agent", group: "ai", home: "/Users/ai-agent")

    When "building the spawn prefix"
    prefix = isolation.spawn_prefix

    Then "non-interactive sudo, fresh HOME, allowlist incl. the redirected toolchain keys"
    prefix.first(5) == ["sudo", "-n", "-H", "-u", "ai-agent"]
    prefix.last == "--"
    preserve = prefix.fetch(5)
    preserve.start_with?("--preserve-env=")
    AiFlow::AgentIsolation::PRESERVED_ENV_KEYS.all? { |key| preserve.include?(key) }
    preserve.include?("GEM_HOME")
    preserve.include?("BUNDLE_PATH")

    Cleanup
    nil
  end

  test "redirect_env points toolchain writes under the agent's own home" do
    Given "an isolation config"
    isolation = AiFlow::AgentIsolation.new(user: "ai-agent", group: "ai", home: "/Users/ai-agent")

    When "building the redirect overlay"
    env = isolation.redirect_env

    Then "gem and bundler installs land in agent-owned disposable space"
    env == {
      "GEM_HOME" => "/Users/ai-agent/.gem",
      "BUNDLE_PATH" => "/Users/ai-agent/.bundle",
    }

    Cleanup
    nil
  end

  test "share_workspace makes a fresh dir group-owned, setgid, and group-writable" do
    Given "a freshly created empty workspace parent"
    dir = Dir.mktmpdir("ai-flow-isolation-test-")
    isolation = AiFlow::AgentIsolation.new(user: CURRENT_USER, group: PRIMARY_GROUP, home: "/tmp")

    When "sharing it"
    isolation.share_workspace(dir)

    Then "group set, 2770 — contents populated later inherit the group via setgid"
    stat = File.stat(dir)
    T.must(Etc.getgrgid(stat.gid)).name == PRIMARY_GROUP
    format("%o", stat.mode & 0o7777) == "2770"

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
