# typed: strict
# frozen_string_literal: true

module AiFlow
  class Adoption
    # Whether the ai-flow GitHub App is installed on the adopting repo —
    # the one step that is a finding only. Installing an App on a repo has
    # no REST write a human's token can perform (the installation endpoints
    # are the App's own, under its JWT), so adopt reads the org's
    # installations as its owner and prints the settings page where the
    # repo is added.
    class AppInstallation
      extend T::Sig

      # @param github [AiFlow::GitHub]
      sig { params(github: GitHub).void }
      def initialize(github:)
        @github = github
      end

      # @param repository [GitHub::Repository] the adopting repo
      # @param app_slug [String] the App's slug (its URL name)
      # @return [Outcome] Settled when installed on the repo, Finding
      #   otherwise — adopt never installs
      sig { params(repository: GitHub::Repository, app_slug: String).returns(Outcome) }
      def converge(repository, app_slug)
        org = repository.owner
        step = "#{app_slug} App"
        installations = begin
          @github.org_app_installations(org)
        rescue GitHub::NotFound
          return Outcome::Finding.new(
            step: step,
            detail: "cannot list #{org}'s App installations (not an organization, or this gh login is not an org owner)",
            remedy: "check the App is installed on #{repository.full_name}: https://github.com/settings/installations",
          )
        end

        installation = installations.find { |candidate| candidate.app_slug == app_slug }
        unless installation
          return Outcome::Finding.new(
            step: step,
            detail: "not installed in #{org}",
            remedy: "install it on #{repository.full_name}: https://github.com/apps/#{app_slug}/installations/new",
          )
        end

        selection = installation.repository_selection
        case selection
        when GitHub::AppInstallation::RepositorySelection::All
          Outcome::Settled.new(step: step, detail: "installed on every repository in #{org}")
        when GitHub::AppInstallation::RepositorySelection::Selected
          if @github.installation_repositories(installation.id).include?(repository.full_name)
            Outcome::Settled.new(step: step, detail: "installed on #{repository.full_name}")
          else
            Outcome::Finding.new(
              step: step,
              detail: "installed in #{org} but not on #{repository.full_name}",
              remedy: "add the repository at https://github.com/organizations/#{org}/settings/installations/#{installation.id}",
            )
          end
        else
          T.absurd(selection)
        end
      end
    end
  end
end
