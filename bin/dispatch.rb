#!/usr/bin/env ruby
# typed: strict
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

# Built first: from_env removes the App private key from the process
# environment, so every subprocess spawned after this line (the agent above
# all) sees only short-lived installation tokens, never the key.
token_provider = AiFlow::TokenProvider.from_env

executor = AiFlow::Executor.new(token_provider: token_provider)

# Group-rw from creation: under the OS-user split (plans#26) the dispatcher's
# own writes into shared checkouts and workspaces must stay readable and
# writable across the UID boundary.
File.umask(0o002) if executor.isolation

github = AiFlow::GitHub.new(executor: executor)
prefix = ENV.fetch("AI_FLOW_COMMAND_PREFIX", "")

# A submitted review is one command surface carrying N comment bodies
# (ai-flow#73): expand it into per-comment dispatches and run them all in
# this one job — sequential, so the per-PR concurrency group can no longer
# evict sibling commands. Every context runs even when an earlier one
# failed; any failure still turns the run red at the end.
contexts = AiFlow::ReviewUnit.new(context: context, github: github, prefix: prefix).contexts
results = contexts.map do |dispatch_context|
  AiFlow::Dispatcher.new(
    context: dispatch_context,
    workdir: ENV.fetch("AI_FLOW_WORKDIR", Dir.pwd),
    prefix: prefix,
    executor: executor,
    github: github,
  ).run
end
exit 1 unless results.all?
