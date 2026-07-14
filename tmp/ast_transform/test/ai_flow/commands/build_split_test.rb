require("test_helper")
require("support/fakes")

class AiFlow::Commands::BuildSplitTest < Minitest::Test
  (begin
    extend(RSpock::Declarative)
    REPO = "d3mlabs/demo"

    class RecordingBuild
      (begin
        extend(RSpock::Declarative)
        attr_reader(:built)

        def initialize
          @built = []
        end

        def build_issue(issue, extra_instruction: "")
          @built << issue.number
          { "html_url" => "https://github.com/d3mlabs/demo/pull/#{issue.number}" }
        end
      rescue StandardError => e
        ::RSpock::BacktraceFilter.new.filter_exception(e)
        raise
      end)
    end

    def sub_issue(number, title, body)
      AiFlow::GitHub::Issue.new(number:, title:, body:, updated_at: "2026-07-13T00:00:00Z", html_url: "https://github.com/#{REPO}/issues/#{number}", state: "open", repo: REPO)
    end
    test("builds waves in dependency order and finishes with the integration sub-issue") {
      begin
        github = FakeGitHub.new
        github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
        github.seed_sub_issues(REPO, 7, [sub_issue(1, "Server API", "Build the API.\n"), sub_issue(2, "Client UI", "Build the UI.\n"), sub_issue(3, "Wiring", "Wire them.\n\nDepends on: #1, #2\n"), sub_issue(4, "Integration: Parent", "Integrate.\n\nDepends on: #1, #2, #3\n")])
        build = RecordingBuild.new
        context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
        segment = AiFlow::CommentParser.new.parse("/build --split").first
        AiFlow::Commands::BuildSplit.new(context:, github:, build:, result_writer: AiFlow::ResultWriter.new(github:)).run(segment)
        assert_equal([1, 2, 3, 4], build.built)
        assert_equal(true, github.comment_edits.fetch(55).include?("✅ **/build --split**"), "Expected \"github.comment_edits.fetch(55).include?(\"✅ **/build --split**\")\" to be true")
        assert_equal(true, github.comment_edits.fetch(55).include?("[x] #4 Integration: Parent"), "Expected \"github.comment_edits.fetch(55).include?(\"[x] #4 Integration: Parent\")\" to be true")
      ensure
        (nil)
      end
    }
    test("creates the integration sub-issue when the split didn't") {
      begin
        github = FakeGitHub.new
        github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
        github.seed_sub_issues(REPO, 7, [sub_issue(1, "Server API", "Build the API.\n"), sub_issue(2, "Client UI", "Build the UI.\n")])
        build = RecordingBuild.new
        context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
        segment = AiFlow::CommentParser.new.parse("/build --split").first
        AiFlow::Commands::BuildSplit.new(context:, github:, build:, result_writer: AiFlow::ResultWriter.new(github:)).run(segment)
        assert_equal(true, github.calls.any? { |kind, _repo, title|
          kind == :create_issue && title.to_s.start_with?("Integration:")
        }, "Expected \"github.calls.any? { |kind, _repo, title| kind == :create_issue && title.to_s.start_with?(\"Integration:\") }\" to be true")
        assert_equal(true, github.calls.map(&:first).include?(:add_sub_issue), "Expected \"github.calls.map(&:first).include?(:add_sub_issue)\" to be true")
        assert_equal(3, build.built.size)
        assert_operator(build.built.last, :>, 100)
      ensure
        (nil)
      end
    }
    test("a dependency cycle is a hard error") {
      begin
        github = FakeGitHub.new
        github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
        github.seed_sub_issues(REPO, 7, [sub_issue(1, "A", "Depends on: #2\n"), sub_issue(2, "B", "Depends on: #1\n"), sub_issue(3, "Integration: Parent", "Depends on: #1, #2\n")])
        context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
        segment = AiFlow::CommentParser.new.parse("/build --split").first
        assert_raises(AiFlow::GitHub::Error) {
          AiFlow::Commands::BuildSplit.new(context:, github:, build: RecordingBuild.new, result_writer: AiFlow::ResultWriter.new(github:)).run(segment)
        }
      ensure
        (nil)
      end
    }
  rescue StandardError => e
    ::RSpock::BacktraceFilter.new.filter_exception(e)
    raise
  end)
end
