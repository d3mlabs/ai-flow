# typed: strict
# frozen_string_literal: true

module AiFlow
  # Adopting ai-flow on one repository — the derivable, re-convergeable half
  # of the README's adoption checklist, run as `ai-flow adopt <owner/repo>`
  # from the adopting repo's checkout (ai-flow#160). The rule is the one
  # dev applies to runner groups: own what is derived from ai-flow's own
  # knowledge and re-converges on every run; report, but never edit,
  # console state that cannot be derived or has no write API.
  #
  # Four steps, each its own class under Adoption, and every one a
  # relationship between the repo and ai-flow's GitHub-side service:
  #
  # - CallerWorkflow — `.github/workflows/ai-commands.yml` from the caller
  #   template: written when absent; present, its `uses:` ref is converged
  #   to the series tag (`@v1`), and a call to another workflow is a
  #   finding.
  # - RepoConfigFile — `.github/ai-flow.yml` from its template, with
  #   `knowledge_repo:` pre-filled when the adopter names one.
  # - SecretAccess — each of the three org secrets the caller workflow
  #   forwards: the repo is put on a `selected` secret's repository list,
  #   idempotently; other visibilities are reported.
  # - AppInstallation — whether the ai-flow App is installed on the repo:
  #   a finding only, since installing needs the App's own credentials.
  #
  # Two acts of adoption are not steps here because they are not
  # ai-flow's: putting the dispatcher on the adopter's hosts is the
  # adopter's dependency declaration, like any tool it installs (the
  # README's install line), and runner-group admission is `dev runner
  # register --org` from the repo's checkout. The job itself checks that
  # the dispatcher the adopter installed is the series this shell is.
  class Adoption
    extend T::Sig

    # The org Actions secrets every caller workflow forwards to the
    # reusable workflow — the names are ai-flow's vocabulary (the reusable
    # workflow's `secrets:` block declares exactly these; a test holds the
    # two lists together).
    SECRETS = T.let(%w[CURSOR_API_KEY AI_FLOW_APP_ID AI_FLOW_APP_PRIVATE_KEY].freeze, T::Array[String])

    # Where the caller template lives in the ai-flow tree, and where an
    # adopter's copy lives in theirs.
    CALLER_WORKFLOW_TEMPLATE = "templates/caller-workflow.yml"
    CALLER_WORKFLOW_PATH = ".github/workflows/ai-commands.yml"

    # The per-repo config template; its destination is RepoConfig::PATH.
    REPO_CONFIG_TEMPLATE = "templates/ai-flow.yml"

    # `adopt` writes into the adopting repo's checkout; a path that is not
    # a directory is a typo, not a repo.
    class NoCheckoutError < StandardError; end

    # What one adoption step found or did. Sealed so the CLI renders
    # exhaustively; every outcome names its step in the adopter's words
    # (the file path, the secret, the App) and carries one sentence.
    module Outcome
      extend T::Sig
      extend T::Helpers
      include ValueEquality
      abstract!
      sealed!

      # @return [String] the step, in the adopter's words
      sig { abstract.returns(String) }
      def step; end

      # @return [String] the one sentence about it
      sig { abstract.returns(String) }
      def detail; end

      # The step wrote or PUT something: the repo is nearer adopted than
      # before this run.
      class Changed
        extend T::Sig
        include Outcome
        include ValueEquality::Derived

        # @return [String] the step, in the adopter's words
        sig { override.returns(String) }
        attr_reader :step

        # @return [String] what changed
        sig { override.returns(String) }
        attr_reader :detail

        # @param step [String]
        # @param detail [String]
        sig { params(step: String, detail: String).void }
        def initialize(step:, detail:)
          @step = step
          @detail = detail
        end

        sig { override.returns(T::Array[Object]) }
        def equality_members
          [@step, @detail]
        end
      end

      # The step found its state already as adoption wants it.
      class Settled
        extend T::Sig
        include Outcome
        include ValueEquality::Derived

        # @return [String] the step, in the adopter's words
        sig { override.returns(String) }
        attr_reader :step

        # @return [String] what was found
        sig { override.returns(String) }
        attr_reader :detail

        # @param step [String]
        # @param detail [String]
        sig { params(step: String, detail: String).void }
        def initialize(step:, detail:)
          @step = step
          @detail = detail
        end

        sig { override.returns(T::Array[Object]) }
        def equality_members
          [@step, @detail]
        end
      end

      # Something adoption needs that this run could not or must not
      # change: drift in a file the adopter owns, console state with no
      # write API, a secret that does not exist. Carries the remedy, since
      # the adopter is the one who acts on it.
      class Finding
        extend T::Sig
        include Outcome
        include ValueEquality::Derived

        # @return [String] the step, in the adopter's words
        sig { override.returns(String) }
        attr_reader :step

        # @return [String] what is wrong
        sig { override.returns(String) }
        attr_reader :detail

        # @return [String] what the adopter does about it
        sig { returns(String) }
        attr_reader :remedy

        # @param step [String]
        # @param detail [String]
        # @param remedy [String]
        sig { params(step: String, detail: String, remedy: String).void }
        def initialize(step:, detail:, remedy:)
          @step = step
          @detail = detail
          @remedy = remedy
        end

        sig { override.returns(T::Array[Object]) }
        def equality_members
          [@step, @detail, @remedy]
        end
      end
    end

    # @param github [AiFlow::GitHub] org-side reads and the secret PUTs
    # @param root [String] the ai-flow tree the templates and VERSION are
    #   read from
    # @raise [Series::InvalidVersionError] when the tree's VERSION is not
    #   a version
    sig { params(github: GitHub, root: String).void }
    def initialize(github:, root:)
      @github = github
      @caller_workflow = T.let(
        CallerWorkflow.new(template: File.join(root, CALLER_WORKFLOW_TEMPLATE), series: Series.of_tree(root)),
        CallerWorkflow,
      )
      @repo_config_file = T.let(RepoConfigFile.new(template: File.join(root, REPO_CONFIG_TEMPLATE)), RepoConfigFile)
      @secret_access = T.let(SecretAccess.new(github: github), SecretAccess)
      @app_installation = T.let(AppInstallation.new(github: github), AppInstallation)
    end

    # Run every step once, files first, and report each. The repository is
    # resolved before anything is written so a mistyped name fails before
    # it leaves files in the wrong checkout.
    #
    # @param owner_repo [String] the adopting repo, "owner/repo"
    # @param checkout [String] the adopting repo's working tree
    # @param knowledge_repo [String, nil] the org knowledge repo to
    #   pre-fill in a generated .github/ai-flow.yml; nil leaves the key
    #   commented out as the template has it
    # @param app_slug [String] the ai-flow App's slug in this org
    # @return [Array<Outcome>] one per step, in step order
    # @raise [NoCheckoutError] when checkout is not a directory
    # @raise [GitHub::NotFound] when the repository does not exist
    sig do
      params(owner_repo: String, checkout: String, knowledge_repo: T.nilable(String), app_slug: String)
        .returns(T::Array[Outcome])
    end
    def converge(owner_repo:, checkout:, knowledge_repo: nil, app_slug: CommitIdentity::DEFAULT_APP_SLUG)
      raise NoCheckoutError, "#{checkout} is not a directory — run adopt from the adopting repo's checkout" unless File.directory?(checkout)

      repository = @github.repository(owner_repo)
      outcomes = T.let([], T::Array[Outcome])
      outcomes << @caller_workflow.converge(checkout)
      outcomes << @repo_config_file.converge(checkout, knowledge_repo: knowledge_repo)
      SECRETS.each { |name| outcomes << @secret_access.converge(repository, name) }
      outcomes << @app_installation.converge(repository, app_slug)
      outcomes
    end
  end
end
