#!/usr/bin/env ruby
# typed: strict
# frozen_string_literal: true

# Origin-firing check entry point, invoked by
# .github/workflows/origin-firing.yml on a learning repo's pull requests.
# Reads the PR payload from GITHUB_EVENT_PATH, re-runs retrieval against the
# proposal's origin context, and fails the job when a changed learning's cue
# does not fire. See lib/ai_flow/proposal_checks.rb.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

$stdout.sync = true

require "ai_flow"
require "json"

event = JSON.parse(File.read(ENV.fetch("GITHUB_EVENT_PATH")))
pull_request = event.fetch("pull_request")

# Built first: from_env removes the App private key from the process
# environment before the agent subprocess is spawned (same order as
# bin/dispatch.rb).
token_provider = AiFlow::TokenProvider.from_env
executor = AiFlow::Executor.new(token_provider: token_provider)

result = AiFlow::ProposalChecks.new(
  github: AiFlow::GitHub.new(executor: executor),
  agent: AiFlow::Agent.new(executor: executor),
  executor: executor,
).origin_firing(
  workdir: ENV.fetch("AI_FLOW_WORKDIR", Dir.pwd),
  pr_body: pull_request["body"].to_s,
  base_ref: pull_request.fetch("base").fetch("ref"),
)

# This boundary owns the CI verdict and its rendering: a Skip is green
# (out-of-scope PRs must not block), and only checked results carry the
# slug listings.
lines, green =
  case result
  when AiFlow::ProposalChecks::Result::Pass
    [["✅ origin-firing (pass): #{result.detail}",
      "changed learnings: #{result.new_slugs.join(", ")}",
      "fired on origin: #{result.fired.empty? ? "(none)" : result.fired.join(", ")}"], true]
  when AiFlow::ProposalChecks::Result::Fail
    [["❌ origin-firing (fail): #{result.detail}",
      "changed learnings: #{result.new_slugs.join(", ")}",
      "fired on origin: #{result.fired.empty? ? "(none)" : result.fired.join(", ")}"], false]
  when AiFlow::ProposalChecks::Result::Skip
    [["ℹ️ origin-firing (skip): #{result.detail}"], true]
  else
    T.absurd(result)
  end

report = lines.join("\n")
puts report
step_summary = ENV["GITHUB_STEP_SUMMARY"]
File.write(step_summary, "#{report}\n", mode: "a") if step_summary

exit(green ? 0 : 1)
