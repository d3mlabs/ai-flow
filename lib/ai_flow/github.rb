# typed: strict
# frozen_string_literal: true

require "json"
require "time"

module AiFlow
  # GitHub API access via the `gh` CLI (authenticated with the workflow's
  # GH_TOKEN). JSON payloads go through `--input -` so bodies never hit argv.
  class GitHub
    extend T::Sig

    class Error < StandardError; end

    # `repo` is the "owner/repo" the issue lives in (derived from
    # repository_url) — sub-issues may live in a different repo than their
    # parent, so it can't be assumed from context. `body` and `state` are
    # props: the in-memory test fake mutates them on update_issue_body and
    # close_issue. Every field is non-nilable: both builders (the REST
    # to_issue and the GraphQL parent_issue) receive fully hydrated issue
    # objects, so there is no partial shape to represent.
    class Issue < T::Struct
      extend T::Sig

      const :number, Integer
      const :title, String
      prop :body, String
      const :html_url, String
      prop :state, String
      const :repo, String

      # @return [Boolean] whether the issue is open
      sig { returns(T::Boolean) }
      def open? = state == "open"
    end

    # One conversation comment (issues and PR conversations share the REST
    # issues namespace). `author` is the login, "" for ghost/deleted users.
    # `created_at` is parsed at the boundary — no consumer re-parses strings.
    class Comment < T::Struct
      extend T::Sig

      const :id, Integer
      const :author, String
      const :body, String
      const :html_url, String
      const :created_at, Time

      # A copy with the body replaced — consumers strip noise (collapsed
      # <details> diffs) without mutating a shared collection.
      #
      # @param body [String]
      # @return [Comment]
      sig { params(body: String).returns(Comment) }
      def with_body(body)
        Comment.new(id: id, author: author, body: body, html_url: html_url, created_at: created_at)
      end
    end

    # One unresolved PR review thread — /build's feedback sweep unit. The
    # GraphQL node is flattened at the boundary: the hunk and the REST id of
    # the first comment (the replies API anchors on it) are hoisted off the
    # comment page, which can be empty — hence the nilable id and "" hunk.
    class ReviewThread < T::Struct
      # One comment in the thread's conversation. `author` is the login,
      # "" for ghost/deleted users.
      class Comment < T::Struct
        const :author, String
        const :body, String
        const :url, String
      end

      const :path, String
      const :diff_hunk, String
      const :first_comment_id, T.nilable(Integer)
      const :comments, T::Array[Comment]
    end

    # A pull request, as the commands consume it: the number anchors API
    # calls (close, assign), the URL lands in result comments.
    class PullRequest < T::Struct
      const :number, Integer
      const :html_url, String
    end

    # @param executor [AiFlow::Executor]
    sig { params(executor: Executor).void }
    def initialize(executor: Executor.new)
      @executor = executor
      # Memoization stores for the routing menus (see owner_repos /
      # app_installed_repos) — read several times per run.
      @owner_repos = T.let({}, T::Hash[String, T::Array[String]])
      @app_installed_repos = T.let(nil, T.nilable(T::Array[String]))
    end

    # @param path [String] REST path, e.g. "repos/o/r/issues/1"
    # @param method [String, nil] HTTP method (nil = GET)
    # @param payload [Hash, nil] JSON body
    # @return [Object] parsed JSON response (nil for empty responses)
    sig do
      params(path: String, method: T.nilable(String), payload: T.nilable(T::Hash[T.untyped, T.untyped]))
        .returns(T.untyped)
    end
    def api(path, method: nil, payload: nil)
      argv = ["gh", "api"]
      argv += ["-X", method] if method
      argv += ["--input", "-"] if payload
      argv << path
      # T.unsafe: splatting a runtime-built argv into capture's rest param
      # is beyond Sorbet's static splat support (srb.help/7019).
      out, err, ok = T.unsafe(@executor).capture(*argv, stdin: payload && JSON.generate(payload))
      raise Error, "gh api #{path} failed: #{err.strip}" unless ok

      out.empty? ? nil : JSON.parse(out)
    end

    # @param query [String] GraphQL query/mutation with $variables
    # @param variables [Hash]
    # @return [Hash] the "data" object
    sig do
      params(query: String, variables: T::Hash[Symbol, T.untyped])
        .returns(T::Hash[String, T.untyped])
    end
    def graphql(query, variables = {})
      argv = ["gh", "api", "graphql"]
      argv += ["-f", "query=#{query}"]
      variables.each do |key, value|
        flag = value.is_a?(String) ? "-f" : "-F"
        argv += [flag, "#{key}=#{value}"]
      end
      # T.unsafe: same runtime-built argv splat as api (srb.help/7019).
      out, err, ok = T.unsafe(@executor).capture(*argv)
      raise Error, "gh graphql failed: #{err.strip}" unless ok

      JSON.parse(out).fetch("data")
    end

    # @param owner_repo [String]
    # @param number [Integer]
    # @return [Issue]
    sig { params(owner_repo: String, number: Integer).returns(Issue) }
    def issue(owner_repo, number)
      to_issue(api("repos/#{owner_repo}/issues/#{number}"))
    end

    # @return [Issue] the created issue
    sig { params(owner_repo: String, title: String, body: String).returns(Issue) }
    def create_issue(owner_repo, title:, body:)
      to_issue(api("repos/#{owner_repo}/issues", method: "POST", payload: { title: title, body: body }))
    end

    # @return [Issue] the updated issue
    sig { params(owner_repo: String, number: Integer, body: String).returns(Issue) }
    def update_issue_body(owner_repo, number, body:)
      to_issue(api("repos/#{owner_repo}/issues/#{number}", method: "PATCH", payload: { body: body }))
    end

    # @param owner_repo [String]
    # @param number [Integer]
    # @param comment [String, nil] posted before closing, when given
    # @return [void]
    sig { params(owner_repo: String, number: Integer, comment: T.nilable(String)).void }
    def close_issue(owner_repo, number, comment: nil)
      post_issue_comment(owner_repo, number, comment) if comment
      api("repos/#{owner_repo}/issues/#{number}", method: "PATCH", payload: { state: "closed" })
    end

    # @return [Comment] the created comment
    sig { params(owner_repo: String, number: Integer, body: String).returns(Comment) }
    def post_issue_comment(owner_repo, number, body)
      to_comment(api("repos/#{owner_repo}/issues/#{number}/comments", method: "POST", payload: { body: body }))
    end

    # The issue's conversation, oldest first. One page of 100 covers our
    # review threads; quote-context resolution degrades gracefully (verbatim
    # fallback) if a source comment ever falls past the cap.
    #
    # @return [Array<Comment>]
    sig { params(owner_repo: String, number: Integer).returns(T::Array[Comment]) }
    def issue_comments(owner_repo, number)
      list = api("repos/#{owner_repo}/issues/#{number}/comments?per_page=100") || []
      list.map { |data| to_comment(data) }
    end

    # Edit an issue/PR-conversation comment in place (the noise-minimization
    # protocol: results append into the command comment, no reply comments).
    #
    # @return [void]
    sig { params(owner_repo: String, comment_id: Integer, body: String).void }
    def update_issue_comment(owner_repo, comment_id, body:)
      api("repos/#{owner_repo}/issues/comments/#{comment_id}", method: "PATCH", payload: { body: body })
    end

    # Same, for line-anchored PR review comments (different REST namespace).
    #
    # @return [void]
    sig { params(owner_repo: String, comment_id: Integer, body: String).void }
    def update_review_comment(owner_repo, comment_id, body:)
      api("repos/#{owner_repo}/pulls/comments/#{comment_id}", method: "PATCH", payload: { body: body })
    end

    # Reply in a PR review comment thread.
    #
    # @return [void]
    sig { params(owner_repo: String, pull_number: Integer, comment_id: Integer, body: String).void }
    def reply_to_review_comment(owner_repo, pull_number, comment_id, body)
      api(
        "repos/#{owner_repo}/pulls/#{pull_number}/comments/#{comment_id}/replies",
        method: "POST", payload: { body: body },
      )
    end

    # Thread resolution state only exists in GraphQL, not REST.
    UNRESOLVED_THREADS_QUERY = <<~GRAPHQL
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            reviewThreads(first: 100) {
              nodes {
                isResolved
                path
                comments(first: 50) {
                  nodes { databaseId body diffHunk url author { login } }
                }
              }
            }
          }
        }
      }
    GRAPHQL

    # The PR's unresolved review threads — /build's feedback sweep.
    #
    # @return [Array<ReviewThread>]
    sig { params(owner_repo: String, number: Integer).returns(T::Array[ReviewThread]) }
    def unresolved_review_threads(owner_repo, number)
      owner, name = owner_repo.split("/", 2)
      data = graphql(UNRESOLVED_THREADS_QUERY, owner: owner, name: name, number: number)
      threads = data.dig("repository", "pullRequest", "reviewThreads", "nodes") || []
      threads.reject { |thread| thread["isResolved"] }.map { |thread| to_review_thread(thread) }
    end

    # The native sub-issue relationship, from the child side (only GraphQL
    # exposes it).
    PARENT_ISSUE_QUERY = <<~GRAPHQL
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          issue(number: $number) {
            parent { number title body url state repository { nameWithOwner } }
          }
        }
      }
    GRAPHQL

    # The plan a sub-issue belongs to — how /build reconstructs a subtask's
    # scope (sub-issues carry thin bodies; the parent plan is the spec).
    # Works for adopted issues too, since adoption creates the same native
    # relationship.
    #
    # @return [Issue, nil] nil when the issue has no parent
    sig { params(owner_repo: String, number: Integer).returns(T.nilable(Issue)) }
    def parent_issue(owner_repo, number)
      owner, name = owner_repo.split("/", 2)
      data = graphql(PARENT_ISSUE_QUERY, owner: owner, name: name, number: number)
      parent = data.dig("repository", "issue", "parent")
      return nil unless parent

      Issue.new(
        number: parent.fetch("number"),
        title: parent.fetch("title"),
        body: parent["body"] || "",
        html_url: parent.fetch("url"),
        state: parent.fetch("state").downcase,
        repo: parent.fetch("repository").fetch("nameWithOwner"),
      )
    end

    # Acknowledge a command with a reaction (👀 while running) — never a
    # status comment.
    #
    # @return [void]
    sig do
      params(owner_repo: String, comment_id: Integer, reaction: String, review_comment: T::Boolean).void
    end
    def react_to_comment(owner_repo, comment_id, reaction, review_comment: false)
      namespace = review_comment ? "pulls" : "issues"
      api(
        "repos/#{owner_repo}/#{namespace}/comments/#{comment_id}/reactions",
        method: "POST", payload: { content: reaction },
      )
    end

    # @return [Array<Issue>] the issue's native sub-issues
    sig { params(owner_repo: String, number: Integer).returns(T::Array[Issue]) }
    def sub_issues(owner_repo, number)
      list = api("repos/#{owner_repo}/issues/#{number}/sub_issues") || []
      list.map { |data| to_issue(data) }
    end

    # Attach an existing issue as a sub-issue of the parent (native sub-issue
    # API; the sub-issue may live in another repo of the same owner).
    #
    # @return [void]
    sig { params(owner_repo: String, parent_number: Integer, sub_issue_id: Integer).void }
    def add_sub_issue(owner_repo, parent_number, sub_issue_id)
      api(
        "repos/#{owner_repo}/issues/#{parent_number}/sub_issues",
        method: "POST", payload: { sub_issue_id: sub_issue_id },
      )
    end

    # @param draft [Boolean] open as a draft (learning PRs are drafts — the
    #   human merge is the curation gate, never an auto-merge)
    # @return [PullRequest] the created PR
    sig do
      params(owner_repo: String, title: String, body: String, head: String, base: String, draft: T::Boolean)
        .returns(PullRequest)
    end
    def create_pull_request(owner_repo, title:, body:, head:, base:, draft: false)
      to_pull_request(api(
        "repos/#{owner_repo}/pulls",
        method: "POST", payload: { title: title, body: body, head: head, base: base, draft: draft },
      ))
    end

    # The open PR whose head is this branch, or nil — how /learn finds a
    # source surface's existing draft to refine instead of duplicating (the
    # branch convention ai/learn-<source> is the discovery key). The head
    # filter is `owner:branch`; owner is the repo's owner.
    #
    # @return [PullRequest, nil] nil when no PR is open on the branch
    sig { params(owner_repo: String, branch: String).returns(T.nilable(PullRequest)) }
    def open_pull_request_for_head(owner_repo, branch)
      owner = owner_repo.split("/", 2).first
      list = api("repos/#{owner_repo}/pulls?state=open&head=#{owner}:#{branch}") || []
      first = list.first
      return nil if first.nil?

      to_pull_request(first)
    end

    # Close a PR without merging — how a later pass retires a dissolved
    # draft learning PR.
    #
    # @return [void]
    sig { params(owner_repo: String, number: Integer).void }
    def close_pull_request(owner_repo, number)
      api("repos/#{owner_repo}/pulls/#{number}", method: "PATCH", payload: { state: "closed" })
    end

    # Assign users to an issue or PR (PRs share the issues namespace).
    #
    # @return [void]
    sig { params(owner_repo: String, number: Integer, logins: T::Array[String]).void }
    def add_assignees(owner_repo, number, logins)
      api(
        "repos/#{owner_repo}/issues/#{number}/assignees",
        method: "POST", payload: { assignees: logins },
      )
    end

    # @return [String] the repo's default branch
    sig { params(owner_repo: String).returns(String) }
    def default_branch(owner_repo)
      api("repos/#{owner_repo}").fetch("default_branch")
    end

    # @return [String] the user's effective permission on the repo:
    #   "admin", "write", "read", or "none"
    sig { params(owner_repo: String, login: String).returns(String) }
    def collaborator_permission(owner_repo, login)
      api("repos/#{owner_repo}/collaborators/#{login}/permission").fetch("permission")
    end

    # The owner's repositories — /split's routing menu. One page of 100
    # covers the org; personal accounts (ai-flow on JPDuchesne/**) use the
    # users endpoint instead. Memoized: the menu is read several times per
    # run.
    #
    # @return [Array<String>] "owner/repo" names
    sig { params(owner: String).returns(T::Array[String]) }
    def owner_repos(owner)
      @owner_repos[owner] ||= begin
        list = begin
          api("orgs/#{owner}/repos?per_page=100")
        rescue Error
          api("users/#{owner}/repos?per_page=100")
        end
        (list || []).map { |repo| repo.fetch("full_name") }
      end
    end

    # Repos this token's App installation can act on — exactly the repos
    # /split may create sub-issues in. Empty under a plain token (local
    # runs), which makes every cross-repo route fall back to the parent's
    # repo: conservative, never over-permissive.
    #
    # @return [Array<String>] "owner/repo" names
    sig { returns(T::Array[String]) }
    def app_installed_repos
      @app_installed_repos ||= (api("installation/repositories?per_page=100") || {})
                               .fetch("repositories", [])
                               .map { |repo| repo.fetch("full_name") }
    rescue Error
      @app_installed_repos = []
    end

    # Open issues (never PRs — the shared REST namespace mixes them in) —
    # /split's discovery pool for existing-issue matching.
    #
    # @return [Array<Issue>]
    sig { params(owner_repo: String, limit: Integer).returns(T::Array[Issue]) }
    def open_issues(owner_repo, limit: 50)
      list = api("repos/#{owner_repo}/issues?state=open&per_page=#{limit}") || []
      list.reject { |data| data.key?("pull_request") }.map { |data| to_issue(data) }
    end

    private

    # @param thread [Hash] a GraphQL reviewThreads node
    # @return [ReviewThread]
    sig { params(thread: T::Hash[String, T.untyped]).returns(ReviewThread) }
    def to_review_thread(thread)
      comments = thread.dig("comments", "nodes") || []
      ReviewThread.new(
        path: thread.fetch("path"),
        diff_hunk: comments.first&.dig("diffHunk").to_s,
        first_comment_id: comments.first&.dig("databaseId"),
        comments: comments.map do |comment|
          ReviewThread::Comment.new(
            # dig: ghost/deleted users surface as a null author object.
            author: comment.dig("author", "login").to_s,
            body: comment.fetch("body"),
            url: comment.fetch("url"),
          )
        end,
      )
    end

    # @param data [Hash] a REST pull-request object
    # @return [PullRequest]
    sig { params(data: T::Hash[String, T.untyped]).returns(PullRequest) }
    def to_pull_request(data)
      PullRequest.new(number: data.fetch("number"), html_url: data.fetch("html_url"))
    end

    # @param data [Hash] a REST issue-comment object
    # @return [Comment]
    sig { params(data: T::Hash[String, T.untyped]).returns(Comment) }
    def to_comment(data)
      Comment.new(
        id: data.fetch("id"),
        # dig: ghost/deleted users surface as a null user object.
        author: data.dig("user", "login").to_s,
        body: data.fetch("body").to_s,
        html_url: data.fetch("html_url"),
        created_at: Time.parse(data.fetch("created_at")),
      )
    end

    # @param data [Hash] a REST issue object
    # @return [Issue]
    sig { params(data: T::Hash[String, T.untyped]).returns(Issue) }
    def to_issue(data)
      Issue.new(
        number: data.fetch("number"),
        title: data.fetch("title"),
        body: data["body"] || "",
        html_url: data.fetch("html_url"),
        state: data.fetch("state"),
        repo: data.fetch("repository_url").split("/repos/").fetch(-1),
      )
    end
  end
end
