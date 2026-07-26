# frozen_string_literal: true

module AiFlow
  # In-place result appending — the noise-minimization protocol (plan,
  # Component 6): acting commands never reply; the dispatcher edits the
  # command comment so one comment carries both the ask and the outcome.
  # Each segment's result interleaves directly under the quote+command that
  # produced it (a mini-thread per segment); batch-level material (the plan
  # diff) appends once at the bottom under a horizontal rule.
  #
  # Review summaries (pull_request_review) are the one surface without an
  # editable command comment (reviews accept no edits by the App), so their
  # ⏳ status and results ride a single bot-owned PR comment instead — the
  # review panel: posted once, updated thereafter, quoting the review text
  # so the panel stays self-contained. One comment either way.
  class ResultWriter
    # @param github [AiFlow::GitHub]
    # @param agent [AiFlow::Agent, nil] source of truth for the models the
    #   run actually used; nil (e.g. in tests) leaves the footer run-link-only
    def initialize(github:, agent: nil)
      @github = github
      @agent = agent
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
    # @return [String, nil] the post-hoc observability line: run link, plus
    #   the model(s) the agent actually ran on when it ran at all
    def footer(run_url)
      return nil unless run_url

      note = self.class.models_note(@agent&.models_used || {})
      "⚙️ #{["[workflow run](#{run_url})", note].compact.join(" · ")}"
    end

    # In practice this renders one name: a job launches under a single
    # command policy (a batch is one agent pass — run as /edit when any
    # edit is present — and /build --split's fan-out passes all share the
    # "build" key), so models_used holds one entry. Distinct values (if
    # per-segment passes ever exist) list out. nil for an empty hash (no
    # agent pass: failure before launch, /split --apply) so the caller's
    # line stays run-link-only. A class method so the dispatcher's ⏳
    # status line renders its pre-launch prediction with the same grammar
    # as the footer.
    #
    # @param models [Hash{String => String}] command => model
    # @return [String, nil]
    def self.models_note(models)
      return nil if models.empty?

      "model: #{models.values.uniq.map { |model| "`#{model}`" }.join(", ")}"
    end

    # @param text [String]
    # @return [Array<String>] the text's lines, each quote-prefixed
    def blockquote(text)
      text.split("\n", -1).map { |line| line.empty? ? ">" : "> #{line}" }
    end

    # Deliver the results: edit the command comment in place, or upsert the
    # review panel on the review-summary surface.
    #
    # @param context [AiFlow::Context]
    # @param results [Array<Array(CommentParser::Segment, String)>]
    # @param appendix [String, nil]
    # @return [void]
    def write(context, results, appendix: nil)
      if context.review_summary?
        upsert_review_panel(context, render_review_panel(context, results, appendix: appendix))
      else
        write_raw(context, render(context.comment_body, results, appendix: appendix, run_url: context.run_url))
      end
    end

    # The temporary status line while a command runs. On comment surfaces
    # it appends to the command comment (every final render starts from the
    # payload body, so it vanishes when results land); on the review-summary
    # surface it seeds the review panel that the results later overwrite.
    #
    # @param context [AiFlow::Context]
    # @param status [String] the ⏳ line, composed by the dispatcher
    # @return [void]
    def announce(context, status)
      if context.review_summary?
        body = [review_panel_header(context), "", *blockquote(context.comment_body.gsub("\r\n", "\n")), "", status]
        upsert_review_panel(context, body.join("\n"))
      else
        write_raw(context, "#{context.comment_body.rstrip}\n\n> #{status}")
      end
    end

    # The review panel's quoting is the in-place edit's inverse: the review
    # text is blockquoted (it is the human's words inside a bot comment) and
    # each panel lands plain under its segment. blockquote maps lines 1:1,
    # so the segment line anchors hold unchanged.
    #
    # @param context [AiFlow::Context]
    # @param results [Array<Array(CommentParser::Segment, String)>]
    # @param appendix [String, nil]
    # @return [String] the panel comment's body
    def render_review_panel(context, results, appendix: nil)
      lines = blockquote(context.comment_body.gsub("\r\n", "\n"))
      results.sort_by { |segment, _result| -segment.end_line }.each do |segment, result|
        lines.insert(segment.end_line + 1, "", result)
      end

      body = [review_panel_header(context), "", *lines].join("\n").rstrip
      bottom = [appendix, footer(context.run_url)].compact.join("\n\n")
      body = "#{body}\n\n---\n\n#{bottom}" unless bottom.empty?
      body
    end

    # Edit the command comment to an exact body — the reply path's revert of
    # the status line. Comment surfaces only; the review-summary surface has
    # no editable command comment (its flows go through write/announce).
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

    private

    # @return [String] the panel's attribution line — the panel is a bot
    #   comment, so it must name whose review it answers
    def review_panel_header(context)
      "In reply to #{context.commenter_login}'s [review](#{context.comment_url}):"
    end

    # First write posts the panel comment; every later write edits it, so
    # the surface keeps the one-comment protocol of the other surfaces.
    def upsert_review_panel(context, body)
      if @review_panel_comment_id
        @github.update_issue_comment(context.owner_repo, @review_panel_comment_id, body: body)
      else
        comment = @github.post_issue_comment(context.owner_repo, context.number, body)
        @review_panel_comment_id = comment.fetch("id")
      end
    end
  end
end
