# typed: strict
# frozen_string_literal: true

module AiFlow
  # Expands a dispatch context into the contexts one job must handle — the
  # review-as-one-unit fix (ai-flow#73).
  #
  # Submitting a review fires one pull_request_review_comment event per
  # comment, all at once; the dispatch job's per-PR concurrency group keeps
  # one running and at most one pending run, so a review carrying several
  # commands silently lost all but ~two. GitHub also fires a single
  # pull_request_review (submitted) event for every comment shape — batch
  # submission, single comment, and thread reply (each creates an implicit
  # review) — so that event is a complete surface: this class enumerates the
  # submitted review's own comments and hands every command-bearing one to
  # the dispatcher sequentially, inside the one run the group admits.
  #
  # Trust surface: a review is single-author by construction, so the hosted
  # authorize gate on the submitter covers every comment enumerated here —
  # the review is one command surface carrying N bodies (plans#5 doctrine).
  # Defense-in-depth: a comment whose author differs from the submitter is
  # dropped fail-closed with a log line, so the design doesn't rest on
  # GitHub's invariant never changing.
  class ReviewUnit
    extend T::Sig

    # @param context [AiFlow::Context] the event's own context
    # @param github [AiFlow::GitHub]
    # @param prefix [String] configured command prefix ("" by default)
    sig { params(context: Context, github: GitHub, prefix: String).void }
    def initialize(context:, github:, prefix: "")
      @context = context
      @github = github
      @prefix = prefix
    end

    # The contexts to dispatch, in surface order. Non-review events pass
    # through untouched; a review summary expands into itself (when its body
    # carries a command) plus one synthesized ReviewComment context per
    # command-bearing comment of the review, in review order.
    #
    # @return [Array<AiFlow::Context>]
    sig { returns(T::Array[Context]) }
    def contexts
      summary = @context
      return [summary] unless summary.is_a?(Context::ReviewSummary)

      children = command_comments(summary).map { |comment| summary.comment_context(comment) }
      (commands?(summary.comment_body) ? [summary] : []) + children
    end

    private

    # The review's command-bearing comments by the review's own submitter.
    #
    # @param summary [Context::ReviewSummary]
    # @return [Array<Hash>] raw review-comment nodes
    sig { params(summary: Context::ReviewSummary).returns(T::Array[T::Hash[String, T.untyped]]) }
    def command_comments(summary)
      @github.review_comments(summary.owner_repo, summary.number, summary.comment_id)
             .select { |comment| vouched?(summary, comment) }
             .select { |comment| commands?(comment["body"].to_s) }
    end

    # Single-author assertion, fail closed: the authorize gate vetted the
    # review's submitter, so only the submitter's comments may ride that
    # authorization.
    #
    # @param summary [Context::ReviewSummary]
    # @param comment [Hash] a raw review-comment node
    # @return [Boolean]
    sig { params(summary: Context::ReviewSummary, comment: T::Hash[String, T.untyped]).returns(T::Boolean) }
    def vouched?(summary, comment)
      author = comment.dig("user", "login")
      return true if author && author == summary.commenter_login

      warn "ai-flow: review comment #{comment["id"]} author #{author.inspect} is not the review's " \
           "submitter #{summary.commenter_login.inspect} — dropped (fail closed)."
      false
    end

    # Does the body hold at least one command line? A body whose commands
    # parse invalidly (a lifecycle command inside a batch) still counts:
    # dispatching it is what lands the ⚠️ parse error on that comment
    # instead of dropping it silently.
    #
    # @param body [String]
    # @return [Boolean]
    sig { params(body: String).returns(T::Boolean) }
    def commands?(body)
      CommentParser.new(prefix: @prefix).parse(body).any?
    rescue CommentParser::ParseError
      true
    end
  end
end
