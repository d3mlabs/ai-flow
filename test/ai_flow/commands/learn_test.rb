# frozen_string_literal: true

require "test_helper"
require "support/fakes"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class AiFlow::Commands::LearnTest < Minitest::Test
  REPO = "d3mlabs/demo"

  # Records every git invocation as a joined command line; `staged` is the
  # file list `git diff --cached --name-only` reports — i.e. what the (faked)
  # agent "wrote" into the learning worktree.
  class RecordingExecutor
    attr_reader :command_lines, :refreshes

    def initialize(staged: [])
      @staged = staged
      @command_lines = []
      @refreshes = 0
    end

    def refresh_auth!
      @refreshes += 1
    end

    def capture(*argv, stdin: nil, chdir: nil, env: {})
      @command_lines << argv.join(" ")
      out = argv.take(4) == %w[git diff --cached --name-only] ? "#{@staged.join("\n")}\n" : ""
      [out, "", true]
    end
  end

  def run_learn(github:, executor:, body:, context: nil, agent: FakeAgent.new(["done"]), workdir: Dir.pwd)
    context ||= ContextBuilder.issue_comment(number: 7, body: body)
    segment = AiFlow::CommentParser.new.parse(body).first
    AiFlow::Commands::Learn.new(
      context: context,
      github: github,
      agent: agent,
      result_writer: AiFlow::ResultWriter.new(github: github),
      executor: executor,
      workdir: workdir,
      org_invariants: empty_org_invariants,
    ).run(segment)
  end

  # A real repo-shaped workdir for the --promote form, which reads the
  # learning's files from the job checkout: config, one skill, its index line.
  def promotable_workdir(dir, knowledge_repo: "d3mlabs/knowledge")
    FileUtils.mkdir_p(File.join(dir, ".github"))
    File.write(File.join(dir, ".github", "ai-flow.yml"), "knowledge_repo: #{knowledge_repo}\n") if knowledge_repo
    FileUtils.mkdir_p(File.join(dir, ".cursor", "skills", "learnings", "typed-errors"))
    File.write(
      File.join(dir, ".cursor", "skills", "learnings", "typed-errors", "SKILL.md"),
      "---\nname: typed-errors\n---\nRaise typed errors, never bare strings.\n",
    )
    FileUtils.mkdir_p(File.join(dir, ".cursor", "rules"))
    File.write(
      File.join(dir, ".cursor", "rules", "learnings-index.mdc"),
      "## ruby\n- [ruby/typed-errors] Raising? Use a typed error. → .cursor/skills/learnings/typed-errors/\n",
    )
    dir
  end

  # A cache dir that doesn't exist: no invariants injected. Tests must never
  # pick up the developer machine's real knowledge cache.
  def empty_org_invariants
    AiFlow::OrgInvariants.new(cache_dir: File.join(Dir.tmpdir, "ai-flow-learn-no-cache-#{object_id}"))
  end

  SKILL = ".cursor/skills/learnings/factory-over-class-methods/SKILL.md"
  INDEX = ".cursor/rules/learnings-index.mdc"

  test "a dictated /learn drafts a new learning PR on its own comment-scoped branch" do
    Given "a dictated lesson and an agent that wrote an index line + skill"
    github = FakeGitHub.new
    executor = RecordingExecutor.new(staged: [INDEX, SKILL])
    agent = FakeAgent.new(["drafted design/factory-over-class-methods"])

    When "learning"
    run_learn(github: github, executor: executor, body: "/learn prefer a factory over class methods", agent: agent)

    Then "the agent got the dictated statement, and a draft PR opened on ai/learn-c55 with the marker"
    agent.launches.first[:command] == "learn"
    agent.prompts.first.include?("DICTATED LESSON")
    agent.prompts.first.include?("prefer a factory over class methods")
    github.calls.include?([:create_pull_request, REPO, "ai/learn-c55", "main"])
    github.pull_request_drafts.first == true
    github.pull_request_bodies.first.include?("learned-from: #{REPO}#7 (dictated)")
    github.pull_request_bodies.first.include?("> prefer a factory over class methods")
    github.comment_edits.fetch(55).include?("✅ **/learn** — drafted")
    github.comment_edits.fetch(55).include?("factory-over-class-methods")
    executor.command_lines.any? { |line| line.include?("push -u origin ai/learn-c55") }

    Cleanup
    nil
  end

  test "a bare /learn sweeps the PR surface and drafts on a PR-scoped branch" do
    Given "a PR with a review thread and discussion, and an agent that captured a learning"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: "The description.")
    github.seed_review_threads(REPO, 7, [
      {
        "path" => "lib/thing.rb", "diff_hunk" => "@@ -1 +1 @@",
        "first_comment_id" => 91,
        "comments" => [{ "author" => "jpduchesne", "body" => "this pattern keeps recurring", "url" => "u" }],
      },
    ])
    github.seed_issue_comment(REPO, 7, id: 70, body: "we should always do X", login: "jpduchesne")
    executor = RecordingExecutor.new(staged: [INDEX, SKILL])
    context = ContextBuilder.issue_comment(number: 7, body: "/learn", pull_request: true)

    When "learning"
    run_learn(github: github, executor: executor, body: "/learn", context: context)

    Then "the sweep prompt carried the surface evidence and the draft opened on ai/learn-pr-7"
    github.calls.include?([:create_pull_request, REPO, "ai/learn-pr-7", "main"])
    github.pull_request_bodies.first.include?("learned-from: #{REPO}#7 (learn-sweep)")

    Cleanup
    nil
  end

  test "the sweep prompt carries the threads and discussion as evidence" do
    Given "a PR surface with a thread and a comment"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: "The description.")
    github.seed_review_threads(REPO, 7, [
      {
        "path" => "lib/thing.rb", "diff_hunk" => "@@ -1 +1 @@",
        "first_comment_id" => 91,
        "comments" => [{ "author" => "jpduchesne", "body" => "this pattern keeps recurring", "url" => "u" }],
      },
    ])
    github.seed_issue_comment(REPO, 7, id: 70, body: "we should always do X", login: "jpduchesne")
    agent = FakeAgent.new(["done"])
    context = ContextBuilder.issue_comment(number: 7, body: "/learn", pull_request: true)

    When "learning"
    run_learn(github: github, executor: RecordingExecutor.new(staged: [INDEX, SKILL]), body: "/learn", context: context, agent: agent)

    Then "the prompt swept the description, the thread, and the discussion"
    agent.prompts.first.include?("SWEEP THIS SURFACE")
    agent.prompts.first.include?("The description.")
    agent.prompts.first.include?("this pattern keeps recurring")
    agent.prompts.first.include?("we should always do X")

    Cleanup
    nil
  end

  test "a re-run on a surface with an open draft refines it instead of opening a second PR" do
    Given "an open learning draft already exists for this PR's branch"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Carve system", body: "The description.")
    github.seed_open_pull_request_for_head("ai/learn-pr-7",
      { "html_url" => "https://github.com/#{REPO}/pull/500", "number" => 500 })
    executor = RecordingExecutor.new(staged: [INDEX, SKILL])
    context = ContextBuilder.issue_comment(number: 7, body: "/learn", pull_request: true)

    When "learning again"
    run_learn(github: github, executor: executor, body: "/learn", context: context)

    Then "no new PR is created; the existing draft's branch is force-updated and the panel says refined"
    github.calls.map(&:first).none? { |kind| kind == :create_pull_request }
    executor.command_lines.any? { |line| line.include?("push -u origin ai/learn-pr-7") }
    github.comment_edits.fetch(55).include?("✅ **/learn** — refined")
    github.comment_edits.fetch(55).include?("pull/500")

    Cleanup
    nil
  end

  test "an empty capture (nothing generalized) opens no PR and says so" do
    Given "an agent run that wrote no learning files"
    github = FakeGitHub.new
    executor = RecordingExecutor.new(staged: [])

    When "learning"
    run_learn(github: github, executor: executor, body: "/learn prefer a factory over class methods")

    Then "no push, no PR, and the panel reports the empty outcome"
    github.calls.map(&:first).none? { |kind| kind == :create_pull_request }
    executor.command_lines.none? { |line| line.include?("push -u origin") }
    github.comment_edits.fetch(55).include?("ℹ️ **/learn** — no learning")

    Cleanup
    nil
  end

  test "the index-only edit is not counted as a named learning in the panel" do
    Given "an agent that only touched the index (a revision), no skill folder"
    github = FakeGitHub.new
    executor = RecordingExecutor.new(staged: [INDEX])

    When "learning"
    run_learn(github: github, executor: executor, body: "/learn tighten the srp trigger wording")

    Then "a PR still opens, but no phantom `index` slug is listed"
    github.calls.map(&:first).include?(:create_pull_request)
    !github.comment_edits.fetch(55).include?("`index`")

    Cleanup
    nil
  end

  test "--scan surveys the repo on the repo-scoped ai/learn-scan branch, steering passed verbatim" do
    Given "a scan with steering text and an agent that drafted an architecture digest"
    github = FakeGitHub.new
    executor = RecordingExecutor.new(staged: [INDEX, ".cursor/skills/architecture/layering/SKILL.md"])
    agent = FakeAgent.new(["drafted architecture/layering"])

    When "scanning"
    run_learn(github: github, executor: executor,
      body: "/learn --scan focus on error handling, ignore the legacy adapters", agent: agent)

    Then "the survey prompt carried the steering, and the draft opened on ai/learn-scan with the scan marker"
    agent.prompts.first.include?("SURVEY MISSION")
    agent.prompts.first.include?("focus on error handling, ignore the legacy adapters")
    github.calls.include?([:create_pull_request, REPO, "ai/learn-scan", "main"])
    github.pull_request_bodies.first.include?("learned-from: #{REPO}#7 (scan)")
    github.comment_edits.fetch(55).include?("`layering`")

    Cleanup
    nil
  end

  test "--scan re-run refines the open scan draft instead of duplicating" do
    Given "an open scan draft on ai/learn-scan"
    github = FakeGitHub.new
    github.seed_open_pull_request_for_head("ai/learn-scan",
      { "html_url" => "https://github.com/#{REPO}/pull/510", "number" => 510 })
    executor = RecordingExecutor.new(staged: [INDEX])

    When "rescanning"
    run_learn(github: github, executor: executor, body: "/learn --scan")

    Then "no new PR; the existing draft's branch is updated and the panel says refined"
    github.calls.map(&:first).none? { |kind| kind == :create_pull_request }
    executor.command_lines.any? { |line| line.include?("push -u origin ai/learn-scan") }
    github.comment_edits.fetch(55).include?("✅ **/learn** — refined")

    Cleanup
    nil
  end

  test "--promote refuses with a pointer when no knowledge_repo is configured" do
    Given "a workdir whose ai-flow.yml names no knowledge repo"
    dir = Dir.mktmpdir("ai-flow-learn-test-")
    promotable_workdir(dir, knowledge_repo: nil)
    github = FakeGitHub.new
    agent = FakeAgent.new([])

    When "promoting"
    run_learn(github: github, executor: RecordingExecutor.new, body: "/learn --promote typed-errors",
      agent: agent, workdir: dir)

    Then "no agent pass; the panel names the missing config key"
    agent.prompts.empty?
    github.comment_edits.fetch(55).include?("no `knowledge_repo:` configured")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "--promote an unknown slug refuses, listing near matches" do
    Given "a workdir that knows typed-errors but not the typo'd slug"
    dir = Dir.mktmpdir("ai-flow-learn-test-")
    promotable_workdir(dir)
    github = FakeGitHub.new
    agent = FakeAgent.new([])

    When "promoting a typo"
    run_learn(github: github, executor: RecordingExecutor.new, body: "/learn --promote typed-error",
      agent: agent, workdir: dir)

    Then "no agent pass; the panel lists the near match"
    agent.prompts.empty?
    github.comment_edits.fetch(55).include?("no learning named `typed-error`")
    github.comment_edits.fetch(55).include?("`typed-errors`")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "--promote opens the org draft plus the paired repo-local removal draft" do
    Given "a promotable learning and an agent that placed it in the knowledge repo"
    dir = Dir.mktmpdir("ai-flow-learn-test-")
    promotable_workdir(dir)
    github = FakeGitHub.new
    executor = RecordingExecutor.new(staged: ["index.md", "skills/typed-errors/SKILL.md"])
    agent = FakeAgent.new(["placed under ruby"])

    When "promoting (domain prefix accepted and dropped)"
    run_learn(github: github, executor: executor, body: "/learn --promote ruby/typed-errors",
      agent: agent, workdir: dir)

    Then "the agent saw the verbatim learning; the knowledge repo was cloned; both draft PRs opened"
    agent.prompts.first.include?("Raise typed errors, never bare strings.")
    agent.prompts.first.include?("[ruby/typed-errors]")
    executor.command_lines.any? { |line| line.start_with?("gh repo clone d3mlabs/knowledge") }
    github.calls.include?([:create_pull_request, "d3mlabs/knowledge", "ai/learn-promote-demo-typed-errors", "main"])
    github.calls.include?([:create_pull_request, REPO, "ai/learn-promote-typed-errors", "main"])
    github.pull_request_bodies.fetch(1).include?("Merge after that PR lands")
    github.comment_edits.fetch(55).include?("✅ **/learn --promote** — `typed-errors` → d3mlabs/knowledge")
    github.comment_edits.fetch(55).include?("🧹 paired removal draft")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "--promote re-run refines the open org draft instead of opening a second one" do
    Given "an open promotion draft in the knowledge repo"
    dir = Dir.mktmpdir("ai-flow-learn-test-")
    promotable_workdir(dir)
    github = FakeGitHub.new
    github.seed_open_pull_request_for_head("ai/learn-promote-demo-typed-errors",
      { "html_url" => "https://github.com/d3mlabs/knowledge/pull/12", "number" => 12 })
    executor = RecordingExecutor.new(staged: ["index.md", "skills/typed-errors/SKILL.md"])

    When "promoting again"
    run_learn(github: github, executor: executor, body: "/learn --promote typed-errors", workdir: dir)

    Then "the org side refines (no new org PR); the panel links the existing draft"
    github.calls.none? { |call| call == [:create_pull_request, "d3mlabs/knowledge", "ai/learn-promote-demo-typed-errors", "main"] }
    github.comment_edits.fetch(55).include?("refined the open org draft")
    github.comment_edits.fetch(55).include?("knowledge/pull/12")

    Cleanup
    FileUtils.rm_rf(dir)
  end
end
