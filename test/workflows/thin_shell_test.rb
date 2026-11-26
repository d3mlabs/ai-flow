# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "yaml"

transform!(RSpock::AST::Transformation)
# The reusable workflows are a shell whose contract holds across a major:
# check out the adopter → `dev up` (what the adopter declared, the
# dispatcher among it) → check the dispatcher is this shell's series →
# `dev runner status --check` → `ai-flow dispatch` / `ai-flow gate`. No
# second checkout and no per-job install: the dispatcher a job runs is the
# one the adopter installed, and this YAML is what the adopter's
# `@v<major>` resolves to.
class ThinShellTest < Minitest::Test
  WORKFLOWS_DIR = File.join(AI_FLOW_ROOT, ".github", "workflows")
  SERIES = AiFlow::Series.of_tree(AI_FLOW_ROOT)
  SELF_RULE_STEP = "Resolve ai-flow to the checkout when the checkout is ai-flow"
  SERIES_CHECK_STEPS = ["Check the dispatcher is this shell's series", "Check the checker is this shell's series"].freeze

  def steps(workflow, job)
    YAML.safe_load(File.read(File.join(WORKFLOWS_DIR, workflow))).fetch("jobs").fetch(job).fetch("steps")
  end

  def step_named(workflow, job, names)
    steps(workflow, job).find { |step| Array(names).include?(step["name"]) } or raise "no step #{names} in #{workflow}"
  end

  # Run a step's script with a stand-in `shadowenv exec -- ai-flow version`
  # that answers +version+, or fails when nil.
  def run_step(step, env: {}, version: nil)
    Dir.mktmpdir do |dir|
      shadowenv = File.join(dir, "shadowenv")
      File.write(shadowenv, version ? "#!/bin/sh\necho '#{version}'\n" : "#!/bin/sh\nexit 127\n")
      File.chmod(0o755, shadowenv)
      path_file = File.join(dir, "github_path")
      File.write(path_file, "")
      run_env = { "PATH" => "#{dir}:#{ENV.fetch("PATH")}", "GITHUB_WORKSPACE" => dir, "GITHUB_PATH" => path_file }
      out, err, status = Open3.capture3(run_env.merge(env), "bash", "-e", "-c", step.fetch("run"), chdir: dir)
      [status.success?, out + err, File.read(path_file), dir]
    end
  end

  test "no shipped workflow checks ai-flow out or installs it per job" do
    Given "every workflow under .github"
    texts = Dir.glob(File.join(WORKFLOWS_DIR, "*.yml")).to_h { |path| [File.basename(path), File.read(path)] }

    Expect "the acceptance grep: rg '\\.ai-flow|dev deps install' .github returns nothing"
    !texts.empty?
    texts.select { |_name, text| text.match?(/\.ai-flow\b|dev deps install/) }.keys == []
  end

  test "#{workflow}'s #{job} job runs dev/up, the series check, the posture check, then `#{entry}` — in that order, in the adopter's checkout" do
    Given "the job's steps"
    job_steps = steps(workflow, job)
    uses = job_steps.map { |step| step["uses"].to_s }
    runs = job_steps.map { |step| step["run"].to_s }
    names = job_steps.map { |step| step["name"].to_s }

    Expect "one checkout, dev/up after it, the series check, then the two dev-and-ai-flow steps"
    uses.count { |value| value.start_with?("actions/checkout@") } == 1
    uses.count("d3mlabs/dev/up@main") == 1
    up_at = uses.index("d3mlabs/dev/up@main")
    up_at > uses.index { |value| value.start_with?("actions/checkout@") }
    series_at = names.index { |name| SERIES_CHECK_STEPS.include?(name) }
    posture_at = runs.index("dev runner status --check")
    entry_at = runs.index("shadowenv exec -- #{entry}")
    up_at < series_at
    series_at < posture_at
    posture_at < entry_at
    job_steps.none? { |step| step.key?("working-directory") }

    Where
    workflow             | job             | entry
    "ai-commands.yml"    | "dispatch"      | "ai-flow dispatch"
    "origin-firing.yml"  | "origin-firing" | "ai-flow gate"
  end

  test "#{workflow}'s self rule puts the checkout's exe/ on the job PATH, and runs only when the caller is this repository" do
    Given "the step"
    step = step_named(workflow, job, SELF_RULE_STEP)

    When "its script runs"
    ok, _output, appended, workspace = run_step(step)

    Then "the rule is the repository's name, not a sniff of the checkout"
    step["if"] == "github.repository == 'd3mlabs/ai-flow'"
    ok
    appended == "#{workspace}/exe\n"

    Where
    workflow            | job
    "ai-commands.yml"   | "dispatch"
    "origin-firing.yml" | "origin-firing"
  end

  test "#{workflow}'s series check holds SHELL_SERIES to this checkout's VERSION" do
    Expect "a major bump that forgets the YAML fails here"
    step_named(workflow, job, SERIES_CHECK_STEPS).fetch("env").fetch("SHELL_SERIES") == SERIES.major.to_s

    Where
    workflow            | job
    "ai-commands.yml"   | "dispatch"
    "origin-firing.yml" | "origin-firing"
  end

  test "#{workflow}'s series check passes a dispatcher of its series and fails every other answer: #{name}" do
    Given "the step, with `ai-flow version` answering #{version.inspect}"
    step = step_named(workflow, job, SERIES_CHECK_STEPS)

    When "its script runs for a v1 shell"
    ok, output, = run_step(step, env: { "SHELL_SERIES" => "1" }, version: version)

    Then
    ok == passes
    passes || output.include?("::error::")
    says.nil? || output.include?(says)

    Where
    workflow            | job             | name                  | version              | passes | says
    "ai-commands.yml"   | "dispatch"      | "the series"          | "1.4.2 (ruby 4.0.6)" | true   | nil
    "ai-commands.yml"   | "dispatch"      | "the next major"      | "2.0.0 (ruby 4.1.0)" | false  | "call the workflow at @v2"
    "ai-commands.yml"   | "dispatch"      | "nothing on the PATH" | nil                  | false  | "does not install ai-flow"
    "origin-firing.yml" | "origin-firing" | "the series"          | "1.0.0 (ruby 4.0.6)" | true   | nil
    "origin-firing.yml" | "origin-firing" | "the next major"      | "2.1.0 (ruby 4.1.0)" | false  | "install a 1.x release"
  end

  test "#{file} calls the reusable workflow at this checkout's series tag, never a branch" do
    Given "the file's one job"
    jobs = YAML.safe_load(File.read(File.join(AI_FLOW_ROOT, file))).fetch("jobs")
    uses = jobs.values.map { |job| job.fetch("uses") }

    Expect "@v<major> of VERSION — the tag `dev deploy gh` moves and `ai-flow adopt` writes"
    uses.size == 1
    uses.first == "d3mlabs/ai-flow/#{reusable}@#{SERIES.tag}"

    Where
    file                                        | reusable
    "templates/caller-workflow.yml"             | ".github/workflows/ai-commands.yml"
    "templates/proposal-checks.yml"             | ".github/workflows/origin-firing.yml"
    ".github/workflows/ai-commands-caller.yml"  | ".github/workflows/ai-commands.yml"
  end
end
