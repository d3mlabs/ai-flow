# frozen_string_literal: true

module AiFlow
  # In-place result appending — the noise-minimization protocol (plan,
  # Component 6): acting commands never reply; the dispatcher edits the
  # command comment so one comment carries both the ask and the outcome.
  # Each segment's result interleaves directly under the quote+command that
  # produced it (a mini-thread per segment); batch-level material (the plan
  # diff) appends once at the bottom under a horizontal rule.
  class ResultWriter
    # @param github [AiFlow::GitHub]
    def initialize(github:)
      @github = github
    end

    # Pure body transformation. Per-segment panels insert after each
    # segment's owned region (descending, so earlier indices stay valid);
    # the human's text is otherwise untouched. Panels are blockquote-wrapped
    # so they read as one visual unit (the left accent bar) distinct from
    # the human's command text. Batch-level material — the appendix (plan
    # diff) and the permanent run-link footer — lands at the bottom under
    # one --- rule.
    #
    # @param original_body [String] the command comment as posted
    # @param results [Array<Array(CommentParser::Segment, String)>]
    # @param appendix [String, nil] batch-level block (the plan diff)
    # @param run_url [String, nil] the Actions run that produced the results
    # @return [String] the updated comment body
    def render(original_body, results, appendix: nil, run_url: nil)
      lines = original_body.gsub("\r\n", "\n").split("\n", -1)
      results.sort_by { |segment, _result| -segment.end_line }.each do |segment, result|
        lines.insert(segment.end_line + 1, "", *blockquote(result))
      end

      body = lines.join("\n").rstrip
      bottom = [appendix, footer(run_url)].compact.join("\n\n")
      body = "#{body}\n\n---\n\n#{blockquote(bottom).join("\n")}" unless bottom.empty?
      body
    end

    # @param run_url [String, nil]
    # @return [String, nil] the post-hoc observability link
    def footer(run_url)
      run_url && "⚙️ [workflow run](#{run_url})"
    end

    # @param text [String]
    # @return [Array<String>] the text's lines, each quote-prefixed
    def blockquote(text)
      text.split("\n", -1).map { |line| line.empty? ? ">" : "> #{line}" }
    end

    # Edit the command comment in place with the results.
    #
    # @param context [AiFlow::Context]
    # @param results [Array<Array(CommentParser::Segment, String)>]
    # @param appendix [String, nil]
    # @return [void]
    def write(context, results, appendix: nil)
      write_raw(context, render(context.comment_body, results, appendix: appendix, run_url: context.run_url))
    end

    # Edit the command comment to an exact body — the status line while a
    # command runs, and the reply path's revert of it.
    #
    # @param context [AiFlow::Context]
    # @param body [String]
    # @return [void]
    def write_raw(context, body)
      if context.review_comment?
        @github.update_review_comment(context.owner_repo, context.comment_id, body: body)
      else
        @github.update_issue_comment(context.owner_repo, context.comment_id, body: body)
      end
    end
  end
end
