# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "support/fakes"

transform!(RSpock::AST::Transformation)
class AiFlow::Adoption::SecretAccessTest < Minitest::Test
  def repository(visibility: "private")
    AiFlow::GitHub::Repository.new(id: 777, full_name: "acme/widgets", visibility: visibility)
  end

  test "a selected-visibility secret gains the repo on its list — the PUT dev#470 refused to leave to humans" do
    Given "an org secret shared with other repos only"
    github = FakeGitHub.new
    github.seed_repository("acme/widgets", id: 777)
    github.seed_org_secret("acme", "CURSOR_API_KEY", visibility: "selected", repositories: ["acme/other"])

    When "converging"
    outcome = AiFlow::Adoption::SecretAccess.new(github: github).converge(repository, "CURSOR_API_KEY")

    Then "the repo was PUT by id and the outcome says so"
    github.calls.include?([:add_org_secret_repository, "acme", "CURSOR_API_KEY", 777])
    github.org_secret_repositories("acme", "CURSOR_API_KEY") == ["acme/other", "acme/widgets"]
    outcome == AiFlow::Adoption::Outcome::Changed.new(
      step: "org secret CURSOR_API_KEY", detail: "acme/widgets added to its selected repositories",
    )
  end

  test "a selected-visibility secret already listing the repo is settled, with no PUT — re-running converges to the same place" do
    Given "the repo already on the list"
    github = FakeGitHub.new
    github.seed_org_secret("acme", "AI_FLOW_APP_ID", visibility: "selected", repositories: ["acme/widgets"])

    When "converging"
    outcome = AiFlow::Adoption::SecretAccess.new(github: github).converge(repository, "AI_FLOW_APP_ID")

    Then
    github.third_args(:add_org_secret_repository) == []
    outcome == AiFlow::Adoption::Outcome::Settled.new(
      step: "org secret AI_FLOW_APP_ID", detail: "acme/widgets is among its selected repositories",
    )
  end

  test "a secret visible to the whole org is settled" do
    Given
    github = FakeGitHub.new
    github.seed_org_secret("acme", "CURSOR_API_KEY", visibility: "all")

    When
    outcome = AiFlow::Adoption::SecretAccess.new(github: github).converge(repository, "CURSOR_API_KEY")

    Then
    outcome == AiFlow::Adoption::Outcome::Settled.new(
      step: "org secret CURSOR_API_KEY", detail: "visible to every repository in acme",
    )
  end

  test "a private-visibility secret reaches a #{repo_visibility} repo: #{kind}" do
    Given "a secret shared with the org's private repos"
    github = FakeGitHub.new
    github.seed_org_secret("acme", "CURSOR_API_KEY", visibility: "private")

    When "converging a repo of that visibility"
    outcome = AiFlow::Adoption::SecretAccess.new(github: github).converge(repository(visibility: repo_visibility), "CURSOR_API_KEY")

    Then "the posture is reported, never changed — only the secret's owner can switch its visibility"
    outcome.class == kind
    github.third_args(:add_org_secret_repository) == []

    Where
    repo_visibility | kind
    "private"       | AiFlow::Adoption::Outcome::Settled
    "internal"      | AiFlow::Adoption::Outcome::Settled
    "public"        | AiFlow::Adoption::Outcome::Finding
  end

  test "a private-visibility secret over a public repo tells the adopter how to switch it" do
    Given
    github = FakeGitHub.new
    github.seed_org_secret("acme", "CURSOR_API_KEY", visibility: "private")

    When
    outcome = AiFlow::Adoption::SecretAccess.new(github: github).converge(repository(visibility: "public"), "CURSOR_API_KEY")

    Then
    outcome.detail == "visibility is private, which excludes the public acme/widgets"
    outcome.remedy.include?("gh secret set CURSOR_API_KEY --org acme --visibility selected --repos acme/widgets")
  end

  test "a secret the org does not have (or this login cannot see) is a finding with the creating command" do
    Given "no such org secret"
    github = FakeGitHub.new

    When
    outcome = AiFlow::Adoption::SecretAccess.new(github: github).converge(repository, "AI_FLOW_APP_PRIVATE_KEY")

    Then
    outcome.is_a?(AiFlow::Adoption::Outcome::Finding)
    outcome.step == "org secret AI_FLOW_APP_PRIVATE_KEY"
    outcome.detail.start_with?("not found in acme")
    outcome.remedy.include?("gh secret set AI_FLOW_APP_PRIVATE_KEY --org acme --visibility selected --repos acme/widgets")
  end
end
