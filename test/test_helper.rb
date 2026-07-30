# typed: true
# frozen_string_literal: true

# SimpleCov must start before any application code loads so every file is
# tracked; the cobertura report is what CI uploads to Codecov (Codecov's
# parser rejects SimpleCov's JSON once simplecov-sorbet marks lines skipped).
# simplecov/sorbet skips type-level Sorbet constructs (T.type_alias/sig
# blocks, T.absurd) so they never read as coverage misses. sorbet-runtime is
# a gem (not tracked code) and its T must exist before the config block runs.
require "sorbet-runtime"
require "simplecov"
require "simplecov-cobertura"

SimpleCov.start do
  # T.unsafe: SimpleCov instance_evals this block against its configuration
  # object, a rebinding Sorbet cannot see statically.
  T.unsafe(self).skip("/test/")
  T.unsafe(self).formatter(SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::CoberturaFormatter,
  ]))
end

require "simplecov/sorbet"

AI_FLOW_ROOT = File.expand_path("..", __dir__) unless defined?(AI_FLOW_ROOT)
$LOAD_PATH.unshift(File.join(AI_FLOW_ROOT, "lib")) unless $LOAD_PATH.include?(File.join(AI_FLOW_ROOT, "lib"))

require "ai_flow"
require "minitest"

begin
  require "minitest/reporters"
  Minitest::Reporters.use!
rescue LoadError
  # minitest-reporters not installed
end

Minitest.autorun
