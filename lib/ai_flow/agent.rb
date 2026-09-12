# typed: strict
# frozen_string_literal: true

require "bundler"
require "json"

module AiFlow
  # The one seam through which every command runs the Cursor agent (see the
  # ai-flow plan, Decision 4): it drives the `agent` CLI's ACP server
  # (`agent acp`, plans#33) on the self-hosted runner; an alternative
  # backend (e.g. the cloud REST API) would be a change here, not in the
  # four command scripts.
  #
  # Invocation details owned here: binary path (AI_FLOW_AGENT_BIN), model
  # resolution (repo config via RepoConfig, env override) and its catalog
  # handoff to the ACP session, working directory, prompt passing, the
  # permission-request policy (force allows, non-force rejects mutating
  # kinds — the tool gate's successor to the old --force flag), and
  # progress rendering from session updates. Runaway runs are bounded by
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

    # Boundary wants surfaced across this run's launches (plans#33):
    # declared WANTED lines extracted from final texts (and later, observed
    # denials). Feeds the dispatcher's step summary and the result panel.
    #
    # @return [Array<AiFlow::Denials::Want>] deduped, first-seen order
    sig { returns(T::Array[Denials::Want]) }
    attr_reader :wants

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

    # The ACP tool kinds a non-force pass may allow — reads of the world,
    # never changes to it. An allowlist, not a mutating-kinds blocklist:
    # a kind this list has never seen (protocol additions, "other") fails
    # closed and surfaces as a want instead of silently passing. force
    # passes allow everything — the boundary is the OS user, plans#26 —
    # same stance as the old --force flag.
    READONLY_TOOL_KINDS = T.let(%w[read search fetch think].freeze, T::Array[String])

    # @param executor [AiFlow::Executor]
    sig { params(executor: Executor).void }
    def initialize(executor: Executor.new)
      @executor = executor
      @models_used = T.let({}, T::Hash[Command, T::Array[ModelSelection]])
      @knowledge_applied = T.let([], T::Array[String])
      @wants = T.let([], T::Array[Denials::Want])
    end

    # Run the agent to completion over ACP and return its final answer text.
    #
    # The CLI runs as an ACP server (`agent acp`, JSON-RPC over stdio) and
    # every session update prints as a concise progress line the moment it
    # arrives — the Actions run page live-streams a running step's stdout,
    # so this is what makes "follow the run" worth following.
    #
    # @param prompt [String]
    # @param workdir [String] repo checkout the agent works in
    # @param command [AiFlow::Command] the policy the pass runs under
    # @param force [Boolean] answer permission requests with allow (used by
    #   /edit-on-PR and /build, which work in disposable worktrees); a
    #   non-force pass rejects mutating tool kinds per request
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
        force: T::Boolean,
        policy_root: String,
      ).returns(String)
    end
    def launch(prompt:, workdir:, command:, force: false, policy_root: workdir)
      selection = model_for(command, policy_root)
      (@models_used[command] ||= []) << selection
      # Display names speak the comment vocabulary, so they come from the
      # parser's table.
      word = CommentParser.word_for(command)
      # Ungrouped so the effective model is scannable on the run page next
      # to the config printout from the Log versions step.
      $stdout.puts "ai-flow model (/#{word}): #{log_label(selection)}"
      # The handle crosses into the session via the ACP catalog — the
      # global --model flag does not apply to ACP sessions.
      handle = case selection
               when ModelSelection::Named then selection.handle
               when ModelSelection::AccountDefault then nil
               else T.absurd(selection)
               end

      # The denial-surfacing contract (plans#33) rides every isolated
      # launch here — the one seam all commands cross — so no command can
      # forget it and non-split hosts see zero prompt change.
      contract = Denials.prompt_contract(@executor.isolation)
      prompt = "#{prompt}\n\n#{contract}" unless contract.empty?

      log_group("ai-flow agent prompt (/#{word})", prompt)
      $stdout.puts "ai-flow agent token (/#{word}): read-only, installation-wide (plans#25)"
      posture = @executor.isolation
      $stdout.puts "ai-flow agent spawn (/#{word}): " \
        "#{posture ? "user=#{posture.user} (plans#26)" : "user=(dispatcher)"} transport=acp"
      chunks = T.let([], T::Array[String])
      stop_reason = T.let(nil, T.nilable(String))
      protocol_error = T.let(nil, T.nilable(AcpClient::ProtocolError))
      # The env: overlay wins over the executor's default auth injection, so
      # this is what replaces the dispatcher's full-permission token with the
      # read-only one for the agent subprocess.
      agent_env = @executor.agent_auth_env
      err, _ok = @executor.duplex(binary, "acp", chdir: workdir, env: agent_env, isolate: true) do |to_agent, from_agent|
        client = AcpClient.new(
          input: from_agent,
          output: to_agent,
          on_update: ->(params) { render_update(word, params, chunks) },
          on_permission: ->(params) { decide_permission(word, params, force) },
        )
        begin
          stop_reason = client.run(prompt: prompt, cwd: workdir, model: handle)
        rescue AcpClient::ProtocolError => e
          # Captured, not raised: the transport must still close down and
          # surface its stderr before the failure story is told.
          protocol_error = e
        end
      end

      # The updates already scrolled by live, so the post-hoc groups carry
      # only the prompt (above), the final text, and any stderr.
      final_text = chunks.join
      log_group("ai-flow agent final result (/#{word})", final_text)
      # Declared wants come out of the text before anything downstream
      # parses it, so segment blocks and FIRED: lines never carry them.
      declared, final_text = Denials.extract_declared(final_text)
      declared.each { |want| record_want(word, want) }
      log_group("ai-flow agent stderr (/#{word})", err) unless err.strip.empty?
      raise Error, "agent CLI not found — install the Cursor agent CLI on this runner" if err.include?("No such file")

      if protocol_error
        detail = [protocol_error.message, err.strip.empty? ? nil : "stderr: #{err.strip}"].compact.join("; ")
        raise Error, "agent run failed: #{detail}"
      end
      # A completed turn is the success criterion; transport exit noise
      # after end_turn (e.g. a lingering server the reap killed) is logged
      # above but not fatal.
      unless stop_reason == "end_turn"
        detail = err.strip.empty? ? final_text.strip : err.strip
        detail = "see the streamed agent log above" if detail.empty?
        raise Error, "agent run failed (stop: #{stop_reason || "none"}): #{detail}"
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

    # One concise progress line per session update, printed as it arrives.
    # Unknown update kinds print nothing (protocol additions must never
    # break a run). The `[/word]` prefix names the policy the pass runs
    # under — a batch is a single pass (as /edit when any edit is present),
    # and /build --split runs one /build pass per sub-issue.
    #
    # Message chunks accumulate silently (they are stream fragments, not
    # lines; the final-result log group carries the whole text) — tool
    # calls are the live progress signal.
    #
    # @param word [String] the command's comment word, for the line prefix
    # @param params [Hash] a session/update notification's params
    # @param chunks [Array<String>] accumulator for the final answer text
    sig do
      params(
        word: String,
        params: T::Hash[String, T.untyped],
        chunks: T::Array[String],
      ).void
    end
    def render_update(word, params, chunks)
      update = T.let(params["update"] || {}, T::Hash[String, T.untyped])
      case update["sessionUpdate"]
      when "agent_message_chunk"
        text = update.dig("content", "text").to_s
        chunks << text unless text.empty?
      when "tool_call"
        knowledge = knowledge_name(update)
        if knowledge
          @knowledge_applied << knowledge unless @knowledge_applied.include?(knowledge)
          $stdout.puts "[/#{word}] knowledge: #{knowledge}"
        else
          $stdout.puts "[/#{word}] → #{tool_summary(update)}"
        end
      when "tool_call_update"
        # The observed denial channel (plans#33): a permission wall in a
        # tool's output surfaces even when the agent doesn't declare it.
        update_texts(update).each do |text|
          Denials.observed_in(text).each { |want| record_want(word, want) }
        end
      end
    end

    # One want per subject, whatever the channel mix: a declared want (the
    # agent's own articulate reason) replaces an observed pattern-match on
    # the same subject; anything else first-seen wins.
    #
    # @param word [String] the command word, for the log line
    # @param want [AiFlow::Denials::Want]
    # @return [void]
    sig { params(word: String, want: Denials::Want).void }
    def record_want(word, want)
      existing = @wants.find { |seen| seen.subject == want.subject }
      if existing
        return unless want.channel == :declared && existing.channel == :observed

        @wants.delete(existing)
      end
      @wants << want
      $stdout.puts "[/#{word}] wanted (#{want.channel}): #{want.subject}"
    end

    # The text bodies of a tool_call_update: the spec's content-block
    # wrapper (one level deep) and the live CLI's rawOutput stdout/stderr
    # (cursor-agent 2026.08.11 sends denials there — probed 2026-09-12,
    # a manual run the content-block-only reader missed).
    #
    # @param update [Hash] a tool_call_update payload
    # @return [Array<String>]
    sig { params(update: T::Hash[String, T.untyped]).returns(T::Array[String]) }
    def update_texts(update)
      texts = T.let([], T::Array[String])
      content = update["content"]
      if content.is_a?(Array)
        content.each do |item|
          next unless item.is_a?(Hash)

          inner = item["content"]
          text = inner.is_a?(Hash) ? inner["text"] : item["text"]
          texts << text.to_s unless text.to_s.empty?
        end
      end
      raw = update["rawOutput"]
      if raw.is_a?(Hash)
        %w[stdout stderr output].each do |key|
          value = raw[key]
          texts << value if value.is_a?(String) && !value.empty?
        end
      end
      texts
    end

    # The knowledge name when the update is a file read under a skill or
    # rule path: the skill's slug (its directory) or the rule's basename.
    #
    # @param update [Hash] a tool_call update payload
    # @return [String, nil] nil for every other tool call
    sig { params(update: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
    def knowledge_name(update)
      return nil unless update["kind"].to_s == "read"

      path = tool_path(update)
      KNOWLEDGE_PATH_PATTERNS.each do |pattern|
        match = pattern.match(path)
        return match[1] if match
      end
      nil
    end

    # The path a tool call touches: the first location, or the rawInput
    # path when locations are absent.
    #
    # @param update [Hash] a tool_call / tool_call_update payload
    # @return [String] "" when the update carries no path
    sig { params(update: T::Hash[String, T.untyped]).returns(String) }
    def tool_path(update)
      update.dig("locations", 0, "path").to_s.then do |located|
        located.empty? ? update.dig("rawInput", "path").to_s : located
      end
    end

    # The tool call's own title ("Read file …", "$ rake test"), the kind as
    # fallback — ACP titles are already human-composed.
    #
    # @param update [Hash] a tool_call update payload
    # @return [String]
    sig { params(update: T::Hash[String, T.untyped]).returns(String) }
    def tool_summary(update)
      title = update["title"].to_s
      return truncate(title) unless title.empty?

      kind = update["kind"].to_s
      kind.empty? ? "tool call" : kind
    end

    # The permission-request policy (plans#33, decision 2): force passes
    # allow everything — the boundary is the OS user, not the tool gate,
    # exactly like the old --force flag; non-force passes allow only the
    # read-only kinds and reject the rest (unknown kinds fail closed).
    #
    # @param word [String] the command word, for the log line
    # @param params [Hash] the session/request_permission params
    # @param force [Boolean]
    # @return [Symbol] :allow or :reject
    sig do
      params(
        word: String,
        params: T::Hash[String, T.untyped],
        force: T::Boolean,
      ).returns(Symbol)
    end
    def decide_permission(word, params, force)
      kind = params.dig("toolCall", "kind").to_s
      title = params.dig("toolCall", "title").to_s
      if force || READONLY_TOOL_KINDS.include?(kind)
        $stdout.puts "[/#{word}] permission: allow #{kind.empty? ? "tool" : kind} (#{truncate(title)})"
        :allow
      else
        $stdout.puts "[/#{word}] permission: reject #{kind} (#{truncate(title)}) — non-force pass"
        # Deny-with-context is a natural WANTED carrier (plans#33,
        # decision 2): the request names exactly what was blocked.
        record_want(word, Denials::Want.new(
          subject: title.empty? ? kind : title,
          reason: "permission request rejected (non-force pass)",
          channel: :observed,
        ))
        :reject
      end
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
