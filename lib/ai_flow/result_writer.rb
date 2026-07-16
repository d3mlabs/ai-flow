# frozen_string_literal: true

module AiFlow
  # In-place result appending — the noise-minimization protocol (plan,
  # Component 6): acting commands never reply; the dispatcher edits the
  # command comment, appending each segment's result under its command line.
  # One comment per interaction, containing both the ask and the outcome.
  class ResultWriter
    # @param github [AiFlow::GitHub]
    def initialize(github:)
      @github = github
    end

    # Pure body transformation: insert each segment's rendered result directly
    # under the text that segment owns (bottom-up, so indices stay valid).
    # Results are blockquote-wrapped so the machine-appended part reads as one
    # panel (the left accent bar), visually separated from the human's command
    # text — a stronger grouping than the bare `---` rule it replaced.
    #
    # @param original_body [String] the command comment as posted
    # @param results [Array<Array(CommentParser::Segment, String)>]
    # @return [String] the updated comment body
    def render(original_body, results)
      lines = original_body.gsub("\r\n", "\n").split("\n", -1)
      results.sort_by { |segment, _result| -segment.end_line }.each do |segment, result|
        lines.insert(segment.end_line + 1, "", *blockquote(result))
      end
      lines.join("\n")
    end

    # @param result [String]
    # @return [Array<String>] the result's lines, each quote-prefixed
    def blockquote(result)
      result.split("\n", -1).map { |line| line.empty? ? ">" : "> #{line}" }
    end

    # Edit the command comment in place with the segments' results.
    #
    # @param context [AiFlow::Context]
    # @param results [Array<Array(CommentParser::Segment, String)>]
    # @return [void]
    def write(context, results)
      body = render(context.comment_body, results)
      if context.review_comment?
        @github.update_review_comment(context.owner_repo, context.comment_id, body: body)
      else
        @github.update_issue_comment(context.owner_repo, context.comment_id, body: body)
      end
    end
  end
end
