# frozen_string_literal: true

require "json"

module AiFlow
  # The one seam through which every command runs the Cursor agent (see the
  # ai-flow plan, Decision 4): today it wraps the headless `agent` CLI on the
  # self-hosted runner; an alternative backend (e.g. the cloud REST API) would
  # be a change here, not in the four command scripts.
  #
  # Invocation details owned here: binary path (AI_FLOW_AGENT_BIN), model
  # resolution (repo config via RepoConfig, env override, MODELS fallback),
  # working directory, prompt passing, output parsing. Runaway runs are
  # bounded by the workflow job's timeout-minutes, not here.
  class Agent
    class Error < StandardError; end

    # Code-level model fallback. Deliberately all-nil: ai-flow code carries
    # no model opinion — per-repo policy lives in .github/ai-flow.yml (see
    # RepoConfig), and nil means the CLI's account default.
    MODELS = {
      "ask" => nil,
      "edit" => nil,
      "split" => nil,
      "build" => nil,
    }.freeze

    # What each command actually ran on, keyed by command so a batch that
    # launches the same command repeatedly records one entry. Feeds the
    # ResultWriter footer's model note.
    #
    # @return [Hash{String => String}] command => model ("cursor default"
    #   when no policy resolved and the CLI's account default applied)
    attr_reader :models_used

    # @param executor [AiFlow::Executor]
    def initialize(executor: Executor.new)
      @executor = executor
      @models_used = {}
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
      model = model_for(command, workdir)
      @models_used[command] = model || "cursor default"
      # Ungrouped so the effective model is scannable on the run page next
      # to the config + --list-models printout from the Log versions step.
      $stdout.puts "ai-flow model (/#{command}): #{model || "(CLI account default)"}"
      argv += ["--model", model] if model
      argv << "--force" if force

      out, err, ok = @executor.capture(*argv, stdin: prompt, chdir: workdir)
      log_run(command, prompt, out, err)
      raise Error, "agent CLI not found — install the Cursor agent CLI on this runner" if err.include?("No such file")
      raise Error, "agent run failed: #{err.strip.empty? ? out.strip : err.strip}" unless ok

      parse_result(out)
    end

    # Model precedence: AI_FLOW_MODEL env (ops escape hatch on the runner
    # box) > models.<command> > models.default (both from the repo's
    # .github/ai-flow.yml) > MODELS[command] (code fallback) > nil, meaning
    # the CLI's account default. Blanks are unset per link, so e.g.
    # `build: ""` falls through to `default` rather than passing
    # `--model ""` to the CLI. Public and pure: the dispatcher calls it
    # pre-launch to predict the model for the ⏳ status line.
    #
    # @param command [String]
    # @param workdir [String]
    # @return [String, nil]
    def model_for(command, workdir)
      models = RepoConfig.load(workdir).models
      [ENV["AI_FLOW_MODEL"], models[command], models["default"], MODELS[command]]
        .map { |candidate| candidate.to_s.strip }
        .find { |candidate| !candidate.empty? }
    end

    private

    # The workflow job log is ai-flow's observability surface: every agent
    # pass logs its prompt and raw output as collapsed groups, so a bad run
    # can be diagnosed from the run page without reproducing it. `::group::`
    # is the Actions log-grouping command; the runner only processes workflow
    # commands on stdout, and outside Actions the lines are harmless.
    def log_run(command, prompt, out, err)
      log_group("ai-flow agent prompt (/#{command})", prompt)
      log_group("ai-flow agent raw output (/#{command})", out)
      log_group("ai-flow agent stderr (/#{command})", err) unless err.strip.empty?
    end

    def log_group(title, content)
      $stdout.puts "::group::#{title}"
      $stdout.puts content
      $stdout.puts "::endgroup::"
    end

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
