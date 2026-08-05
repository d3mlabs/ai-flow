# typed: true
# frozen_string_literal: true

require "test_helper"
require "rbconfig"

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

  def scoped_token(repositories:)
    "#{@current}_scoped_to_#{repositories.join("+")}"
  end
end unless defined?(ScriptedTokenProvider)

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

  test "scoped_auth_env carries the downscoped token in the same env shape as the default injection" do
    Given "an executor with a token provider"
    provider = ScriptedTokenProvider.new(["ghs_alpha"])
    executor = AiFlow::Executor.new(token_provider: provider)

    When "building the agent's scoped overlay"
    env = executor.scoped_auth_env(repositories: ["d3mlabs/ai-flow"])

    Then "GH_TOKEN and the git extraheader both carry the scoped token"
    env.fetch("GH_TOKEN") == "ghs_alpha_scoped_to_d3mlabs/ai-flow"
    env.fetch("GIT_CONFIG_VALUE_0") ==
      "AUTHORIZATION: basic #{["x-access-token:ghs_alpha_scoped_to_d3mlabs/ai-flow"].pack("m0")}"

    Cleanup
    nil
  end

  test "a spawn with the scoped overlay overrides the default installation-wide injection" do
    Given "an executor with a token provider"
    provider = ScriptedTokenProvider.new(["ghs_alpha"])
    executor = AiFlow::Executor.new(token_provider: provider)

    When "capturing with the scoped overlay as the caller env"
    out, = executor.capture(
      RUBY, "-e", 'print ENV["GH_TOKEN"]',
      env: executor.scoped_auth_env(repositories: ["d3mlabs/ai-flow"]),
    )

    Then "the child sees the scoped token, not the dispatcher's"
    out == "ghs_alpha_scoped_to_d3mlabs/ai-flow"

    Cleanup
    nil
  end

  test "without a provider the scoped overlay is empty — ambient auth stays ambient" do
    Given "a bare executor"
    executor = AiFlow::Executor.new

    When "building the agent's scoped overlay"
    env = executor.scoped_auth_env(repositories: ["d3mlabs/ai-flow"])

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
end
