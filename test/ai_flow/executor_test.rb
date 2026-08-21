# typed: true
# frozen_string_literal: true

require "test_helper"
require "rbconfig"
require "etc"
require "tmpdir"
require "fileutils"

# A provider stub with a scripted token sequence — observable freshness
# without real minting. Subclasses the real class so sorbet-runtime's sig
# checks accept it at the injection seam.
class ScriptedTokenProvider < AiFlow::TokenProvider
  attr_reader :refreshes

  def initialize(tokens)
    @tokens = tokens
    @current = tokens.first
    @refreshes = 0
  end

  def token
    @current
  end

  def refresh!
    @refreshes += 1
    @current = @tokens[@refreshes] || @tokens.last
  end

  def agent_token
    "#{@current}_read_only"
  end
end unless defined?(ScriptedTokenProvider)

# A benign stand-in for the sudo re-exec: /usr/bin/env with a marker
# assignment proves the prefix preceded the argv without real sudo (which
# only the runner-box smoke test exercises). Subclasses the real class so
# sorbet-runtime's sig checks accept it at the injection seam.
class MarkerIsolation < AiFlow::AgentIsolation
  def spawn_prefix
    ["/usr/bin/env", "AI_FLOW_ISOLATION_MARKER=yes"]
  end
end unless defined?(MarkerIsolation)

