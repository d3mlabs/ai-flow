# frozen_string_literal: true

require "json"

module AiFlow
  # The dispatch context, parsed from the Actions webhook payload
  # (GITHUB_EVENT_PATH). Normalizes the two comment surfaces the dispatcher
  # listens on: issue_comment (issues + PR conversation comments — PRs fire
  # issue_comment too) and pull_request_review_comment (line-anchored).
  class Context
    ALLOWED_ASSOCIATIONS = %w[OWNER MEMBER COLLABORATOR].freeze

    # @return [String] "owner/repo"
    attr_reader :owner_repo
    # @return [Integer] issue or PR number
    attr_reader :number
    # @return [Integer] the command comment's id
    attr_reader :comment_id
    # @return [String] the command comment's body
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
    # @return [String, nil] PR head branch (review comments only)
    attr_reader :pr_head_ref
    # @return [String, nil] the review comment's line anchor (diff hunk)
    attr_reader :diff_hunk
    # @return [String, nil] file path of the review comment's anchor
    attr_reader :diff_path

    # @param event_name [String] GITHUB_EVENT_NAME
    # @param payload [Hash] parsed event JSON
    def initialize(event_name:, payload:)
      @event_name = event_name
      comment = payload.fetch("comment")
      @owner_repo = payload.fetch("repository").fetch("full_name")
      @comment_id = comment.fetch("id")
      @comment_body = comment["body"] || ""
      @author_association = comment["author_association"] || "NONE"
      @comment_url = comment.fetch("html_url")
      user = comment["user"] || {}
      @commenter_login = user["login"]
      @commenter_id = user["id"]

      if review_comment?
        pull_request = payload.fetch("pull_request")
        @number = pull_request.fetch("number")
        @pr_head_ref = pull_request.fetch("head").fetch("ref")
        @diff_hunk = comment["diff_hunk"]
        @diff_path = comment["path"]
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

    # @return [Boolean] any PR surface (conversation or review comment)?
    def pull_request?
      review_comment? || @pull_request
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
  end
end
