# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "yaml"

transform!(RSpock::AST::Transformation)
# The reusable workflows are a shell whose contract holds across a major
# (plans#76, ai-flow#186): check out the adopter → `dev up` (the adopter's
# lock, the dispatcher among it) → `dev runner status --check` → `ai-flow
# dispatch` / `ai-flow gate`. No second checkout and no per-job install:
# the dispatcher a job runs is the adopter's lock's, and this YAML is what
# the adopter's `@v<major>` resolves to.
class ThinShellTest < Minitest::Test
  WORKFLOWS_DIR = File.join(AI_FLOW_ROOT, ".github", "workflows")
  SERIES = AiFlow::Series.of_tree(AI_FLOW_ROOT)

  def steps(workflow, job)
    YAML.safe_load(File.read(File.join(WORKFLOWS_DIR, workflow))).fetch("jobs").fetch(job).fetch("steps")
  end

  test "no shipped workflow checks ai-flow out or installs it per job" do
    Given "every workflow under .github"
    texts = Dir.glob(File.join(WORKFLOWS_DIR, "*.yml")).to_h { |path| [File.basename(path), File.read(path)] }

    Expect "the acceptance grep: rg '\\.ai-flow|dev deps install' .github returns nothing"
    !texts.empty?
    texts.select { |_name, text| text.match?(/\.ai-flow\b|dev deps install/) }.keys == []
  end

  test "#{workflow}'s #{job} job runs dev/up, then the posture check, then `#{entry}` — in that order, in the adopter's checkout" do
    Given "the job's steps"
    job_steps = steps(workflow, job)
    uses = job_steps.map { |step| step["uses"].to_s }
    runs = job_steps.map { |step| step["run"].to_s }

    Expect "one checkout, dev/up after it, the two dev-and-ai-flow steps after that"
    uses.count { |value| value.start_with?("actions/checkout@") } == 1
    uses.count("d3mlabs/dev/up@main") == 1
    up_at = uses.index("d3mlabs/dev/up@main")
    up_at > uses.index { |value| value.start_with?("actions/checkout@") }
    posture_at = runs.index("dev runner status --check")
    entry_at = runs.index("shadowenv exec -- #{entry}")
    up_at < posture_at
    posture_at < entry_at
    job_steps.none? { |step| step.key?("working-directory") }

    Where
    workflow             | job             | entry
    "ai-commands.yml"    | "dispatch"      | "ai-flow dispatch"
    "origin-firing.yml"  | "origin-firing" | "ai-flow gate"
  end

  test "#{workflow}'s self rule puts the checkout's exe/ on the job PATH only when the checkout is ai-flow: #{name}" do
    Given "the step's script, run in a checkout shaped that way"
    step = steps(workflow, job).find { |candidate| candidate["run"].to_s.include?("GITHUB_PATH") }
    appended, workspace = Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "exe"))
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "dev.yml"), dev_yml) if dev_yml
      File.write(File.join(dir, "lib", "ai_flow.rb"), "") if lib
      if exe
        File.write(File.join(dir, "exe", "ai-flow"), "#!/bin/sh\n")
        File.chmod(0o755, File.join(dir, "exe", "ai-flow"))
      end
      path_file = File.join(dir, "github_path")
      File.write(path_file, "")
      env = { "GITHUB_WORKSPACE" => dir, "GITHUB_PATH" => path_file }
      _out, err, status = Open3.capture3(env, "bash", "-e", "-c", step.fetch("run"), chdir: dir)
      raise "self-rule script failed: #{err}" unless status.success?

      [File.read(path_file), dir]
    end

    Expect
    appended == (resolves_to_checkout ? "#{workspace}/exe\n" : "")

    Where
    workflow            | job             | name                   | dev_yml                  | lib   | exe   | resolves_to_checkout
    "ai-commands.yml"   | "dispatch"      | "ai-flow's checkout"   | "name: ai-flow\n"        | true  | true  | true
    "ai-commands.yml"   | "dispatch"      | "an adopter"           | "name: widgets\n"        | true  | true  | false
    "ai-commands.yml"   | "dispatch"      | "no dev.yml"           | nil                      | true  | true  | false
    "ai-commands.yml"   | "dispatch"      | "no exe"               | "name: ai-flow\n"        | true  | false | false
    "origin-firing.yml" | "origin-firing" | "ai-flow's checkout"   | "name: ai-flow\n"        | true  | true  | true
    "origin-firing.yml" | "origin-firing" | "an adopter"           | "name: knowledge\n"      | false | false | false
  end

  test "#{file} calls the reusable workflow at this checkout's series tag, never a branch" do
    Given "the file's one job"
    jobs = YAML.safe_load(File.read(File.join(AI_FLOW_ROOT, file))).fetch("jobs")
    uses = jobs.values.map { |job| job.fetch("uses") }

    Expect "@v<major> of VERSION — the ref `dev deploy gh` moves and `ai-flow adopt` writes"
    uses.size == 1
    uses.first == "d3mlabs/ai-flow/#{reusable}@#{SERIES.tag}"

    Where
    file                                        | reusable
    "templates/caller-workflow.yml"             | ".github/workflows/ai-commands.yml"
    "templates/proposal-checks.yml"             | ".github/workflows/origin-firing.yml"
    ".github/workflows/ai-commands-caller.yml"  | ".github/workflows/ai-commands.yml"
  end
end
