# frozen_string_literal: true

require "open3"

module AiFlow
  # Thin wrapper over the external CLIs ai-flow drives (gh, git, agent). The
  # one injectable boundary, so command orchestration is testable without real
  # subprocesses (same pattern as d3mlabs/dev's RunnerSetup::Executor).
  class Executor
    # @param argv [Array<String>] command and arguments
    # @param stdin [String, nil] data piped to the subprocess
    # @param chdir [String, nil] working directory
    # @param env [Hash{String => String}] extra environment variables
    # @return [Array(String, String, Boolean)] stdout, stderr, success?
    def capture(*argv, stdin: nil, chdir: nil, env: {})
      opts = {}
      opts[:stdin_data] = stdin if stdin
      opts[:chdir] = chdir if chdir
      out, err, status = Open3.capture3(env, *argv, **opts)
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
    # @yieldparam line [String] one stdout line, as emitted
    # @return [Array(String, Boolean)] stderr, success?
    def stream(*argv, stdin: nil, chdir: nil)
      opts = chdir ? { chdir: chdir } : {}
      err = ""
      status = Open3.popen3(*argv, **opts) do |stdin_io, stdout_io, stderr_io, wait_thread|
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
  end
end
