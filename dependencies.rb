# typed: false
# frozen_string_literal: true

# Dependency manifest for dev: the exact Ruby toolchain plus the gem set.
# dev generates Gemfile/Gemfile.lock from these declarations — edit here,
# then run `dev update-deps` (re-lock) and `dev up` (install). CI and
# runners install with `dev install-deps`.
require "dev/deps"

Dev::Deps.define do
  ruby "3.3.10"

  # Runtime: sorbet-runtime backs the inline sigs and sealed result
  # hierarchies. The dispatcher runs through `dev`, so runners install
  # this like any other locked dependency.
  gem "sorbet-runtime"

  group(:development) do
    gem "sorbet"
    gem "tapioca", require: false
    gem "rubocop", require: false
    gem "rubocop-shopify", require: false
    gem "rubocop-sorbet", require: false
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

  # The headless Cursor agent CLI the dispatcher spawns — a runtime
  # dependency like sorbet-runtime, hence :app (Gemfile convention: the
  # default group is what the software needs to run). Converging this
  # checkout (`dev up`) is what makes a box agent-capable. The CLI is
  # dual-homed by design: the org baseline also carries it as org-wide
  # human dev tooling. Installed via the upstream homebrew-cask package,
  # world-readable under /opt/homebrew (the isolated agent user reads it
  # with no extra grants); AI_FLOW_AGENT_BIN points at the Caskroom's
  # stable bin/cursor-agent symlink. darwin-gated: agent jobs route to
  # Mac runners.
  group(:app, host: :darwin) do
    brew "cursor-cli", cask: true
  end
end
