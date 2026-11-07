# typed: false — rspock Where tables
# frozen_string_literal: true

require "test_helper"
require "yaml"
require "open3"
require "tmpdir"

transform!(RSpock::AST::Transformation)
# The authorize job's scan step is a shell script inside the workflow yaml;
# the dispatch job's `runs-on` and `timeout-minutes` read what it emits.
# Running the script itself (with the engine expressions it embeds
# substituted) is what makes the routing a tested fact rather than a
# comment — plans#53's orchestrator route depends on it.
class AiCommandsRoutingTest < Minitest::Test
  WORKFLOW_PATH = File.join(AI_FLOW_ROOT, ".github", "workflows", "ai-commands.yml")

  test "the scan routes #{body.inspect} (prefix #{prefix.inspect}) to #{runner}" do
    Given "the scan step's script, run as an issue_comment with that body"
    outputs = run_scan(body: body, prefix: prefix)

    Expect
    outputs["commanded"] == "true"
    outputs["runner"] == runner

    Where
    body                                                              | prefix | runner
    "/build"                                                          | ""     | "ai-build"
    "/build --split"                                                  | ""     | "ai-orchestrator"
    "/build  --split please"                                          | ""     | "ai-orchestrator"
    "/d-build --split"                                                | "d-"   | "ai-orchestrator"
    "/build --base=https://github.com/d3mlabs/dev/pull/1 --for=jane"  | ""     | "ai-build"
    "/ask what would /build --split do here?"                         | ""     | "ai-orchestrator"
    "/split --dry"                                                    | ""     | "ai-split"
  end

  test "the dispatch job takes the scan's runner label and gives the orchestrator route six hours" do
    Given "the dispatch job"
    job = YAML.safe_load(File.read(WORKFLOW_PATH)).fetch("jobs").fetch("dispatch")

    Expect "runs-on is the scan's label; the timeout is 360 on the orchestrator route and 120 otherwise"
    job.fetch("runs-on").include?("needs.authorize.outputs.runner")
    job.fetch("timeout-minutes") == "${{ needs.authorize.outputs.runner == 'ai-orchestrator' && 360 || 120 }}"
  end

  private

  # Run the scan step's `run:` script as bash would on the runner, for an
  # issue_comment event, returning the GITHUB_OUTPUT key/value pairs.
  def run_scan(body:, prefix:)
    workflow = YAML.safe_load(File.read(WORKFLOW_PATH))
    step = workflow.fetch("jobs").fetch("authorize").fetch("steps").find { |candidate| candidate["id"] == "scan" }
    script = step.fetch("run").gsub("${{ github.event_name }}", "issue_comment")
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "output")
      File.write(output_path, "")
      env = { "COMMENT_BODY" => body, "REVIEW_BODY" => "", "PREFIX" => prefix, "GITHUB_OUTPUT" => output_path }
      _stdout, stderr, status = Open3.capture3(env, "bash", "-e", "-c", script)
      raise "scan script failed: #{stderr}" unless status.success?

      File.readlines(output_path, chomp: true).to_h { |line| line.split("=", 2) }
    end
  end
end
