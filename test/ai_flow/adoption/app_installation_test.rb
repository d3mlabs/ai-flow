# typed: true
# frozen_string_literal: true

require "test_helper"
require "support/fakes"

transform!(RSpock::AST::Transformation)
class AiFlow::Adoption::AppInstallationTest < Minitest::Test
  REPOSITORY = AiFlow::GitHub::Repository.new(id: 777, full_name: "acme/widgets", visibility: "private")

  test "an App installed on every repo in the org is settled" do
    Given
    github = FakeGitHub.new
    github.seed_app_installation("acme", id: 55, app_slug: "ai-flow", repository_selection: "all")

    When
    outcome = AiFlow::Adoption::AppInstallation.new(github: github).converge(REPOSITORY, "ai-flow")

    Then
    outcome == AiFlow::Adoption::Outcome::Settled.new(step: "ai-flow App", detail: "installed on every repository in acme")
  end

  test "an App installed on a selection that includes the repo is settled" do
    Given
    github = FakeGitHub.new
    github.seed_app_installation("acme", id: 55, app_slug: "ai-flow", repository_selection: "selected",
      repositories: ["acme/other", "acme/widgets"])

    When
    outcome = AiFlow::Adoption::AppInstallation.new(github: github).converge(REPOSITORY, "ai-flow")

    Then
    outcome == AiFlow::Adoption::Outcome::Settled.new(step: "ai-flow App", detail: "installed on acme/widgets")
  end

  test "an App installed in the org but not on the repo is a finding with the installation's settings page" do
    Given "the installation selects other repos"
    github = FakeGitHub.new
    github.seed_app_installation("acme", id: 55, app_slug: "ai-flow", repository_selection: "selected", repositories: ["acme/other"])

    When
    outcome = AiFlow::Adoption::AppInstallation.new(github: github).converge(REPOSITORY, "ai-flow")

    Then "no write was attempted — there is none to attempt"
    outcome == AiFlow::Adoption::Outcome::Finding.new(
      step: "ai-flow App",
      detail: "installed in acme but not on acme/widgets",
      remedy: "add the repository at https://github.com/organizations/acme/settings/installations/55",
    )
  end

  test "an App not installed in the org at all points at the App's install page, under the slug asked for" do
    Given "an org with another App only"
    github = FakeGitHub.new
    github.seed_app_installation("acme", id: 9, app_slug: "dependabot", repository_selection: "all")

    When "converging under the org's own slug"
    outcome = AiFlow::Adoption::AppInstallation.new(github: github).converge(REPOSITORY, "acme-ai-flow")

    Then
    outcome == AiFlow::Adoption::Outcome::Finding.new(
      step: "acme-ai-flow App",
      detail: "not installed in acme",
      remedy: "install it on acme/widgets: https://github.com/apps/acme-ai-flow/installations/new",
    )
  end

  test "an owner whose installations cannot be listed (a user account, or not its owner) is a finding, not a crash" do
    Given "a fake that knows no such org"
    github = FakeGitHub.new

    When
    outcome = AiFlow::Adoption::AppInstallation.new(github: github).converge(REPOSITORY, "ai-flow")

    Then
    outcome.is_a?(AiFlow::Adoption::Outcome::Finding)
    T.cast(outcome, AiFlow::Adoption::Outcome::Finding).detail.start_with?("cannot list acme's App installations")
    T.cast(outcome, AiFlow::Adoption::Outcome::Finding).remedy.include?("https://github.com/settings/installations")
  end
end
