# typed: true
# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class AiFlow::PersistentWorkspaceTest < Minitest::Test
  # Records git/gh invocations; the lock and the workspace dirs are real
  # files (the flock semantics under test are kernel behavior, never
  # mocked). `fail_on` substrings make matching command lines fail — the
  # unhealthy-worktree path.
  class RecordingExecutor < AiFlow::Executor
    attr_reader :command_lines, :shared_workspaces

    def initialize(fail_on: [])
      @fail_on = fail_on
      @command_lines = []
      @shared_workspaces = []
    end

    def share_workspace(dir)
      @shared_workspaces << dir
    end

    def isolation
      nil
    end

    def capture(*argv, stdin: nil, chdir: nil, env: {})
      line = argv.join(" ")
      @command_lines << line
      return ["", "simulated failure", false] if @fail_on.any? { |needle| line.include?(needle) }

      ["", "", true]
    end
  end

  def workspace(executor: RecordingExecutor.new, repo: "d3mlabs/demo")
    AiFlow::PersistentWorkspace.new(repo: repo, job_checkout: "/job/checkout", executor: executor)
  end

  def with_root
    Dir.mktmpdir("ai-flow-pw-test-") do |dir|
      ENV["AI_FLOW_WORKSPACE_ROOT"] = dir
      return yield dir
    end
  ensure
    ENV.delete("AI_FLOW_WORKSPACE_ROOT")
  end

  test "first acquire creates the worktree from the job checkout and shares root + leaf" do
    Given "an empty workspace root"
    executor = RecordingExecutor.new
    ws = workspace(executor: executor)

    When "the workspace is acquired"
    yielded, stable_path, root = with_root do
      [ws.acquire(default_branch: "main") { |path| path }, ws.path, ws.root]
    end

    Then "the checkout is a detached worktree on origin/main at the stable path"
    yielded == stable_path
    executor.command_lines.include?("git fetch origin main")
    executor.command_lines.include?("git worktree prune")
    executor.command_lines.include?("git worktree add --detach #{stable_path} origin/main")
    executor.shared_workspaces == [root, stable_path]

    Cleanup
    nil
  end

  test "an existing healthy checkout resyncs in place — never -x, warmth is the point" do
    Given "a workspace left behind by a prior run"
    executor = RecordingExecutor.new
    ws = workspace(executor: executor)

    When "the workspace is acquired again"
    with_root do
      FileUtils.mkdir_p(ws.path)
      ws.acquire(default_branch: "main") { |path| path }
    end

    Then "git state resyncs cold in place; the worktree is not recreated"
    executor.command_lines.include?("git rev-parse --git-dir")
    executor.command_lines.include?("git reset --hard")
    executor.command_lines.include?("git checkout --detach origin/main")
    executor.command_lines.include?("git clean -fd")
    executor.command_lines.none? { |line| line.include?("worktree add") }
    executor.command_lines.none? { |line| line.include?("clean -fdx") || line.include?("-x") }

    Cleanup
    nil
  end

  test "an orphaned checkout (severed gitdir link) is recreated, not resynced" do
    Given "a workspace dir whose git link is dead"
    executor = RecordingExecutor.new(fail_on: ["rev-parse"])
    ws = workspace(executor: executor)

    When
    stable_path = with_root do
      FileUtils.mkdir_p(ws.path)
      ws.acquire(default_branch: "main") { |path| path }
      ws.path
    end

    Then "the residue is removed and a fresh worktree is added"
    executor.command_lines.include?("git worktree add --detach #{stable_path} origin/main")
    executor.command_lines.none? { |line| line.include?("git reset") }

    Cleanup
    nil
  end

  test "a held lock fails loudly with holder diagnostics, never waits" do
    Given "another holder owns the workspace lock"
    ws = workspace

    When "acquire is attempted while the lock is held"
    message, lock_path = with_root do
      FileUtils.mkdir_p(ws.root)
      File.open(ws.lock_path, File::CREAT | File::RDWR) do |holder|
        holder.flock(File::LOCK_EX)
        begin
          ws.acquire(default_branch: "main") { |path| path }
          [nil, ws.lock_path]
        rescue AiFlow::PersistentWorkspace::BusyError => e
          [e.message, ws.lock_path]
        end
      end
    end

    Then "the failure names the lockfile and how to find the holder"
    message.include?("busy")
    message.include?(lock_path)
    message.include?("lsof")

    Cleanup
    nil
  end

  test "the lock releases after the block and after a raise inside it" do
    Given "a workspace acquired twice, the first pass raising"
    ws = workspace

    When "a failing acquire is followed by a clean one"
    reacquired, stable_path = with_root do
      begin
        ws.acquire(default_branch: "main") { raise "boom" }
      rescue RuntimeError
        nil
      end
      [ws.acquire(default_branch: "main") { |path| path }, ws.path]
    end

    Then "the second acquire succeeds — no stale lock survives a raise"
    reacquired == stable_path

    Cleanup
    nil
  end

  test "spawned children do not inherit the lock (FD_CLOEXEC default)" do
    Given "a child process spawned while the lock is held, outliving the run"
    ws = workspace
    child = T.let(nil, T.nilable(Integer))

    When "acquire returns while the child still runs"
    free = with_root do
      ws.acquire(default_branch: "main") { child = Process.spawn("sleep", "30") }
      File.open(ws.lock_path, File::RDWR) { |probe| probe.flock(File::LOCK_EX | File::LOCK_NB) != false }
    end

    Then "the lock is free — its lifetime is the dispatcher process, not the spawn tree"
    free == true

    Cleanup
    if child
      Process.kill("KILL", child)
      Process.wait(child)
    end
  end

  test "root resolution: env override wins; the unisolated default is durable, under HOME" do
    Given "no override"
    ws = workspace

    Expect "the durable home default (never /tmp — macOS purges it)"
    ws.root == File.join(Dir.home, ".ai-flow", "workspaces")
    ws.lock_path == "#{ws.path}.lock"

    Cleanup
    nil
  end
end
