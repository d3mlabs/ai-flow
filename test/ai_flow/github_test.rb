# typed: true
# frozen_string_literal: true

require "test_helper"
require "json"

transform!(RSpock::AST::Transformation)
class AiFlow::GitHubTest < Minitest::Test
  # Plays back one canned `gh` response; GitHub's real argv construction and
  # JSON parsing run for real (the executor is the class's one seam).
  # Subclasses the real class so sorbet-runtime's sig checks accept it.
  class CannedExecutor < AiFlow::Executor
    attr_reader :command_lines, :stdins

    def initialize(out: "")
      @out = out
      @command_lines = []
      @stdins = []
    end

    def capture(*argv, stdin: nil, chdir: nil, env: {})
      @command_lines << argv.join(" ")
      @stdins << stdin
      [@out, "", true]
    end
  end

  test "open_pull_request_for_head filters by owner:branch and returns the first open PR" do
    Given "one open PR on the branch"
    executor = CannedExecutor.new(out: JSON.generate([{
      "number" => 12, "html_url" => "u",
      "head" => { "ref" => "ai/learn-pr-7" },
      "base" => { "repo" => { "full_name" => "d3mlabs/demo" } },
    }]))
    github = AiFlow::GitHub.new(executor: executor)

    When "looking the branch up"
    pr = github.open_pull_request_for_head("d3mlabs/demo", "ai/learn-pr-7")

    Then "the query carried the owner-qualified head filter and a typed PR came back"
    executor.command_lines.first == "gh api repos/d3mlabs/demo/pulls?state=open&head=d3mlabs:ai/learn-pr-7"
    T.must(pr).number == 12
    T.must(pr).html_url == "u"
    T.must(pr).repo == "d3mlabs/demo"
    T.must(pr).head_ref == "ai/learn-pr-7"

    Cleanup
    nil
  end

  test "review_comments hits the event-sourced review endpoint and returns raw nodes" do
    Given "one comment on the review"
    node = { "id" => 9, "body" => "/ask why?", "user" => { "login" => "jpduchesne" } }
    executor = CannedExecutor.new(out: JSON.generate([node]))
    github = AiFlow::GitHub.new(executor: executor)

    When "listing the review's comments"
    comments = github.review_comments("d3mlabs/demo", 3, 77)

    Then "the path is keyed by the review id (never 'latest review') and nodes come back raw"
    executor.command_lines.first == "gh api repos/d3mlabs/demo/pulls/3/reviews/77/comments?per_page=100"
    comments == [node]

    Cleanup
    nil
  end

  test "review_comments returns [] for a review with no line comments" do
    Given "an empty listing"
    github = AiFlow::GitHub.new(executor: CannedExecutor.new(out: "[]"))

    Expect
    github.review_comments("d3mlabs/demo", 3, 77).empty?

    Cleanup
    nil
  end

  test "open_pull_request_for_head returns nil when no PR is open on the branch" do
    Given "an empty listing"
    github = AiFlow::GitHub.new(executor: CannedExecutor.new(out: "[]"))

    Expect
    github.open_pull_request_for_head("d3mlabs/demo", "ai/learn-scan").nil?

    Cleanup
    nil
  end

  test "close_pull_request patches the PR state to closed" do
    Given "a PR to retire"
    executor = CannedExecutor.new
    github = AiFlow::GitHub.new(executor: executor)

    When "closing"
    github.close_pull_request("d3mlabs/demo", 500)

    Then "a PATCH with the closed state went to the pulls endpoint"
    executor.command_lines.first == "gh api -X PATCH --input - repos/d3mlabs/demo/pulls/500"
    executor.stdins.first == JSON.generate({ state: "closed" })

    Cleanup
    nil
  end

  test "create_pull_request POSTs the branch pair and returns the created PR" do
    Given "an API that answers with the created PR"
    executor = CannedExecutor.new(out: JSON.generate({
      "number" => 7, "html_url" => "u",
      "head" => { "ref" => "ai/7-x" },
      "base" => { "repo" => { "full_name" => "d3mlabs/demo" } },
    }))
    github = AiFlow::GitHub.new(executor: executor)

    When "opening a PR"
    pr = github.create_pull_request(
      "d3mlabs/demo", title: "t", body: "b", head: "ai/7-x", base: "main",
    )

    Then "the payload carried the branch pair and a typed PR came back"
    executor.command_lines.first == "gh api -X POST --input - repos/d3mlabs/demo/pulls"
    executor.stdins.first ==
      JSON.generate({ title: "t", body: "b", head: "ai/7-x", base: "main", draft: false })
    pr.number == 7
    pr.repo == "d3mlabs/demo"
    pr.head_ref == "ai/7-x"

    Cleanup
    nil
  end

  test "issue_comments coerces the REST page into Comment values at the boundary" do
    Given "one page with a signed and a ghost-authored comment"
    executor = CannedExecutor.new(out: JSON.generate([
      { "id" => 42, "body" => "earlier question", "user" => { "login" => "jpduchesne" },
        "html_url" => "https://github.com/d3mlabs/demo/issues/7#issuecomment-42",
        "created_at" => "2026-07-30T12:00:00Z" },
      { "id" => 43, "body" => "orphaned", "user" => nil,
        "html_url" => "https://github.com/d3mlabs/demo/issues/7#issuecomment-43",
        "created_at" => "2026-07-30T13:00:00Z" },
    ]))
    github = AiFlow::GitHub.new(executor: executor)

    When "listing the conversation"
    comments = github.issue_comments("d3mlabs/demo", 7)

    Then "typed comments came back, timestamp parsed and ghost author coerced to empty"
    first = T.must(comments.first)
    first.id == 42
    first.author == "jpduchesne"
    first.body == "earlier question"
    first.html_url == "https://github.com/d3mlabs/demo/issues/7#issuecomment-42"
    first.created_at == Time.utc(2026, 7, 30, 12)
    T.must(comments.last).author == ""

    Cleanup
    nil
  end

  test "post_issue_comment returns the created Comment" do
    Given "an API that answers with the created comment"
    executor = CannedExecutor.new(out: JSON.generate(
      { "id" => 9, "body" => "posted", "user" => { "login" => "ai-flow[bot]" },
        "html_url" => "https://github.com/d3mlabs/demo/issues/7#issuecomment-9",
        "created_at" => "2026-07-30T12:00:00Z" },
    ))
    github = AiFlow::GitHub.new(executor: executor)

    When "posting"
    comment = github.post_issue_comment("d3mlabs/demo", 7, "posted")

    Then "the typed comment came back"
    comment.id == 9
    comment.author == "ai-flow[bot]"
    comment.body == "posted"

    Cleanup
    nil
  end

  test "issue_comment fetches one comment by id and coerces it" do
    Given "an API that answers with the comment"
    executor = CannedExecutor.new(out: JSON.generate(
      { "id" => 1001, "body" => "> ✅ **/build**", "user" => { "login" => "ai-flow[bot]" },
        "html_url" => "https://github.com/d3mlabs/demo/issues/7#issuecomment-1001",
        "created_at" => "2026-07-30T12:00:00Z" },
    ))
    github = AiFlow::GitHub.new(executor: executor)

    When "reading it back"
    comment = github.issue_comment("d3mlabs/demo", 1001)

    Then "the comments endpoint was hit and a typed comment came back"
    executor.command_lines.first == "gh api repos/d3mlabs/demo/issues/comments/1001"
    comment.id == 1001
    comment.body == "> ✅ **/build**"

    Cleanup
    nil
  end

  test "pull_request fetches one PR by number and coerces it" do
    Given "an API that answers with the PR"
    executor = CannedExecutor.new(out: JSON.generate({
      "number" => 12, "html_url" => "https://github.com/d3mlabs/demo/pull/12",
      "head" => { "ref" => "ai/12-x" },
      "base" => { "repo" => { "full_name" => "d3mlabs/demo" } },
    }))
    github = AiFlow::GitHub.new(executor: executor)

    When "fetching it"
    pr = github.pull_request("d3mlabs/demo", 12)

    Then "the pulls endpoint was hit and a typed PR came back"
    executor.command_lines.first == "gh api repos/d3mlabs/demo/pulls/12"
    pr.number == 12
    pr.repo == "d3mlabs/demo"
    pr.head_ref == "ai/12-x"

    Cleanup
    nil
  end

  test "user_id resolves a login to its numeric id" do
    Given "an API that answers with the user"
    executor = CannedExecutor.new(out: JSON.generate({ "login" => "jane", "id" => 777 }))
    github = AiFlow::GitHub.new(executor: executor)

    When "resolving"
    id = github.user_id("jane")

    Then "the users endpoint was hit and the id came back"
    executor.command_lines.first == "gh api users/jane"
    id == 777

    Cleanup
    nil
  end

  test "Comment#with_body returns a copy, leaving the original untouched" do
    Given "a comment whose body carries noise to strip"
    comment = AiFlow::GitHub::Comment.new(
      id: 1, author: "jpduchesne", body: "original <details>diff</details>",
      html_url: "u", created_at: Time.utc(2026, 7, 30),
    )

    When "replacing the body"
    stripped = comment.with_body("original (collapsed diff omitted)")

    Then "the copy carries the new body and everything else; the original is unchanged"
    stripped.body == "original (collapsed diff omitted)"
    stripped.id == 1
    stripped.author == "jpduchesne"
    comment.body == "original <details>diff</details>"

    Cleanup
    nil
  end

  test "unresolved_review_threads flattens GraphQL nodes into ReviewThread values" do
    Given "one resolved and one unresolved thread, the latter with a ghost-authored reply"
    executor = CannedExecutor.new(out: JSON.generate(
      { "data" => { "repository" => { "pullRequest" => { "reviewThreads" => { "nodes" => [
        { "isResolved" => true, "path" => "done.rb",
          "comments" => { "nodes" => [
            { "databaseId" => 1, "body" => "old", "diffHunk" => "@@", "url" => "u",
              "author" => { "login" => "a" } },
          ] } },
        { "isResolved" => false, "path" => "lib/thing.rb",
          "comments" => { "nodes" => [
            { "databaseId" => 91, "body" => "this walk is O(n^2)", "diffHunk" => "@@ -1 +1 @@",
              "url" => "https://github.com/d3mlabs/demo/pull/7#discussion_r91",
              "author" => { "login" => "jpduchesne" } },
            { "databaseId" => 92, "body" => "agreed", "diffHunk" => "@@ -1 +1 @@", "url" => "u2",
              "author" => nil },
          ] } },
      ] } } } } },
    ))
    github = AiFlow::GitHub.new(executor: executor)

    When "sweeping the PR"
    threads = github.unresolved_review_threads("d3mlabs/demo", 7)

    Then "only the unresolved thread came back, flattened into typed values"
    threads.size == 1
    thread = T.must(threads.first)
    thread.path == "lib/thing.rb"
    thread.diff_hunk == "@@ -1 +1 @@"
    thread.first_comment_id == 91
    thread.comments.map(&:author) == ["jpduchesne", ""]
    T.must(thread.comments.first).body == "this walk is O(n^2)"
    T.must(thread.comments.first).url == "https://github.com/d3mlabs/demo/pull/7#discussion_r91"

    Cleanup
    nil
  end

  test "unresolved_review_threads renders a Bot author in the REST login form" do
    Given "a thread where the App replied — GraphQL reports Bot logins without the [bot] suffix"
    executor = CannedExecutor.new(out: JSON.generate(
      { "data" => { "repository" => { "pullRequest" => { "reviewThreads" => { "nodes" => [
        { "isResolved" => false, "path" => "lib/thing.rb",
          "comments" => { "nodes" => [
            { "databaseId" => 91, "body" => "/ask why?", "diffHunk" => "@@", "url" => "u",
              "author" => { "login" => "jpduchesne", "__typename" => "User" } },
            { "databaseId" => 92, "body" => "Because.", "diffHunk" => "@@", "url" => "u2",
              "author" => { "login" => "d3mlabs-ai-flow", "__typename" => "Bot" } },
          ] } },
      ] } } } } },
    ))
    github = AiFlow::GitHub.new(executor: executor)

    When "sweeping the PR"
    thread = T.must(github.unresolved_review_threads("d3mlabs/demo", 7).first)

    Then "the bot's login matches what REST (and CommitIdentity.bot_login) would say"
    thread.comments.map(&:author) == ["jpduchesne", "d3mlabs-ai-flow[bot]"]

    Cleanup
    nil
  end

  test "react_to_comment posts the reaction to the surface's namespace" do
    Given "a plain issue comment to acknowledge"
    executor = CannedExecutor.new
    github = AiFlow::GitHub.new(executor: executor)

    When "reacting"
    github.react_to_comment("d3mlabs/demo", 55, "eyes")

    Then "the reaction went to the issues namespace"
    executor.command_lines.first == "gh api -X POST --input - repos/d3mlabs/demo/issues/comments/55/reactions"
    executor.stdins.first == JSON.generate({ content: "eyes" })

    Cleanup
    nil
  end

  test "graphql flags string variables -f and non-strings -F, returning data" do
    Given "an API that answers a mutation"
    executor = CannedExecutor.new(out: JSON.generate({ "data" => { "ok" => true } }))
    github = AiFlow::GitHub.new(executor: executor)

    When "running a query with mixed variable types"
    data = github.graphql("query($id: Int!, $name: String!) {}", id: 12, name: "x")

    Then "typed flags per variable, and the data object came back"
    executor.command_lines.first ==
      "gh api graphql -f query=query($id: Int!, $name: String!) {} -F id=12 -f name=x"
    data == { "ok" => true }

    Cleanup
    nil
  end
end
