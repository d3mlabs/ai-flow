# frozen_string_literal: true

require "test_helper"
require "json"
require "openssl"

# In-memory GitHub App endpoints: installation lookup + token mint, counting
# mints and handing out sequenced tokens so freshness is observable.
class FakeAppApi
  attr_reader :mints, :requests

  def initialize(owner_kind: "orgs")
    @owner_kind = owner_kind
    @mints = 0
    @requests = []
  end

  def call(method, url, _headers)
    @requests << [method, url]
    case url
    when %r{/#{@owner_kind}/[^/]+/installation\z}
      [200, JSON.generate(id: 42)]
    when %r{/(orgs|users)/[^/]+/installation\z}
      [404, JSON.generate(message: "Not Found")]
    when %r{/app/installations/42/access_tokens\z}
      @mints += 1
      [201, JSON.generate(token: "ghs_minted_#{@mints}")]
    else
      [404, JSON.generate(message: "unexpected: #{url}")]
    end
  end
end unless defined?(FakeAppApi)

transform!(RSpock::AST::Transformation)
class AiFlow::TokenProviderTest < Minitest::Test
  KEY = OpenSSL::PKey::RSA.new(2048)

  def build_provider(http:, clock:, owner: "d3mlabs")
    AiFlow::TokenProvider.new(
      app_id: "1234", private_key_pem: KEY.to_pem, owner: owner,
      http: http, clock: clock,
    )
  end

  test "a fresh token is minted lazily and reused while young" do
    Given "App credentials and a fixed clock"
    api = FakeAppApi.new
    provider = build_provider(http: api, clock: -> { Time.at(1_000_000) })

    When "asking for the token twice"
    first = provider.token
    second = provider.token

    Then "one mint serves both calls"
    first == "ghs_minted_1"
    second == "ghs_minted_1"
    api.mints == 1

    Cleanup
    nil
  end

  test "a token past the age cap re-mints on the next call — the lazy gap-proof check" do
    Given "a clock that jumps 51 minutes between calls"
    api = FakeAppApi.new
    times = [Time.at(0), Time.at(0), Time.at(51 * 60), Time.at(51 * 60)]
    provider = build_provider(http: api, clock: -> { times.shift || Time.at(51 * 60) })

    When "asking before and after the jump"
    young = provider.token
    aged = provider.token

    Then "the second call minted fresh"
    young == "ghs_minted_1"
    aged == "ghs_minted_2"
    api.mints == 2

    Cleanup
    nil
  end

  test "refresh! re-mints unconditionally — the write-phase guarantee" do
    Given "a young token"
    api = FakeAppApi.new
    provider = build_provider(http: api, clock: -> { Time.at(0) })
    provider.token

    When "refreshing and asking again"
    provider.refresh!
    token = provider.token

    Then "the token is fresh despite its predecessor's youth"
    token == "ghs_minted_2"
    api.mints == 2

    Cleanup
    nil
  end

  test "a personal-account owner falls back to the users installation endpoint" do
    Given "an App installed on a user account (orgs lookup 404s)"
    api = FakeAppApi.new(owner_kind: "users")
    provider = build_provider(http: api, clock: -> { Time.at(0) }, owner: "JPDuchesne")

    When "asking for the token"
    token = provider.token

    Then "the users endpoint served the installation"
    token == "ghs_minted_1"
    api.requests.any? { |_method, url| url.include?("/users/JPDuchesne/installation") }

    Cleanup
    nil
  end

  test "without App credentials the static token serves, never refreshed" do
    Given "a provider built from a plain GH_TOKEN"
    provider = AiFlow::TokenProvider.new(
      app_id: nil, private_key_pem: nil, owner: "d3mlabs", static_token: "ghp_static",
    )

    When "asking and refreshing"
    before = provider.token
    provider.refresh!
    after = provider.token

    Then "the static token is the answer both times, and no App mode"
    !provider.app?
    before == "ghp_static"
    after == "ghp_static"

    Cleanup
    nil
  end

  test "with no credentials at all the token is nil — ambient auth" do
    Given "an empty provider"
    provider = AiFlow::TokenProvider.new(app_id: nil, private_key_pem: nil, owner: nil)

    When "asking"
    token = provider.token

    Then
    token.nil?

    Cleanup
    nil
  end

  test "from_env scrubs the private key out of the environment" do
    Given "an env carrying App credentials"
    env = {
      "AI_FLOW_APP_ID" => "1234",
      "AI_FLOW_APP_PRIVATE_KEY" => KEY.to_pem,
      "GITHUB_REPOSITORY_OWNER" => "d3mlabs",
      "GH_TOKEN" => "ghs_preminted",
    }

    When "building the provider"
    provider = AiFlow::TokenProvider.from_env(env: env)

    Then "the key is gone from the env and the provider is in App mode"
    provider.app?
    !env.key?("AI_FLOW_APP_PRIVATE_KEY")
    env["AI_FLOW_APP_ID"] == "1234"

    Cleanup
    nil
  end

  test "the mint JWT authenticates as the App and is verifiable with its key" do
    Given "an API that captures the Authorization header"
    captured = nil
    http = lambda do |_method, url, headers|
      captured ||= headers.fetch("Authorization")
      if url.end_with?("/orgs/d3mlabs/installation")
        [200, JSON.generate(id: 42)]
      else
        [201, JSON.generate(token: "ghs_minted_1")]
      end
    end
    provider = build_provider(http: http, clock: -> { Time.at(1_700_000_000) })

    When "minting"
    provider.token
    header_b64, payload_b64, signature_b64 = captured.sub("Bearer ", "").split(".")
    payload = JSON.parse(pad_base64url(payload_b64).tr("-_", "+/").unpack1("m0"))
    signing_input = "#{header_b64}.#{payload_b64}"
    signature = pad_base64url(signature_b64).tr("-_", "+/").unpack1("m0")

    Then "the JWT names the App, is backdated, short-lived, and signed by the key"
    payload["iss"] == "1234"
    payload["iat"] == 1_700_000_000 - 60
    payload["exp"] == 1_700_000_000 + 540
    KEY.public_key.verify(OpenSSL::Digest.new("SHA256"), signature, signing_input)

    Cleanup
    nil
  end

  test "a failed mint raises with the status and body" do
    Given "an API that rejects the installation lookup everywhere"
    http = ->(_method, _url, _headers) { [401, "Bad credentials"] }
    provider = build_provider(http: http, clock: -> { Time.at(0) })

    When "asking for the token"
    error = assert_raises(AiFlow::TokenProvider::Error) { provider.token }

    Then
    error.message.include?("401")

    Cleanup
    nil
  end

  # Ruby's unpack1("m0") insists on padded input; JWT segments drop padding.
  def pad_base64url(segment)
    segment + "=" * ((4 - segment.length % 4) % 4)
  end
end