transform!(RSpock::AST::Transformation)
class AiFlow::ExecutorTest < Minitest::Test
  RUBY = RbConfig.ruby

  test "every spawn gets the harness scrub — bundler and toolchain activation never leak (#46)" do
    Given "a harness-polluted process env"
    saved = ENV["RBENV_VERSION"]
    ENV["RBENV_VERSION"] = "9.9.9"
    executor = AiFlow::Executor.new

    When "capturing with no caller env at all"
    out, _err, ok = executor.capture(RUBY, "-e", 'print [ENV["RBENV_VERSION"], ENV["BUNDLE_GEMFILE"]].inspect')

    Then "the child sees the pre-activation environment, not the dispatcher's"
    ok
    out == [nil, Bundler.original_env["BUNDLE_GEMFILE"]].inspect

    Cleanup
    saved.nil? ? ENV.delete("RBENV_VERSION") : ENV["RBENV_VERSION"] = saved
  end

  test "stream applies the same default scrub" do
    Given "a harness-polluted process env"
    saved = ENV["RBENV_VERSION"]
    ENV["RBENV_VERSION"] = "9.9.9"
    executor = AiFlow::Executor.new

    When "streaming with no caller env"
    lines = []
    _err, ok = executor.stream(RUBY, "-e", 'puts ENV["RBENV_VERSION"].inspect') { |line| lines << line.chomp }

    Then
    ok
    lines == ["nil"]

    Cleanup
    saved.nil? ? ENV.delete("RBENV_VERSION") : ENV["RBENV_VERSION"] = saved
  end

  test "a caller env override outranks the scrub" do
    Given "a caller that explicitly wants a scrubbed key back"
    saved = ENV["RBENV_VERSION"]
    ENV["RBENV_VERSION"] = "9.9.9"
    executor = AiFlow::Executor.new

    When "capturing with the key in the caller env"
    out, = executor.capture(RUBY, "-e", 'print ENV["RBENV_VERSION"]', env: { "RBENV_VERSION" => "kept" })

    Then
    out == "kept"

    Cleanup
    saved.nil? ? ENV.delete("RBENV_VERSION") : ENV["RBENV_VERSION"] = saved
  end

  test "capture injects GH_TOKEN and env-borne git auth from the provider" do
    Given "an executor with a token provider"
    provider = ScriptedTokenProvider.new(["ghs_alpha"])
    executor = AiFlow::Executor.new(token_provider: provider)

    When "capturing a subprocess that prints its auth env"
    out, _err, ok = executor.capture(
      RUBY, "-e", 'puts ENV["GH_TOKEN"]; puts ENV["GIT_CONFIG_KEY_0"]; puts ENV["GIT_CONFIG_VALUE_0"]',
    )
    lines = out.split("\n")

    Then "the token reaches gh and git through env, never argv"
    ok
    lines.fetch(0) == "ghs_alpha"
    lines.fetch(1).start_with?("http.")
    lines.fetch(1).end_with?("/.extraheader")
    lines.fetch(2) == "AUTHORIZATION: basic #{["x-access-token:ghs_alpha"].pack("m0")}"

    Cleanup
    nil
  end

  test "each capture re-asks the provider — a refresh between calls changes the injected token" do
    Given "an executor whose provider rotates on refresh"
    provider = ScriptedTokenProvider.new(%w[ghs_alpha ghs_beta])
    executor = AiFlow::Executor.new(token_provider: provider)

    When "capturing, refreshing, capturing again"
    first, = executor.capture(RUBY, "-e", 'print ENV["GH_TOKEN"]')
    executor.refresh_auth!
    second, = executor.capture(RUBY, "-e", 'print ENV["GH_TOKEN"]')

    Then "the second spawn carries the fresh token"
    first == "ghs_alpha"
    second == "ghs_beta"
    provider.refreshes == 1

    Cleanup
    nil
  end

  test "without a provider no auth env is injected and refresh_auth! is a no-op" do
    Given "a bare executor"
    executor = AiFlow::Executor.new

    When "capturing a subprocess that checks for injected keys"
    executor.refresh_auth!
    out, _err, ok = executor.capture(
      RUBY, "-e", 'print ENV.key?("GIT_CONFIG_KEY_0").to_s',
    )

    Then "no git auth key was injected"
    ok
    out == "false"

    Cleanup
    nil
  end

  test "caller env overrides merge on top of the auth env" do
    Given "an executor with a provider and a caller-supplied variable"
    provider = ScriptedTokenProvider.new(["ghs_alpha"])
    executor = AiFlow::Executor.new(token_provider: provider)

    When "capturing with an extra env var"
    out, = executor.capture(
      RUBY, "-e", 'print [ENV["GH_TOKEN"], ENV["EXTRA"]].join(",")',
      env: { "EXTRA" => "hello" },
    )

    Then "both are present"
    out == "ghs_alpha,hello"

    Cleanup
    nil
  end

  test "agent_auth_env carries the read-only token in the same env shape as the default injection" do
    Given "an executor with a token provider"
    provider = ScriptedTokenProvider.new(["ghs_alpha"])
    executor = AiFlow::Executor.new(token_provider: provider)

    When "building the agent's auth overlay"
    env = executor.agent_auth_env

    Then "GH_TOKEN and the git extraheader both carry the read-only token"
    env.fetch("GH_TOKEN") == "ghs_alpha_read_only"
    env.fetch("GIT_CONFIG_VALUE_0") ==
      "AUTHORIZATION: basic #{["x-access-token:ghs_alpha_read_only"].pack("m0")}"

    Cleanup
    nil
  end

  test "a spawn with the agent overlay overrides the default full-permission injection" do
    Given "an executor with a token provider"
    provider = ScriptedTokenProvider.new(["ghs_alpha"])
    executor = AiFlow::Executor.new(token_provider: provider)

    When "capturing with the agent overlay as the caller env"
    out, = executor.capture(RUBY, "-e", 'print ENV["GH_TOKEN"]', env: executor.agent_auth_env)

    Then "the child sees the read-only token, not the dispatcher's"
    out == "ghs_alpha_read_only"

    Cleanup
    nil
  end

  test "without a provider the agent overlay is empty — ambient auth stays ambient" do
    Given "a bare executor"
    executor = AiFlow::Executor.new

    When "building the agent's auth overlay"
    env = executor.agent_auth_env

    Then
    env.empty?

    Cleanup
    nil
  end

  test "stream injects the same auth env" do
    Given "an executor with a token provider"
    provider = ScriptedTokenProvider.new(["ghs_alpha"])
    executor = AiFlow::Executor.new(token_provider: provider)

    When "streaming a subprocess that prints its token"
    lines = []
    _err, ok = executor.stream(RUBY, "-e", 'puts ENV["GH_TOKEN"]') { |line| lines << line.chomp }

    Then
    ok
    lines == ["ghs_alpha"]

    Cleanup
    nil
  end

  test "stream(isolate: true) prepends the spawn prefix and redirects toolchain writes" do
    Given "an executor with a benign injected isolation"
    isolation = MarkerIsolation.new(user: "ai-agent", group: "ai", home: "/tmp/agent-home")
    executor = AiFlow::Executor.new(isolation: isolation)

    When "streaming isolated"
    lines = []
    _err, ok = executor.stream(
      RUBY, "-e", 'puts [ENV["AI_FLOW_ISOLATION_MARKER"], ENV["GEM_HOME"]].join(",")',
      isolate: true,
    ) { |line| lines << line.chomp }

    Then "the prefix ran ahead of the argv and GEM_HOME points under the agent home"
    ok
    lines == ["yes,/tmp/agent-home/.gem"]

    Cleanup
    nil
  end

  test "a non-isolated stream never picks up the prefix or the redirects" do
    Given "an executor with an isolation configured"
    isolation = MarkerIsolation.new(user: "ai-agent", group: "ai", home: "/tmp/agent-home")
    executor = AiFlow::Executor.new(isolation: isolation)

    When "streaming without isolate:"
    lines = []
    executor.stream(
      # The host env may legitimately carry its own GEM_HOME, so absence of
      # the *redirect value* is the assertable signal.
      RUBY, "-e", 'puts [ENV.key?("AI_FLOW_ISOLATION_MARKER"), ENV["GEM_HOME"] == "/tmp/agent-home/.gem"].join(",")',
    ) { |line| lines << line.chomp }

    Then "gh/git spawns stay the dispatcher's own"
    lines == ["false,false"]

    Cleanup
    nil
  end

  test "isolate: true without configured isolation is a no-op — local runs unchanged" do
    Given "an executor with isolation off"
    executor = AiFlow::Executor.new(isolation: nil)

    When "streaming isolated"
    lines = []
    _err, ok = executor.stream(RUBY, "-e", 'puts "ran"', isolate: true) { |line| lines << line.chomp }

    Then
    ok
    lines == ["ran"]

    Cleanup
    nil
  end

  test "share_workspace applies the isolation's group share to a fresh dir" do
    Given "an executor with a real isolation and a fresh workspace parent"
    group = T.must(Etc.getgrgid(Process.gid)).name
    isolation = AiFlow::AgentIsolation.new(user: "ai-agent", group: group, home: "/tmp")
    executor = AiFlow::Executor.new(isolation: isolation)
    dir = Dir.mktmpdir("ai-flow-executor-share-")

    When "sharing it"
    executor.share_workspace(dir)

    Then
    format("%o", File.stat(dir).mode & 0o7777) == "2770"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "share_workspace without isolation leaves the dir alone" do
    Given "an executor with isolation off and a fresh dir"
    executor = AiFlow::Executor.new(isolation: nil)
    dir = Dir.mktmpdir("ai-flow-executor-share-")
    before = File.stat(dir).mode

    When "sharing it"
    executor.share_workspace(dir)

    Then
    File.stat(dir).mode == before

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
