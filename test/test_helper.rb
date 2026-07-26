# frozen_string_literal: true

# SimpleCov must start before any application code loads so every file is
# tracked; the JSON report is what CI uploads to Codecov.
require "simplecov"
require "simplecov_json_formatter"

SimpleCov.start do
  add_filter("/test/")
  formatter SimpleCov::Formatter::MultiFormatter.new([
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
