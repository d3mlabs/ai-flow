# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "yaml"

transform!(RSpock::AST::Transformation)
class AiFlow::Adoption::CallerWorkflowTest < Minitest::Test
  TEMPLATE = File.join(AI_FLOW_ROOT, AiFlow::Adoption::CALLER_WORKFLOW_TEMPLATE)
  TEMPLATE_USES = YAML.safe_load(File.read(TEMPLATE)).fetch("jobs").fetch("ai-commands").fetch("uses")

  # The step over the shipped template, against a checkout that carries
  # `content` at the caller path (nothing when nil).
  def converge(content)
    Dir.mktmpdir("ai-flow-adopt-") do |checkout|
      unless content.nil?
        FileUtils.mkdir_p(File.join(checkout, ".github", "workflows"))
        File.write(File.join(checkout, AiFlow::Adoption::CALLER_WORKFLOW_PATH), content)
      end
      outcome = AiFlow::Adoption::CallerWorkflow.new(template: TEMPLATE).converge(checkout)
      return [outcome, File.read(File.join(checkout, AiFlow::Adoption::CALLER_WORKFLOW_PATH))]
    end
  end

  test "an absent caller workflow is written from the template, byte for byte" do
    When "converging a checkout without one"
    outcome, written = converge(nil)

    Then "the template landed and the outcome says to commit it"
    written == File.read(TEMPLATE)
    outcome == AiFlow::Adoption::Outcome::Changed.new(
      step: ".github/workflows/ai-commands.yml",
      detail: "written from templates/caller-workflow.yml — commit and push it",
    )
  end

  test "a present caller workflow calling the template's ref is settled, and left alone" do
    Given "an adopter's copy, hand-edited but calling the same reusable workflow"
    content = "name: mine\non: issue_comment\njobs:\n  cmd:\n    uses: #{TEMPLATE_USES}\n"

    When "converging"
    outcome, after = converge(content)

    Then "nothing was rewritten"
    after == content
    outcome == AiFlow::Adoption::Outcome::Settled.new(step: ".github/workflows/ai-commands.yml", detail: "calls #{TEMPLATE_USES}")
  end

  test "a present caller workflow pinned to another ref is a drift finding naming both refs" do
    Given "a caller pinned to a tag"
    pinned = TEMPLATE_USES.sub(/@.*\z/, "@v0.3.1")
    content = "jobs:\n  ai-commands:\n    uses: #{pinned}\n"

    When "converging"
    outcome, after = converge(content)

    Then "the adopter's file is untouched and the finding says what to set"
    after == content
    outcome.is_a?(AiFlow::Adoption::Outcome::Finding)
    outcome.detail == "calls #{pinned}, not #{TEMPLATE_USES}"
    outcome.remedy.include?("set the job's `uses:` to #{TEMPLATE_USES}")
  end

  test "a present file that is not a caller workflow is a finding: #{name}" do
    When "converging over it"
    outcome, _after = converge(content)

    Then
    outcome.is_a?(AiFlow::Adoption::Outcome::Finding)
    outcome.detail.start_with?(detail_start)

    Where
    name                  | content                              | detail_start
    "no jobs"             | "name: x\non: push\n"                | "calls no reusable workflow"
    "a job without uses"  | "jobs:\n  a:\n    runs-on: x\n"      | "calls no reusable workflow"
    "a scalar document"   | "just text\n"                        | "calls no reusable workflow"
    "invalid YAML"        | "jobs: [\n"                          | "is not valid YAML"
  end

  test "a template calling no reusable workflow is ai-flow's own error" do
    Given "a broken template"
    dir = Dir.mktmpdir("ai-flow-adopt-")
    template = File.join(dir, "caller-workflow.yml")
    File.write(template, "jobs:\n  a:\n    runs-on: x\n")

    When "converging an empty checkout over it"
    AiFlow::Adoption::CallerWorkflow.new(template: template).converge(dir)

    Then
    raises AiFlow::Adoption::CallerWorkflow::TemplateWithoutUsesError

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
