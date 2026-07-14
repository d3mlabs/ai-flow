require("test_helper")
require("support/fakes")

class AiFlow::ResultWriterTest < Minitest::Test
  (begin
    extend(RSpock::Declarative)
    test("results insert under each segment, preserving the batch layout") {
      begin
        body = "> Q1\n\n/edit tighten\n\n> Q2\n\n/ask why?"
        segments = AiFlow::CommentParser.new.parse(body)
        writer = AiFlow::ResultWriter.new(github: FakeGitHub.new)
        updated = writer.render(body, [[segments.[](0), "RESULT-1"], [segments.[](1), "RESULT-2"]])
        assert_operator(updated.index("RESULT-1"), :>, updated.index("/edit tighten"))
        assert_operator(updated.index("RESULT-1"), :<, updated.index("> Q2"))
        assert_operator(updated.index("RESULT-2"), :>, updated.index("/ask why?"))
        assert_equal(true, updated.include?("---"), "Expected \"updated.include?(\"---\")\" to be true")
      ensure
        (nil)
      end
    }
    test("review comments are edited through the pulls namespace") {
      begin
        github = FakeGitHub.new
        context = AiFlow::Context.new(event_name: "pull_request_review_comment", payload: { "repository" => { "full_name" => "d3mlabs/demo" }, "pull_request" => { "number" => 3, "head" => { "ref" => "feature" } }, "comment" => { "id" => 9, "body" => "/edit fix this", "author_association" => "OWNER", "html_url" => "https://github.com/d3mlabs/demo/pull/3#discussion_r9", "diff_hunk" => "@@ -1 +1 @@", "path" => "a.rb" } })
        segments = AiFlow::CommentParser.new.parse("/edit fix this")
        AiFlow::ResultWriter.new(github:).write(context, [[segments.first, "DONE"]])
        assert_equal(true, github.calls.map(&:first).include?(:update_review_comment), "Expected \"github.calls.map(&:first).include?(:update_review_comment)\" to be true")
      ensure
        (nil)
      end
    }
  rescue StandardError => e
    ::RSpock::BacktraceFilter.new.filter_exception(e)
    raise
  end)
end
