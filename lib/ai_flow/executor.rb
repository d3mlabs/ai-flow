# typed: strict
# frozen_string_literal: true

require "open3"

module AiFlow
  # Thin wrapper over the external CLIs ai-flow drives (gh, git, agent). The
  # one injectable boundary, so command orchestration is testable without real
  # subprocesses (same pattern as d3mlabs/dev's RunnerSetup::Executor).
  #
  # Env hygiene lives here (#46): every spawn starts from HarnessEnv.scrub —
  # the pre-activation environment — because per-call-site scrubbing kept
  # regrowing the leak (#38 was fixed agent-only, then #44 hit the invariants
  # shell-out that was added without it). gh/git are indifferent to the
  # bundler keys, and children that resolve a Ruby toolchain (agent, dev)
  # need them gone, so the clean env is the default for everyone; a caller's
  # env: overlay still wins key-by-key.
  #
  # Auth freshness lives here too: every spawn asks the TokenProvider for a
  # token (age-checked per call, see TokenProvider) and injects it into the
  # subprocess env — GH_TOKEN for gh, a git-config extraheader for git. Git
  # auth in particular must be per-invocation: actions/checkout bakes the
  # mint-time token into the repo's git config, which is exactly what expired
  # under the gh-34 long run, so the checkouts run with persist-credentials
  # off and this injection is the only git credential.
  class Executor
    extend T::Sig

    # @param token_provider [AiFlow::TokenProvider, nil] nil (local runs)
    #   means ambient auth — the developer's own gh/git login
    sig { params(token_provider: T.nilable(TokenProvider)).void }
    def initialize(token_provider: nil)
      @token_provider = token_provider
    end

    # Unconditional re-mint (no-op without App credentials) — commands call
    # this entering their write phase so the final burst of pushes and
    # comment edits never runs on a token about to age out.
    #
    # @return [void]
    sig { void }
    def refresh_auth!
      @token_provider&.refresh!
    end

    # The auth overlay for an agent launch (plans#25): same shape as the
    # per-spawn default, but the token is downscoped to the run's declared
    # repos, so the arbitrary shell the agent runs under --force never holds
    # the dispatcher's installation-wide reach. Callers pass it as the env:
    # overlay, which wins key-by-key over the default injection.
    #
    # @param repositories [Array<String>] "owner/repo" names the run touches
    # @return [Hash{String => String}] empty without credentials (ambient)
    sig { params(repositories: T::Array[String]).returns(T::Hash[String, String]) }
    def scoped_auth_env(repositories:)
      auth_overlay(@token_provider&.scoped_token(repositories: repositories))
    end

    # @param argv [Array<String>] command and arguments
    # @param stdin [String, nil] data piped to the subprocess
    # @param chdir [String, nil] working directory
    # @param env [Hash{String => String, nil}] extra environment variables
    #   (a nil value unsets the key in the subprocess)
    # @return [Array(String, String, Boolean)] stdout, stderr, success?
    sig do
      params(
        argv: String,
        stdin: T.nilable(String),
        chdir: T.nilable(String),
        env: T::Hash[String, T.nilable(String)],
      ).returns([String, String, T::Boolean])
    end
    def capture(*argv, stdin: nil, chdir: nil, env: {})
      opts = {}
      opts[:stdin_data] = stdin if stdin
      opts[:chdir] = chdir if chdir
      # T.unsafe: variadic forwarding (env hash + *argv + **opts) is beyond
      # what Sorbet can check against Open3's sigs (srb.help/7019).
      out, err, status = T.unsafe(Open3).capture3(spawn_env(env), *argv, **opts)
      [out, err, status.success?]
    rescue Errno::ENOENT => e
      ["", e.message, false]
    end

    # Like capture, but yields stdout line by line as the subprocess emits
    # it — the live half of the Actions job log (a running step streams its
    # stdout to the run page). stdin is written on a thread so a large
    # prompt can't deadlock against a filling stdout pipe; stderr drains on
    # a thread for the same reason.
    #
    # @param argv [Array<String>] command and arguments
    # @param stdin [String, nil] data piped to the subprocess
    # @param chdir [String, nil] working directory
    # @param env [Hash{String => String, nil}] extra environment variables
    #   (a nil value unsets the key in the subprocess)
    # @yieldparam line [String] one stdout line, as emitted
    # @return [Array(String, Boolean)] stderr, success?
    sig do
      params(
        argv: String,
        stdin: T.nilable(String),
        chdir: T.nilable(String),
        env: T::Hash[String, T.nilable(String)],
        on_line: T.proc.params(line: String).void,
      ).returns([String, T::Boolean])
    end
    def stream(*argv, stdin: nil, chdir: nil, env: {}, &on_line)
      opts = chdir ? { chdir: chdir } : {}
      err = T.let("", String)
      # T.unsafe: same variadic forwarding as capture (srb.help/7019).
      status = T.unsafe(Open3).popen3(spawn_env(env), *argv, **opts) do |stdin_io, stdout_io, stderr_io, wait_thread|
        writer = Thread.new do
          stdin_io.write(stdin) if stdin
          stdin_io.close
        rescue Errno::EPIPE
          # The subprocess died before reading the prompt; its stderr and
          # exit status carry the story.
        end
        drain = Thread.new { stderr_io.read }
        stdout_io.each_line { |line| yield line }
        writer.join
        err = drain.value.to_s
        wait_thread.value
      end
      [err, status.success?]
    rescue Errno::ENOENT => e
      [e.message, false]
    end

    private

    # The full env overlay for one spawn: harness scrub as the base, auth on
    # top, the caller's explicit overrides last.
    #
    # @param env [Hash{String => String, nil}] caller overrides
    # @return [Hash{String => String, nil}]
    sig { params(env: T::Hash[String, T.nilable(String)]).returns(T::Hash[String, T.nilable(String)]) }
    def spawn_env(env)
      HarnessEnv.scrub.merge(auth_env).merge(env)
    end

    # The per-spawn auth overlay. GH_TOKEN covers gh (the agent's own gh
    # calls inherit it too — the agent only ever sees short-lived
    # installation tokens, never the App key); the GIT_CONFIG_* triplet is
    # git's env-borne `-c` equivalent, kept off argv so the token never
    # shows in process listings. Empty in ambient mode.
    #
    # @return [Hash{String => String}]
    sig { returns(T::Hash[String, String]) }
    def auth_env
      auth_overlay(@token_provider&.token)
    end

    # @param token [String, nil]
    # @return [Hash{String => String}] empty when there is no token
    sig { params(token: T.nilable(String)).returns(T::Hash[String, String]) }
    def auth_overlay(token)
      return {} unless token

      basic = ["x-access-token:#{token}"].pack("m0")
      {
        "GH_TOKEN" => token,
        "GIT_CONFIG_COUNT" => "1",
        "GIT_CONFIG_KEY_0" => "http.#{server_url}/.extraheader",
        "GIT_CONFIG_VALUE_0" => "AUTHORIZATION: basic #{basic}",
      }
    end

    # @return [String]
    sig { returns(String) }
    def server_url
      ENV["GITHUB_SERVER_URL"] || "https://github.com"
    end
  end
end
