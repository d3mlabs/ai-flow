# typed: true
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
    # Payload associations that authorize on their own. Not exhaustive:
    # review-comment payloads under-report (an org MEMBER can arrive as
    # CONTRIBUTOR), so the dispatcher backstops a miss here with the
    # collaborator-permission API.
    ALLOWED_ASSOCIATIONS = %w[OWNER MEMBER COLLABORATOR].freeze

    # @return [String] "owner/repo"
    attr_reader :owner_repo
    # @return [Integer] issue or PR number
    attr_reader :number
    # @return [Integer] the command comment's id (the review's id on the
    #   review-summary surface — identity only, never editable there)
    attr_reader :comment_id
    # @return [String] the command comment's (or review summary's) body
    attr_reader :comment_body
    # @return [String] commenter's author_association
    attr_reader :author_association
    # @return [String] the comment's html_url
    attr_reader :comment_url
    # @return [String, nil] the commenter's login (the requesting human)
    attr_reader :commenter_login
    # @return [Integer, nil] the commenter's user id (for the canonical
    #   <id>+<login>@users.noreply.github.com credit form)
    attr_reader :commenter_id
    # @return [String, nil] PR head branch (review surfaces only)
    attr_reader :pr_head_ref
    # @return [String, nil] the review comment's line anchor (diff hunk)
    attr_reader :diff_hunk
    # @return [String, nil] file path of the review comment's anchor
    attr_reader :diff_path

    # @param event_name [String] GITHUB_EVENT_NAME
    # @param payload [Hash] parsed event JSON
    # @param env [Hash-like] injectable for tests; the Actions job env
    def initialize(event_name:, payload:, env: ENV)
      @event_name = event_name
      @env = env
      # Review-summary payloads carry the command under "review"; both
      # comment surfaces carry it under "comment". Same fields either way.
      source = review_summary? ? payload.fetch("review") : payload.fetch("comment")
      @owner_repo = payload.fetch("repository").fetch("full_name")
      @comment_id = source.fetch("id")
      @comment_body = source["body"] || ""
      @author_association = source["author_association"] || "NONE"
      @comment_url = source.fetch("html_url")
      user = source["user"] || {}
      @commenter_login = user["login"]
      @commenter_id = user["id"]

      if review_comment? || review_summary?
        pull_request = payload.fetch("pull_request")
        @number = pull_request.fetch("number")
        @pr_head_ref = pull_request.fetch("head").fetch("ref")
        @diff_hunk = source["diff_hunk"]
        @diff_path = source["path"]
      else
        issue = payload.fetch("issue")
        @number = issue.fetch("number")
        @pull_request = !issue["pull_request"].nil?
      end
    end

    # @param event_name [String] GITHUB_EVENT_NAME
    # @param event_path [String] GITHUB_EVENT_PATH
    # @return [Context]
    def self.from_event_file(event_name:, event_path:)
      new(event_name: event_name, payload: JSON.parse(File.read(event_path)))
    end

    # @return [Boolean] line-anchored PR review comment?
    def review_comment?
      @event_name == "pull_request_review_comment"
    end

    # A review summary supports neither reactions nor in-place edits (no
    # API for either), so the 👀/⏳/result flow rides a bot-owned PR
    # comment instead — see ResultWriter's review panel.
    #
    # @return [Boolean] a submitted review's summary?
    def review_summary?
      @event_name == "pull_request_review"
    end

    # @return [Boolean] any PR surface (conversation, review comment, or
    #   review summary)?
    def pull_request?
      review_comment? || review_summary? || @pull_request
    end

    # Permission gate: only owners/members/collaborators may drive the agent.
    #
    # @return [Boolean]
    def authorized?
      ALLOWED_ASSOCIATIONS.include?(author_association)
    end

    # @return [String] the issue/PR html URL (for text-fragment backlinks)
    def subject_url
      "https://github.com/#{owner_repo}/#{pull_request? ? "pull" : "issues"}/#{number}"
    end

    # The Actions run executing this dispatch — the observability surface
    # linked from the command comment (status line while running, footer in
    # the delivered results).
    #
    # @return [String, nil] nil outside Actions (local runs)
    def run_url
      run_id = @env["GITHUB_RUN_ID"]
      return nil if run_id.nil? || run_id.empty?

      server = @env["GITHUB_SERVER_URL"] || "https://github.com"
      "#{server}/#{@env["GITHUB_REPOSITORY"]}/actions/runs/#{run_id}"
    end
  end
end
