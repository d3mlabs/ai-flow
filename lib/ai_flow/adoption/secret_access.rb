# typed: strict
# frozen_string_literal: true

module AiFlow
  class Adoption
    # One org Actions secret's reach to the adopting repo. The org's secrets
    # use `selected` visibility, so adopting a repo means putting it on
    # each secret's repository list — exactly the list someone had to
    # remember by hand. The PUT is idempotent (GitHub answers 204 either
    # way), so re-running adopt re-converges it. Every other state is
    # reported, not changed: a secret visible to all is fine, a `private`
    # one cannot reach a public repo and only its owner can switch it, a
    # missing one has to be created with its value by a human.
    #
    # Needs the org-admin gh auth `dev runner register --org` already
    # requires; under lesser auth every secret reads as not found.
    class SecretAccess
      extend T::Sig

      # @param github [AiFlow::GitHub]
      sig { params(github: GitHub).void }
      def initialize(github:)
        @github = github
      end

      # @param repository [GitHub::Repository] the adopting repo
      # @param name [String] the secret's name
      # @return [Outcome]
      sig { params(repository: GitHub::Repository, name: String).returns(Outcome) }
      def converge(repository, name)
        org = repository.owner
        step = "org secret #{name}"
        secret = begin
          @github.org_secret(org, name)
        rescue GitHub::NotFound
          return Outcome::Finding.new(
            step: step,
            detail: "not found in #{org} (no such org secret, or this gh login is not an org owner)",
            remedy: "create it: gh secret set #{name} --org #{org} --visibility selected --repos #{repository.full_name} " \
              "— or set it as a repository secret",
          )
        end

        visibility = secret.visibility
        case visibility
        when GitHub::OrgSecret::Visibility::All
          Outcome::Settled.new(step: step, detail: "visible to every repository in #{org}")
        when GitHub::OrgSecret::Visibility::Private
          private_visibility(repository, step, org, name)
        when GitHub::OrgSecret::Visibility::Selected
          selected_visibility(repository, step, org, name)
        else
          T.absurd(visibility)
        end
      end

      private

      # @param repository [GitHub::Repository]
      # @param step [String]
      # @param org [String]
      # @param name [String]
      # @return [Outcome]
      sig { params(repository: GitHub::Repository, step: String, org: String, name: String).returns(Outcome) }
      def private_visibility(repository, step, org, name)
        unless repository.public?
          return Outcome::Settled.new(step: step, detail: "visible to #{org}'s private repositories, which includes this one")
        end

        Outcome::Finding.new(
          step: step,
          detail: "visibility is private, which excludes the public #{repository.full_name}",
          remedy: "switch it to selected: gh secret set #{name} --org #{org} --visibility selected " \
            "--repos #{repository.full_name} (and every repo already relying on it)",
        )
      end

      # @param repository [GitHub::Repository]
      # @param step [String]
      # @param org [String]
      # @param name [String]
      # @return [Outcome]
      sig { params(repository: GitHub::Repository, step: String, org: String, name: String).returns(Outcome) }
      def selected_visibility(repository, step, org, name)
        if @github.org_secret_repositories(org, name).include?(repository.full_name)
          return Outcome::Settled.new(step: step, detail: "#{repository.full_name} is among its selected repositories")
        end

        @github.add_org_secret_repository(org, name, repository.id)
        Outcome::Changed.new(step: step, detail: "#{repository.full_name} added to its selected repositories")
      end
    end
  end
end
