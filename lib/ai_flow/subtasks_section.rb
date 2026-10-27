# typed: strict
# frozen_string_literal: true

require "json"
require "yaml"

module AiFlow
  # The `## Subtasks` plan-body section — /split's two-phase artifact.
  #
  # Before apply it holds the staged proposal as a fenced-yaml spec (the
  # canonical, human-editable escrow); at apply, canonicity transfers to the
  # created sub-issues and the section is rewritten into a linked map. The
  # yaml spec fails loudly on malformed hand-edits — the desired failure mode
  # for an executable artifact.
  module SubtasksSection
    # Sorbet models bare modules without Object's ancestry, so Kernel methods
    # (raise) need the explicit include (srb.help/7003).
    include Kernel
    extend T::Sig

    # Raised on a malformed spec (bad yaml, wrong shape). The dispatcher
    # reports it on the command comment like any other command failure.
    class Error < StandardError; end

    # One staged subtask — the spec interface is exactly these fields (see
    # validate_entry). `repo` is a prop: Split defaults an empty routing to
    # the parent's repo after parsing.
    class Entry < T::Struct
      const :title, String
      prop :repo, String
      const :depends_on, T::Array[Integer]
      const :existing, T.nilable(String)
      # A human step (a ruleset, a grant, an App install, a secret) — not
      # /build's to do. /build --split never dispatches it and holds its
      # dependents until the human closes it.
      const :manual, T::Boolean, default: false
    end

    HEADER = "## Subtasks"
    # The body line a created manual sub-issue carries, so the issue itself
    # tells its reader who acts (the applied map's `(manual)` annotation is
    # what /build --split reads; this is for the human).
    MANUAL_LINE = "Manual: a human does this step, not /build — close it when done."
    SPEC_MARKER = "<!-- ai-flow:subtasks v1 — edit freely, then comment `/split --apply` -->"
    APPLIED_MARKER = "<!-- ai-flow:subtasks v1 — applied; a fresh `/split --dry` restages -->"
    ISSUE_REF_PATTERN = %r{[\w.-]+/[\w.-]+#\d+}

    # extend self (not module_function): module_function copies methods onto
    # the singleton before sorbet-runtime wraps them, silently skipping every
    # runtime sig validation. extend self keeps one wrapped method in the chain.
    extend self

    # @param body [String] the plan-issue body
    # @return [Boolean] whether an unapplied (fenced-yaml) spec is staged
    sig { params(body: String).returns(T::Boolean) }
    def spec?(body)
      section = section_text(body)
      !section.nil? && section.include?("```yaml")
    end

    # @param body [String]
    # @return [Array<Entry>]
    # @raise [Error] when the section is missing or hand-edits broke it
    sig { params(body: String).returns(T::Array[Entry]) }
    def parse_spec(body)
      section = section_text(body)
      yaml = section && section[/```yaml\n(.*?)```/m, 1]
      raise Error, "no staged `#{HEADER}` spec found — run `/split --dry` first." unless yaml

      entries = YAML.safe_load(yaml)
      raise Error, "the `#{HEADER}` spec must be a yaml list of subtasks." unless entries.is_a?(Array)

      entries.map { |entry| validate_entry(entry) }
    rescue Psych::SyntaxError => e
      raise Error, "the `#{HEADER}` spec is not valid yaml (#{e.message}) — fix it or re-run `/split --dry`."
    end

    # @param entries [Array<Entry>] proposal entries
    # @param possible_matches [Hash{Integer => Array<String>}] per-entry-index
    #   suggestion lines ('owner/repo#n "title"') for the human to promote
    #   into `existing:` or delete
    # @return [String] the staged spec section
    sig do
      params(
        entries: T::Array[Entry],
        possible_matches: T::Hash[Integer, T::Array[String]],
      ).returns(String)
    end
    def render_spec(entries, possible_matches: {})
      yaml_blocks = entries.each_with_index.map do |entry, index|
        render_entry(entry, possible_matches.fetch(index, []))
      end
      "#{HEADER}\n#{SPEC_MARKER}\n\n```yaml\n#{yaml_blocks.join("\n")}```"
    end

    # @param lines [Array<String>] pre-formatted map lines, e.g.
    #   'd3mlabs/dev#12 — Server API (adopted)'
    # @return [String] the post-apply linked-map section
    sig { params(lines: T::Array[String]).returns(String) }
    def render_applied(lines)
      "#{HEADER}\n#{APPLIED_MARKER}\n\n#{lines.map { |line| "- #{line}" }.join("\n")}"
    end

    # Replace the existing `## Subtasks` section (or append one) — the rest
    # of the body is untouched.
    #
    # @param body [String]
    # @param section [String] a rendered section (spec or applied map)
    # @return [String] the new body
    sig { params(body: String, section: String).returns(String) }
    def replace(body, section)
      lines = PlanBody.from_issue_body(body).split("\n", -1)
      bounds = section_bounds(lines)
      if bounds
        lines[bounds] = section.split("\n", -1)
      else
        lines = [lines.join("\n").rstrip, "", section]
      end
      "#{lines.join("\n").rstrip}\n"
    end

    # The annotation tokens an applied-map line may carry, in parentheses
    # after the title (`(adopted)`, `(adopted, manual)`): the external-issue
    # dispositions, and `manual` for a human step. /build --split reads them
    # to know which nodes it does not drive.
    ANNOTATIONS = T.let(%w[adopted referenced manual].freeze, T::Array[String])

    # Annotations recorded in the applied map, per sub-issue ref.
    #
    # @param body [String] the plan-issue body
    # @return [Hash{String => Array<String>}] "owner/repo#n" => tokens, e.g. ["adopted", "manual"]
    sig { params(body: String).returns(T::Hash[String, T::Array[String]]) }
    def applied_annotations(body)
      section = section_text(body)
      return {} if section.nil? || section.include?("```yaml")

      # T.cast: a two-group scan always yields string pairs, but the stdlib
      # RBI types it as a union that to_h can't accept.
      pairs = T.cast(
        section.scan(/^- (#{ISSUE_REF_PATTERN}) — .*\(((?:#{ANNOTATIONS.join("|")})(?:, (?:#{ANNOTATIONS.join("|")}))*)\)\s*$/),
        T::Array[[String, String]],
      )
      pairs.to_h { |ref, tokens| [ref, tokens.split(", ")] }
    end

    # @return [String, nil] the section's text, header included
    sig { params(body: String).returns(T.nilable(String)) }
    def section_text(body)
      lines = PlanBody.from_issue_body(body).split("\n", -1)
      bounds = section_bounds(lines)
      return nil unless bounds

      lines[bounds]&.join("\n")
    end

    # @return [Range<Integer>, nil] the section's line range — header line
    #   up to (exclusive) the next H2 or EOF; nil when the body has no
    #   `## Subtasks` section (the two bounds are one fact, not two)
    sig { params(lines: T::Array[String]).returns(T.nilable(T::Range[Integer])) }
    def section_bounds(lines)
      start = lines.index { |line| line.strip == HEADER }
      return nil unless start

      finish = ((start + 1)...lines.size).find { |index| lines.fetch(index).start_with?("## ") } || lines.size
      start...finish
    end

    # The interface is exactly these five keys — sub-issue bodies are not
    # part of the spec (the parent plan is the spec; created sub-issues get
    # a thin templated body). Unknown keys are ignored.
    #
    # @return [Entry] the entry, shape-checked with defaults filled in
    sig { params(entry: T.untyped).returns(Entry) }
    def validate_entry(entry)
      raise Error, "each subtask must be a yaml mapping, got: #{entry.inspect}" unless entry.is_a?(Hash)

      title = entry["title"].to_s.strip
      raise Error, "a subtask is missing its title: #{entry.inspect}" if title.empty?

      existing = entry["existing"]
      if existing && !existing.to_s.match?(/\A#{ISSUE_REF_PATTERN}\z/)
        raise Error, "`existing:` must be `owner/repo#n`, got: #{existing.inspect}"
      end

      depends_on = entry["depends_on"] || []
      unless depends_on.is_a?(Array) && depends_on.all? { |index| index.is_a?(Integer) }
        raise Error, "`depends_on` must be a list of entry indices, got: #{depends_on.inspect}"
      end

      manual = entry.fetch("manual", false)
      raise Error, "`manual:` must be true or false, got: #{manual.inspect}" unless [true, false].include?(manual)

      Entry.new(
        title: title,
        repo: entry["repo"].to_s.strip,
        depends_on: depends_on,
        existing: existing&.to_s,
        manual: manual,
      )
    end

    # Manual yaml emission — Psych can't attach the possible-match comments,
    # and the hand-edited artifact reads better with a stable key order.
    #
    # @param entry [Entry] a validated entry
    # @param match_lines [Array<String>] possible-match suggestion lines
    # @return [String]
    sig { params(entry: Entry, match_lines: T::Array[String]).returns(String) }
    def render_entry(entry, match_lines)
      lines = ["- title: #{entry.title.to_json}"]
      lines << "  repo: #{entry.repo}" unless entry.repo.empty?
      lines << "  existing: #{entry.existing}" if entry.existing
      lines << "  manual: true" if entry.manual
      lines << "  depends_on: [#{entry.depends_on.join(", ")}]" unless entry.depends_on.empty?
      match_lines.each { |line| lines << "  # possible match: #{line}" }
      "#{lines.join("\n")}\n"
    end
  end
end
