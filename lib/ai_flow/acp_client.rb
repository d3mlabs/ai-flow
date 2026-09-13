# typed: strict
# frozen_string_literal: true

require "json"

module AiFlow
  # A hand-rolled Agent Client Protocol client (plans#33, spike attached to
  # plans#26): JSON-RPC 2.0 over the agent process's stdio, newline-
  # delimited. Deliberately dependency-free — the protocol usage here is
  # strictly sequential (each request awaits its response; notifications
  # and agent-initiated requests are dispatched inside the wait), so a
  # single read loop suffices and no acpx/Node sidecar is needed.
  #
  # The client owns protocol mechanics only: framing, request/response
  # correlation, model resolution against the session catalog, and the
  # permission-request exchange. What the updates mean (progress lines,
  # knowledge telemetry, observed denials) and what a permission decision
  # should be are the caller's business, injected as callbacks.
  class AcpClient
    extend T::Sig

    # The protocol conversation broke: the agent answered with a JSON-RPC
    # error, ended the stream mid-request, offered no usable permission
    # option, or the model handle didn't resolve against the catalog.
    class ProtocolError < StandardError; end

    PROTOCOL_VERSION = 1

    # @param input [IO] the agent's stdout (read side)
    # @param output [IO] the agent's stdin (write side)
    # @param on_update [Proc] receives every session/update's params
    # @param on_permission [Proc] receives a session/request_permission's
    #   params, returns :allow or :reject
    sig do
      params(
        input: IO,
        output: IO,
        on_update: T.proc.params(params: T::Hash[String, T.untyped]).void,
        on_permission: T.proc.params(params: T::Hash[String, T.untyped]).returns(Symbol),
      ).void
    end
    def initialize(input:, output:, on_update:, on_permission:)
      @input = input
      @output = output
      @on_update = on_update
      @on_permission = on_permission
      @next_id = T.let(0, Integer)
    end

    # The whole conversation: initialize, open a session in cwd, select the
    # model when one is configured (the global --model flag does not apply
    # to ACP sessions — verified live 2026-09-12), then prompt and stream
    # until the turn ends.
    #
    # @param prompt [String]
    # @param cwd [String] the session's working directory
    # @param model [String, nil] a configured handle (resolved against the
    #   session catalog); nil rides the account default
    # @return [String] the turn's stopReason ("end_turn" on success)
    # @raise [ProtocolError]
    sig { params(prompt: String, cwd: String, model: T.nilable(String)).returns(String) }
    def run(prompt:, cwd:, model: nil)
      request("initialize", {
        "protocolVersion" => PROTOCOL_VERSION,
        "clientCapabilities" => { "fs" => { "readTextFile" => false, "writeTextFile" => false } },
      })
      session = request("session/new", { "cwd" => cwd, "mcpServers" => [] })
      session_id = session["sessionId"].to_s
      if model
        catalog = T.let(session.dig("models", "availableModels"), T.untyped)
        model_id = self.class.resolve_model(catalog.is_a?(Array) ? catalog : [], model)
        request("session/set_model", { "sessionId" => session_id, "modelId" => model_id })
      end
      response = request("session/prompt", {
        "sessionId" => session_id,
        "prompt" => [{ "type" => "text", "text" => prompt }],
      })
      response["stopReason"].to_s
    end

    class << self
      extend T::Sig

      # A configured handle against the session catalog: exact name, exact
      # modelId, then a unique name prefix. Ambiguity and absence raise —
      # a silently wrong model is worse than a loud launch failure.
      #
      # @param available [Array<Hash>] the catalog's availableModels
      # @param handle [String]
      # @return [String] the catalog modelId
      # @raise [ProtocolError]
      sig { params(available: T::Array[T::Hash[String, T.untyped]], handle: String).returns(String) }
      def resolve_model(available, handle)
        exact = available.find { |entry| entry["name"] == handle || entry["modelId"] == handle }
        return exact["modelId"].to_s if exact

        prefixed = available.select { |entry| entry["name"].to_s.start_with?(handle) }
        return prefixed.fetch(0)["modelId"].to_s if prefixed.length == 1

        # The session catalog is the only naming domain that matters here —
        # `agent --list-models` ids are a different dialect (ai-flow#84) —
        # so the failure dumps names *and* modelIds: the modelId is where
        # thinking/effort variants live, and this error is how an operator
        # discovers the exact string to pin in .github/ai-flow.yml.
        catalog = available.map { |entry| "#{entry["name"]} (#{entry["modelId"]})" }.join(", ")
        detail = prefixed.empty? ? "not in the agent's catalog" : "ambiguous (#{prefixed.map { |entry| entry["name"] }.join(", ")})"
        raise ProtocolError, "model '#{handle}' is #{detail} — available: #{catalog}"
      end
    end

    private

    # One request/response round trip. While waiting, notifications and
    # agent-initiated requests dispatch inline — the permission exchange
    # happens inside the session/prompt wait.
    #
    # @param method [String]
    # @param params [Hash]
    # @return [Hash] the response's result
    # @raise [ProtocolError]
    sig { params(method: String, params: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def request(method, params)
      id = (@next_id += 1)
      send_line({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
      loop do
        line = @input.gets
        raise ProtocolError, "agent ended the stream during #{method}" unless line

        message = parse(line)
        next unless message

        if message["method"] && message["id"]
          handle_agent_request(message)
        elsif message["method"]
          @on_update.call(message["params"] || {}) if message["method"] == "session/update"
        elsif message["id"] == id
          error = message["error"]
          raise ProtocolError, "#{method}: #{error["message"]} (code #{error["code"]})" if error

          result = message["result"]
          return result.is_a?(Hash) ? result : {}
        end
        # Responses to other ids can't occur under sequential usage; a
        # stray one is ignored rather than fatal.
      end
    end

    # @param message [Hash] an agent-initiated request
    # @return [void]
    sig { params(message: T::Hash[String, T.untyped]).void }
    def handle_agent_request(message)
      if message["method"] == "session/request_permission"
        params = T.let(message["params"] || {}, T::Hash[String, T.untyped])
        decision = @on_permission.call(params)
        options = T.let(params["options"] || [], T::Array[T::Hash[String, T.untyped]])
        option_id = pick_option(options, decision)
        send_line({ "jsonrpc" => "2.0", "id" => message["id"],
                    "result" => { "outcome" => { "outcome" => "selected", "optionId" => option_id } } })
      else
        # Unknown agent→client requests (fs reads were declined in the
        # initialize capabilities) get the JSON-RPC method-not-found error.
        send_line({ "jsonrpc" => "2.0", "id" => message["id"],
                    "error" => { "code" => -32_601, "message" => "method not supported: #{message["method"]}" } })
      end
    end

    # The option honoring a decision: the *_once kind first (never persist
    # a widening), any matching kind as fallback.
    #
    # @param options [Array<Hash>]
    # @param decision [Symbol] :allow or :reject
    # @return [String] the chosen optionId
    # @raise [ProtocolError] when the request offers no matching option
    sig { params(options: T::Array[T::Hash[String, T.untyped]], decision: Symbol).returns(String) }
    def pick_option(options, decision)
      prefix = decision == :allow ? "allow" : "reject"
      option = options.find { |entry| entry["kind"].to_s == "#{prefix}_once" } ||
               options.find { |entry| entry["kind"].to_s.start_with?(prefix) }
      raise ProtocolError, "permission request offered no #{prefix} option" unless option

      option["optionId"].to_s
    end

    # @param line [String]
    # @return [Hash, nil] nil for junk (protocol noise degrades, not crashes)
    sig { params(line: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def parse(line)
      parsed = JSON.parse(line)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    # @param payload [Hash]
    # @return [void]
    sig { params(payload: T::Hash[String, T.untyped]).void }
    def send_line(payload)
      @output.puts(JSON.generate(payload))
      @output.flush
    end
  end
end
