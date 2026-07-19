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
    # The CLI runs in stream-json mode (one NDJSON event per assistant
    # message / tool call) and each event prints as a concise progress line
    # the moment it arrives — the Actions run page live-streams a running
    # step's stdout, so this is what makes "follow the run" worth following.
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
      argv = [binary, "-p", "--output-format", "stream-json", "--trust"]
      model = model_for(command, workdir)
      @models_used[command] = model || "cursor default"
      # Ungrouped so the effective model is scannable on the run page next
      # to the config + --list-models printout from the Log versions step.
      $stdout.puts "ai-flow model (/#{command}): #{model || "(CLI account default)"}"
      argv += ["--model", model] if model
      argv << "--force" if force

      log_group("ai-flow agent prompt (/#{command})", prompt)
      result = nil
      assistant_texts = []
      err, ok = @executor.stream(*argv, stdin: prompt, chdir: workdir) do |line|
        event = parse_event(line)
        result = event["result"].to_s if event && event["type"] == "result"
        render_event(command, line, event, assistant_texts)
      end

      # The stream already scrolled by live, so the post-hoc groups carry
      # only the prompt (above), the final text, and any stderr.
      final_text = result || assistant_texts.join("\n\n")
      log_group("ai-flow agent final result (/#{command})", final_text)
      log_group("ai-flow agent stderr (/#{command})", err) unless err.strip.empty?
      raise Error, "agent CLI not found — install the Cursor agent CLI on this runner" if err.include?("No such file")
      unless ok
        detail = err.strip.empty? ? final_text.strip : err.strip
        detail = "see the streamed agent log above" if detail.empty?
        raise Error, "agent run failed: #{detail}"
      end

      final_text
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

    # @param line [String] one NDJSON line from the stream
    # @return [Hash, nil] nil when the line isn't a JSON event (format drift)
    def parse_event(line)
      parsed = JSON.parse(line)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    # One concise progress line per event, printed as it arrives. Unknown
    # event types print nothing (CLI additions must never break a run);
    # unparseable lines print raw so a format drift degrades to noise, not
    # silence. The `[/command]` prefix attributes interleaved passes — a
    # batch runs one pass per segment and /build --split fans out further.
    #
    # @param command [String]
    # @param line [String] the raw NDJSON line
    # @param event [Hash, nil] the parsed event
    # @param assistant_texts [Array<String>] accumulator for the result
    #   fallback when the stream ends without a terminal result event
    def render_event(command, line, event, assistant_texts)
      unless event
        $stdout.puts line.chomp unless line.strip.empty?
        return
      end

      case event["type"]
      when "system"
        $stdout.puts "[/#{command}] session started (model: #{event["model"]})" if event["subtype"] == "init"
      when "assistant"
        text = event.dig("message", "content", 0, "text").to_s
        return if text.empty?

        assistant_texts << text
        $stdout.puts "[/#{command}] assistant: #{truncate(text.lines.first.to_s.strip)}"
      when "tool_call"
        $stdout.puts "[/#{command}] → #{tool_summary(event)}" if event["subtype"] == "started"
      end
    end

    # "shell: bundle exec rake test", "read: lib/thing.rb", or the bare tool
    # name when no headline argument is recognizable. The tool kind is the
    # one `*ToolCall` key of the event's tool_call object (observed shape,
    # matching the CLI reference).
    #
    # @param event [Hash] a tool_call event
    # @return [String]
    def tool_summary(event)
      kind, payload = (event["tool_call"] || {}).find { |key, _value| key.end_with?("ToolCall") }
      return "tool call" unless kind

      name = kind.sub(/ToolCall\z/, "")
      args = payload.is_a?(Hash) ? (payload["args"] || {}) : {}
      detail = args["command"] || args["path"] || args["pattern"] || args["query"]
      detail ? "#{name}: #{truncate(detail.to_s)}" : name
    end

    # @param text [String]
    # @return [String] at most ~120 chars, ellipsized
    def truncate(text, max = 120)
      text.length > max ? "#{text[0, max - 1]}…" : text
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
  end
end
