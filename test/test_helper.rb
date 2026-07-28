# typed: true
# frozen_string_literal: true

# SimpleCov must start before any application code loads so every file is
# tracked; the JSON report is what CI uploads to Codecov. sorbet-runtime is
# a gem (not tracked code) and its T must exist before the config block runs.
require "sorbet-runtime"
require "simplecov"
require "simplecov_json_formatter"

SimpleCov.start do
  # T.unsafe: SimpleCov instance_evals this block against its configuration
  # object, a rebinding Sorbet cannot see statically.
  T.unsafe(self).add_filter("/test/")
  T.unsafe(self).formatter SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::JSONFormatter,
  ])
end

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
