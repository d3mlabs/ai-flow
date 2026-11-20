# typed: strict
# frozen_string_literal: true

require "fileutils"

module AiFlow
  class Adoption
    # The adopting repo's `.github/ai-flow.yml`, from its template. Absent,
    # it is written — with `knowledge_repo:` filled in when the adopter
    # names one, since that is the one key an adopter cannot leave to the
    # defaults if they want `/learn --promote` to work. Present, it is the
    # adopter's policy and is left alone; the one thing checked is that a
    # knowledge repo asked for on the command line is the one the file
    # names, so a stale value is reported rather than silently kept.
    class RepoConfigFile
      extend T::Sig

      # The template line a named knowledge repo replaces. Held here as a
      # literal so the substitution is exact; the template test keeps the
      # two in step.
      KNOWLEDGE_REPO_LINE = "# knowledge_repo: d3mlabs/knowledge"

      # The template no longer carries the line a knowledge repo is filled
      # into — ai-flow's own drift, not the adopter's.
      class TemplateWithoutKnowledgeRepoError < StandardError; end

      # @param template [String] path to templates/ai-flow.yml
      sig { params(template: String).void }
      def initialize(template:)
        @template = template
      end

      # @param checkout [String] the adopting repo's working tree
      # @param knowledge_repo [String, nil] the org knowledge repo to fill
      #   in; nil keeps the template's commented-out line
      # @return [Outcome] Changed when written, Settled when present and
      #   consistent, Finding when present but unreadable or naming
      #   another knowledge repo than the one asked for
      # @raise [TemplateWithoutKnowledgeRepoError] when a knowledge repo
      #   was asked for and the template has no line to fill it into
      sig { params(checkout: String, knowledge_repo: T.nilable(String)).returns(Outcome) }
      def converge(checkout, knowledge_repo:)
        path = File.join(checkout, RepoConfig::PATH)
        return write(path, knowledge_repo) unless File.exist?(path)

        present = begin
          RepoConfig.load(checkout)
        rescue RepoConfig::Error => e
          return Outcome::Finding.new(step: RepoConfig::PATH, detail: e.message, remedy: "fix the file; see #{REPO_CONFIG_TEMPLATE}")
        end
        return Outcome::Settled.new(step: RepoConfig::PATH, detail: "present, left as is") if knowledge_repo.nil?
        return Outcome::Settled.new(step: RepoConfig::PATH, detail: "present, names #{knowledge_repo}") if present.knowledge_repo == knowledge_repo

        Outcome::Finding.new(
          step: RepoConfig::PATH,
          detail: present.knowledge_repo ? "names knowledge_repo #{present.knowledge_repo}, not #{knowledge_repo}" : "sets no knowledge_repo",
          remedy: "set `knowledge_repo: #{knowledge_repo}` in it — adopt never edits an adopter's policy file",
        )
      end

      private

      # @param path [String] where the file goes
      # @param knowledge_repo [String, nil]
      # @return [Outcome::Changed]
      sig { params(path: String, knowledge_repo: T.nilable(String)).returns(Outcome::Changed) }
      def write(path, knowledge_repo)
        content = File.read(@template)
        if knowledge_repo
          raise TemplateWithoutKnowledgeRepoError, "#{REPO_CONFIG_TEMPLATE} has no `#{KNOWLEDGE_REPO_LINE}` line" unless content.include?(KNOWLEDGE_REPO_LINE)

          content = content.sub(KNOWLEDGE_REPO_LINE, "knowledge_repo: #{knowledge_repo}")
        end
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        detail = knowledge_repo ? "written from #{REPO_CONFIG_TEMPLATE} with knowledge_repo: #{knowledge_repo}" : "written from #{REPO_CONFIG_TEMPLATE}"
        Outcome::Changed.new(step: RepoConfig::PATH, detail: "#{detail} — commit and push it")
      end
    end
  end
end
