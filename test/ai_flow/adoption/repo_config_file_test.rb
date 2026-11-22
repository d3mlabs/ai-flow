# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class AiFlow::Adoption::RepoConfigFileTest < Minitest::Test
  TEMPLATE = File.join(AI_FLOW_ROOT, AiFlow::Adoption::REPO_CONFIG_TEMPLATE)

  # The step over the shipped template, against a checkout carrying
  # `content` at .github/ai-flow.yml (nothing when nil). Returns the
  # outcome and the file as the step left it.
  def converge(content, knowledge_repo: nil)
    Dir.mktmpdir("ai-flow-adopt-") do |checkout|
      unless content.nil?
        FileUtils.mkdir_p(File.join(checkout, ".github"))
        File.write(File.join(checkout, AiFlow::RepoConfig::PATH), content)
      end
      step = AiFlow::Adoption::RepoConfigFile.new(template: TEMPLATE)
      outcome = step.converge(checkout, knowledge_repo: knowledge_repo)
      return [outcome, File.read(File.join(checkout, AiFlow::RepoConfig::PATH)), AiFlow::RepoConfig.load(checkout)]
    end
  end

  test "the shipped template carries the line a knowledge repo is filled into" do
    Expect "the substitution target exists exactly once, commented out"
    File.read(TEMPLATE).scan(AiFlow::Adoption::RepoConfigFile::KNOWLEDGE_REPO_LINE).size == 1
  end

  test "an absent config is written from the template as is when no knowledge repo is named" do
    When "converging an empty checkout"
    outcome, written, config = converge(nil)

    Then "the template landed verbatim, so the key stays commented out"
    written == File.read(TEMPLATE)
    config.knowledge_repo.nil?
    outcome == AiFlow::Adoption::Outcome::Changed.new(
      step: ".github/ai-flow.yml", detail: "written from templates/ai-flow.yml — commit and push it",
    )
  end

  test "an absent config is written with the named knowledge repo filled in" do
    When "converging with a knowledge repo"
    outcome, written, config = converge(nil, knowledge_repo: "acme/knowledge")

    Then "the generated file reads back through RepoConfig with that repo, and the rest of the template survives"
    config.knowledge_repo == "acme/knowledge"
    written.include?("knowledge_repo: acme/knowledge")
    !written.include?(AiFlow::Adoption::RepoConfigFile::KNOWLEDGE_REPO_LINE)
    written.include?("models:")
    outcome == AiFlow::Adoption::Outcome::Changed.new(
      step: ".github/ai-flow.yml",
      detail: "written from templates/ai-flow.yml with knowledge_repo: acme/knowledge — commit and push it",
    )
  end

  test "a present config is the adopter's: left as is, settled" do
    Given "an adopter's policy file"
    content = "models:\n  default: opus\n"

    When "converging without a knowledge repo"
    outcome, after, _config = converge(content)

    Then
    after == content
    outcome == AiFlow::Adoption::Outcome::Settled.new(step: ".github/ai-flow.yml", detail: "present, left as is")
  end

  test "a present config naming the requested knowledge repo is settled" do
    When "converging with the repo the file already names"
    outcome, _after, _config = converge("knowledge_repo: acme/knowledge\n", knowledge_repo: "acme/knowledge")

    Then
    outcome == AiFlow::Adoption::Outcome::Settled.new(step: ".github/ai-flow.yml", detail: "present, names acme/knowledge")
  end

  test "a present config that disagrees with the requested knowledge repo is a finding, not an edit: #{name}" do
    When "converging with a knowledge repo the file does not name"
    outcome, after, _config = converge(content, knowledge_repo: "acme/knowledge")

    Then "the file is untouched and the finding says what it found"
    after == content
    outcome.is_a?(AiFlow::Adoption::Outcome::Finding)
    outcome.detail == detail
    outcome.remedy.include?("knowledge_repo: acme/knowledge")

    Where
    name            | content                                | detail
    "another repo"  | "knowledge_repo: other/knowledge\n"    | "names knowledge_repo other/knowledge, not acme/knowledge"
    "no repo"       | "models:\n  default: opus\n"           | "sets no knowledge_repo"
  end

  test "a present config that is not valid is a finding carrying RepoConfig's message" do
    Given "a file RepoConfig refuses"
    dir = Dir.mktmpdir("ai-flow-adopt-")
    FileUtils.mkdir_p(File.join(dir, ".github"))
    File.write(File.join(dir, AiFlow::RepoConfig::PATH), "- not\n- a mapping\n")

    When "converging"
    outcome = AiFlow::Adoption::RepoConfigFile.new(template: TEMPLATE).converge(dir, knowledge_repo: nil)

    Then
    outcome.is_a?(AiFlow::Adoption::Outcome::Finding)
    outcome.detail == ".github/ai-flow.yml must be a YAML mapping"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a template without the knowledge-repo line is ai-flow's own error when one is asked for" do
    Given "a template missing the line"
    dir = Dir.mktmpdir("ai-flow-adopt-")
    template = File.join(dir, "ai-flow.yml")
    File.write(template, "models:\n  default: opus\n")

    When "converging an empty checkout with a knowledge repo"
    AiFlow::Adoption::RepoConfigFile.new(template: template).converge(dir, knowledge_repo: "acme/knowledge")

    Then
    raises AiFlow::Adoption::RepoConfigFile::TemplateWithoutKnowledgeRepoError

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
