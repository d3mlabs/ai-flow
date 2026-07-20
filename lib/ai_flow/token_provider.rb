# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module AiFlow
  # Lazy-minting GitHub App tokens. Installation tokens are hard-capped at
  # 1 hour by GitHub, so a pre-minted job token dies under any long agent
  # run (the gh-34 failure: 1h30m of work, then 401s on the push and the
  # result comment). Instead of a pre-minted token, the dispatcher holds the
  # App id + private key and this provider checks token age at every call —
  # stale means mint-then-answer. Lazy-at-call-time is inherently gap-proof:
  # a 3-hour silence just means the next call mints fresh.
  #
  # Without App credentials (local runs, allow_token_fallback) the provider
  # degrades to the static GH_TOKEN: never refreshed, same lifetime rules as
  # before. With neither, #token is nil and callers fall back to ambient
  # auth (a developer's own gh login).
  #
  # Key isolation: .from_env deletes the private key from the process
  # environment after reading it, so no subprocess — in particular the agent,
  # which runs arbitrary shell under --force — can ever see it. The agent
  # only ever sees short-lived installation tokens, the same blast radius as
  # the pre-minted design.
  class TokenProvider
    class Error < StandardError; end

    # Re-mint when the token is older than this. GitHub caps installation
    # tokens at 60 minutes; 50 leaves headroom for the call the check guards.
    MAX_AGE_SECONDS = 50 * 60

    # App JWTs may live 10 minutes; mint short and backdate against clock
    # skew, per GitHub's own guidance.
    JWT_BACKDATE_SECONDS = 60
    JWT_TTL_SECONDS = 540

    # Read credentials from the environment — and remove the private key
    # from it, so subprocesses (which inherit the dispatcher's environment)
    # never see it.
    #
    # @param env [Hash-like] injectable for tests; the Actions job env
    # @return [TokenProvider]
    def self.from_env(env: ENV)
      new(
        app_id: env["AI_FLOW_APP_ID"],
        private_key_pem: env.delete("AI_FLOW_APP_PRIVATE_KEY"),
        owner: env["GITHUB_REPOSITORY_OWNER"] || env["GITHUB_REPOSITORY"].to_s.split("/").first,
        static_token: env["GH_TOKEN"],
        api_url: env["GITHUB_API_URL"] || "https://api.github.com",
      )
    end

    # @param app_id [String, nil] GitHub App id
    # @param private_key_pem [String, nil] the App's private key (PEM)
    # @param owner [String, nil] the org/user the App is installed on
    # @param static_token [String, nil] fallback token when no App key
    # @param api_url [String] GitHub API root
    # @param http [#call, nil] transport `(method, url, headers) ->
    #   [status, body]`, injectable for tests
    # @param clock [#call] returns the current Time, injectable for tests
    def initialize(app_id:, private_key_pem:, owner:, static_token: nil,
                   api_url: "https://api.github.com", http: nil, clock: -> { Time.now })
      @app_id = presence(app_id)
      @private_key = presence(private_key_pem) && OpenSSL::PKey::RSA.new(private_key_pem)
      @owner = presence(owner)
      @static_token = presence(static_token)
      @api_url = api_url.chomp("/")
      @http = http || method(:default_http)
      @clock = clock
      @minted_token = nil
      @minted_at = nil
    end

    # @return [Boolean] whether App credentials are present (minting mode)
    def app?
      !(@app_id.nil? || @private_key.nil?)
    end

    # A token fresh enough for the call about to be made: the age check runs
    # here, on every call.
    #
    # @return [String, nil] nil when there is no auth at all (ambient mode)
    def token
      return @static_token unless app?

      refresh! if @minted_token.nil? || @clock.call - @minted_at > MAX_AGE_SECONDS
      @minted_token
    end

    # Unconditional re-mint — the write phase calls this so its final burst
    # (push + comments) never runs on a 49-minute-old token. No-op without
    # App credentials (a static token can't be refreshed).
    #
    # @return [void]
    def refresh!
      return unless app?

      @minted_token = mint
      @minted_at = @clock.call
    end

    private

    # @param value [String, nil]
    # @return [String, nil] the value, nil when blank
    def presence(value)
      value.to_s.strip.empty? ? nil : value
    end

    # @return [String] a fresh installation token
    def mint
      jwt = app_jwt
      response = request("POST", "app/installations/#{installation_id(jwt)}/access_tokens", jwt)
      response.fetch("token")
    end

    # The installation on the owner org (or user account — personal-account
    # adopters like JPDuchesne/** live under /users). Memoized: it never
    # changes within a job.
    #
    # @param jwt [String]
    # @return [Integer]
    def installation_id(jwt)
      @installation_id ||= begin
        response = begin
          request("GET", "orgs/#{@owner}/installation", jwt)
        rescue Error
          request("GET", "users/#{@owner}/installation", jwt)
        end
        response.fetch("id")
      end
    end

    # A short-lived RS256 JWT authenticating as the App itself (stdlib only —
    # no jwt gem; pack("m0") because base64 left the default gems).
    #
    # @return [String]
    def app_jwt
      now = @clock.call.to_i
      header = base64url(JSON.generate(alg: "RS256", typ: "JWT"))
      payload = base64url(JSON.generate(
                            iat: now - JWT_BACKDATE_SECONDS, exp: now + JWT_TTL_SECONDS, iss: @app_id,
                          ))
      signing_input = "#{header}.#{payload}"
      "#{signing_input}.#{base64url(@private_key.sign(OpenSSL::Digest.new("SHA256"), signing_input))}"
    end

    # @param data [String]
    # @return [String]
    def base64url(data)
      [data].pack("m0").tr("+/", "-_").delete("=")
    end

    # @param method [String]
    # @param path [String]
    # @param jwt [String]
    # @return [Hash] the parsed response body
    def request(method, path, jwt)
      status, body = @http.call(
        method, "#{@api_url}/#{path}",
        { "Authorization" => "Bearer #{jwt}", "Accept" => "application/vnd.github+json" },
      )
      raise Error, "GitHub App auth: #{method} #{path} returned #{status}: #{body.to_s[0, 200]}" unless (200..299).cover?(status)

      JSON.parse(body)
    end

    # In-process transport (never a subprocess: the JWT and the minted token
    # must not appear on any argv).
    def default_http(method, url, headers)
      uri = URI.parse(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        request = (method == "POST" ? Net::HTTP::Post : Net::HTTP::Get).new(uri, headers)
        http.request(request)
      end
      [response.code.to_i, response.body]
    end
  end
end
