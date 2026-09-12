# typed: true
# frozen_string_literal: true

require "test_helper"
require "support/acp"

transform!(RSpock::AST::Transformation)
class AiFlow::AcpClientTest < Minitest::Test
  # Runs a client conversation against a FakeAcpServer over real pipes,
  # returning [stop_reason, server, updates, decisions_seen].
  def converse(server, prompt: "do it", cwd: "/work", model: nil, decision: :allow)
    client_reads, server_writes = IO.pipe
    server_reads, client_writes = IO.pipe
    thread = Thread.new { server.serve(server_reads, server_writes) }
    updates = []
    permission_params = []
    client = AiFlow::AcpClient.new(
      input: client_reads,
      output: client_writes,
      on_update: ->(params) { updates << params },
      on_permission: lambda { |params|
        permission_params << params
        decision
      },
    )
    stop_reason = client.run(prompt: prompt, cwd: cwd, model: model)
    [stop_reason, updates, permission_params]
  ensure
    [client_writes, client_reads, server_writes, server_reads].each do |io|
      io&.close unless io&.closed?
    end
    thread&.join(5)
  end

  test "the happy path: initialize, session, prompt; updates stream to the callback" do
    Given "a server scripted with one message chunk"
    server = FakeAcpServer.new(result_text: "the answer")

    When "conversing"
    stop_reason, updates, _permissions = converse(server)

    Then "the protocol ran in order and the chunk reached the callback"
    stop_reason == "end_turn"
    server.requests == ["initialize", "session/new", "session/prompt"]
    server.prompt_texts == ["do it"]
    updates.map { |u| u.dig("update", "sessionUpdate") } == ["agent_message_chunk"]

    Cleanup
    nil
  end

  test "a configured model resolves through the catalog into session/set_model" do
    Given "a server with the default catalog"
    server = FakeAcpServer.new

    When "conversing with a model handle matching a catalog name"
    converse(server, model: "gpt-6-nova")

    Then "set_model carried the catalog's modelId"
    server.set_model_ids == ["gpt-6-nova[reasoning=high]"]

    Cleanup
    nil
  end

  test "no model means no set_model call — the account default rides" do
    Given
    server = FakeAcpServer.new

    When "conversing without a model"
    converse(server, model: nil)

    Then
    !server.requests.include?("session/set_model")

    Cleanup
    nil
  end

  test "an unknown model handle raises with the catalog listed" do
    Given
    server = FakeAcpServer.new

    When "conversing with a handle the catalog lacks"
    error = begin
      converse(server, model: "no-such-model")
      nil
    rescue AiFlow::AcpClient::ProtocolError => e
      e
    end

    Then "the error names the handle and the available names"
    T.must(error).message.include?("no-such-model")
    T.must(error).message.include?("claude-fable-5")

    Cleanup
    nil
  end

  test "an ambiguous prefix raises rather than guessing" do
    Given "a catalog where the handle prefixes two models"
    server = FakeAcpServer.new

    When
    error = begin
      converse(server, model: "gpt-6")
      nil
    rescue AiFlow::AcpClient::ProtocolError => e
      e
    end

    Then "gpt-6 matches gpt-6-nova and gpt-6-nova-mini"
    T.must(error).message.include?("ambiguous")

    Cleanup
    nil
  end

  test "a unique prefix resolves" do
    Given
    server = FakeAcpServer.new

    When "conversing with a handle that uniquely prefixes one name"
    converse(server, model: "claude")

    Then
    server.set_model_ids == ["claude-fable-5[thinking=true,effort=high]"]

    Cleanup
    nil
  end

  test "an allow decision answers the allow_once option" do
    Given "a server that asks permission once"
    server = FakeAcpServer.new(permission_requests: [
      { "toolCall" => { "title" => "rm -rf build" }, "options" => FakeAcpServer::DEFAULT_PERMISSION_OPTIONS },
    ])

    When "conversing with an allowing policy"
    _stop, _updates, permissions = converse(server, decision: :allow)

    Then "the server recorded allow-once and the callback saw the request"
    server.permission_answers == ["allow-once"]
    permissions.map { |p| p.dig("toolCall", "title") } == ["rm -rf build"]

    Cleanup
    nil
  end

  test "a reject decision answers the reject_once option" do
    Given
    server = FakeAcpServer.new(permission_requests: [
      { "toolCall" => { "title" => "rm -rf build" }, "options" => FakeAcpServer::DEFAULT_PERMISSION_OPTIONS },
    ])

    When "conversing with a rejecting policy"
    converse(server, decision: :reject)

    Then
    server.permission_answers == ["reject-once"]

    Cleanup
    nil
  end

  test "a JSON-RPC error response raises ProtocolError with the method and message" do
    Given "a server that fails set_model"
    server = FakeAcpServer.new(error_on: { "session/set_model" => "model unavailable" })

    When
    error = begin
      converse(server, model: "claude-fable-5")
      nil
    rescue AiFlow::AcpClient::ProtocolError => e
      e
    end

    Then
    T.must(error).message.include?("session/set_model")
    T.must(error).message.include?("model unavailable")

    Cleanup
    nil
  end

  test "stream EOF mid-conversation raises ProtocolError, not a hang" do
    Given "pipes with no server behind them"
    client_reads, server_writes = IO.pipe
    server_reads, client_writes = IO.pipe
    server_writes.close
    client = AiFlow::AcpClient.new(
      input: client_reads, output: client_writes,
      on_update: ->(_params) { nil }, on_permission: ->(_params) { :allow },
    )

    When "running against the closed stream"
    error = begin
      client.run(prompt: "p", cwd: "/work", model: nil)
      nil
    rescue AiFlow::AcpClient::ProtocolError => e
      e
    end

    Then
    T.must(error).message.include?("initialize")

    Cleanup
    [client_reads, server_reads, client_writes].each { |io| io.close unless io.closed? }
  end
end
