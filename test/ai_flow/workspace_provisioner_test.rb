# typed: true
# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class AiFlow::WorkspaceProvisionerTest < Minitest::Test
  REPO = "d3mlabs/demo"

  # Records what was streamed and where; `ok` is the install's verdict.
  # Subclasses the real class so sorbet-runtime's sig checks accept it.
  class StreamingExecutor < AiFlow::Executor
    attr_reader :streamed

    def initialize(ok: true, stderr: "")
      @ok = ok
      @stderr = stderr
      @streamed = []
    end

    def stream(*argv, stdin: nil, chdir: nil, env: {}, isolate: false)
      @streamed << [argv.join(" "), chdir]
      yield "installing…" if block_given?
      [@stderr, @ok]
    end
  end

  def provisioner(executor)
    AiFlow::WorkspaceProvisioner.new(executor: executor)
  end

  test "a checkout carrying dev.yml is provisioned in place with dev deps install" do
    Given "a dev project checkout"
    dir = Dir.mktmpdir("ai-flow-provision-")
    File.write(File.join(dir, "dev.yml"), "name: demo\n")
    executor = StreamingExecutor.new

    When "provisioning"
    provisioner(executor).provision(REPO, dir)

    Then "one dev deps install ran, in that checkout"
    executor.streamed == [["dev deps install", dir]]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a checkout without dev.yml is not a dev project — nothing runs" do
    Given "a plain checkout"
    dir = Dir.mktmpdir("ai-flow-provision-")
    executor = StreamingExecutor.new

    When "provisioning"
    provisioner(executor).provision(REPO, dir)

    Then "no dev call"
    executor.streamed.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failed install is a typed error carrying the repo, the command and dev's stderr" do
    Given "a dev project whose install fails"
    dir = Dir.mktmpdir("ai-flow-provision-")
    File.write(File.join(dir, "dev.yml"), "name: demo\n")
    executor = StreamingExecutor.new(ok: false, stderr: "no such bottle\n")

    When "provisioning"
    error = assert_raises(AiFlow::WorkspaceProvisioner::ProvisionError) { provisioner(executor).provision(REPO, dir) }

    Then "the message names what a reader needs to act"
    error.message.include?(REPO)
    error.message.include?("dev deps install")
    error.message.include?("no such bottle")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
