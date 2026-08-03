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
end
