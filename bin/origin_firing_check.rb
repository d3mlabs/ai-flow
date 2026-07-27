#!/usr/bin/env ruby
# frozen_string_literal: true

# Origin-firing check entry point, invoked by
# .github/workflows/origin-firing.yml on a learning repo's pull requests.
# Reads the PR payload from GITHUB_EVENT_PATH, re-runs retrieval against the
# draft's origin context, and fails the job when a changed learning's cue
# does not fire. See lib/ai_flow/draft_checks.rb.

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

result = AiFlow::DraftChecks.new(
  github: AiFlow::GitHub.new(executor: executor),
  agent: AiFlow::Agent.new(executor: executor),
  executor: executor,
).origin_firing(
  workdir: ENV.fetch("AI_FLOW_WORKDIR", Dir.pwd),
  pr_body: pull_request["body"].to_s,
  base_ref: pull_request.fetch("base").fetch("ref"),
)

icon = { pass: "✅", fail: "❌", skip: "ℹ️" }.fetch(result.status)
lines = ["#{icon} origin-firing (#{result.status}): #{result.detail}"]
lines << "changed learnings: #{result.new_slugs.join(", ")}" unless result.new_slugs.empty?
lines << "fired on origin: #{result.fired.empty? ? "(none)" : result.fired.join(", ")}" unless result.status == :skip
report = lines.join("\n")

puts report
File.write(ENV["GITHUB_STEP_SUMMARY"], "#{report}\n", mode: "a") if ENV["GITHUB_STEP_SUMMARY"]

exit(result.pass? ? 0 : 1)
