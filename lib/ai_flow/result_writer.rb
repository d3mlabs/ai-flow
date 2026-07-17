# frozen_string_literal: true

module AiFlow
  # In-place result appending — the noise-minimization protocol (plan,
  # Component 6): acting commands never reply; the dispatcher edits the
  # command comment, appending one result section under the human's text.
  # One comment per interaction, containing both the ask and the outcome.
  class ResultWriter
    # @param github [AiFlow::GitHub]
    def initialize(github:)
      @github = github
    end

    # Pure body transformation: the human's text stays untouched, then a
    # horizontal rule separates the machine-appended section — per-segment
    # result lines (numbered when there are several) and the optional
    # batch-level appendix (the plan diff). The section is blockquote-wrapped
    # so it reads as one panel (the left accent bar) distinct from the
    # human's command text.
    #
    # @param original_body [String] the command comment as posted
    # @param results [Array<Array(CommentParser::Segment, String)>]
    # @param appendix [String, nil]
    # @return [String] the updated comment body
    def render(original_body, results, appendix: nil)
      texts = results.map(&:last)
      texts = texts.each_with_index.map { |text, index| "**#{index + 1}.** #{text}" } if texts.size > 1
      section = (texts + [appendix].compact).join("\n\n")
      "#{original_body.gsub("\r\n", "\n").rstrip}\n\n---\n\n#{blockquote(section)}"
    end

    # @param text [String]
    # @return [String] the text's lines, each quote-prefixed
    def blockquote(text)
      text.split("\n", -1).map { |line| line.empty? ? ">" : "> #{line}" }.join("\n")
    end

    # Edit the command comment in place with the result section.
    #
    # @param context [AiFlow::Context]
    # @param results [Array<Array(CommentParser::Segment, String)>]
    # @param appendix [String, nil]
    # @return [void]
    def write(context, results, appendix: nil)
      body = render(context.comment_body, results, appendix: appendix)
      if context.review_comment?
        @github.update_review_comment(context.owner_repo, context.comment_id, body: body)
      else
        @github.update_issue_comment(context.owner_repo, context.comment_id, body: body)
      end
    end
  end
end
