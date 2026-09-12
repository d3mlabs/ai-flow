# typed: true
# frozen_string_literal: true

require "json"

# A scripted ACP agent for tests: speaks the JSON-RPC/stdio protocol the
# real `cursor-agent acp` speaks (verified live 2026-09-12 — initialize,
# session/new with a models catalog, session/set_model, session/prompt with
# streamed session/update notifications and permission requests), entirely
# in-process over real pipes. The recorded-executor doctrine's ACP
# counterpart: tests never run the real CLI.
class FakeAcpServer
  DEFAULT_MODELS = [
    { "modelId" => "claude-fable-5[thinking=true,effort=high]", "name" => "claude-fable-5" },
    { "modelId" => "gpt-6-nova[reasoning=high]", "name" => "gpt-6-nova" },
    { "modelId" => "gpt-6-nova-mini[reasoning=low]", "name" => "gpt-6-nova-mini" },
    # Plain handles the agent tests configure through .github/ai-flow.yml.
    { "modelId" => "opus[test]", "name" => "opus" },
    { "modelId" => "gpt-5[test]", "name" => "gpt-5" },
    { "modelId" => "env-model[test]", "name" => "env-model" },
  ].freeze

  DEFAULT_PERMISSION_OPTIONS = [
    { "optionId" => "allow-once", "kind" => "allow_once" },
    { "optionId" => "allow-always", "kind" => "allow_always" },
    { "optionId" => "reject-once", "kind" => "reject_once" },
  ].freeze

  attr_reader :requests, :set_model_ids, :prompt_texts, :permission_answers, :extra_answers

  # @param result_text [String] emitted as one agent_message_chunk update
  # @param stop_reason [String] the session/prompt response's stopReason
  # @param updates [Array<Hash>, nil] session/update payloads (the `update`
  #   member) emitted before the prompt response; nil derives one message
  #   chunk from result_text
  # @param permission_requests [Array<Hash>] session/request_permission
  #   params (minus sessionId) sent after the updates, each awaiting the
  #   client's answer
  # @param models [Array<Hash>] the session/new catalog
  # @param error_on [Hash{String => String}] method => message; the server
  #   answers those requests with a JSON-RPC error
  # @param junk_lines [Array<String>] raw non-JSON lines emitted before the
  #   updates (protocol-noise resilience)
  # @param extra_requests [Array<Hash>] agent→client requests ({"method",
  #   "params"}) sent before the permission requests, each awaiting the
  #   client's answer (recorded in extra_answers)
  def initialize(result_text: "ok", stop_reason: "end_turn", updates: nil, permission_requests: [],
                 models: DEFAULT_MODELS, error_on: {}, junk_lines: [], extra_requests: [])
    @result_text = result_text
    @stop_reason = stop_reason
    @updates = updates
    @permission_requests = permission_requests
    @models = models
    @error_on = error_on
    @junk_lines = junk_lines
    @extra_requests = extra_requests
    @requests = []
    @set_model_ids = []
    @prompt_texts = []
    @permission_answers = []
    @extra_answers = []
    @next_server_id = 100
  end

  # Blocking serve loop — run it on a thread. Exits on stdin EOF like the
  # real ACP server.
  def serve(input, output)
    output.sync = true
    while (line = input.gets)
      msg = JSON.parse(line)
      # Responses to server-initiated requests are consumed inside
      # handle_prompt's permission exchange; anything with a method here is
      # a client request.
      next unless msg["method"]

      @requests << msg["method"]
      if (message = @error_on[msg["method"]])
        respond_error(output, msg["id"], message)
        next
      end
      case msg["method"]
      when "initialize"
        respond(output, msg["id"], { "protocolVersion" => 1, "agentCapabilities" => {} })
      when "session/new"
        respond(output, msg["id"], {
          "sessionId" => "sess-1",
          "models" => { "currentModelId" => @models.dig(0, "modelId"), "availableModels" => @models },
        })
      when "session/set_model"
        @set_model_ids << msg.dig("params", "modelId")
        respond(output, msg["id"], {})
      when "session/prompt"
        handle_prompt(input, output, msg)
      else
        respond_error(output, msg["id"], "method not found", code: -32_601)
      end
    end
  rescue IOError, Errno::EPIPE
    # The client hung up mid-serve (EOF-path tests); nothing to clean up.
  end

  private

  def handle_prompt(input, output, msg)
    @prompt_texts << msg.dig("params", "prompt", 0, "text")
    @junk_lines.each { |line| output.puts(line) }
    updates = @updates || [{
      "sessionUpdate" => "agent_message_chunk",
      "content" => { "type" => "text", "text" => @result_text },
    }]
    updates.each do |update|
      notify(output, "session/update", { "sessionId" => "sess-1", "update" => update })
    end
    @extra_requests.each do |request|
      id = (@next_server_id += 1)
      send_line(output, { "jsonrpc" => "2.0", "id" => id, "method" => request.fetch("method"),
                          "params" => request["params"] || {} })
      @extra_answers << JSON.parse(input.gets.to_s)
    end
    @permission_requests.each do |params|
      id = (@next_server_id += 1)
      send_line(output, { "jsonrpc" => "2.0", "id" => id, "method" => "session/request_permission",
                          "params" => params.merge("sessionId" => "sess-1") })
      answer = JSON.parse(input.gets.to_s)
      @permission_answers << answer.dig("result", "outcome", "optionId")
    end
    respond(output, msg["id"], { "stopReason" => @stop_reason })
  end

  def respond(output, id, result)
    send_line(output, { "jsonrpc" => "2.0", "id" => id, "result" => result })
  end

  def respond_error(output, id, message, code: -32_000)
    send_line(output, { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } })
  end

  def notify(output, method, params)
    send_line(output, { "jsonrpc" => "2.0", "method" => method, "params" => params })
  end

  def send_line(output, payload)
    output.puts(JSON.generate(payload))
  end
end unless defined?(FakeAcpServer)

# The agent-launch executor double for the ACP transport: duplex runs a
# FakeAcpServer over real pipes on a thread, recording argv/env/isolate
# like the stream-json RecordingExecutor did. Subclasses the real class so
# sorbet-runtime's sig checks accept it at the injection seam.
class AcpFakeExecutor < AiFlow::Executor
  attr_reader :captures, :envs, :isolates, :chdirs, :server

  def initialize(server: FakeAcpServer.new, err: "", ok: true)
    @server = server
    @err = err
    @ok = ok
    @captures = []
    @envs = []
    @isolates = []
    @chdirs = []
  end

  def duplex(*argv, chdir: nil, env: {}, isolate: false, reap_timeout: 10)
    @captures << argv
    @envs << env
    @isolates << isolate
    @chdirs << chdir
    client_reads, server_writes = IO.pipe
    server_reads, client_writes = IO.pipe
    thread = Thread.new { @server.serve(server_reads, server_writes) }
    begin
      yield client_writes, client_reads
    ensure
      client_writes.close unless client_writes.closed?
      thread.join(5)
      [client_reads, server_writes, server_reads].each { |io| io.close unless io.closed? }
    end
    [@err, @ok]
  end
end unless defined?(AcpFakeExecutor)
