# frozen_string_literal: true

require "erb"
require "tmpdir"

module AiFlow
  # Renders the /edit result format (see the ai-flow plan, Component 5):
  # word-level <ins>/<del> prose (both allowed by GitHub's sanitizer — visually
  # the PR rich diff's green-underline/red-strikethrough), changed mermaid
  # blocks re-rendered live, the exact unified source diff collapsed in
  # <details>, and a text-fragment backlink to the edited section.
  class RichDiff
    # @param executor [AiFlow::Executor] used for git's word/unified diffs
    def initialize(executor: Executor.new)
      @executor = executor
    end

    # @param before [String] the section (or document) before the edit
    # @param after [String] the section after the edit
    # @param backlink_url [String, nil] issue/PR URL for the text-fragment link
    # @return [String] the rendered result block
    def render(before:, after:, backlink_url: nil)
      parts = []
      parts << ins_del_prose(before, after)
      mermaid = changed_mermaid_blocks(before, after)
      parts << "Updated diagram:\n\n#{mermaid.join("\n\n")}" unless mermaid.empty?
      parts << collapsed_source_diff(before, after)
      link = backlink(after, backlink_url)
      parts << link if link
      parts.join("\n\n")
    end

    private

    # Word-level diff via `git diff --word-diff=plain` ({+…+} / [-…-] markers),
    # converted to <ins>/<del>. Mermaid/code fences are excluded — a word-diffed
    # fence body would corrupt the block (the diagram is re-rendered whole
    # instead), so fenced regions are dropped from the prose diff.
    #
    # @return [String]
    def ins_del_prose(before, after)
      word_diff = git_diff(before, after, ["--word-diff=plain"])
      kept = []
      in_fence = false
      word_diff.split("\n").drop_while { |line| !line.start_with?("@@") }.each do |line|
        next if line.start_with?("@@")

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
      converted.empty? ? "Section rewritten (see the source diff below)." : converted
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

    # The exact unified diff, collapsed. Formatter rule from the plan: the
    # fence must be longer than any fence the diff contains, otherwise an inner
    # fence terminates the block and the rest of the comment spills out.
    #
    # @return [String]
    def collapsed_source_diff(before, after)
      diff_body = git_diff(before, after, ["--unified=3"])
        .split("\n")
        .drop_while { |line| !line.start_with?("@@") }
        .join("\n")
      longest_inner_fence = diff_body.scan(/`{3,}/).map(&:length).max || 0
      fence = "`" * [longest_inner_fence + 1, 4].max
      <<~MARKDOWN.strip
        <details>
        <summary>Source diff</summary>

        #{fence}diff
        #{diff_body}
        #{fence}

        </details>
      MARKDOWN
    end

    # Text-fragment backlink (#:~:text=) to the first distinctive prose line of
    # the edited section — browser-native scroll-and-highlight. Generated
    # against the current body; the agent refreshes it when the section changes.
    #
    # @return [String, nil]
    def backlink(after, url)
      return nil unless url

      anchor_line = after.split("\n").find do |line|
        stripped = line.strip
        !stripped.empty? && !stripped.start_with?("#", "```", ">", "-", "*", "|", "<")
      end
      return nil unless anchor_line

      fragment = ERB::Util.url_encode(anchor_line.strip.split(" ").take(6).join(" "))
      "[View the edited section](#{url}#:~:text=#{fragment})"
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
