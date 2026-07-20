# frozen_string_literal: true

require "ai_flow/token_provider"
require "ai_flow/executor"
require "ai_flow/github"
require "ai_flow/repo_config"
require "ai_flow/agent"
require "ai_flow/agent_output"
require "ai_flow/comment_parser"
require "ai_flow/commit_identity"
require "ai_flow/context"
require "ai_flow/plan_body"
require "ai_flow/subtasks_section"
require "ai_flow/rich_diff"
require "ai_flow/result_writer"
require "ai_flow/commands/batch"
require "ai_flow/commands/split"
require "ai_flow/commands/build"
require "ai_flow/commands/build_split"
require "ai_flow/dispatcher"

# ai-flow: GitHub-side slash commands (/ask, /edit, /split, /build) that run
# the headless Cursor agent on self-hosted runners. See README.md.
module AiFlow
end
