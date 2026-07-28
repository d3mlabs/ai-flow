# typed: strict
# frozen_string_literal: true

require "json"

module AiFlow
  # The dispatch context, parsed from the Actions webhook payload
  # (GITHUB_EVENT_PATH). Normalizes the three command surfaces the dispatcher
  # listens on: issue_comment (issues + PR conversation comments — PRs fire
  # issue_comment too), pull_request_review_comment (line-anchored), and
  # pull_request_review (the review summary itself — its body carries the
  # command; the payload nests it under "review", not "comment").
  class Context
    extend T::Sig

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

    # @return [String, nil] the commenter's login (the requesting human)
    sig { returns(T.nilable(String)) }
    attr_reader :commenter_login

    # @return [Integer, nil] the commenter's user id (for the canonical
    #   <id>+<login>@users.noreply.github.com credit form)
    sig { returns(T.nilable(Integer)) }
    attr_reader :commenter_id

    # @return [String, nil] PR head branch (review surfaces only)
    sig { returns(T.nilable(String)) }
    attr_reader :pr_head_ref

    # @return [String, nil] the review comment's line anchor (diff hunk)
    sig { returns(T.nilable(String)) }
    attr_reader :diff_hunk

    # @return [String, nil] file path of the review comment's anchor
    sig { returns(T.nilable(String)) }
    attr_reader :diff_path

    # @param event_name [String] GITHUB_EVENT_NAME
    # @param payload [Hash] parsed event JSON
    # @param env [Hash-like] injectable for tests; the Actions job env
    sig { params(event_name: String, payload: T::Hash[String, T.untyped], env: T.untyped).void }
    def initialize(event_name:, payload:, env: ENV)
      @event_name = event_name
      @env = env
      # Declared unconditionally (strict forbids branch-only ivars); the
      # issue_comment branch below overwrites it from the payload.
      @pull_request = T.let(false, T::Boolean)
      # Review-summary payloads carry the command under "review"; both
      # comment surfaces carry it under "comment". Same fields either way.
      # The T.lets coerce the untyped webhook JSON at this boundary — a
      # malformed payload fails here, loudly, not deep in a command.
      source = review_summary? ? payload.fetch("review") : payload.fetch("comment")
      @owner_repo = T.let(payload.fetch("repository").fetch("full_name"), String)
      @comment_id = T.let(source.fetch("id"), Integer)
      @comment_body = T.let(source["body"] || "", String)
      @author_association = T.let(source["author_association"] || "NONE", String)
      @comment_url = T.let(source.fetch("html_url"), String)
      user = source["user"] || {}
      @commenter_login = T.let(user["login"], T.nilable(String))
      @commenter_id = T.let(user["id"], T.nilable(Integer))

      if review_comment? || review_summary?
        pull_request = payload.fetch("pull_request")
        @number = T.let(pull_request.fetch("number"), Integer)
        @pr_head_ref = T.let(pull_request.fetch("head").fetch("ref"), T.nilable(String))
        @diff_hunk = T.let(source["diff_hunk"], T.nilable(String))
        @diff_path = T.let(source["path"], T.nilable(String))
      else
        issue = payload.fetch("issue")
        @number = T.let(issue.fetch("number"), Integer)
        @pull_request = !issue["pull_request"].nil?
      end
    end

    # @param event_name [String] GITHUB_EVENT_NAME
    # @param event_path [String] GITHUB_EVENT_PATH
    # @return [Context]
    sig { params(event_name: String, event_path: String).returns(Context) }
    def self.from_event_file(event_name:, event_path:)
      new(event_name: event_name, payload: JSON.parse(File.read(event_path)))
    end

    # @return [Boolean] line-anchored PR review comment?
    sig { returns(T::Boolean) }
    def review_comment?
      @event_name == "pull_request_review_comment"
    end

    # A review summary supports neither reactions nor in-place edits (no
    # API for either), so the 👀/⏳/result flow rides a bot-owned PR
    # comment instead — see ResultWriter's review panel.
    #
    # @return [Boolean] a submitted review's summary?
    sig { returns(T::Boolean) }
    def review_summary?
      @event_name == "pull_request_review"
    end

    # @return [Boolean] any PR surface (conversation, review comment, or
    #   review summary)?
    sig { returns(T::Boolean) }
    def pull_request?
      review_comment? || review_summary? || @pull_request
    end

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
  end
end
