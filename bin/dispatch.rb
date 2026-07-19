#!/usr/bin/env ruby
# frozen_string_literal: true

# ai-flow dispatch entry point, invoked by .github/workflows/ai-commands.yml
# on the self-hosted runner. Reads the webhook payload from GITHUB_EVENT_PATH
# and routes the comment's command(s). See README.md.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

# The Actions run page live-streams a running step's stdout; unbuffered
# writes are what make the agent's progress lines appear as they happen.
$stdout.sync = true

require "ai_flow"

context = AiFlow::Context.from_event_file(
  event_name: ENV.fetch("GITHUB_EVENT_NAME"),
  event_path: ENV.fetch("GITHUB_EVENT_PATH"),
)

AiFlow::Dispatcher.new(
  context: context,
  workdir: ENV.fetch("AI_FLOW_WORKDIR", Dir.pwd),
  prefix: ENV.fetch("AI_FLOW_COMMAND_PREFIX", ""),
).run
