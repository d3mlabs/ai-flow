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

  test "from_env accepts an agent user the passwd database knows" do
    Given "the agent user set to a user that exists on this host"
    saved_user = ENV["AI_FLOW_AGENT_USER"]
    saved_group = ENV.delete("AI_FLOW_AGENT_GROUP")
    ENV["AI_FLOW_AGENT_USER"] = CURRENT_USER

    When "reading the isolation config"
    isolation = T.must(AiFlow::AgentIsolation.from_env)

    Then "user comes from env, group defaults to the legacy name"
    isolation.user == CURRENT_USER
    isolation.group == AiFlow::AgentIsolation::LEGACY_GROUP

    Cleanup
    saved_user ? ENV["AI_FLOW_AGENT_USER"] = saved_user : ENV.delete("AI_FLOW_AGENT_USER")
    ENV["AI_FLOW_AGENT_GROUP"] = saved_group if saved_group
  end

  # plans#59: dev writes the data root's group into the service env on
  # every host it registers; the legacy default is for a Mac from before.
  test "from_env takes the group dev wrote into the service env over the legacy default" do
    Given "the service env naming the agent user and the data root's group"
    saved_user = ENV["AI_FLOW_AGENT_USER"]
    saved_group = ENV["AI_FLOW_AGENT_GROUP"]
    ENV["AI_FLOW_AGENT_USER"] = CURRENT_USER
    ENV["AI_FLOW_AGENT_GROUP"] = "dev"

    When "reading the isolation config"
    isolation = T.must(AiFlow::AgentIsolation.from_env)

    Then
    isolation.group == "dev"

    Cleanup
    saved_user ? ENV["AI_FLOW_AGENT_USER"] = saved_user : ENV.delete("AI_FLOW_AGENT_USER")
    saved_group ? ENV["AI_FLOW_AGENT_GROUP"] = saved_group : ENV.delete("AI_FLOW_AGENT_GROUP")
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
    isolation = AiFlow::AgentIsolation.new(user: "ai-agent", group: "ai")

    When "building the spawn prefix"
    prefix = isolation.spawn_prefix

    Then "non-interactive sudo, fresh HOME, allowlist incl. the agent overlay's keys"
    prefix.first(5) == ["sudo", "-n", "-H", "-u", "ai-agent"]
    prefix.last == "--"
    preserve = prefix.fetch(5)
    preserve.start_with?("--preserve-env=")
    AiFlow::AgentIsolation::PRESERVED_ENV_KEYS.all? { |key| preserve.include?(key) }
    preserve.include?("AGENT_CLI_CREDENTIAL_STORE")

    Cleanup
    nil
  end

  # ai-flow#107: the agent installs gems into dev's per-project gem home
  # under the data root (dev#294), as the caller's env already says. A
  # redirect from the harness was one directory for every Ruby the agent
  # met — bundler keys it by ABI alone, so native extensions built under one
  # 4.0.x loaded under another — and dev's project shadowenv overrode the
  # GEM_HOME half anyway.
  test "neither the allowlist nor the overlay carries a gem or bundler key" do
    Given "an isolation config"
    isolation = AiFlow::AgentIsolation.new(user: "ai-agent", group: "ai")

    Expect "the agent's gem env is the caller's, untouched"
    (AiFlow::AgentIsolation::PRESERVED_ENV_KEYS + isolation.redirect_env.keys)
      .none? { |key| key.start_with?("GEM_", "BUNDLE_", "BUNDLER_") }
  end

  test "the allowlist carries a second GIT_CONFIG slot — safe.directory rides behind the auth header (#101)" do
    Expect "both halves of slot 1 survive sudo's env_reset"
    AiFlow::AgentIsolation::PRESERVED_ENV_KEYS.include?("GIT_CONFIG_KEY_1")
    AiFlow::AgentIsolation::PRESERVED_ENV_KEYS.include?("GIT_CONFIG_VALUE_1")
  end

  test "safe_directory_config names the workspace by the path git itself resolves (#101)" do
    Given "an isolation and a workspace reached through a symlinked base (/tmp on macOS)"
    isolation = AiFlow::AgentIsolation.new(user: "ai-agent", group: "ai")
    dir = Dir.mktmpdir("ai-flow-safe-dir-", "/tmp")

    When "building the git config entry"
    key, value = isolation.safe_directory_config(dir)

    Then "safe.directory on the realpath — git compares against the resolved worktree, not the spelling"
    key == "safe.directory"
    value == File.realpath(dir)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "redirect_env is the agent CLI's file credential store and nothing else" do
    Given "an isolation config"
    isolation = AiFlow::AgentIsolation.new(user: "ai-agent", group: "ai")

    When "building the agent overlay"
    env = isolation.redirect_env

    Then "the agent CLI stores credentials in a file — a headless user has " \
         "no login keychain, and securityd's prompt lands in the runner " \
         "user's GUI session; gems need no redirect (ai-flow#107)"
    env == { "AGENT_CLI_CREDENTIAL_STORE" => "file" }

    Cleanup
    nil
  end

  test "workspace_base is a world-traversable root — the agent user must reach the shared leaf" do
    Given "an isolation"
    isolation = AiFlow::AgentIsolation.new(user: CURRENT_USER, group: PRIMARY_GROUP)

    Expect "the base escapes the dispatcher's private per-user tempdir (0700 on macOS): " \
           "the group share on the leaf is worthless when the sidecar user cannot traverse to it"
    isolation.workspace_base == "/tmp"
  end

  test "share_workspace makes a fresh dir group-owned, setgid, and group-writable" do
    Given "a freshly created empty workspace parent"
    dir = Dir.mktmpdir("ai-flow-isolation-test-")
    isolation = AiFlow::AgentIsolation.new(user: CURRENT_USER, group: PRIMARY_GROUP)

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
