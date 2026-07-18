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
    # Raised on a malformed spec (bad yaml, wrong shape). The dispatcher
    # reports it on the command comment like any other command failure.
    class Error < StandardError; end

    HEADER = "## Subtasks"
    SPEC_MARKER = "<!-- ai-flow:subtasks v1 — edit freely, then comment `/split --apply` -->"
    APPLIED_MARKER = "<!-- ai-flow:subtasks v1 — applied; a fresh `/split --dry` restages -->"
    ISSUE_REF_PATTERN = %r{[\w.-]+/[\w.-]+#\d+}

    module_function

    # @param body [String] the plan-issue body
    # @return [Boolean] whether an unapplied (fenced-yaml) spec is staged
    def spec?(body)
      section = section_text(body)
      !section.nil? && section.include?("```yaml")
    end

    # @param body [String]
    # @return [Array<Hash>] entries with "title", "repo", "body",
    #   "depends_on" (indices), and optional "existing" ("owner/repo#n")
    # @raise [Error] when the section is missing or hand-edits broke it
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

    # @param entries [Array<Hash>] proposal entries
    # @param possible_matches [Hash{Integer => Array<String>}] per-entry-index
    #   suggestion lines ('owner/repo#n "title"') for the human to promote
    #   into `existing:` or delete
    # @return [String] the staged spec section
    def render_spec(entries, possible_matches: {})
      yaml_blocks = entries.each_with_index.map do |entry, index|
        render_entry(entry, possible_matches.fetch(index, []))
      end
      "#{HEADER}\n#{SPEC_MARKER}\n\n```yaml\n#{yaml_blocks.join("\n")}```"
    end

    # @param lines [Array<String>] pre-formatted map lines, e.g.
    #   'd3mlabs/dev#12 — Server API (adopted)'
    # @return [String] the post-apply linked-map section
    def render_applied(lines)
      "#{HEADER}\n#{APPLIED_MARKER}\n\n#{lines.map { |line| "- #{line}" }.join("\n")}"
    end

    # Replace the existing `## Subtasks` section (or append one) — the rest
    # of the body is untouched.
    #
    # @param body [String]
    # @param section [String] a rendered section (spec or applied map)
    # @return [String] the new body
    def replace(body, section)
      lines = PlanBody.from_issue_body(body).split("\n", -1)
      start, finish = section_bounds(lines)
      if start
        lines[start...finish] = section.split("\n", -1)
      else
        lines = [lines.join("\n").rstrip, "", section]
      end
      "#{lines.join("\n").rstrip}\n"
    end

    # Dispositions recorded in the applied map — /build --split reads them to
    # know which nodes it cannot drive (adopted/referenced external issues).
    #
    # @param body [String] the plan-issue body
    # @return [Hash{String => String}] "owner/repo#n" => "adopted"/"referenced"
    def applied_annotations(body)
      section = section_text(body)
      return {} if section.nil? || section.include?("```yaml")

      section.scan(/^- (#{ISSUE_REF_PATTERN}) — .*\((adopted|referenced)\)\s*$/).to_h
    end

    # @return [String, nil] the section's text, header included
    def section_text(body)
      lines = PlanBody.from_issue_body(body).split("\n", -1)
      start, finish = section_bounds(lines)
      start && lines[start...finish].join("\n")
    end

    # @return [Array(Integer, Integer), Array(nil, nil)] the section's line
    #   range: header line to the next H2 (or EOF)
    def section_bounds(lines)
      start = lines.index { |line| line.strip == HEADER }
      return [nil, nil] unless start

      finish = ((start + 1)...lines.size).find { |index| lines[index].start_with?("## ") } || lines.size
      [start, finish]
    end

    # @return [Hash] the entry, shape-checked with defaults filled in
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

      {
        "title" => title,
        "repo" => entry["repo"].to_s.strip,
        "body" => entry["body"].to_s,
        "depends_on" => depends_on,
        "existing" => existing&.to_s,
      }.compact
    end

    # Manual yaml emission — Psych can't attach the possible-match comments,
    # and the hand-edited artifact reads better with a stable key order.
    def render_entry(entry, match_lines)
      lines = ["- title: #{entry.fetch("title").to_json}"]
      lines << "  repo: #{entry.fetch("repo")}" unless entry["repo"].to_s.empty?
      lines << "  existing: #{entry["existing"]}" if entry["existing"]
      depends_on = entry["depends_on"] || []
      lines << "  depends_on: [#{depends_on.join(", ")}]" unless depends_on.empty?
      match_lines.each { |line| lines << "  # possible match: #{line}" }
      body = entry["body"].to_s.rstrip
      if body.empty?
        lines << "  body: \"\""
      else
        lines << "  body: |"
        body.split("\n").each { |line| lines << (line.empty? ? "" : "    #{line}") }
      end
      "#{lines.join("\n")}\n"
    end
  end
end
