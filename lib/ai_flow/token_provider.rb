# typed: strict
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
  # Which credentials the process holds is decided once, at construction,
  # as a sealed AuthMode: App (minting), Static (a plain GH_TOKEN, never
  # refreshed), or Ambient (no auth at all — callers fall back to a
  # developer's own gh login). #token still answers nil in Ambient mode,
  # but that nil now has one named source instead of being the residue of
  # four unset fields.
  #
  # Key isolation: .from_env deletes the private key from the process
  # environment after reading it, so no subprocess — in particular the agent,
  # which runs arbitrary shell under --force — can ever see it. The agent
  # only ever sees short-lived installation tokens, the same blast radius as
  # the pre-minted design.
  class TokenProvider
    extend T::Sig

    class Error < StandardError; end

    class << self
      extend T::Sig

      # Read credentials from the environment — and remove the private key
      # from it, so subprocesses (which inherit the dispatcher's environment)
      # never see it.
      #
      # @param env [Hash-like] injectable for tests; the Actions job env
      # @return [TokenProvider]
      sig { params(env: T.untyped).returns(TokenProvider) }
      def from_env(env: ENV)
        new(
          app_id: env["AI_FLOW_APP_ID"],
          private_key_pem: env.delete("AI_FLOW_APP_PRIVATE_KEY"),
          owner: env["GITHUB_REPOSITORY_OWNER"] || env["GITHUB_REPOSITORY"].to_s.split("/").first,
          static_token: env["GH_TOKEN"],
          api_url: env["GITHUB_API_URL"] || "https://api.github.com",
        )
      end
    end

    # The credential params stay nilable — this constructor is the boundary
    # where the environment's "maybe set" strings are resolved, once, into
    # one of the three modes.
    #
    # @param app_id [String, nil] GitHub App id
    # @param private_key_pem [String, nil] the App's private key (PEM)
    # @param owner [String, nil] the org/user the App is installed on
    # @param static_token [String, nil] fallback token when no App key
    # @param api_url [String] GitHub API root
    # @param http [#call, nil] transport `(method, url, headers) ->
    #   [status, body]`, injectable for tests
    # @param clock [#call] returns the current Time, injectable for tests
    sig do
      params(
        app_id: T.nilable(String),
        private_key_pem: T.nilable(String),
        owner: T.nilable(String),
        static_token: T.nilable(String),
        api_url: String,
        http: T.untyped,
        clock: T.proc.returns(Time),
      ).void
    end
    def initialize(app_id:, private_key_pem:, owner:, static_token: nil,
                   api_url: "https://api.github.com", http: nil, clock: -> { Time.now })
      id = presence(app_id)
      pem = presence(private_key_pem)
      token = presence(static_token)
      @mode = T.let(
        if id && pem
          AuthMode::App.new(
            app_id: id, private_key: OpenSSL::PKey::RSA.new(pem), owner: presence(owner),
            api_url: api_url.chomp("/"), http: http || method(:default_http), clock: clock,
          )
        elsif token
          AuthMode::Static.new(token: token)
        else
          AuthMode::Ambient.new
        end,
        AuthMode,
      )
    end

    # @return [Boolean] whether App credentials are present (minting mode)
    sig { returns(T::Boolean) }
    def app?
      @mode.is_a?(AuthMode::App)
    end

    # A token fresh enough for the call about to be made: in App mode the
    # age check runs here, on every call.
    #
    # @return [String, nil] nil in Ambient mode (no auth at all)
    sig { returns(T.nilable(String)) }
    def token
      case (mode = @mode)
      when AuthMode::App then mode.fresh_token
      when AuthMode::Static then mode.token
      when AuthMode::Ambient then nil
      else T.absurd(mode)
      end
    end

    # Unconditional re-mint — the write phase calls this so its final burst
    # (push + comments) never runs on a 49-minute-old token. No-op outside
    # App mode (a static token can't be refreshed; ambient has nothing to).
    #
    # @return [void]
    sig { void }
    def refresh!
      case (mode = @mode)
      when AuthMode::App then mode.refresh!
      when AuthMode::Static, AuthMode::Ambient then nil
      else T.absurd(mode)
      end
    end

    private

    # @param value [String, nil]
    # @return [String, nil] the value, nil when blank
    sig { params(value: T.nilable(String)).returns(T.nilable(String)) }
    def presence(value)
      value.to_s.strip.empty? ? nil : value
    end

    # In-process transport (never a subprocess: the JWT and the minted token
    # must not appear on any argv).
    #
    # @param method [String]
    # @param url [String]
    # @param headers [Hash{String => String}]
    # @return [Array(Integer, String)] status code and response body
    sig do
      params(method: String, url: String, headers: T::Hash[String, String])
        .returns([Integer, String])
    end
    def default_http(method, url, headers)
      uri = URI.parse(url)
      response = Net::HTTP.start(T.must(uri.host), uri.port, use_ssl: uri.scheme == "https") do |http|
        request = (method == "POST" ? Net::HTTP::Post : Net::HTTP::Get).new(uri, headers)
        http.request(request)
      end
      [response.code.to_i, response.body]
    end

    # The three shapes auth can take, chosen once at construction. Sealed so
    # token/refresh! dispatch exhaustively — a fourth mode fails to compile,
    # not to run.
    module AuthMode
      extend T::Helpers
      include Kernel # is_a? for srb without the experimental requires_ancestor
      sealed!

      # GitHub App credentials: mints short-lived installation tokens on
      # demand and owns the mint state (token, age, installation id) — state
      # that only exists in this mode lives only in this mode.
      class App
        extend T::Sig
        include AuthMode

        # Re-mint when the token is older than this. GitHub caps
        # installation tokens at 60 minutes; 50 leaves headroom for the call
        # the check guards.
        MAX_AGE_SECONDS = T.let(50 * 60, Integer)

        # App JWTs may live 10 minutes; mint short and backdate against
        # clock skew, per GitHub's own guidance.
        JWT_BACKDATE_SECONDS = 60
        JWT_TTL_SECONDS = 540

        # @param app_id [String] GitHub App id
        # @param private_key [OpenSSL::PKey::RSA] the App's private key
        # @param owner [String, nil] the org/user the App is installed on —
        #   nilable env truth (unset outside Actions); a nil owner surfaces
        #   as an installation-lookup Error at mint time
        # @param api_url [String] GitHub API root, no trailing slash
        # @param http [#call] transport `(method, url, headers) ->
        #   [status, body]`
        # @param clock [#call] returns the current Time
        sig do
          params(
            app_id: String,
            private_key: OpenSSL::PKey::RSA,
            owner: T.nilable(String),
            api_url: String,
            http: T.untyped,
            clock: T.proc.returns(Time),
          ).void
        end
        def initialize(app_id:, private_key:, owner:, api_url:, http:, clock:)
          @app_id = app_id
          @private_key = private_key
          @owner = owner
          @api_url = api_url
          @http = http
          @clock = clock
          @minted_token = T.let(nil, T.nilable(String))
          @minted_at = T.let(nil, T.nilable(Time))
          @installation_id = T.let(nil, T.nilable(Integer))
        end

        # A token fresh enough for the call about to be made: the age check
        # runs here, on every call.
        #
        # @return [String] a minted installation token
        sig { returns(String) }
        def fresh_token
          minted_at = @minted_at
          refresh! if minted_at.nil? || @clock.call - minted_at > MAX_AGE_SECONDS
          T.must(@minted_token)
        end

        # Unconditional re-mint.
        #
        # @return [void]
        sig { void }
        def refresh!
          @minted_token = mint
          @minted_at = @clock.call
        end

        private

        # @return [String] a fresh installation token
        sig { returns(String) }
        def mint
          jwt = app_jwt
          response = request("POST", "app/installations/#{installation_id(jwt)}/access_tokens", jwt)
          response.fetch("token")
        end

        # The installation on the owner org (or user account —
        # personal-account adopters like JPDuchesne/** live under /users).
        # Memoized: it never changes within a job.
        #
        # @param jwt [String]
        # @return [Integer]
        sig { params(jwt: String).returns(Integer) }
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

        # A short-lived RS256 JWT authenticating as the App itself (stdlib
        # only — no jwt gem; pack("m0") because base64 left the default
        # gems).
        #
        # @return [String]
        sig { returns(String) }
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
        sig { params(data: String).returns(String) }
        def base64url(data)
          [data].pack("m0").tr("+/", "-_").delete("=")
        end

        # @param method [String]
        # @param path [String]
        # @param jwt [String]
        # @return [Hash] the parsed response body
        # @raise [Error] on any non-2xx answer
        sig { params(method: String, path: String, jwt: String).returns(T::Hash[String, T.untyped]) }
        def request(method, path, jwt)
          status, body = @http.call(
            method, "#{@api_url}/#{path}",
            { "Authorization" => "Bearer #{jwt}", "Accept" => "application/vnd.github+json" },
          )
          raise Error, "GitHub App auth: #{method} #{path} returned #{status}: #{body.to_s[0, 200]}" unless (200..299).cover?(status)

          JSON.parse(body)
        end
      end

      # A plain pre-issued token (GH_TOKEN): served as-is, never refreshed,
      # same lifetime rules as the pre-minted design.
      class Static
        extend T::Sig
        include AuthMode

        # @return [String] the token, verbatim
        sig { returns(String) }
        attr_reader :token

        # @param token [String]
        sig { params(token: String).void }
        def initialize(token:)
          @token = token
        end
      end

      # No credentials at all (local runs): the provider answers nil and
      # callers ride the developer's own gh login.
      class Ambient
        extend T::Sig
        include AuthMode
      end
    end
  end
end
