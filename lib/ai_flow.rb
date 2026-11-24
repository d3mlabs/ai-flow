# typed: strict
# frozen_string_literal: true

# The one place the type system's runtime enters: everything under lib/
# assumes T/sig exist because this file loaded first. dev installs the
# released tree self-contained, the gem converged into it (exe/ai-flow
# selects it); a checkout gets it from `dev up`.
require "sorbet-runtime"

require "ai_flow/value_equality"
require "ai_flow/command"
require "ai_flow/model_selection"
require "ai_flow/token_provider"
require "ai_flow/harness_env"
require "ai_flow/runner_slot"
require "ai_flow/host_posture"
require "ai_flow/agent_isolation"
require "ai_flow/denials"
require "ai_flow/executor"
require "ai_flow/workspace_provisioner"
require "ai_flow/github"
require "ai_flow/provenance"
require "ai_flow/repo_config"
require "ai_flow/persistent_workspace"
require "ai_flow/acp_client"
require "ai_flow/agent"
require "ai_flow/agent_output"
require "ai_flow/comment_parser"
require "ai_flow/commit_identity"
require "ai_flow/rebase"
require "ai_flow/context"
require "ai_flow/plan_body"
require "ai_flow/subtasks_section"
require "ai_flow/rich_diff"
require "ai_flow/result_writer"
require "ai_flow/org_invariants"
require "ai_flow/proposal_checks"
require "ai_flow/commands/batch"
require "ai_flow/commands/split"
require "ai_flow/commands/build"
require "ai_flow/commands/build_split"
require "ai_flow/commands/learn"
require "ai_flow/dispatcher"
require "ai_flow/review_unit"
require "ai_flow/adoption"
require "ai_flow/adoption/caller_workflow"
require "ai_flow/adoption/repo_config_file"
require "ai_flow/adoption/secret_access"
require "ai_flow/adoption/app_installation"
require "ai_flow/cli"
require "ai_flow/cli/job"
require "ai_flow/cli/dispatch"
require "ai_flow/cli/gate"
require "ai_flow/cli/adopt"

# ai-flow: GitHub-side slash commands (/ask, /edit, /split, /build) that run
# the headless Cursor agent on self-hosted runners. See README.md.
module AiFlow
end
