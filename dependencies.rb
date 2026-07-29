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
  end

  group(:test) do
    gem "minitest"
    gem "minitest-reporters"
    gem "rake"
    gem "rspock", "~> 3.0"
    gem "simplecov", "~> 1.0"
    # Skips type-level Sorbet constructs (T.type_alias/sig blocks, T.absurd)
    # so they never read as coverage misses.
    gem "simplecov-sorbet", "~> 0.2", require: false
  end
end
