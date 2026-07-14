# frozen_string_literal: true

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
