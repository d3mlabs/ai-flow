# frozen_string_literal: true

require "test_helper"
require "support/fakes"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class AiFlow::Commands::BatchTest < Minitest::Test
  REPO = "d3mlabs/demo"
  PLAN_FILE = "ai-flow-plan-7.md"

  SNAPSHOT = <<~BODY
    # Carve system

    The carve system uses LOD0 only.

    ## Streaming

    Chunks stream in 64m cells.
  BODY

  def build_batch(github:, agent:, context:, workdir:)
    AiFlow::Commands::Batch.new(
      context: context,
      github: github,
      agent: agent,
      rich_diff: AiFlow::RichDiff.new,
      result_writer: AiFlow::ResultWriter.new(github: github),
      executor: AiFlow::Executor.new,
      workdir: workdir,
    )
  end

  def parse(body)
    AiFlow::CommentParser.new.parse(body)
  end

  test "an /edit batch runs one file pass, PATCHes once, and appends results + one diff" do
    Given "a plan issue, a two-segment edit batch, and an agent that edits the plan file"
    dir = Dir.mktmpdir("ai-flow-batch-test-")
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: SNAPSHOT)
    comment = "> The carve system uses LOD0 only.\n\n/edit cover LOD1 too\n\n" \
              "> Chunks stream in 64m cells.\n\n/edit make cells 32m"
    context = ContextBuilder.issue_comment(body: comment)
    new_body = SNAPSHOT.sub("LOD0 only", "LOD0 and LOD1").sub("64m cells", "32m cells")
    agent = FakeAgent.new([<<~OUTPUT]) { File.write(File.join(dir, PLAN_FILE), new_body) }
      <<<AI-FLOW:SEGMENT 1>>>
      Extended the carve system to LOD1.
      <<<AI-FLOW:SEGMENT 2>>>
      Reduced streaming cells to 32m.
    OUTPUT

    When "running the batch"
    success = build_batch(github:, agent:, context:, workdir: dir).run(parse(comment))

    Then "one forced agent pass, one body PATCH, interleaved results, one bottom diff"
    success == true
    agent.prompts.size == 1
    agent.launches.first[:force] == true
    github.calls.map(&:first).count(:update_issue_body) == 1
    github.issue(REPO, 7).body == new_body
    edited = github.comment_edits.fetch(55)
    edited.index("> ✅ **/edit** — Extended the carve system to LOD1.") > edited.index("/edit cover LOD1 too")
    edited.index("> ✅ **/edit** — Extended the carve system to LOD1.") < edited.index("> Chunks stream in 64m cells.")
    edited.index("> ✅ **/edit** — Reduced streaming cells to 32m.") > edited.index("/edit make cells 32m")
    edited.index("\n\n---\n\n") > edited.index("> ✅ **/edit** — Reduced streaming cells to 32m.")
    edited.scan("**Plan updated**").size == 1
    edited.scan("<summary>Word diff</summary>").size == 1
    edited.scan("<summary>Source diff</summary>").size == 1
    edited.include?("<ins>")
    !File.exist?(File.join(dir, PLAN_FILE))

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an /edit whose pass leaves the plan file untouched reports ⚠️ and skips the PATCH" do
    Given "an agent that produces a summary but never edits the file"
    dir = Dir.mktmpdir("ai-flow-batch-test-")
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: SNAPSHOT)
    comment = "/edit rework the plan"
    context = ContextBuilder.issue_comment(body: comment)
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nReworked the plan."])

    When "running the batch"
    success = build_batch(github:, agent:, context:, workdir: dir).run(parse(comment))

    Then "no PATCH, a loud ⚠️, and the batch reports failure"
    success == false
    !github.calls.map(&:first).include?(:update_issue_body)
    github.comment_edits.fetch(55).include?("⚠️ **/edit** — the agent made no change to the plan document.")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "contradicting segments report CONFLICT and apply nothing" do
    Given "an agent that refuses both segments"
    dir = Dir.mktmpdir("ai-flow-batch-test-")
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: SNAPSHOT)
    comment = "> Chunks stream in 64m cells.\n\n/edit make cells 32m\n\n" \
              "> Chunks stream in 64m cells.\n\n/edit make cells 128m"
    context = ContextBuilder.issue_comment(body: comment)
    agent = FakeAgent.new([<<~OUTPUT])
      <<<AI-FLOW:SEGMENT 1>>>
      CONFLICT: contradicts segment 2 (32m vs 128m).
      <<<AI-FLOW:SEGMENT 2>>>
      CONFLICT: contradicts segment 1 (32m vs 128m).
    OUTPUT

    When "running the batch"
    success = build_batch(github:, agent:, context:, workdir: dir).run(parse(comment))

    Then
    success == false
    !github.calls.map(&:first).include?(:update_issue_body)
    github.comment_edits.fetch(55).scan("⚠️ **/edit** — CONFLICT:").size == 2

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a quote of an earlier answer panel resolves to its source comment" do
    Given "a thread where an earlier comment carries an answer panel with a collapsed diff"
    dir = Dir.mktmpdir("ai-flow-batch-test-")
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: SNAPSHOT)
    panel_comment = "> earlier question\n\n/ask why?\n\n> ✅ **/ask**\n>\n" \
                    "> Not today — there is no such command in the repo.\n\n" \
                    "<details>\n<summary>Word diff</summary>\nHUGE-DIFF-NOISE\n</details>"
    github.seed_issue_comment(REPO, 7, id: 42, body: panel_comment)
    comment = "> Not today — there is no such command in the repo.\n\n/edit record it as out of scope"
    # The command comment itself is in the thread too — it must be excluded,
    # or its own "> " quote lines would match trivially.
    github.seed_issue_comment(REPO, 7, id: 55, body: comment)
    context = ContextBuilder.issue_comment(body: comment)
    new_body = "#{SNAPSHOT}\nOut of scope: that command.\n"
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nRecorded it as out of scope."]) do
      File.write(File.join(dir, PLAN_FILE), new_body)
    end

    When "running the batch"
    success = build_batch(github:, agent:, context:, workdir: dir).run(parse(comment))

    Then "the prompt carries the quote's source comment, diff noise stripped"
    success == true
    prompt = agent.prompts.first
    prompt.include?("quoted from @jpduchesne's comment https://github.com/d3mlabs/demo/issues/7#issuecomment-42")
    prompt.include?("The full source comment, for context:")
    prompt.include?("> earlier question")
    prompt.include?("(collapsed diff omitted)")
    !prompt.include?("HUGE-DIFF-NOISE")
    github.calls.map(&:first).count(:issue_comments) == 1
    github.issue(REPO, 7).body == new_body

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a quote found nowhere falls back to verbatim discussion context" do
    Given "a batch quoting text that is neither in the body nor in any thread comment"
    dir = Dir.mktmpdir("ai-flow-batch-test-")
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: SNAPSHOT)
    comment = "> Not today — there is no such command in the repo.\n\n/edit record it as out of scope\n\n" \
              "> Chunks stream in 64m cells.\n\n/edit make cells 32m"
    context = ContextBuilder.issue_comment(body: comment)
    new_body = SNAPSHOT.sub("64m cells", "32m cells\n\nOut of scope: that command.")
    agent = FakeAgent.new([<<~OUTPUT]) { File.write(File.join(dir, PLAN_FILE), new_body) }
      <<<AI-FLOW:SEGMENT 1>>>
      Recorded the command as out of scope.
      <<<AI-FLOW:SEGMENT 2>>>
      Reduced streaming cells to 32m.
    OUTPUT

    When "running the batch"
    success = build_batch(github:, agent:, context:, workdir: dir).run(parse(comment))

    Then "both segments run in one pass; the unmatched quote is flagged as verbatim context"
    success == true
    github.issue(REPO, 7).body == new_body
    agent.prompts.first.include?("quoted by the reviewer from the discussion — this text is NOT in the document")
    agent.prompts.first.include?("Not today — there is no such command in the repo.")
    edited = github.comment_edits.fetch(55)
    edited.index("> ✅ **/edit** — Recorded the command as out of scope.") > edited.index("/edit record it as out of scope")
    edited.index("> ✅ **/edit** — Reduced streaming cells to 32m.") > edited.index("/edit make cells 32m")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a standalone /ask gets a reply comment and an unforced pass" do
    Given "a plan issue and a bare question"
    dir = Dir.mktmpdir("ai-flow-batch-test-")
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: SNAPSHOT)
    context = ContextBuilder.issue_comment(body: "/ask why LOD0 only?")
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nBecause carving happens at runtime."])

    When "running"
    success = build_batch(github:, agent:, context:, workdir: dir).run(parse("/ask why LOD0 only?"))

    Then "the answer is a reply and the body was never PATCHed"
    success == true
    agent.launches.first[:force] == false
    github.comments.size == 1
    github.comments.first.include?("Because carving happens at runtime.")
    github.comment_edits.empty?
    !github.calls.map(&:first).include?(:update_issue_body)

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a standalone /ask inside Actions carries the run footer and reverts the ⏳ line" do
    Given "a bare question in an Actions run (the dispatcher's status line is on the comment)"
    dir = Dir.mktmpdir("ai-flow-batch-test-")
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: SNAPSHOT)
    run_url = "https://github.com/d3mlabs/demo/actions/runs/42"
    context = ContextBuilder.issue_comment(
      body: "/ask why LOD0 only?",
      env: {
        "GITHUB_SERVER_URL" => "https://github.com",
        "GITHUB_REPOSITORY" => "d3mlabs/demo",
        "GITHUB_RUN_ID" => "42",
      },
    )
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nBecause carving happens at runtime."])

    When "running"
    build_batch(github:, agent:, context:, workdir: dir).run(parse("/ask why LOD0 only?"))

    Then "the reply carries the footer; the command comment is reverted to the payload body"
    github.comments.first.end_with?("⚙️ [workflow run](#{run_url})")
    github.comment_edits.fetch(55) == "/ask why LOD0 only?"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "an /ask inside a batch lands in the appended section with the edit" do
    Given "a batch mixing /ask and /edit"
    dir = Dir.mktmpdir("ai-flow-batch-test-")
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: SNAPSHOT)
    comment = "> The carve system uses LOD0 only.\n\n/ask why?\n\n" \
              "> Chunks stream in 64m cells.\n\n/edit make cells 32m"
    context = ContextBuilder.issue_comment(body: comment)
    new_body = SNAPSHOT.sub("64m cells", "32m cells")
    agent = FakeAgent.new([<<~OUTPUT]) { File.write(File.join(dir, PLAN_FILE), new_body) }
      <<<AI-FLOW:SEGMENT 1>>>
      Because carving happens at runtime.
      <<<AI-FLOW:SEGMENT 2>>>
      Reduced streaming cells to 32m.
    OUTPUT

    When "running the batch"
    success = build_batch(github:, agent:, context:, workdir: dir).run(parse(comment))

    Then "the answer interleaves under its quote, not as a reply"
    success == true
    github.comments.empty?
    edited = github.comment_edits.fetch(55)
    edited.index("> ✅ **/ask**\n>\n> Because carving happens at runtime.") > edited.index("/ask why?")
    edited.index("> Because carving happens at runtime.") < edited.index("> Chunks stream in 64m cells.")
    github.issue(REPO, 7).body == new_body

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the guarded PATCH refuses when the body moved mid-batch" do
    Given "a batch whose issue is edited remotely while the agent runs"
    dir = Dir.mktmpdir("ai-flow-batch-test-")
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: SNAPSHOT)
    comment = "> Chunks stream in 64m cells.\n\n/edit make cells 32m"
    context = ContextBuilder.issue_comment(body: comment)
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nReduced streaming cells to 32m."]) do
      github.update_issue_body(REPO, 7, body: "# Changed meanwhile\n")
      File.write(File.join(dir, PLAN_FILE), SNAPSHOT.sub("64m cells", "32m cells"))
    end

    When "running the batch"
    build_batch(github:, agent:, context:, workdir: dir).run(parse(comment))

    Then
    raises AiFlow::GitHub::Error

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
