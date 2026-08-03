# typed: strict
# frozen_string_literal: true

require "bundler"

module AiFlow
  # The env overlay that undoes the harness's own toolchain activation.
  # Executor applies it to every spawn (#46) — callers never pass it
  # themselves. Per-call-site opt-in kept regrowing the leak: #38 was fixed
  # agent-only, then the invariants shell-out added later missed it (#44).
  # gh/git are indifferent to the bundler keys, so a clean default costs
  # nothing.
  #
  # The dispatcher runs under `bundle exec` inside the .ai-flow checkout;
  # without the scrub, RUBYOPT/BUNDLE_GEMFILE/GEM_HOME leak into the child
  # and it resolves the harness's pins instead of its own — the agent's
  # `bundle` hits Bundler::RubyVersionMismatch naming a Ruby the project
  # never declared, and `dev` crashes unable to load its vendored gems.
  # Bundler.original_env is bundler's own record of the pre-activation
  # environment; the toolchain-selection keys it can't see — written before
  # bundler started, by shadowenv activating .ai-flow or an rbenv shim in
  # the launch chain — are force-unset on top (TOOLCHAIN_KEYS). A nil value
  # in a spawn env hash unsets the key.
  module HarnessEnv
    extend T::Sig

    TOOLCHAIN_KEYS = T.let(
      [
        "__shadowenv_data", "RUBY_ROOT", "RUBY_ENGINE", "RUBY_VERSION", "GEM_ROOT",
        "RBENV_VERSION", "RBENV_DIR"
      ].freeze,
      T::Array[String],
    )

    class << self
      extend T::Sig

      # @return [Hash{String => String, nil}] the spawn-env overlay
      sig { returns(T::Hash[String, T.nilable(String)]) }
      def scrub
        original = Bundler.original_env
        overlay = T.let({}, T::Hash[String, T.nilable(String)])
        (ENV.keys | original.keys).each do |key|
          overlay[key] = original[key] unless ENV[key] == original[key]
        end
        TOOLCHAIN_KEYS.each { |key| overlay[key] = nil }
        overlay
      end
    end
  end
end
