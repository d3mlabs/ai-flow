require("test_helper")
require("support/fakes")

class AiFlow::Commands::SplitTest < Minitest::Test
  (begin
    extend(RSpock::Declarative)
    REPO = "d3mlabs/demo"

    def sub_issue(number, title, state: "open")
      AiFlow::GitHub::Issue.new(number:, title:, body: "", updated_at: "2026-07-13T00:00:00Z", html_url: "https://github.com/#{REPO}/issues/#{number}", state:, repo: REPO)
    end

    def run_split(github:, agent:, comment: "/split")
      context = ContextBuilder.issue_comment(number: 7, body: comment)
      segment = AiFlow::CommentParser.new.parse(comment).first
      AiFlow::Commands::Split.new(context:, github:, agent:, result_writer: AiFlow::ResultWriter.new(github:), workdir: Dir.pwd).run(segment)
    end
    test("reconciliation creates missing, closes stale, keeps matching") {
      begin
        github = FakeGitHub.new
        github.seed_issue(REPO, 7, title: "Parent", body: "# Parent plan\n\n<!-- ai-flow:plan -->\n")
        kept = sub_issue(1, "Server API")
        stale = sub_issue(2, "Old approach")
        github.seed_issue(REPO, 1, title: "Server API", body: "")
        github.seed_issue(REPO, 2, title: "Old approach", body: "")
        github.seed_sub_issues(REPO, 7, [kept, stale])
        agent = FakeAgent.new(["[
  {\"title\": \"Server API\", \"body\": \"Build the API.\", \"depends_on\": []},
  {\"title\": \"Client UI\", \"body\": \"Build the UI.\", \"depends_on\": [0]}
]\n"])
        run_split(github:, agent:)
        assert_equal(true, github.calls.any? { |kind, arg|
          kind == :graphql && arg.is_a?(Hash) && arg.[](:title) == "Client UI"
        }, "Expected \"github.calls.any? { |kind, arg| kind == :graphql && arg.is_a?(Hash) && arg[:title] == \"Client UI\" }\" to be true")
        assert_equal(true, github.calls.none? { |kind, arg|
          kind == :graphql && arg.is_a?(Hash) && arg.[](:title) == "Server API"
        }, "Expected \"github.calls.none? { |kind, arg| kind == :graphql && arg.is_a?(Hash) && arg[:title] == \"Server API\" }\" to be true")
        assert_equal("closed", github.issue(REPO, 2).state)
        assert_equal(true, github.calls.any? { |kind, _repo, number|
          kind == :close_issue && number == 2
        }, "Expected \"github.calls.any? { |kind, _repo, number| kind == :close_issue && number == 2 }\" to be true")
        assert_equal(true, github.comment_edits.fetch(55).include?("created 1, closed 1, kept 1"), "Expected \"github.comment_edits.fetch(55).include?(\"created 1, closed 1, kept 1\")\" to be true")
      ensure
        (nil)
      end
    }
    test("dependencies land as a Depends on line in the created sub-issue") {
      begin
        github = FakeGitHub.new
        github.seed_issue(REPO, 7, title: "Parent", body: "# Parent plan\n")
        existing = sub_issue(1, "Server API")
        github.seed_issue(REPO, 1, title: "Server API", body: "")
        github.seed_sub_issues(REPO, 7, [existing])
        agent = FakeAgent.new(["[
  {\"title\": \"Server API\", \"body\": \"Build the API.\", \"depends_on\": []},
  {\"title\": \"Client UI\", \"body\": \"Build the UI.\", \"depends_on\": [0]}
]\n"])
        run_split(github:, agent:)
        created_number = github.calls.find { |kind, _repo, _number|
          kind == :update_issue_body
        }&.fetch(2)
        assert_equal(true, github.issue(REPO, created_number).body.include?("Depends on: #1"), "Expected \"github.issue(REPO, created_number).body.include?(\"Depends on: #1\")\" to be true")
      ensure
        (nil)
      end
    }
  rescue StandardError => e
    ::RSpock::BacktraceFilter.new.filter_exception(e)
    raise
  end)
end
