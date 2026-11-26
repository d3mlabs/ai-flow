# typed: strict
# frozen_string_literal: true

require "fileutils"
require "yaml"

module AiFlow
  class Adoption
    # The adopting repo's caller workflow, `.github/workflows/ai-commands.yml`:
    # a copy of ai-flow's template whose one job `uses:` the reusable
    # workflow at the series tag (`@v1`). Absent, it is written from the
    # template. Present, it is the adopter's file: the one thing converged
    # in it is the ref, because the workflow at the series tag is the
    # shell the dispatcher running this command belongs to (a caller at
    # `@main` would run tomorrow's YAML against the dispatcher the adopter
    # installed today). The same workflow at another ref is re-pinned in
    # place; another workflow (a fork) is the adopter's choice and is
    # reported, never rewritten.
    #
    # The workflow is the template's; the ref is the series' (VERSION), so
    # a major bump moves the drift check with it. A test holds the shipped
    # template at the series tag, so a by-hand copy agrees too.
    class CallerWorkflow
      extend T::Sig

      # Every template this class reads must call exactly one reusable
      # workflow; a template that does not is ai-flow's own bug.
      class TemplateWithoutUsesError < StandardError; end

      # @param template [String] path to templates/caller-workflow.yml
      # @param series [Series] the series the caller must follow
      sig { params(template: String, series: Series).void }
      def initialize(template:, series:)
        @template = template
        @series = series
      end

      # The reusable workflow at the series tag: what every caller must
      # `uses:`.
      #
      # @return [ReusableWorkflowRef]
      # @raise [TemplateWithoutUsesError]
      sig { returns(ReusableWorkflowRef) }
      def expected
        template_uses = uses_in(File.read(@template)) or
          raise TemplateWithoutUsesError, "#{CALLER_WORKFLOW_TEMPLATE} calls no reusable workflow"
        template_uses.at(@series.tag)
      end

      # @param checkout [String] the adopting repo's working tree
      # @return [Outcome] Changed when written or re-pinned, Settled when the
      #   present file calls the series tag, Finding otherwise
      # @raise [TemplateWithoutUsesError] when the template itself calls
      #   no reusable workflow
      sig { params(checkout: String).returns(Outcome) }
      def converge(checkout)
        path = File.join(checkout, CALLER_WORKFLOW_PATH)
        wanted = expected
        remedy = "set the job's `uses:` to #{wanted} — the workflow at the series tag is the shell of the " \
          "dispatcher this repo installs, and `dev deploy gh` moves only that ref"

        unless File.exist?(path)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, File.read(@template))
          return Outcome::Changed.new(
            step: CALLER_WORKFLOW_PATH,
            detail: "written from #{CALLER_WORKFLOW_TEMPLATE} — commit and push it",
          )
        end

        text = File.read(path)
        actual = begin
          uses_in(text)
        rescue Psych::Exception => e
          return Outcome::Finding.new(step: CALLER_WORKFLOW_PATH, detail: "is not valid YAML: #{e.message}", remedy: remedy)
        end
        return Outcome::Finding.new(step: CALLER_WORKFLOW_PATH, detail: "calls no reusable workflow", remedy: remedy) if actual.nil?
        return Outcome::Settled.new(step: CALLER_WORKFLOW_PATH, detail: "calls #{wanted}") if actual == wanted

        unless actual.same_workflow?(wanted)
          return Outcome::Finding.new(step: CALLER_WORKFLOW_PATH, detail: "calls #{actual}, not #{wanted}", remedy: remedy)
        end

        # The whole reference, wherever the file spells it: a comment that
        # names the old ref in full is the same fact and moves with it.
        File.write(path, text.gsub(actual.to_s, wanted.to_s))
        Outcome::Changed.new(
          step: CALLER_WORKFLOW_PATH,
          detail: "re-pinned from @#{actual.ref} to @#{wanted.ref} — commit and push it",
        )
      end

      private

      # The reusable workflow a caller workflow's jobs call: the first
      # job-level `uses:` (a caller has exactly one job). nil when the
      # document is not a workflow with one, or the value is not a
      # reusable-workflow reference.
      #
      # @param text [String] the workflow YAML
      # @return [ReusableWorkflowRef, nil]
      # @raise [Psych::Exception] when the text is not YAML
      sig { params(text: String).returns(T.nilable(ReusableWorkflowRef)) }
      def uses_in(text)
        parsed = YAML.safe_load(text)
        return nil unless parsed.is_a?(Hash)

        jobs = parsed["jobs"]
        return nil unless jobs.is_a?(Hash)

        value = jobs.values.filter_map { |job| job["uses"] if job.is_a?(Hash) && job["uses"].is_a?(String) }.first
        return nil if value.nil?

        ReusableWorkflowRef.parse(value)
      rescue ReusableWorkflowRef::InvalidReferenceError
        nil
      end
    end
  end
end
