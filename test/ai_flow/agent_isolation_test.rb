# typed: false — rspock Where tables are load-time rewritten and have no static typing.
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

  test "the allowlist carries a second GIT_CONFIG slot — safe.directory rides behind the auth header (#101)" do
    Expect "both halves of slot 1 survive sudo's env_reset"
    AiFlow::AgentIsolation::PRESERVED_ENV_KEYS.include?("GIT_CONFIG_KEY_1")
    AiFlow::AgentIsolation::PRESERVED_ENV_KEYS.include?("GIT_CONFIG_VALUE_1")
  end

  test "safe_directory_config names the workspace by the path git itself resolves (#101)" do
    Given "an isolation and a workspace reached through a symlinked base (/tmp on macOS)"
    isolation = AiFlow::AgentIsolation.new(user: "ai-agent", group: "ai", home: "/Users/ai-agent")
    dir = Dir.mktmpdir("ai-flow-safe-dir-", "/tmp")

    When "building the git config entry"
    key, value = isolation.safe_directory_config(dir)

    Then "safe.directory on the realpath — git compares against the resolved worktree, not the spelling"
    key == "safe.directory"
    value == File.realpath(dir)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "redirect_env points toolchain writes under the agent's own home" do
    Given "an isolation config"
    isolation = AiFlow::AgentIsolation.new(user: "ai-agent", group: "ai", home: "/Users/ai-agent")

    When "building the redirect overlay"
    env = isolation.redirect_env

    Then "gem and bundler installs land in agent-owned disposable space, " \
         "and the agent CLI stores credentials in a file — a headless user " \
         "has no login keychain, and securityd's prompt lands in the " \
         "runner user's GUI session"
    env == {
      "GEM_HOME" => "/Users/ai-agent/.gem",
      "BUNDLE_PATH" => "/Users/ai-agent/.bundle",
      "AGENT_CLI_CREDENTIAL_STORE" => "file",
    }

    Cleanup
    nil
  end

  # ai-flow#116: two slots on one box run as the same agent user at the
  # same time; a gem home they share is two bundlers racing on one tree.
  # Slot 1 keeps the path it always had (its warm gems stay warm).
  test "redirect_env keys the gem home and bundle path by slot — slot 1 unchanged, slot N suffixed" do
    Given "an isolation config on the given slot"
    isolation = AiFlow::AgentIsolation.new(user: "ai-agent", group: "ai", home: "/Users/ai-agent", slot: slot)

    Expect "one gem tree per slot; the credential store does not vary"
    isolation.redirect_env.fetch("GEM_HOME") == gem_home
    isolation.redirect_env.fetch("BUNDLE_PATH") == bundle_path
    isolation.redirect_env.fetch("AGENT_CLI_CREDENTIAL_STORE") == "file"

    Where
    slot | gem_home | bundle_path
    AiFlow::RunnerSlot.new(number: 1) | "/Users/ai-agent/.gem"   | "/Users/ai-agent/.bundle"
    AiFlow::RunnerSlot.new(number: 2) | "/Users/ai-agent/.gem-2" | "/Users/ai-agent/.bundle-2"
    AiFlow::RunnerSlot.new(number: 3) | "/Users/ai-agent/.gem-3" | "/Users/ai-agent/.bundle-3"
  end

  test "from_env carries the slot dev wrote into the service env" do
    Given "the agent user set, on slot 2"
    saved_user = ENV["AI_FLOW_AGENT_USER"]
    saved_slot = ENV["AI_FLOW_RUNNER_SLOT"]
    ENV["AI_FLOW_AGENT_USER"] = CURRENT_USER
    ENV["AI_FLOW_RUNNER_SLOT"] = "2"

    When "reading the isolation config"
    isolation = T.must(AiFlow::AgentIsolation.from_env)

    Then "the redirect is slot 2's"
    isolation.redirect_env.fetch("GEM_HOME") == File.join(T.must(Etc.getpwuid(Process.uid)).dir, ".gem-2")

    Cleanup
    saved_user ? ENV["AI_FLOW_AGENT_USER"] = saved_user : ENV.delete("AI_FLOW_AGENT_USER")
    saved_slot ? ENV["AI_FLOW_RUNNER_SLOT"] = saved_slot : ENV.delete("AI_FLOW_RUNNER_SLOT")
  end

  test "workspace_base is a world-traversable root — the agent user must reach the shared leaf" do
    Given "an isolation"
    isolation = AiFlow::AgentIsolation.new(user: CURRENT_USER, group: PRIMARY_GROUP, home: "/tmp")

    Expect "the base escapes the dispatcher's private per-user tempdir (0700 on macOS): " \
           "the group share on the leaf is worthless when the sidecar user cannot traverse to it"
    isolation.workspace_base == "/tmp"
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
