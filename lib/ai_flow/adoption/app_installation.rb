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
    #
    # Which App is "the ai-flow App" is read from the org's installations,
    # not assumed: GitHub App slugs are one global namespace, and an org
    # whose `ai-flow` was taken registers its App under its own prefix
    # (`d3mlabs-ai-flow`). The App is the one installation named
    # {APP_NAME}, plain or `<prefix>-` prefixed; `--app` names it outright.
    class AppInstallation
      extend T::Sig

      # The App's name; an org's slug is this, or this behind a prefix.
      APP_NAME = "ai-flow"

      # @param github [AiFlow::GitHub]
      sig { params(github: GitHub).void }
      def initialize(github:)
        @github = github
      end

      # @param repository [GitHub::Repository] the adopting repo
      # @param app_slug [String, nil] the App's slug (its URL name); nil
      #   finds the org's ai-flow App among its installations
      # @return [Outcome] Settled when installed on the repo, Finding
      #   otherwise — adopt never installs
      sig { params(repository: GitHub::Repository, app_slug: T.nilable(String)).returns(Outcome) }
      def converge(repository, app_slug)
        org = repository.owner
        step = "#{app_slug || APP_NAME} App"
        installations = begin
          @github.org_app_installations(org)
        rescue GitHub::NotFound
          return Outcome::Finding.new(
            step: step,
            detail: "cannot list #{org}'s App installations (not an organization, or this gh login is not an org owner)",
            remedy: "check the App is installed on #{repository.full_name}: https://github.com/settings/installations",
          )
        end

        installation = app_slug ? named(installations, app_slug) : found(installations, org)
        return not_installed(step, org, repository, app_slug, installations) if installation.nil?
        return installation if installation.is_a?(Outcome::Finding)

        step = "#{installation.app_slug} App"
        selection = installation.repository_selection
        case selection
        when GitHub::AppInstallation::RepositorySelection::All
          Outcome::Settled.new(step: step, detail: "installed on every repository in #{org}")
        when GitHub::AppInstallation::RepositorySelection::Selected
          on_selection(step, org, repository, installation)
        else
          T.absurd(selection)
        end
      end

      private

      # @return [GitHub::AppInstallation, nil] the installation under the slug asked for
      sig { params(installations: T::Array[GitHub::AppInstallation], app_slug: String).returns(T.nilable(GitHub::AppInstallation)) }
      def named(installations, app_slug)
        installations.find { |candidate| candidate.app_slug == app_slug }
      end

      # The org's ai-flow App: the one installation named {APP_NAME}, plain
      # or prefixed. Two is a Finding — adopt does not guess which the org
      # runs; none is nil.
      #
      # @return [GitHub::AppInstallation, Outcome::Finding, nil]
      sig do
        params(installations: T::Array[GitHub::AppInstallation], org: String)
          .returns(T.nilable(T.any(GitHub::AppInstallation, Outcome::Finding)))
      end
      def found(installations, org)
        candidates = installations.select { |candidate| ai_flow_app?(candidate.app_slug) }
        return candidates.first if candidates.size <= 1

        count = candidates.size == 2 ? "two" : candidates.size.to_s
        Outcome::Finding.new(
          step: "#{APP_NAME} App",
          detail: "#{count} #{APP_NAME} Apps installed in #{org}: #{candidates.map(&:app_slug).join(", ")}",
          remedy: "name the one this org runs with --app SLUG",
        )
      end

      sig { params(slug: String).returns(T::Boolean) }
      def ai_flow_app?(slug)
        slug == APP_NAME || slug.end_with?("-#{APP_NAME}")
      end

      sig do
        params(
          step: String, org: String, repository: GitHub::Repository, app_slug: T.nilable(String),
          installations: T::Array[GitHub::AppInstallation],
        ).returns(Outcome::Finding)
      end
      def not_installed(step, org, repository, app_slug, installations)
        if app_slug
          Outcome::Finding.new(
            step: step,
            detail: "not installed in #{org}",
            remedy: "install it on #{repository.full_name}: https://github.com/apps/#{app_slug}/installations/new",
          )
        else
          installed = installations.empty? ? "none" : installations.map(&:app_slug).join(", ")
          Outcome::Finding.new(
            step: step,
            detail: "no #{APP_NAME} App installed in #{org} (installed: #{installed})",
            remedy: "install the org's #{APP_NAME} App on #{repository.full_name}, or name it with --app SLUG",
          )
        end
      end

      # Whether the repo is among the installation's selected repositories.
      # `user/installations/{id}/repositories` answers a token the App
      # issued or a classic PAT; gh's own OAuth login is refused, and the
      # honest answer then is that adopt cannot tell.
      sig do
        params(step: String, org: String, repository: GitHub::Repository, installation: GitHub::AppInstallation)
          .returns(Outcome)
      end
      def on_selection(step, org, repository, installation)
        settings = "https://github.com/organizations/#{org}/settings/installations/#{installation.id}"
        if @github.installation_repositories(installation.id).include?(repository.full_name)
          Outcome::Settled.new(step: step, detail: "installed on #{repository.full_name}")
        else
          Outcome::Finding.new(
            step: step,
            detail: "installed in #{org} but not on #{repository.full_name}",
            remedy: "add the repository at #{settings}",
          )
        end
      rescue GitHub::Forbidden
        Outcome::Finding.new(
          step: step,
          detail: "installed in #{org} on selected repositories; whether #{repository.full_name} is one cannot be read " \
            "with this gh login (the endpoint takes a token the App issued, or a classic PAT)",
          remedy: "check the repository is listed at #{settings}",
        )
      end
    end
  end
end
