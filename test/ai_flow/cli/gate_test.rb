# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "support/fakes"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class AiFlow::Cli::GateTest < Minitest::Test
  REPO = "d3mlabs/knowledge"

  # A check with a canned verdict that records what it was asked about.
  # Subclasses the real class so sorbet-runtime's sig accepts it at the
  # injection seam.
  class CannedChecks < AiFlow::ProposalChecks
    attr_reader :asked

    def initialize(result)
      @result = result
    end

    def origin_firing(workdir:, owner_repo:, number:, base_ref:)
      @asked = { workdir: workdir, owner_repo: owner_repo, number: number, base_ref: base_ref }
      @result
    end
  end

  Result = AiFlow::ProposalChecks::Result

  # A pull_request event as the runner finds it: only the PR's identity.
  def job_env(dir, extra: {})
    payload = {
      "repository" => { "full_name" => REPO },
      "pull_request" => { "number" => 39, "base" => { "ref" => "main" } },
    }
    event_path = File.join(dir, "event.json")
    File.write(event_path, JSON.generate(payload))
    { "GITHUB_EVENT_PATH" => event_path, "AI_FLOW_WORKDIR" => dir }.merge(extra)
  end

  def build_gate(env:, result:)
    stdout = StringIO.new
    checks = CannedChecks.new(result)
    [AiFlow::Cli::Gate.new(env: env, checks: checks, stdout: stdout), checks, stdout]
  end

  test "the check is asked about the event's PR in the job's checkout" do
    Given
    dir = Dir.mktmpdir("ai-flow-gate-")
    gate, checks, _stdout = build_gate(env: job_env(dir), result: Result::Unmarked.new)

    When
    gate.run([])

    Then
    checks.asked == { workdir: dir, owner_repo: REPO, number: 39, base_ref: "main" }

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "each verdict has its exit status and first line: #{result.class.name.split('::').last}" do
    Given
    dir = Dir.mktmpdir("ai-flow-gate-")
    gate, _checks, stdout = build_gate(env: job_env(dir), result: result)

    When
    status = gate.run([])

    Then "the run log opens with the verdict and is unbuffered for the Actions page"
    status == expected_status
    stdout.string.lines.first.start_with?(first_line)
    stdout.sync == true

    Cleanup
    FileUtils.rm_rf(dir)

    Where
    result                                                     | expected_status | first_line
    Result::Pass.new(new_slugs: ["a", "b"], fired: ["a", "b"]) | 0               | "✅ origin-firing (pass)"
    Result::Fail.new(new_slugs: ["a", "b"], fired: ["a"])      | 1               | "❌ origin-firing (fail): did not fire on the origin context: `b`"
    Result::Fail.new(new_slugs: ["a"], fired: [])              | 1               | "❌ origin-firing (fail)"
    Result::StructureOnly.new                                  | 0               | "ℹ️ origin-firing (skip): no skill files added or edited"
    Result::Unmarked.new                                       | 0               | "ℹ️ origin-firing (skip): no `learned-from:` marker"
  end

  test "a checked verdict lists the changed and fired slugs, a silent origin reads (none)" do
    Given
    dir = Dir.mktmpdir("ai-flow-gate-")
    gate, _checks, stdout = build_gate(env: job_env(dir), result: Result::Fail.new(new_slugs: ["a"], fired: []))

    When
    gate.run([])

    Then
    stdout.string.lines.map(&:chomp).drop(1) == ["changed learnings: a", "fired on origin: (none)"]

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the report is appended to the step summary when the job has one" do
    Given "a job with a step summary that already has a line"
    dir = Dir.mktmpdir("ai-flow-gate-")
    summary = File.join(dir, "summary.md")
    File.write(summary, "earlier step\n")
    env = job_env(dir, extra: { "GITHUB_STEP_SUMMARY" => summary })
    gate, _checks, stdout = build_gate(env: env, result: Result::Pass.new(new_slugs: ["a"], fired: ["a"]))

    When
    gate.run([])

    Then "the summary carries the report after what was there"
    File.read(summary) == "earlier step\n#{stdout.string}"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "arguments are a usage error ending in gate's usage" do
    Given
    gate, _checks, _stdout = build_gate(env: {}, result: Result::Unmarked.new)

    When
    gate.run(["39"])

    Then
    e = raises AiFlow::Cli::UsageError
    e.message.start_with?("gate takes no arguments\n")
    e.message.include?("usage: ai-flow gate")
  end

  test "a run outside an Actions job names the missing key and gate's usage" do
    Given
    gate, _checks, _stdout = build_gate(env: {}, result: Result::Unmarked.new)

    When
    gate.run([])

    Then
    e = raises AiFlow::Cli::Job::NotUnderActionsError
    e.message.start_with?("GITHUB_EVENT_PATH is not set")
    e.message.include?("usage: ai-flow gate")
  end
end
