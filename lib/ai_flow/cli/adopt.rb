# typed: strict
# frozen_string_literal: true

require "optparse"

module AiFlow
  class Cli
    # `ai-flow adopt <owner/repo>`: parse the adopter's intent, run the
    # adoption, render one line per step. The report's words live here —
    # the outcomes carry facts, the CLI decides how a human reads them.
    class Adopt
      extend T::Sig

      # The two acts of adoption that are the repo's, not this command's:
      # printed under every report and in the usage.
      HOST_SIDE = "Installing the dispatcher on the repo's hosts is the repo's dependency declaration " \
        "(README, adoption checklist); runner-group admission is `dev runner register --org` from its checkout."

      USAGE = T.let(<<~USAGE.freeze, String)
        usage: ai-flow adopt <owner/repo> [--checkout DIR] [--knowledge-repo OWNER/REPO] [--app SLUG]

        Run from the adopting repository's checkout (or name it with --checkout).
        Writes the caller workflow and .github/ai-flow.yml when absent, re-pins a
        caller's `uses:` to this release's series tag (`@v<major>`), puts the
        repository on each org secret's selected list, and reports what it cannot
        change: a caller calling another workflow, a secret it cannot reach, the
        App not installed. Exit 1 when anything was reported.

          --checkout DIR             the adopting repo's working tree (default: the current directory)
          --knowledge-repo OWNER/REPO  pre-fill knowledge_repo: in a generated .github/ai-flow.yml
          --app SLUG                 the ai-flow App's slug in this org (default: the one installation named ai-flow, plain or prefixed)

        #{HOST_SIDE}
      USAGE

      # What the first positional must look like: two non-empty names
      # around one slash.
      class NotARepositoryNameError < UsageError; end

      # @param adoption [AiFlow::Adoption]
      # @param stdout [IO, StringIO]
      sig { params(adoption: Adoption, stdout: Stream).void }
      def initialize(adoption:, stdout:)
        @adoption = adoption
        @stdout = stdout
      end

      # @param args [Array<String>] everything after `adopt`
      # @return [Integer] EXIT_OK when every step settled or changed,
      #   EXIT_REPORTED when any step is a finding
      # @raise [UsageError] on unparseable args
      sig { params(args: T::Array[String]).returns(Integer) }
      def run(args)
        checkout = T.let(Dir.pwd, String)
        knowledge_repo = T.let(nil, T.nilable(String))
        app_slug = T.let(nil, T.nilable(String))
        parser = OptionParser.new do |opts|
          opts.on("--checkout DIR", String) { |dir| checkout = dir }
          opts.on("--knowledge-repo OWNER/REPO", String) { |repo| knowledge_repo = repository_name(repo) }
          opts.on("--app SLUG", String) { |slug| app_slug = slug }
        end
        positionals = begin
          T.cast(parser.parse(args), T::Array[String])
        rescue OptionParser::ParseError => e
          raise UsageError, "#{e.message}\n#{USAGE}"
        end
        raise UsageError, "adopt takes exactly one <owner/repo>\n#{USAGE}" unless positionals.size == 1

        owner_repo = repository_name(positionals.fetch(0))
        outcomes = @adoption.converge(
          owner_repo: owner_repo, checkout: checkout, knowledge_repo: knowledge_repo, app_slug: app_slug,
        )
        render(owner_repo, outcomes)
        outcomes.any?(Adoption::Outcome::Finding) ? EXIT_REPORTED : EXIT_OK
      end

      private

      # @param value [String] what the adopter typed
      # @return [String] the same, once it is an "owner/repo"
      # @raise [NotARepositoryNameError]
      sig { params(value: String).returns(String) }
      def repository_name(value)
        owner, name, extra = value.split("/", 3)
        return value if owner && name && extra.nil? && !owner.empty? && !name.empty?

        raise NotARepositoryNameError, "#{value.inspect} is not an owner/repo\n#{USAGE}"
      end

      # @param owner_repo [String]
      # @param outcomes [Array<Adoption::Outcome>]
      # @return [void]
      sig { params(owner_repo: String, outcomes: T::Array[Adoption::Outcome]).void }
      def render(owner_repo, outcomes)
        @stdout.puts("ai-flow adopt #{owner_repo}")
        outcomes.each do |outcome|
          @stdout.puts("  #{label(outcome)}  #{outcome.step}: #{outcome.detail}")
          @stdout.puts("           → #{outcome.remedy}") if outcome.is_a?(Adoption::Outcome::Finding)
        end
        @stdout.puts(HOST_SIDE)
      end

      # One word per outcome kind, left of each step.
      #
      # @param outcome [Adoption::Outcome]
      # @return [String]
      sig { params(outcome: Adoption::Outcome).returns(String) }
      def label(outcome)
        case outcome
        when Adoption::Outcome::Changed then "changed"
        when Adoption::Outcome::Settled then "settled"
        when Adoption::Outcome::Finding then "finding"
        else T.absurd(outcome)
        end
      end
    end
  end
end
