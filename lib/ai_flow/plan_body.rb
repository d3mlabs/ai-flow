# frozen_string_literal: true

module AiFlow
  # Plan-issue body conventions shared with `dev plan` (the local CLI), plus
  # quote-anchor resolution — the remote cmd+L proxy: a reviewer's quote is
  # located by string match against the body snapshot the batch runs on.
  module PlanBody
    module_function

    # Issue bodies use CRLF line endings when edited via the GitHub web UI, so
    # normalize to LF — quote anchoring and the PATCH race check both compare
    # against LF text.
    #
    # @param issue_body [String, nil]
    # @return [String] LF-normalized body with a single trailing newline
    def from_issue_body(issue_body)
      "#{(issue_body || "").gsub("\r\n", "\n").rstrip}\n"
    end

    # Resolve a quoted anchor against a body snapshot. Quotes come from the
    # rendered issue (markdown syntax stripped), so matching is tolerant:
    # exact source match first, then a normalized match; the resolved region
    # widens to whole paragraphs so the agent gets a workable section.
    #
    # @param body [String] the snapshot the reviewer read
    # @param quote [String] the quoted anchor text
    # @return [String, nil] the resolved source region, or nil when the quote
    #   is not in the body (quoted from an answer panel or discussion comment,
    #   or body text that changed between posting and execution)
    def locate_quote(body, quote)
      return nil if quote.nil? || quote.strip.empty?

      exact = paragraph_span(body, quote) { |paragraph, needle| paragraph.include?(needle) }
      return exact if exact

      paragraph_span(body, quote) do |paragraph, needle|
        normalize(paragraph).include?(normalize(needle))
      end
    end

    # Find the minimal consecutive paragraph span matching the quote. Single
    # paragraphs are tried first, then growing windows for multi-paragraph
    # quotes.
    #
    # @return [String, nil]
    def paragraph_span(body, quote)
      paragraphs = body.split(/\n{2,}/).map(&:strip).reject(&:empty?)
      needles = quote.split(/\n{2,}/).map(&:strip).reject(&:empty?)
      return nil if needles.empty?

      (1..paragraphs.size).each do |window|
        paragraphs.each_cons(window) do |span|
          joined = span.join("\n\n")
          return joined if needles.all? { |needle| yield(joined, needle) }
        end
        # Windows only need to grow up to the quote's own paragraph count + 1.
        break if window > needles.size
      end
      nil
    end

    # Markdown-insensitive comparison form: rendered text lacks emphasis
    # markers, backticks, heading hashes, and collapses whitespace. Two
    # quote-reply artifacts observed in the wild are also neutralized:
    # GitHub backslash-escapes markdown when quoting rendered text (a
    # numbered list item arrives as "4\."), and a partial selection inside a
    # list item arrives with the list prefix glued on ("1. DEV_CD_ROOT"), so
    # leading enumerators/bullets are stripped per line.
    #
    # @param text [String]
    # @return [String]
    def normalize(text)
      text.downcase
          .gsub(/\\(?=[[:punct:]])/, "")
          .gsub(/^\s*(?:\d+[.)]|[-+])\s+/, "")
          .gsub(/[`*_#>|]/, "")
          .gsub(/\[([^\]]*)\]\([^)]*\)/, '\1')
          .gsub(/\s+/, " ")
          .strip
    end
  end
end
