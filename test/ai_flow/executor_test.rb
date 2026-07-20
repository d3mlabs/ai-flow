# frozen_string_literal: true

require "test_helper"
require "rbconfig"

# A provider stub with a scripted token sequence — observable freshness
# without real minting.
class ScriptedTokenProvider
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
end unless defined?(ScriptedTokenProvider)

transform!(RSpock::AST::Transformation)
class AiFlow::ExecutorTest < Minitest::Test
  # The running interpreter, with the test process's bundler activation
  # scrubbed (nil unsets) — otherwise the child ruby loads this suite's
  # bundler setup and dies before the -e script runs.
  RUBY = RbConfig.ruby
  CLEAN = { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil }.freeze

  test "capture injects GH_TOKEN and env-borne git auth from the provider" do
    Given "an executor with a token provider"
    provider = ScriptedTokenProvider.new(["ghs_alpha"])
    executor = AiFlow::Executor.new(token_provider: provider)

    When "capturing a subprocess that prints its auth env"
    out, _err, ok = executor.capture(
      RUBY, "-e", 'puts ENV["GH_TOKEN"]; puts ENV["GIT_CONFIG_KEY_0"]; puts ENV["GIT_CONFIG_VALUE_0"]',
      env: CLEAN,
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
    first, = executor.capture(RUBY, "-e", 'print ENV["GH_TOKEN"]', env: CLEAN)
    executor.refresh_auth!
    second, = executor.capture(RUBY, "-e", 'print ENV["GH_TOKEN"]', env: CLEAN)

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
      env: CLEAN,
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
      env: CLEAN.merge("EXTRA" => "hello"),
    )

    Then "both are present"
    out == "ghs_alpha,hello"

    Cleanup
    nil
  end

  test "stream injects the same auth env" do
    Given "an executor with a token provider"
    provider = ScriptedTokenProvider.new(["ghs_alpha"])
    executor = AiFlow::Executor.new(token_provider: provider)

    When "streaming a subprocess that prints its token"
    lines = []
    _err, ok = executor.stream(RUBY, "-e", 'puts ENV["GH_TOKEN"]', env: CLEAN) { |line| lines << line.chomp }

    Then
    ok
    lines == ["ghs_alpha"]

    Cleanup
    nil
  end
end
