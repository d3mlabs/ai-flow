# frozen_string_literal: true

# Entry point when running tests (-r test_loader), mirroring d3mlabs/dev:
# load path, rspock, then ASTTransform. test_helper is required by each test
# file and provides minitest.
AI_FLOW_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(AI_FLOW_ROOT, "lib")) unless $LOAD_PATH.include?(File.join(AI_FLOW_ROOT, "lib"))

require "rspock"

ASTTransform.install
