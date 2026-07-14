# frozen_string_literal: true

# In-memory stand-ins for the network/process boundaries, so command flows are
# exercised end to end with real parsing/diffing and only gh/agent faked.

# Records every GitHub call; issues are seeded and mutated in memory.
class FakeGitHub
  attr_reader :calls, :comments, :comment_edits

  def initialize
    @issues = {}
    @sub_issues = {}
    @calls = []
    @comments = []
    @comment_edits = {}
    @next_number = 100
  end

  def seed_issue(owner_repo, number, title:, body:, state: "open")
    @issues[[owner_repo, number]] = AiFlow::GitHub::Issue.new(
      number: number, title: title, body: body, updated_at: "2026-07-13T00:00:00Z",
      html_url: "https://github.com/#{owner_repo}/issues/#{number}", state: state, repo: owner_repo,
    )
  end

  def seed_sub_issues(owner_repo, number, subs)
    @sub_issues[[owner_repo, number]] = subs
  end

  def issue(owner_repo, number)
    @issues.fetch([owner_repo, number]).dup
  end

  def update_issue_body(owner_repo, number, body:)
    @calls << [:update_issue_body, owner_repo, number]
    issue = @issues.fetch([owner_repo, number])
    issue.body = body
    issue.dup
  end

  def create_issue(owner_repo, title:, body:)
    number = (@next_number += 1)
    @calls << [:create_issue, owner_repo, title]
    seed_issue(owner_repo, number, title: title, body: body)
  end

  def close_issue(owner_repo, number, comment: nil)
    @calls << [:close_issue, owner_repo, number, comment]
    @issues.fetch([owner_repo, number]).state = "closed"
  end

  def post_issue_comment(owner_repo, number, body)
    @calls << [:post_issue_comment, owner_repo, number]
    @comments << body
    { "id" => 1, "html_url" => "https://github.com/#{owner_repo}/issues/#{number}#issuecomment-1" }
  end

  def update_issue_comment(owner_repo, comment_id, body:)
    @calls << [:update_issue_comment, owner_repo, comment_id]
    @comment_edits[comment_id] = body
  end

  def update_review_comment(owner_repo, comment_id, body:)
    @calls << [:update_review_comment, owner_repo, comment_id]
    @comment_edits[comment_id] = body
  end

  def reply_to_review_comment(owner_repo, pull_number, comment_id, body)
    @calls << [:reply_to_review_comment, owner_repo, pull_number, comment_id]
    @comments << body
  end

  def react_to_comment(owner_repo, comment_id, reaction, review_comment: false)
    @calls << [:react_to_comment, comment_id, reaction]
  end

  def sub_issues(owner_repo, number)
    (@sub_issues[[owner_repo, number]] || []).map(&:dup)
  end

  def add_sub_issue(owner_repo, parent_number, sub_issue_id)
    @calls << [:add_sub_issue, owner_repo, parent_number, sub_issue_id]
  end

  def create_pull_request(owner_repo, title:, body:, head:, base:)
    @calls << [:create_pull_request, owner_repo, head, base]
    { "html_url" => "https://github.com/#{owner_repo}/pull/900", "number" => 900, "body" => body }
  end

  def default_branch(owner_repo)
    "main"
  end

  def api(path, method: nil, payload: nil)
    @calls << [:api, path, method]
    { "id" => 424_242, "head" => { "ref" => "feature-branch" } }
  end

  def graphql(query, variables = {})
    @calls << [:graphql, variables]
    if query.include?("createIssue")
      number = (@next_number += 1)
      # Seed the created issue so follow-up REST calls (dependency annotation)
      # can resolve it. The fake pins one repo; tests only use d3mlabs/demo.
      seed_issue("d3mlabs/demo", number, title: variables[:title], body: variables[:body] || "")
      { "createIssue" => { "issue" => { "number" => number, "url" => "https://github.com/d3mlabs/demo/issues/#{number}" } } }
    else
      { "repository" => { "id" => "REPO_NODE", "issue" => { "id" => "ISSUE_NODE" } } }
    end
  end
end unless defined?(FakeGitHub)

# Replays canned agent outputs and records prompts.
class FakeAgent
  attr_reader :prompts, :launches

  def initialize(outputs)
    @outputs = outputs
    @prompts = []
    @launches = []
  end

  def launch(prompt:, workdir:, command:, force: false)
    @prompts << prompt
    @launches << { command: command, force: force, workdir: workdir }
    @outputs.shift or raise AiFlow::Agent::Error, "no canned output left"
  end
end unless defined?(FakeAgent)

# Builds a Context from a synthetic webhook payload.
module ContextBuilder
  module_function

  def issue_comment(owner_repo: "d3mlabs/demo", number: 7, comment_id: 55, body:, association: "OWNER", pull_request: false)
    issue = { "number" => number }
    issue["pull_request"] = { "url" => "x" } if pull_request
    AiFlow::Context.new(
      event_name: "issue_comment",
      payload: {
        "repository" => { "full_name" => owner_repo },
        "issue" => issue,
        "comment" => {
          "id" => comment_id, "body" => body, "author_association" => association,
          "html_url" => "https://github.com/#{owner_repo}/issues/#{number}#issuecomment-#{comment_id}",
        },
      },
    )
  end
end unless defined?(ContextBuilder)
