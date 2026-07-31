# typed: strict
# frozen_string_literal: true

require "json"

module AiFlow
  # The dispatch context, parsed from the Actions webhook payload
  # (GITHUB_EVENT_PATH). One sealed leaf per command surface, so
  # surface-specific fields exist only where the payload actually carries
  # them (a review comment always has a diff anchor; an issue comment never
  # does) — no field is present-but-nil for the wrong surface. Build with
  # Context.from_event; case dispatch over the leaves is exhaustive.
  class Context
    extend T::Sig
    extend T::Helpers
    abstract!
    sealed!

    # Payload associations that authorize on their own. Not exhaustive:
    # review-comment payloads under-report (an org MEMBER can arrive as
    # CONTRIBUTOR), so the dispatcher backstops a miss here with the
    # collaborator-permission API.
    ALLOWED_ASSOCIATIONS = %w[OWNER MEMBER COLLABORATOR].freeze

    # @return [String] "owner/repo"
    sig { returns(String) }
    attr_reader :owner_repo

    # @return [Integer] issue or PR number
    sig { returns(Integer) }
    attr_reader :number

    # @return [Integer] the command comment's id (the review's id on the
    #   review-summary surface — identity only, never editable there)
    sig { returns(Integer) }
    attr_reader :comment_id

    # @return [String] the command comment's (or review summary's) body
    sig { returns(String) }
    attr_reader :comment_body

    # @return [String] commenter's author_association
    sig { returns(String) }
    attr_reader :author_association

    # @return [String] the comment's html_url
    sig { returns(String) }
    attr_reader :comment_url

    # @return [String, nil] the commenter's login (the requesting human) —
    #   nilable payload truth: GitHub omits `user` for some app-authored
    #   events, and absence here is bare (tier-2), so it stays a nil
    sig { returns(T.nilable(String)) }
    attr_reader :commenter_login

    # @return [Integer, nil] the commenter's user id (for the canonical
    #   <id>+<login>@users.noreply.github.com credit form)
    sig { returns(T.nilable(Integer)) }
    attr_reader :commenter_id

    class << self
      extend T::Sig

      # The surface router: review-summary payloads carry the command under
      # "review", both comment surfaces under "comment"; anything that is not
      # a review event is the issue_comment surface (the only other event the
      # dispatch workflow subscribes to).
      #
      # @param event_name [String] GITHUB_EVENT_NAME
      # @param payload [Hash] parsed event JSON
      # @param env [Hash-like] injectable for tests; the Actions job env
      sig { params(event_name: String, payload: T::Hash[String, T.untyped], env: T.untyped).returns(Context) }
      def from_event(event_name:, payload:, env: ENV)
        case event_name
        when "pull_request_review_comment" then ReviewComment.new(payload: payload, env: env)
        when "pull_request_review" then ReviewSummary.new(payload: payload, env: env)
        else IssueComment.new(payload: payload, env: env)
        end
      end

      # @param event_name [String] GITHUB_EVENT_NAME
      # @param event_path [String] GITHUB_EVENT_PATH
      # @return [Context]
      sig { params(event_name: String, event_path: String).returns(Context) }
      def from_event_file(event_name:, event_path:)
        from_event(event_name: event_name, payload: JSON.parse(File.read(event_path)))
      end
    end

    # Shared coercion of the fields every surface carries. The T.lets coerce
    # the untyped webhook JSON at this boundary — a malformed payload fails
    # here, loudly, not deep in a command.
    #
    # @param source [Hash] the payload node carrying the command (comment
    #   or review)
    # @param payload [Hash] the full event payload
    # @param number [Integer] issue or PR number (leaves extract it from
    #   their own payload shape)
    # @param env [Hash-like]
    sig do
      params(
        source: T::Hash[String, T.untyped],
        payload: T::Hash[String, T.untyped],
        number: Integer,
        env: T.untyped,
      ).void
    end
    def initialize(source:, payload:, number:, env:)
      @env = env
      @number = number
      @owner_repo = T.let(payload.fetch("repository").fetch("full_name"), String)
      @comment_id = T.let(source.fetch("id"), Integer)
      @comment_body = T.let(source["body"] || "", String)
      @author_association = T.let(source["author_association"] || "NONE", String)
      @comment_url = T.let(source.fetch("html_url"), String)
      user = source["user"] || {}
      @commenter_login = T.let(user["login"], T.nilable(String))
      @commenter_id = T.let(user["id"], T.nilable(Integer))
    end

    # @return [Boolean] any PR surface (conversation, review comment, or
    #   review summary)?
    sig { abstract.returns(T::Boolean) }
    def pull_request?; end

    # @return [Boolean] line-anchored PR review comment?
    sig { overridable.returns(T::Boolean) }
    def review_comment? = false

    # A review summary supports neither reactions nor in-place edits (no
    # API for either), so the 👀/⏳/result flow rides a bot-owned PR
    # comment instead — see ResultWriter's review panel.
    #
    # @return [Boolean] a submitted review's summary?
    sig { overridable.returns(T::Boolean) }
    def review_summary? = false

    # Permission gate: only owners/members/collaborators may drive the agent.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def authorized?
      ALLOWED_ASSOCIATIONS.include?(author_association)
    end

    # @return [String] the issue/PR html URL (for text-fragment backlinks)
    sig { returns(String) }
    def subject_url
      "https://github.com/#{owner_repo}/#{pull_request? ? "pull" : "issues"}/#{number}"
    end

    # The Actions run executing this dispatch — the observability surface
    # linked from the command comment (status line while running, footer in
    # the delivered results).
    #
    # @return [String, nil] nil outside Actions (local runs)
    sig { returns(T.nilable(String)) }
    def run_url
      run_id = @env["GITHUB_RUN_ID"]
      return nil if run_id.nil? || run_id.empty?

      server = @env["GITHUB_SERVER_URL"] || "https://github.com"
      "#{server}/#{@env["GITHUB_REPOSITORY"]}/actions/runs/#{run_id}"
    end

    # A comment on an issue thread — which is also how PR *conversation*
    # comments arrive (GitHub fires issue_comment for both), so PR-ness here
    # is payload state, not a separate surface.
    class IssueComment < Context
      extend T::Sig

      # @param payload [Hash]
      # @param env [Hash-like]
      sig { params(payload: T::Hash[String, T.untyped], env: T.untyped).void }
      def initialize(payload:, env:)
        issue = payload.fetch("issue")
        super(source: payload.fetch("comment"), payload: payload, number: issue.fetch("number"), env: env)
        @pull_request = T.let(!issue["pull_request"].nil?, T::Boolean)
      end

      sig { override.returns(T::Boolean) }
      def pull_request? = @pull_request
    end

    # A line-anchored PR review comment: always carries the diff anchor and
    # the PR head branch — non-nilable here by payload contract.
    class ReviewComment < Context
      extend T::Sig

      # @return [String] PR head branch
      sig { returns(String) }
      attr_reader :pr_head_ref

      # @return [String] the review comment's line anchor
      sig { returns(String) }
      attr_reader :diff_hunk

      # @return [String] file path of the review comment's anchor
      sig { returns(String) }
      attr_reader :diff_path

      # @param payload [Hash]
      # @param env [Hash-like]
      sig { params(payload: T::Hash[String, T.untyped], env: T.untyped).void }
      def initialize(payload:, env:)
        source = payload.fetch("comment")
        pull_request = payload.fetch("pull_request")
        super(source: source, payload: payload, number: pull_request.fetch("number"), env: env)
        @pr_head_ref = T.let(pull_request.fetch("head").fetch("ref"), String)
        @diff_hunk = T.let(source.fetch("diff_hunk"), String)
        @diff_path = T.let(source.fetch("path"), String)
      end

      sig { override.returns(T::Boolean) }
      def pull_request? = true

      sig { override.returns(T::Boolean) }
      def review_comment? = true
    end

    # A submitted review's summary body: on a PR (head branch present) but
    # anchored to no line — the diff fields do not exist here at all.
    class ReviewSummary < Context
      extend T::Sig

      # @return [String] PR head branch
      sig { returns(String) }
      attr_reader :pr_head_ref

      # @param payload [Hash]
      # @param env [Hash-like]
      sig { params(payload: T::Hash[String, T.untyped], env: T.untyped).void }
      def initialize(payload:, env:)
        pull_request = payload.fetch("pull_request")
        super(source: payload.fetch("review"), payload: payload, number: pull_request.fetch("number"), env: env)
        @pr_head_ref = T.let(pull_request.fetch("head").fetch("ref"), String)
      end

      sig { override.returns(T::Boolean) }
      def pull_request? = true

      sig { override.returns(T::Boolean) }
      def review_summary? = true
    end
  end
end
