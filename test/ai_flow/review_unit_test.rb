# typed: true
# frozen_string_literal: true

require "test_helper"
require "support/fakes"

transform!(RSpock::AST::Transformation)
class AiFlow::ReviewUnitTest < Minitest::Test
  REPO = "d3mlabs/demo"

  # A raw REST review-comment node, the shape GitHub#review_comments returns
  # (and the pull_request_review_comment webhook carries under "comment").
  def review_comment_node(id:, body:, login: "jpduchesne", path: "lib/thing.rb")
    {
      "id" => id, "body" => body, "author_association" => "OWNER",
      "html_url" => "https://github.com/#{REPO}/pull/3#discussion_r#{id}",
      "diff_hunk" => "@@ -1 +1 @@\n-old\n+new", "path" => path,
      "user" => { "login" => login, "id" => 111 },
    }
  end

  def expand(context, github)
    AiFlow::ReviewUnit.new(context: context, github: github).contexts
  end

  test "a non-review context passes through untouched" do
    Given "an issue-comment context"
    github = FakeGitHub.new
    context = ContextBuilder.issue_comment(body: "/ask why?")

    When "expanding"
    contexts = expand(context, github)

    Then "the context itself is the only dispatch, and no API call was made"
    contexts == [context]
    github.calls.empty?

    Cleanup
    nil
  end

  test "a batch review fans out into one context per command comment, in review order" do
    Given "a submitted review whose body is command-less and whose comments mix commands and prose"
    github = FakeGitHub.new
    github.seed_review_comments(REPO, 3, 77, [
      review_comment_node(id: 1, body: "/ask why LOD0 only?"),
      review_comment_node(id: 2, body: "nice — no action here"),
      review_comment_node(id: 3, body: "/edit rename this method"),
    ])
    context = ContextBuilder.review_summary(body: "A few things inline.", review_id: 77)

    When "expanding"
    contexts = expand(context, github)

    Then "two children, in comment order, each a full review-comment surface with its diff anchor"
    contexts.size == 2
    contexts.all? { |ctx| ctx.is_a?(AiFlow::Context::ReviewComment) }
    contexts.map(&:comment_id) == [1, 3]
    contexts.first.comment_body == "/ask why LOD0 only?"
    contexts.first.diff_path == "lib/thing.rb"
    contexts.first.diff_hunk.include?("+new")
    contexts.first.pr_head_ref == "feature-branch"
    github.calls == [[:review_comments, REPO, 3, 77]]

    Cleanup
    nil
  end

  test "a command in the review body dispatches the summary itself, before the comments" do
    Given "a review whose body and one comment both carry commands"
    github = FakeGitHub.new
    github.seed_review_comments(REPO, 3, 77, [review_comment_node(id: 1, body: "/ask why?")])
    context = ContextBuilder.review_summary(body: "/ask overall, is this sound?", review_id: 77)

    When "expanding"
    contexts = expand(context, github)

    Then "the summary context leads, the comment context follows"
    contexts.size == 2
    contexts.first.equal?(context)
    contexts.last.comment_id == 1

    Cleanup
    nil
  end

  test "a command-less review expands to nothing" do
    Given "a plain approval with prose comments"
    github = FakeGitHub.new
    github.seed_review_comments(REPO, 3, 77, [review_comment_node(id: 1, body: "LGTM")])
    context = ContextBuilder.review_summary(body: "Ship it.", review_id: 77)

    When "expanding"
    contexts = expand(context, github)

    Then
    contexts.empty?

    Cleanup
    nil
  end

  test "a comment by anyone but the review's submitter is dropped fail-closed" do
    Given "a review enumeration that (contrary to GitHub's invariant) carries another author's command"
    github = FakeGitHub.new
    github.seed_review_comments(REPO, 3, 77, [
      review_comment_node(id: 1, body: "/ask mine"),
      review_comment_node(id: 2, body: "/edit not mine", login: "mallory"),
    ])
    context = ContextBuilder.review_summary(body: "", review_id: 77)

    When "expanding"
    contexts = T.let(nil, T.untyped)
    _out, err = capture_io { contexts = expand(context, github) }

    Then "only the submitter's comment dispatches, and the drop is logged"
    contexts.map(&:comment_id) == [1]
    err.include?("mallory")
    err.include?("fail closed")

    Cleanup
    nil
  end

  test "a comment whose commands parse invalidly still dispatches — the error must land on it" do
    Given "a review comment batching a lifecycle command (a parse error downstream)"
    github = FakeGitHub.new
    github.seed_review_comments(REPO, 3, 77, [
      review_comment_node(id: 1, body: "/ask why?\n\n/build now"),
    ])
    context = ContextBuilder.review_summary(body: "", review_id: 77)

    When "expanding"
    contexts = expand(context, github)

    Then "the comment is dispatched so the dispatcher can report the ⚠️ on it"
    contexts.map(&:comment_id) == [1]

    Cleanup
    nil
  end

  test "a prose mention of a command mid-line does not dispatch the comment" do
    Given "a review comment that only mentions /build in prose"
    github = FakeGitHub.new
    github.seed_review_comments(REPO, 3, 77, [
      review_comment_node(id: 1, body: "the /build passed earlier, all good"),
    ])
    context = ContextBuilder.review_summary(body: "", review_id: 77)

    When "expanding"
    contexts = expand(context, github)

    Then
    contexts.empty?

    Cleanup
    nil
  end

  test "a reply's implicit review (empty body, one comment) dispatches that one reply" do
    Given "the review shape a thread reply creates: empty summary, a single command comment"
    github = FakeGitHub.new
    github.seed_review_comments(REPO, 3, 78, [review_comment_node(id: 9, body: "/ask and this?")])
    context = ContextBuilder.review_summary(body: "", review_id: 78)

    When "expanding"
    contexts = expand(context, github)

    Then
    contexts.map(&:comment_id) == [9]
    contexts.first.review_comment?

    Cleanup
    nil
  end
end
