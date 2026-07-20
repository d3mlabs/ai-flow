# frozen_string_literal: true

require "open3"

module AiFlow
  # Thin wrapper over the external CLIs ai-flow drives (gh, git, agent). The
  # one injectable boundary, so command orchestration is testable without real
  # subprocesses (same pattern as d3mlabs/dev's RunnerSetup::Executor).
  #
  # Auth freshness lives here: every spawn asks the TokenProvider for a token
  # (age-checked per call, see TokenProvider) and injects it into the
  # subprocess env — GH_TOKEN for gh, a git-config extraheader for git. Git
  # auth in particular must be per-invocation: actions/checkout bakes the
  # mint-time token into the repo's git config, which is exactly what expired
  # under the gh-34 long run, so the checkouts run with persist-credentials
  # off and this injection is the only git credential.
  class Executor
    # @param token_provider [AiFlow::TokenProvider, nil] nil (local runs)
    #   means ambient auth — the developer's own gh/git login
    def initialize(token_provider: nil)
      @token_provider = token_provider
    end

    # Unconditional re-mint (no-op without App credentials) — commands call
    # this entering their write phase so the final burst of pushes and
    # comment edits never runs on a token about to age out.
    #
    # @return [void]
    def refresh_auth!
      @token_provider&.refresh!
    end

    # @param argv [Array<String>] command and arguments
    # @param stdin [String, nil] data piped to the subprocess
    # @param chdir [String, nil] working directory
    # @param env [Hash{String => String}] extra environment variables
    # @return [Array(String, String, Boolean)] stdout, stderr, success?
    def capture(*argv, stdin: nil, chdir: nil, env: {})
      opts = {}
      opts[:stdin_data] = stdin if stdin
      opts[:chdir] = chdir if chdir
      out, err, status = Open3.capture3(auth_env.merge(env), *argv, **opts)
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
    # @param env [Hash{String => String}] extra environment variables
    # @yieldparam line [String] one stdout line, as emitted
    # @return [Array(String, Boolean)] stderr, success?
    def stream(*argv, stdin: nil, chdir: nil, env: {})
      opts = chdir ? { chdir: chdir } : {}
      err = ""
      status = Open3.popen3(auth_env.merge(env), *argv, **opts) do |stdin_io, stdout_io, stderr_io, wait_thread|
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

    # The per-spawn auth overlay. GH_TOKEN covers gh (the agent's own gh
    # calls inherit it too — the agent only ever sees short-lived
    # installation tokens, never the App key); the GIT_CONFIG_* triplet is
    # git's env-borne `-c` equivalent, kept off argv so the token never
    # shows in process listings. Empty in ambient mode.
    #
    # @return [Hash{String => String}]
    def auth_env
      token = @token_provider&.token
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
    def server_url
      ENV["GITHUB_SERVER_URL"] || "https://github.com"
    end
  end
end
