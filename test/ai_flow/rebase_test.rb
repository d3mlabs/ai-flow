# typed: true
# frozen_string_literal: true

require "test_helper"

transform!(RSpock::AST::Transformation)
class AiFlow::RebaseTest < Minitest::Test
  IDENTITY = ["-c", "user.name=ai-flow[bot]", "-c", "user.email=bot@example"].freeze

  # Records git invocations. `fail_on` substrings make matching command
  # lines fail; `unmerged` is what each successive `--diff-filter=U`
  # listing answers (the last value repeats).
  class RecordingExecutor < AiFlow::Executor
    attr_reader :command_lines, :envs

    def initialize(fail_on: [], unmerged: [[]])
      @fail_on = fail_on
      @unmerged = unmerged.dup
      @command_lines = []
      @envs = []
    end

    def capture(*argv, stdin: nil, chdir: nil, env: {})
      line = argv.join(" ")
      @command_lines << line
      @envs << env
      return ["", "simulated failure: #{line}", false] if @fail_on.any? { |needle| line.include?(needle) }

      out =
        if argv.include?("--diff-filter=U")
          listing = @unmerged.size > 1 ? @unmerged.shift : @unmerged.first
          listing.map { |path| "#{path}\n" }.join
        else
          ""
        end
      [out, "", true]
    end
  end

  def onto(executor)
    AiFlow::Rebase.onto("main", executor: executor, workdir: "/work", identity: IDENTITY)
  end

  test "onto fetches the base and rebases as the identity with no editor; a clean rebase has no conflicts and is not in progress" do
    Given "a base to rebase onto"
    executor = RecordingExecutor.new

    When "starting the rebase"
    rebase = onto(executor)

    Then "fetch, then rebase with the identity flags and GIT_EDITOR=true; the value reads clean"
    executor.command_lines.fetch(0) == "git fetch origin main"
    executor.command_lines.fetch(1) == "git #{IDENTITY.join(" ")} rebase origin/main"
    executor.envs.fetch(1) == { "GIT_EDITOR" => "true" }
    rebase.base == "main"
    rebase.conflicts.empty?
    !rebase.in_progress?
  end

  test "a rebase that stops on conflicts carries the unmerged paths and is in progress" do
    Given "a rebase that stops on two files"
    executor = RecordingExecutor.new(fail_on: ["rebase origin/main"], unmerged: [["docs/DECISIONS.md", "lib/x.rb"]])

    When "starting the rebase"
    rebase = onto(executor)

    Then "the paths are its conflicts and nothing was aborted"
    rebase.conflicts == ["docs/DECISIONS.md", "lib/x.rb"]
    rebase.in_progress?
    executor.command_lines.none? { |line| line.include?("rebase --abort") }
  end

  test "a rebase that fails for any reason but conflicts is aborted and raises FailedError with git's words" do
    Given "the rebase fails and nothing is unmerged — a dirty tree, an unknown ref"
    executor = RecordingExecutor.new(fail_on: ["rebase origin/main"], unmerged: [[]])

    When "starting the rebase"
    error = assert_raises(AiFlow::Rebase::FailedError) { onto(executor) }

    Then "it was aborted and the error carries git's words"
    error.message.include?("git rebase origin/main failed")
    error.message.include?("simulated failure")
    executor.command_lines.last == "git #{IDENTITY.join(" ")} rebase --abort"
  end

  test "continue! runs rebase --continue with no editor once every path is merged" do
    Given "a stopped rebase whose markers the agent cleared"
    executor = RecordingExecutor.new(fail_on: ["rebase origin/main"], unmerged: [["docs/DECISIONS.md"], []])
    rebase = onto(executor)

    When "continuing"
    rebase.continue!

    Then "rebase --continue ran with no editor and the rebase is done"
    executor.command_lines.last == "git #{IDENTITY.join(" ")} rebase --continue"
    executor.envs.last == { "GIT_EDITOR" => "true" }
    executor.command_lines.none? { |line| line.include?("rebase --abort") }
    !rebase.in_progress?
  end

  test "continue! with markers still in the tree aborts and raises UnresolvedError naming the paths" do
    Given "a stopped rebase the agent did not resolve"
    executor = RecordingExecutor.new(fail_on: ["rebase origin/main"], unmerged: [["docs/DECISIONS.md"]])
    rebase = onto(executor)

    When "continuing"
    error = assert_raises(AiFlow::Rebase::UnresolvedError) { rebase.continue! }

    Then "it was aborted without a --continue and the error names the file"
    error.message.include?("docs/DECISIONS.md")
    error.message.include?("main")
    executor.command_lines.last == "git #{IDENTITY.join(" ")} rebase --abort"
    executor.command_lines.none? { |line| line.include?("rebase --continue") }
    !rebase.in_progress?
  end

  test "continue! that stops again on a later commit aborts and raises StoppedAgainError" do
    Given "a stopped rebase whose --continue conflicts again"
    executor = RecordingExecutor.new(fail_on: ["rebase origin/main", "rebase --continue"], unmerged: [["docs/DECISIONS.md"], []])
    rebase = onto(executor)

    When "continuing"
    error = assert_raises(AiFlow::Rebase::StoppedAgainError) { rebase.continue! }

    Then "it was aborted"
    error.message.include?("stopped again")
    executor.command_lines.last == "git #{IDENTITY.join(" ")} rebase --abort"
  end

  test "each error is a GitHub::Error, so the command boundary reports it as any other failed git step" do
    Expect "each error class descends from GitHub::Error"
    AiFlow::Rebase::FailedError.ancestors.include?(AiFlow::GitHub::Error)
    AiFlow::Rebase::UnresolvedError.ancestors.include?(AiFlow::GitHub::Error)
    AiFlow::Rebase::StoppedAgainError.ancestors.include?(AiFlow::GitHub::Error)
  end
end
