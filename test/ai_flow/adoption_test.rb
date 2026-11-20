# typed: true
# frozen_string_literal: true

require "test_helper"
require "support/fakes"
require "support/value_semantics_assertions"
require "fileutils"
require "tmpdir"
require "yaml"

transform!(RSpock::AST::Transformation)
class AiFlow::AdoptionTest < Minitest::Test
  include ValueSemanticsAssertions

  REUSABLE_WORKFLOW = File.join(AI_FLOW_ROOT, ".github", "workflows", "ai-commands.yml")
  CALLER_TEMPLATE = File.join(AI_FLOW_ROOT, AiFlow::Adoption::CALLER_WORKFLOW_TEMPLATE)

  # An org where everything adopt can converge is one step away, and the
  # App is installed on a selection without the repo.
  def seeded_github
    github = FakeGitHub.new
    github.seed_repository("acme/widgets", id: 777)
    AiFlow::Adoption::SECRETS.each do |name|
      github.seed_org_secret("acme", name, visibility: "selected", repositories: ["acme/other"])
    end
    github.seed_app_installation("acme", id: 55, app_slug: "ai-flow", repository_selection: "selected", repositories: ["acme/other"])
    github
  end

  test "SECRETS names exactly the secrets the reusable workflow declares and the caller template forwards" do
    Given "the two YAML surfaces the names live on"
    # YAML 1.1 reads the `on:` key as the boolean true.
    declared = YAML.safe_load(File.read(REUSABLE_WORKFLOW)).fetch(true).fetch("workflow_call").fetch("secrets").keys
    forwarded = YAML.safe_load(File.read(CALLER_TEMPLATE)).fetch("jobs").fetch("ai-commands").fetch("secrets").keys

    Expect "the documented literal is the same set as both"
    declared.sort == AiFlow::Adoption::SECRETS.sort
    forwarded.sort == AiFlow::Adoption::SECRETS.sort
  end

  test "a first run on a bare checkout writes both files, shares every secret, and reports the App — in step order" do
    Given "an empty checkout and the seeded org"
    checkout = Dir.mktmpdir("ai-flow-adopt-")
    github = seeded_github

    When "converging"
    outcomes = AiFlow::Adoption.new(github: github, root: AI_FLOW_ROOT)
      .converge(owner_repo: "acme/widgets", checkout: checkout, knowledge_repo: "acme/knowledge")

    Then "files first, then the three secrets, then the App; the repo was resolved once up front"
    outcomes.map(&:class) == [
      AiFlow::Adoption::Outcome::Changed, AiFlow::Adoption::Outcome::Changed,
      AiFlow::Adoption::Outcome::Changed, AiFlow::Adoption::Outcome::Changed, AiFlow::Adoption::Outcome::Changed,
      AiFlow::Adoption::Outcome::Finding,
    ]
    outcomes.map(&:step) == [
      ".github/workflows/ai-commands.yml", ".github/ai-flow.yml",
      "org secret CURSOR_API_KEY", "org secret AI_FLOW_APP_ID", "org secret AI_FLOW_APP_PRIVATE_KEY",
      "ai-flow App",
    ]
    github.calls.first == [:repository, "acme/widgets"]
    File.read(File.join(checkout, AiFlow::Adoption::CALLER_WORKFLOW_PATH)) == File.read(CALLER_TEMPLATE)
    AiFlow::RepoConfig.load(checkout).knowledge_repo == "acme/knowledge"
    AiFlow::Adoption::SECRETS.all? { |name| github.org_secret_repositories("acme", name).include?("acme/widgets") }

    Cleanup
    FileUtils.rm_rf(checkout)
  end

  test "a second run over the same checkout and org settles every step it converged and repeats only the finding" do
    Given "a checkout and org adopt already ran on"
    checkout = Dir.mktmpdir("ai-flow-adopt-")
    github = seeded_github
    adoption = AiFlow::Adoption.new(github: github, root: AI_FLOW_ROOT)
    adoption.converge(owner_repo: "acme/widgets", checkout: checkout)

    When "converging again"
    outcomes = adoption.converge(owner_repo: "acme/widgets", checkout: checkout)

    Then "nothing changed; the App is still the human's to install"
    outcomes.map(&:class) == [
      AiFlow::Adoption::Outcome::Settled, AiFlow::Adoption::Outcome::Settled,
      AiFlow::Adoption::Outcome::Settled, AiFlow::Adoption::Outcome::Settled, AiFlow::Adoption::Outcome::Settled,
      AiFlow::Adoption::Outcome::Finding,
    ]
    github.third_args(:add_org_secret_repository).size == AiFlow::Adoption::SECRETS.size

    Cleanup
    FileUtils.rm_rf(checkout)
  end

  test "the App slug is the adopter's to name" do
    Given "an org whose App carries its own slug"
    checkout = Dir.mktmpdir("ai-flow-adopt-")
    github = seeded_github
    github.seed_app_installation("acme", id: 56, app_slug: "acme-ai-flow", repository_selection: "all")

    When "converging under that slug"
    outcomes = AiFlow::Adoption.new(github: github, root: AI_FLOW_ROOT)
      .converge(owner_repo: "acme/widgets", checkout: checkout, app_slug: "acme-ai-flow")

    Then
    outcomes.last == AiFlow::Adoption::Outcome::Settled.new(step: "acme-ai-flow App", detail: "installed on every repository in acme")

    Cleanup
    FileUtils.rm_rf(checkout)
  end

  test "a checkout that is not a directory is refused before anything is read or written" do
    Given
    github = seeded_github

    When "converging on a path that does not exist"
    AiFlow::Adoption.new(github: github, root: AI_FLOW_ROOT).converge(owner_repo: "acme/widgets", checkout: "/nonexistent/checkout")

    Then
    raises AiFlow::Adoption::NoCheckoutError
    github.calls.empty?
  end

  test "a repository GitHub does not know fails before any file is written" do
    Given "an empty checkout and a repo the fake has not seeded"
    checkout = Dir.mktmpdir("ai-flow-adopt-")

    When
    AiFlow::Adoption.new(github: FakeGitHub.new, root: AI_FLOW_ROOT).converge(owner_repo: "acme/typo", checkout: checkout)

    Then
    raises AiFlow::GitHub::NotFound
    Dir.children(checkout).empty?

    Cleanup
    FileUtils.rm_rf(checkout)
  end

  test "outcomes are values: equal by kind and members" do
    Expect
    assert_value_semantics(
      AiFlow::Adoption::Outcome::Changed.new(step: "a", detail: "b"),
      equal_to: AiFlow::Adoption::Outcome::Changed.new(step: "a", detail: "b"),
      unequal_to: [
        AiFlow::Adoption::Outcome::Changed.new(step: "a", detail: "c"),
        AiFlow::Adoption::Outcome::Settled.new(step: "a", detail: "b"),
      ],
    )
    assert_value_semantics(
      AiFlow::Adoption::Outcome::Settled.new(step: "a", detail: "b"),
      equal_to: AiFlow::Adoption::Outcome::Settled.new(step: "a", detail: "b"),
      unequal_to: [AiFlow::Adoption::Outcome::Settled.new(step: "x", detail: "b")],
    )
    assert_value_semantics(
      AiFlow::Adoption::Outcome::Finding.new(step: "a", detail: "b", remedy: "c"),
      equal_to: AiFlow::Adoption::Outcome::Finding.new(step: "a", detail: "b", remedy: "c"),
      unequal_to: [AiFlow::Adoption::Outcome::Finding.new(step: "a", detail: "b", remedy: "d")],
    )
  end
end
