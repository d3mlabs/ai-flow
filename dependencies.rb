# typed: false
# frozen_string_literal: true

# Dependency manifest for dev: the exact Ruby toolchain plus the gem set,
# and what ai-flow needs on a host. dev generates Gemfile/Gemfile.lock from
# these declarations — edit here, then run `dev deps update` (re-lock) and
# `dev up` (install). A released ai-flow tree ships this manifest and its
# lock, so dev installs it self-contained where the tree lands (the agent
# hosts following the gh channel's head).
require "dev/deps"

Dev::Deps.define do
  ruby "4.0.6"

  # The headless Cursor agent CLI every command drives (Agent is the one
  # seam to it). A cask: Homebrew publishes no versions for it, so the pin
  # is the name alone, and the upstream cask carries Linux builds, so the
  # binary lands in the Linuxbrew prefix like any other. Declared here
  # because an agent host's shape is ai-flow's to state, not dev's.
  brew "cursor-cli", cask: true

  # Runtime: sorbet-runtime backs the inline sigs and sealed result
  # hierarchies. The one gem the deployed tree's executables need.
  gem "sorbet-runtime"

  group(:development) do
    gem "sorbet"
    gem "tapioca", require: false
    gem "rubocop-d3mlabs", "~> 1.0", require: false
  end

  group(:test) do
    gem "minitest"
    gem "minitest-reporters"
    gem "rake"
    gem "rspock", "~> 3.0"
    gem "simplecov", "~> 1.0"
    # Codecov's parser rejects SimpleCov's JSON once a report carries skipped
    # lines ("ignored" entries — exactly what simplecov-sorbet produces);
    # cobertura XML is Codecov's documented format for SimpleCov output.
    gem "simplecov-cobertura", "~> 4.0", require: false
    # Skips type-level Sorbet constructs (T.type_alias/sig blocks, T.absurd)
    # so they never read as coverage misses.
    gem "simplecov-sorbet", "~> 0.2", require: false
  end
end
