# typed: strict
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
    extend T::Sig

    # backlink: markdown link to the edited section (nil without a URL or
    # anchor); collapsed: the two <details> blocks, closed by default.
    class Result < T::Struct
      const :backlink, T.nilable(String)
      const :collapsed, String
    end

    # @param executor [AiFlow::Executor] used for git's word/unified diffs
    sig { params(executor: Executor).void }
    def initialize(executor: Executor.new)
      @executor = executor
    end

    # @param before [String] the section (or document) before the edit
    # @param after [String] the section after the edit
    # @param backlink_url [String, nil] issue/PR URL for the text-fragment link
    # @return [Result]
    sig { params(before: String, after: String, backlink_url: T.nilable(String)).returns(Result) }
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
    sig { params(summary: String, content: String).returns(String) }
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
    sig { params(before: String, after: String).returns(String) }
    def ins_del_prose(before, after)
      word_diff = git_diff(before, after, ["--word-diff=plain"])
      kept = []
      in_fence = T.let(false, T::Boolean)
      in_first_hunk = T.let(true, T::Boolean)
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
    sig { params(before: String, after: String).returns(T::Array[String]) }
    def changed_mermaid_blocks(before, after)
      extract_mermaid(after) - extract_mermaid(before)
    end

    # @return [Array<String>]
    sig { params(text: String).returns(T::Array[String]) }
    def extract_mermaid(text)
      # T.cast: scan with a group-free pattern always yields strings, but
      # the stdlib RBI types it for the grouped case too.
      T.cast(text.scan(/^```mermaid\n.*?^```$/m), T::Array[String])
    end

    # The exact unified diff in a colored ```diff fence. Formatter rule from
    # the plan: the fence must be longer than any fence the diff contains,
    # otherwise an inner fence terminates the block and the rest of the
    # comment spills out.
    #
    # @return [String]
    sig { params(before: String, after: String).returns(String) }
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
    sig { params(before: String, after: String, url: T.nilable(String)).returns(T.nilable(String)) }
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
    sig { params(before: String, after: String).returns(T.nilable(String)) }
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
    sig { params(before: String, after: String, flags: T::Array[String]).returns(String) }
    def git_diff(before, after, flags)
      Dir.mktmpdir("ai-flow-diff-") do |dir|
        before_path = File.join(dir, "before")
        after_path = File.join(dir, "after")
        File.write(before_path, ensure_trailing_newline(before))
        File.write(after_path, ensure_trailing_newline(after))
        argv = ["git", "diff", "--no-index", *flags, before_path, after_path]
        # T.unsafe: splatting a runtime-built argv into capture's rest param
        # is beyond Sorbet's static splat support (srb.help/7019).
        out, _err, _ok = T.unsafe(@executor).capture(*argv)
        out
      end
    end

    # @return [String]
    sig { params(text: String).returns(String) }
    def ensure_trailing_newline(text)
      text.end_with?("\n") ? text : "#{text}\n"
    end
  end
end
