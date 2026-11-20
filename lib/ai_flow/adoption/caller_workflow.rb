# typed: strict
# frozen_string_literal: true

require "fileutils"
require "yaml"

module AiFlow
  class Adoption
    # The adopting repo's caller workflow, `.github/workflows/ai-commands.yml`:
    # a copy of ai-flow's template whose one job `uses:` the reusable
    # workflow. Absent, it is written from the template. Present, it is the
    # adopter's file — never rewritten — but the ref it calls is checked
    # against the template's, because the reusable workflow's YAML and the
    # dispatcher code it drives must be the same version: a caller pinned
    # to a tag or a fork keeps running old YAML against new code, and
    # nothing else reports that.
    #
    # The expected `uses:` is read from the template, not held as a second
    # literal: when the template moves (`@main` to `@v1` under plans#76),
    # the drift check moves with it.
    class CallerWorkflow
      extend T::Sig

      # Every template this class reads must call exactly one reusable
      # workflow; a template that does not is ai-flow's own bug.
      class TemplateWithoutUsesError < StandardError; end

      # @param template [String] path to templates/caller-workflow.yml
      sig { params(template: String).void }
      def initialize(template:)
        @template = template
      end

      # @param checkout [String] the adopting repo's working tree
      # @return [Outcome] Changed when written, Settled when the present
      #   file calls the template's ref, Finding otherwise
      # @raise [TemplateWithoutUsesError] when the template itself calls
      #   no reusable workflow
      sig { params(checkout: String).returns(Outcome) }
      def converge(checkout)
        path = File.join(checkout, CALLER_WORKFLOW_PATH)
        template = File.read(@template)
        expected = uses_in(template) or
          raise TemplateWithoutUsesError, "#{CALLER_WORKFLOW_TEMPLATE} calls no reusable workflow"
        remedy = "set the job's `uses:` to #{expected} — the workflow YAML must track the dispatcher it drives; " \
          "a tag or fork pin silently splits the two"

        unless File.exist?(path)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, template)
          return Outcome::Changed.new(
            step: CALLER_WORKFLOW_PATH,
            detail: "written from #{CALLER_WORKFLOW_TEMPLATE} — commit and push it",
          )
        end

        actual = begin
          uses_in(File.read(path))
        rescue Psych::Exception => e
          return Outcome::Finding.new(step: CALLER_WORKFLOW_PATH, detail: "is not valid YAML: #{e.message}", remedy: remedy)
        end
        return Outcome::Settled.new(step: CALLER_WORKFLOW_PATH, detail: "calls #{expected}") if actual == expected

        Outcome::Finding.new(
          step: CALLER_WORKFLOW_PATH,
          detail: actual ? "calls #{actual}, not #{expected}" : "calls no reusable workflow",
          remedy: remedy,
        )
      end

      private

      # The reusable workflow a caller workflow's jobs call: the first
      # job-level `uses:` (a caller has exactly one job). nil when the
      # document is not a workflow with one.
      #
      # @param text [String] the workflow YAML
      # @return [String, nil]
      # @raise [Psych::Exception] when the text is not YAML
      sig { params(text: String).returns(T.nilable(String)) }
      def uses_in(text)
        parsed = YAML.safe_load(text)
        return nil unless parsed.is_a?(Hash)

        jobs = parsed["jobs"]
        return nil unless jobs.is_a?(Hash)

        jobs.values.filter_map { |job| job["uses"] if job.is_a?(Hash) && job["uses"].is_a?(String) }.first
      end
    end
  end
end
