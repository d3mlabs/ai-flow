# typed: true
# frozen_string_literal: true

require "test_helper"

transform!(RSpock::AST::Transformation)
class AiFlow::HarnessEnvTest < Minitest::Test
  test "scrub restores bundler keys and unsets toolchain-selection keys" do
    Given "an env polluted the way bundle exec + shadowenv leave the harness's"
    polluted = {
      "RUBYOPT" => "-r/harness/.ai-flow/bundler/setup",
      "BUNDLE_GEMFILE" => "/harness/.ai-flow/Gemfile",
      "__shadowenv_data" => "harness-shadowenv-blob",
      "RBENV_VERSION" => "3.3.10",
    }
    saved = polluted.keys.to_h { |key| [key, ENV[key]] }
    polluted.each { |key, value| ENV[key] = value }

    When "computing the scrub"
    env = AiFlow::HarnessEnv.scrub

    Then "bundler keys restore to their pre-activation values and toolchain keys are unset"
    env.fetch("RUBYOPT", :missing) == Bundler.original_env["RUBYOPT"]
    env.fetch("BUNDLE_GEMFILE", :missing) == Bundler.original_env["BUNDLE_GEMFILE"]
    env.fetch("__shadowenv_data", :missing).nil?
    env.fetch("RBENV_VERSION", :missing).nil?

    Cleanup
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "scrub unsets gem-resolution keys even when bundler recorded them as original" do
    Given "GEM_HOME/GEM_PATH/RUBYLIB exactly as bundler recorded them pre-activation"
    # A harness export written before bundler booted (shadowenv's GEM_HOME/
    # GEM_PATH, dev's RUBYLIB) is what Bundler.original_env holds, so the
    # restore half of the scrub has nothing to undo — only the force-unset
    # can remove it. Aligning ENV with original_env reproduces that state.
    keys = ["GEM_HOME", "GEM_PATH", "RUBYLIB"]
    saved = keys.to_h { |key| [key, ENV[key]] }
    keys.each do |key|
      original_value = Bundler.original_env[key]
      original_value.nil? ? ENV.delete(key) : ENV[key] = original_value
    end

    When "computing the scrub"
    env = AiFlow::HarnessEnv.scrub

    Then "the overlay force-unsets all three"
    env.fetch("GEM_HOME", :missing).nil?
    env.fetch("GEM_PATH", :missing).nil?
    env.fetch("RUBYLIB", :missing).nil?

    Cleanup
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
