# frozen_string_literal: true

require "erb"
require "tmpdir"

module AiFlow
  # Renders the /edit result format (see the ai-flow plan, Component 5): two
  # sibling collapsibles — "Word diff" (word-level <ins>/<del> rendered prose,
  # both allowed by GitHub's sanitizer, plus changed mermaid blocks re-rendered
  # live) and "Source diff" (the exact unified diff in a colored ```diff
  # fence) — with a text-fragment backlink returned separately so the caller
  # can put it on the always-visible header line. Details summary rows are the
  # structural separators: bold labels were rejected because diff content
  # contains bold prose and the structure dissolved into it.
  class RichDiff
    # @!attribute backlink
    #   @return [String, nil] markdown link to the edited section
    # @!attribute collapsed
    #   @return [String] the two <details> blocks, closed by default
    Result = Struct.new(:backlink, :collapsed, keyword_init: true)

    # @param executor [AiFlow::Executor] used for git's word/unified diffs
    def initialize(executor: Executor.new)
      @executor = executor
    end

    # @param before [String] the section (or document) before the edit
    # @param after [String] the section after the edit
    # @param backlink_url [String, nil] issue/PR URL for the text-fragment link
    # @return [Result]
    def render(before:, after:, backlink_url: nil)
      word_diff = [ins_del_prose(before, after)]
      mermaid = changed_mermaid_blocks(before, after)
      word_diff << "Updated diagram:\n\n#{mermaid.join("\n\n")}" unless mermaid.empty?

      Result.new(
        backlink: backlink(before, after, backlink_url),
        collapsed: [
          details("Word diff", word_diff.join("\n\n")),
          details("Source diff", source_diff_fence(before, after)),
        ].join("\n"),
      )
    end

    private

    # @param summary [String]
    # @param content [String]
    # @return [String]
    def details(summary, content)
      "<details>\n<summary>#{summary}</summary>\n\n#{content}\n\n</details>"
    end

    # Word-level diff via `git diff --word-diff=plain` ({+…+} / [-…-] markers),
    # converted to <ins>/<del>. Mermaid/code fences are excluded — a word-diffed
    # fence body would corrupt the block (the diagram is re-rendered whole
    # instead), so fenced regions are dropped from the prose diff. Hunk
    # headers are stripped, but non-adjacent hunks get a standalone `⋯`
    # paragraph between them — whole-document diffs would otherwise read
    # distant excerpts as contiguous prose.
    #
    # @return [String]
    def ins_del_prose(before, after)
      word_diff = git_diff(before, after, ["--word-diff=plain"])
      kept = []
      in_fence = false
      in_first_hunk = true
      word_diff.split("\n").drop_while { |line| !line.start_with?("@@") }.each do |line|
        if line.start_with?("@@")
          kept << "" << "⋯" << "" unless in_first_hunk
          in_first_hunk = false
          next
        end

        # Fences may arrive wrapped in word-diff markers ({+```+} etc.) when a
        # whole block was added/removed.
        if line.strip.match?(/\A(\{\+|\[-)?```/)
          in_fence = !in_fence
          next
        end
        kept << line unless in_fence
      end
      converted = kept.join("\n")
        .gsub(/\{\+(.*?)\+\}/m) { "<ins>#{Regexp.last_match(1)}</ins>" }
        .gsub(/\[-(.*?)-\]/m) { "<del>#{Regexp.last_match(1)}</del>" }
        .strip
      converted.empty? ? "Fenced blocks changed — see the source diff." : converted
    end

    # Mermaid blocks present in the edited text that differ from before — these
    # re-render live in the comment, giving the visual diagram diff.
    #
    # @return [Array<String>] full ```mermaid fenced blocks
    def changed_mermaid_blocks(before, after)
      extract_mermaid(after) - extract_mermaid(before)
    end

    # @return [Array<String>]
    def extract_mermaid(text)
      text.scan(/^```mermaid\n.*?^```$/m)
    end

    # The exact unified diff in a colored ```diff fence. Formatter rule from
    # the plan: the fence must be longer than any fence the diff contains,
    # otherwise an inner fence terminates the block and the rest of the
    # comment spills out.
    #
    # @return [String]
    def source_diff_fence(before, after)
      diff_body = git_diff(before, after, ["--unified=3"])
        .split("\n")
        .drop_while { |line| !line.start_with?("@@") }
        .join("\n")
      longest_inner_fence = diff_body.scan(/`{3,}/).map(&:length).max || 0
      fence = "`" * [longest_inner_fence + 1, 4].max
      "#{fence}diff\n#{diff_body}\n#{fence}"
    end

    # Text-fragment backlink (#:~:text=) to the first changed line —
    # browser-native scroll-and-highlight. Anchoring to a changed line (not
    # the first prose line of `after`) matters for whole-document diffs,
    # where the document's first line is usually untouched.
    #
    # @return [String, nil]
    def backlink(before, after, url)
      return nil unless url

      anchor = anchor_text(before, after)
      return nil unless anchor

      fragment = ERB::Util.url_encode(anchor.split(" ").take(6).join(" "))
      "[view the edited section](#{url}#:~:text=#{fragment})"
    end

    # The first changed line of `after`, preferring bare prose. Sections made
    # only of bullets/headings would otherwise have no anchor, so fall back
    # to the first changed line with its leading markers stripped — text
    # fragments match the rendered text, and a rendered bullet/heading drops
    # those markers.
    #
    # @return [String, nil]
    def anchor_text(before, after)
      lines = after.split("\n").map(&:strip).reject(&:empty?)
      changed = lines.reject { |line| before.include?(line) }
      changed = lines if changed.empty?

      prose = changed.find { |line| !line.start_with?("#", "```", ">", "-", "*", "|", "<") }
      return prose if prose

      decorated = changed.find { |line| !line.start_with?("```", "|", "<") }
      stripped = decorated&.sub(/\A[#>*\- ]+/, "")
      stripped unless stripped.nil? || stripped.empty?
    end

    # Diff two strings via git --no-index (exit 1 = differences, not failure).
    #
    # @return [String] raw git diff output
    def git_diff(before, after, flags)
      Dir.mktmpdir("ai-flow-diff-") do |dir|
        before_path = File.join(dir, "before")
        after_path = File.join(dir, "after")
        File.write(before_path, ensure_trailing_newline(before))
        File.write(after_path, ensure_trailing_newline(after))
        out, _err, _ok = @executor.capture(
          "git", "diff", "--no-index", *flags, before_path, after_path
        )
        out
      end
    end

    # @return [String]
    def ensure_trailing_newline(text)
      text.end_with?("\n") ? text : "#{text}\n"
    end
  end
end
