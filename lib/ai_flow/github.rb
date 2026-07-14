# frozen_string_literal: true

require "json"

module AiFlow
  # GitHub API access via the `gh` CLI (authenticated with the workflow's
  # GH_TOKEN). JSON payloads go through `--input -` so bodies never hit argv.
  class GitHub
    class Error < StandardError; end

    # `repo` is the "owner/repo" the issue lives in (derived from
    # repository_url) — sub-issues may live in a different repo than their
    # parent, so it can't be assumed from context.
    Issue = Struct.new(:number, :title, :body, :updated_at, :html_url, :state, :repo, keyword_init: true)

    # @param executor [AiFlow::Executor]
    def initialize(executor: Executor.new)
      @executor = executor
    end

    # @param path [String] REST path, e.g. "repos/o/r/issues/1"
    # @param method [String, nil] HTTP method (nil = GET)
    # @param payload [Hash, nil] JSON body
    # @return [Object] parsed JSON response (nil for empty responses)
    def api(path, method: nil, payload: nil)
      argv = ["gh", "api"]
      argv += ["-X", method] if method
      argv += ["--input", "-"] if payload
      argv << path
      out, err, ok = @executor.capture(*argv, stdin: payload && JSON.generate(payload))
      raise Error, "gh api #{path} failed: #{err.strip}" unless ok

      out.empty? ? nil : JSON.parse(out)
    end

    # @param query [String] GraphQL query/mutation with $variables
    # @param variables [Hash]
    # @return [Hash] the "data" object
    def graphql(query, variables = {})
      argv = ["gh", "api", "graphql"]
      argv += ["-f", "query=#{query}"]
      variables.each do |key, value|
        flag = value.is_a?(String) ? "-f" : "-F"
        argv += [flag, "#{key}=#{value}"]
      end
      out, err, ok = @executor.capture(*argv)
      raise Error, "gh graphql failed: #{err.strip}" unless ok

      JSON.parse(out).fetch("data")
    end

    # @param owner_repo [String]
    # @param number [Integer]
    # @return [Issue]
    def issue(owner_repo, number)
      to_issue(api("repos/#{owner_repo}/issues/#{number}"))
    end

    # @return [Issue] the created issue
    def create_issue(owner_repo, title:, body:)
      to_issue(api("repos/#{owner_repo}/issues", method: "POST", payload: { title: title, body: body }))
    end

    # @return [Issue] the updated issue
    def update_issue_body(owner_repo, number, body:)
      to_issue(api("repos/#{owner_repo}/issues/#{number}", method: "PATCH", payload: { body: body }))
    end

    def close_issue(owner_repo, number, comment: nil)
      post_issue_comment(owner_repo, number, comment) if comment
      api("repos/#{owner_repo}/issues/#{number}", method: "PATCH", payload: { state: "closed" })
    end

    # @return [Hash] the created comment (with "id", "html_url")
    def post_issue_comment(owner_repo, number, body)
      api("repos/#{owner_repo}/issues/#{number}/comments", method: "POST", payload: { body: body })
    end

    # Edit an issue/PR-conversation comment in place (the noise-minimization
    # protocol: results append into the command comment, no reply comments).
    def update_issue_comment(owner_repo, comment_id, body:)
      api("repos/#{owner_repo}/issues/comments/#{comment_id}", method: "PATCH", payload: { body: body })
    end

    # Same, for line-anchored PR review comments (different REST namespace).
    def update_review_comment(owner_repo, comment_id, body:)
      api("repos/#{owner_repo}/pulls/comments/#{comment_id}", method: "PATCH", payload: { body: body })
    end

    # Reply in a PR review comment thread.
    def reply_to_review_comment(owner_repo, pull_number, comment_id, body)
      api(
        "repos/#{owner_repo}/pulls/#{pull_number}/comments/#{comment_id}/replies",
        method: "POST", payload: { body: body },
      )
    end

    # Acknowledge a command with a reaction (👀 while running) — never a
    # status comment.
    def react_to_comment(owner_repo, comment_id, reaction, review_comment: false)
      namespace = review_comment ? "pulls" : "issues"
      api(
        "repos/#{owner_repo}/#{namespace}/comments/#{comment_id}/reactions",
        method: "POST", payload: { content: reaction },
      )
    end

    # @return [Array<Issue>] the issue's native sub-issues
    def sub_issues(owner_repo, number)
      list = api("repos/#{owner_repo}/issues/#{number}/sub_issues") || []
      list.map { |data| to_issue(data) }
    end

    # Attach an existing issue as a sub-issue of the parent (native sub-issue
    # API; the sub-issue may live in another repo of the same owner).
    def add_sub_issue(owner_repo, parent_number, sub_issue_id)
      api(
        "repos/#{owner_repo}/issues/#{parent_number}/sub_issues",
        method: "POST", payload: { sub_issue_id: sub_issue_id },
      )
    end

    # @return [Hash] the created PR (with "html_url", "number")
    def create_pull_request(owner_repo, title:, body:, head:, base:)
      api(
        "repos/#{owner_repo}/pulls",
        method: "POST", payload: { title: title, body: body, head: head, base: base },
      )
    end

    # @return [String] the repo's default branch
    def default_branch(owner_repo)
      api("repos/#{owner_repo}").fetch("default_branch")
    end

    private

    def to_issue(data)
      Issue.new(
        number: data.fetch("number"),
        title: data.fetch("title"),
        body: data["body"] || "",
        updated_at: data.fetch("updated_at"),
        html_url: data.fetch("html_url"),
        state: data["state"],
        repo: data["repository_url"]&.split("/repos/")&.last,
      )
    end
  end
end
