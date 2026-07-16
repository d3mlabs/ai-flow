# frozen_string_literal: true

require "json"

module AiFlow
  # The one seam through which every command runs the Cursor agent (see the
  # ai-flow plan, Decision 4): today it wraps the headless `agent` CLI on the
  # self-hosted runner; an alternative backend (e.g. the cloud REST API) would
  # be a change here, not in the four command scripts.
  #
  # Invocation details owned here: binary path (AI_FLOW_AGENT_BIN), per-command
  # model policy (MODELS), working directory, prompt passing, output parsing.
  # Runaway runs are bounded by the workflow job's timeout-minutes, not here.
  class Agent
    class Error < StandardError; end

    # Per-command model policy — the fine model/mode control that motivated
    # self-hosting (one-file change, per the plan). nil = the CLI's default.
    # Override per run with AI_FLOW_MODEL.
    MODELS = {
      "ask" => nil,
      "edit" => nil,
      "split" => nil,
      "build" => nil,
    }.freeze

    # @param executor [AiFlow::Executor]
    def initialize(executor: Executor.new)
      @executor = executor
    end

    # Run the headless agent to completion and return its final answer text.
    #
    # @param prompt [String]
    # @param workdir [String] repo checkout the agent works in
    # @param command [String] ai-flow command name, for model policy
    # @param force [Boolean] allow file edits/commands without approval (used
    #   by /edit-on-PR and /build, which work in disposable worktrees)
    # @return [String] the agent's result text
    # @raise [Error] when the agent fails
    def launch(prompt:, workdir:, command:, force: false)
      # --trust: headless runs can't answer the workspace-trust prompt, and the
      # workdir is always a CI checkout of a repo we dispatched for.
      argv = [binary, "-p", "--output-format", "json", "--trust"]
      model = ENV["AI_FLOW_MODEL"] || MODELS[command]
      argv += ["--model", model] if model
      argv << "--force" if force

      out, err, ok = @executor.capture(*argv, stdin: prompt, chdir: workdir)
      raise Error, "agent CLI not found — install the Cursor agent CLI on this runner" if err.include?("No such file")
      raise Error, "agent run failed: #{err.strip.empty? ? out.strip : err.strip}" unless ok

      parse_result(out)
    end

    private

    # @return [String]
    def binary
      ENV.fetch("AI_FLOW_AGENT_BIN", "agent")
    end

    # The CLI emits a JSON envelope with the final text in "result"; fall back
    # to raw stdout so a format drift degrades gracefully instead of failing.
    #
    # @param out [String]
    # @return [String]
    def parse_result(out)
      parsed = JSON.parse(out)
      parsed.is_a?(Hash) ? (parsed["result"] || parsed["text"] || out).to_s : out
    rescue JSON::ParserError
      out
    end
  end
end
