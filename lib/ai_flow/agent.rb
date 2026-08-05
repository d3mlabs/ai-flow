# typed: strict
# frozen_string_literal: true

require "bundler"
require "json"

module AiFlow
  # The one seam through which every command runs the Cursor agent (see the
  # ai-flow plan, Decision 4): today it wraps the headless `agent` CLI on the
  # self-hosted runner; an alternative backend (e.g. the cloud REST API) would
  # be a change here, not in the four command scripts.
  #
  # Invocation details owned here: binary path (AI_FLOW_AGENT_BIN), model
  # resolution (repo config via RepoConfig, env override), working
  # directory, prompt passing, output parsing. Runaway runs are bounded by
  # the workflow job's timeout-minutes, not here. ai-flow code carries no
  # model opinion of its own: per-repo policy lives in .github/ai-flow.yml
  # (see RepoConfig), and no policy means the CLI's account default.
  class Agent
    extend T::Sig

    class Error < StandardError; end

    # What each command actually ran on — every launch's selection, in
    # order, grouped by command. Keying a single selection per command let
    # a later launch erase an earlier one (#49: the promote pass overwrote
    # the drafting pass's name in the footer). Feeds the ResultWriter
    # footer's model note, which dedupes for display.
    #
    # @return [Hash{AiFlow::Command => Array<AiFlow::ModelSelection>}]
    sig { returns(T::Hash[Command, T::Array[ModelSelection]]) }
    attr_reader :models_used

    # Skill and rule reads observed in the event stream — the loop's own
    # telemetry (whether a learning actually gets consulted feeds later
    # retire decisions). Feeds the dispatcher's GITHUB_STEP_SUMMARY list.
    #
    # @return [Array<String>] deduped names, in first-read order
    sig { returns(T::Array[String]) }
    attr_reader :knowledge_applied

    # A read under one of these paths is knowledge consumption, not generic
    # file reading: on-demand skills (installed user-globally by dev) and a
    # project's Cursor rules (learnings-index.mdc, committed conventions).
    KNOWLEDGE_PATH_PATTERNS = T.let(
      [
        %r{\.cursor/skills/([^/]+)/},
        %r{\.cursor/rules/([^/]+)\.mdc\z},
      ].freeze,
      T::Array[Regexp],
    )

    # @param executor [AiFlow::Executor]
    sig { params(executor: Executor).void }
    def initialize(executor: Executor.new)
      @executor = executor
      @models_used = T.let({}, T::Hash[Command, T::Array[ModelSelection]])
      @knowledge_applied = T.let([], T::Array[String])
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
    # @param command [AiFlow::Command] the policy the pass runs under
    # @param repos [Array<String>] the "owner/repo" set this pass may touch —
    #   its GH_TOKEN is downscoped to exactly this list (plans#25), so every
    #   launch site declares its blast radius explicitly
    # @param force [Boolean] allow file edits/commands without approval (used
    #   by /edit-on-PR and /build, which work in disposable worktrees)
    # @param policy_root [String] the checkout whose .github/ai-flow.yml
    #   governs the pass — the workdir unless the pass executes on behalf of
    #   another repo's request (a /learn promote pass runs in the knowledge
    #   clone under the source repo's policy, #49)
    # @return [String] the agent's result text
    # @raise [Error] when the agent fails
    sig do
      params(
        prompt: String,
        workdir: String,
        command: Command,
        repos: T::Array[String],
        force: T::Boolean,
        policy_root: String,
      ).returns(String)
    end
    def launch(prompt:, workdir:, command:, repos:, force: false, policy_root: workdir)
      # --trust: headless runs can't answer the workspace-trust prompt, and the
      # workdir is always a CI checkout of a repo we dispatched for.
      argv = [binary, "-p", "--output-format", "stream-json", "--trust"]
      selection = model_for(command, policy_root)
      (@models_used[command] ||= []) << selection
      # Display names speak the comment vocabulary, so they come from the
      # parser's table.
      word = CommentParser.word_for(command)
      # Ungrouped so the effective model is scannable on the run page next
      # to the config + --list-models printout from the Log versions step.
      $stdout.puts "ai-flow model (/#{word}): #{log_label(selection)}"
      case selection
      when ModelSelection::Named
        argv += ["--model", selection.handle]
      when ModelSelection::AccountDefault
        nil # no --model flag; the CLI applies its account default
      else
        T.absurd(selection)
      end
      argv << "--force" if force

      log_group("ai-flow agent prompt (/#{word})", prompt)
      $stdout.puts "ai-flow agent token scope (/#{word}): #{repos.join(", ")}"
      result = T.let(nil, T.nilable(String))
      assistant_texts = T.let([], T::Array[String])
      # The env: overlay wins over the executor's default auth injection, so
      # this is what replaces the installation-wide token with the scoped one
      # for the agent subprocess.
      scoped_env = @executor.scoped_auth_env(repositories: repos)
      # T.unsafe: splatting a runtime-built argv into stream's rest param is
      # beyond Sorbet's static splat support (srb.help/7019).
      err, ok = T.unsafe(@executor).stream(*argv, stdin: prompt, chdir: workdir, env: scoped_env) do |line|
        event = parse_event(line)
        result = event["result"].to_s if event && event["type"] == "result"
        render_event(word, line, event, assistant_texts)
      end

      # The stream already scrolled by live, so the post-hoc groups carry
      # only the prompt (above), the final text, and any stderr.
      final_text = result || assistant_texts.join("\n\n")
      log_group("ai-flow agent final result (/#{word})", final_text)
      log_group("ai-flow agent stderr (/#{word})", err) unless err.strip.empty?
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
    # .github/ai-flow.yml) > AccountDefault. Absence exists inside the
    # chain (config keys are optional) but dies at this return: callers
    # always receive a ModelSelection, never nil. Public and pure: the
    # dispatcher calls it pre-launch to predict the model for the ⏳
    # status line.
    #
    # @param command [AiFlow::Command]
    # @param workdir [String]
    # @return [AiFlow::ModelSelection]
    sig { params(command: Command, workdir: String).returns(ModelSelection) }
    def model_for(command, workdir)
      config = RepoConfig.load(workdir)
      env_selection || config.models[command] || config.default_model || ModelSelection::AccountDefault.new
    end

    private

    # The AI_FLOW_MODEL override coerced at its boundary: blank is unset.
    #
    # @return [AiFlow::ModelSelection::Named, nil]
    sig { returns(T.nilable(ModelSelection::Named)) }
    def env_selection
      handle = ENV["AI_FLOW_MODEL"].to_s.strip
      handle.empty? ? nil : ModelSelection::Named.new(handle)
    end

    # This boundary's rendering of a selection — the run-log vocabulary.
    #
    # @param selection [AiFlow::ModelSelection]
    # @return [String]
    sig { params(selection: ModelSelection).returns(String) }
    def log_label(selection)
      case selection
      when ModelSelection::Named then selection.handle
      when ModelSelection::AccountDefault then "(CLI account default)"
      else T.absurd(selection)
      end
    end

    # @param line [String] one NDJSON line from the stream
    # @return [Hash, nil] nil when the line isn't a JSON event (format drift)
    sig { params(line: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def parse_event(line)
      parsed = JSON.parse(line)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    # One concise progress line per event, printed as it arrives. Unknown
    # event types print nothing (CLI additions must never break a run);
    # unparseable lines print raw so a format drift degrades to noise, not
    # silence. The `[/word]` prefix names the policy the pass runs
    # under — a batch is a single pass (as /edit when any edit is present),
    # and /build --split runs one /build pass per sub-issue.
    #
    # @param word [String] the command's comment word, for the line prefix
    # @param line [String] the raw NDJSON line
    # @param event [Hash, nil] the parsed event
    # @param assistant_texts [Array<String>] accumulator for the result
    #   fallback when the stream ends without a terminal result event
    sig do
      params(
        word: String,
        line: String,
        event: T.nilable(T::Hash[String, T.untyped]),
        assistant_texts: T::Array[String],
      ).void
    end
    def render_event(word, line, event, assistant_texts)
      unless event
        $stdout.puts line.chomp unless line.strip.empty?
        return
      end

      case event["type"]
      when "system"
        $stdout.puts "[/#{word}] session started (model: #{event["model"]})" if event["subtype"] == "init"
      when "assistant"
        text = event.dig("message", "content", 0, "text").to_s
        return if text.empty?

        assistant_texts << text
        $stdout.puts "[/#{word}] assistant: #{truncate(text.lines.first.to_s.strip)}"
      when "tool_call"
        return unless event["subtype"] == "started"

        knowledge = knowledge_name(event)
        if knowledge
          @knowledge_applied << knowledge unless @knowledge_applied.include?(knowledge)
          $stdout.puts "[/#{word}] knowledge: #{knowledge}"
        else
          $stdout.puts "[/#{word}] → #{tool_summary(event)}"
        end
      end
    end

    # The knowledge name when the event is a file read under a skill or rule
    # path: the skill's slug (its directory) or the rule's basename.
    #
    # @param event [Hash] a tool_call event
    # @return [String, nil] nil for every other tool call
    sig { params(event: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
    def knowledge_name(event)
      kind, payload = (event["tool_call"] || {}).find { |key, _value| key.end_with?("ToolCall") }
      return nil unless kind == "readToolCall"

      path = payload.is_a?(Hash) ? (payload["args"] || {})["path"].to_s : ""
      KNOWLEDGE_PATH_PATTERNS.each do |pattern|
        match = pattern.match(path)
        return match[1] if match
      end
      nil
    end

    # "shell: bundle exec rake test", "read: lib/thing.rb", or the bare tool
    # name when no headline argument is recognizable. The tool kind is the
    # one `*ToolCall` key of the event's tool_call object (observed shape,
    # matching the CLI reference).
    #
    # @param event [Hash] a tool_call event
    # @return [String]
    sig { params(event: T::Hash[String, T.untyped]).returns(String) }
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
    sig { params(text: String, max: Integer).returns(String) }
    def truncate(text, max = 120)
      text.length > max ? "#{text[0, max - 1]}…" : text
    end

    # @param title [String]
    # @param content [String]
    # @return [void]
    sig { params(title: String, content: String).void }
    def log_group(title, content)
      $stdout.puts "::group::#{title}"
      $stdout.puts content
      $stdout.puts "::endgroup::"
    end

    # @return [String]
    sig { returns(String) }
    def binary
      ENV.fetch("AI_FLOW_AGENT_BIN", "agent")
    end
  end
end
