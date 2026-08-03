# typed: true
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
  # agent "wrote" into the learning worktree. `staged_queue` (when given)
  # instead consumes one list per diff call, so a multi-phase form like
  # --promote can stage on the org side and come up empty on the removal side.
  # Subclasses the real class so sorbet-runtime's sig checks accept it.
  class RecordingExecutor < AiFlow::Executor
    extend T::Sig

    attr_reader :command_lines, :refreshes

    # `fail_on` substrings make matching command lines fail, for the
    # best-effort routing paths.
    def initialize(staged: [], staged_queue: nil, fail_on: [])
      @staged = staged
      @staged_queue = staged_queue
      @fail_on = fail_on
      @command_lines = []
      @envs = []
      @refreshes = 0
    end

    def refresh_auth!
      @refreshes += 1
    end

    def capture(*argv, stdin: nil, chdir: nil, env: {})
      @command_lines << argv.join(" ")
      @envs << env
      return ["", "simulated failure", false] if @fail_on.any? { |needle| argv.join(" ").include?(needle) }

      out = argv.take(4) == %w[git diff --cached --name-only] ? "#{next_staged.join("\n")}\n" : ""
      [out, "", true]
    end

    # The env the first command line containing +needle+ was spawned with.
    def env_for(needle)
      @envs.fetch(@command_lines.index { |line| line.include?(needle) })
    end

    private

    sig { returns(T::Array[String]) }
    def next_staged
      @staged_queue ? (@staged_queue.shift || []) : @staged
    end
  end

  # The removal side of --promote edits the index file checked out in its
  # worktree; the fake `git worktree add` plants one (a real temp file, per
  # the no-filesystem-mocks rule) and the fake `git push` snapshots it, since
  # the worktree is gone once the run returns.
  class WorktreePlantingExecutor < RecordingExecutor
    attr_reader :index_after_removal

    INDEX_RELATIVE_PATH = File.join(".cursor", "rules", "learnings-index.mdc")
    PLANTED_INDEX = "- [ruby/typed-errors] Raising? Use a typed error. → .cursor/skills/learnings/typed-errors/\n" \
      "- [design/one-seam] Keep me.\n"

    def capture(*argv, stdin: nil, chdir: nil, env: {})
      if argv.take(3) == %w[git worktree add]
        index = File.join(argv[4], INDEX_RELATIVE_PATH)
        FileUtils.mkdir_p(File.dirname(index))
        File.write(index, PLANTED_INDEX)
      end
      if argv.take(2) == %w[git push]
        index = File.join(chdir.to_s, INDEX_RELATIVE_PATH)
        @index_after_removal = File.read(index) if File.exist?(index)
      end
      super
    end
  end

  def run_learn(github:, executor:, body:, context: nil, agent: FakeAgent.new(["done"]), workdir: Dir.pwd)
    context ||= ContextBuilder.issue_comment(number: 7, body: body)
    segment = AiFlow::CommentParser.new.parse(body).fetch(0)
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

  # A dev CLI declining: no invariants injected. Tests must never shell out
  # to the developer machine's real dev/knowledge setup.
  def empty_org_invariants
    AiFlow::OrgInvariants.new(executor: FakeInvariantsExecutor.new(ok: false))
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

    Then "the agent got the dictated statement, and a proposal PR opened on ai/learn-c55 — ordinary, not GitHub draft state — with the marker"
    agent.launches.first[:command] == AiFlow::Command::Learn.new
    agent.prompts.first.include?("DICTATED LESSON")
    agent.prompts.first.include?("prefer a factory over class methods")
    github.calls.include?([:create_pull_request, REPO, "ai/learn-c55", "main"])
    github.pull_request_drafts.first == false
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
      AiFlow::GitHub::ReviewThread.new(
        path: "lib/thing.rb", diff_hunk: "@@ -1 +1 @@", first_comment_id: 91,
        comments: [AiFlow::GitHub::ReviewThread::Comment.new(
          author: "jpduchesne", body: "this pattern keeps recurring", url: "u",
        )],
      ),
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
      AiFlow::GitHub::ReviewThread.new(
        path: "lib/thing.rb", diff_hunk: "@@ -1 +1 @@", first_comment_id: 91,
        comments: [AiFlow::GitHub::ReviewThread::Comment.new(
          author: "jpduchesne", body: "this pattern keeps recurring", url: "u",
        )],
      ),
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
      AiFlow::GitHub::PullRequest.new(number: 500, html_url: "https://github.com/#{REPO}/pull/500"))
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

  test "a capture on an unseeded repo scaffolds the index via dev before the write phase" do
    Given "a worktree with no learnings index (the fake never materializes one)"
    github = FakeGitHub.new
    executor = RecordingExecutor.new(staged: [INDEX, SKILL])

    When "learning"
    run_learn(github: github, executor: executor, body: "/learn prefer a factory over class methods")

    Then "dev learnings init ran with the harness scrub, ahead of the commit phase's staged diff"
    init_at = executor.command_lines.index("dev learnings init")
    diff_at = executor.command_lines.index { |line| line.start_with?("git diff --cached") }
    !init_at.nil?
    init_at < diff_at
    # The dev child must resolve its own toolchain, never the dispatcher's
    # bundler env (#44) — the scrub always carries the toolchain unsets.
    executor.env_for("dev learnings init").fetch("RBENV_VERSION", :missing).nil?

    Cleanup
    nil
  end

  test "a capture on a seeded repo never shells out to dev learnings init" do
    Given "a worktree already carrying a learnings index (planted by the fake)"
    github = FakeGitHub.new
    executor = WorktreePlantingExecutor.new(staged: [INDEX, SKILL])

    When "learning"
    run_learn(github: github, executor: executor, body: "/learn prefer a factory over class methods")

    Then "no scaffold call was made"
    executor.command_lines.none? { |line| line.include?("dev learnings init") }

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
      AiFlow::GitHub::PullRequest.new(number: 510, html_url: "https://github.com/#{REPO}/pull/510"))
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

  # ---- Capture-initiated org routing (the PROMOTE contract, #35) ----

  # Writes a learning (skill + index line) into the launch workdir — the
  # per-run capture worktree — via FakeAgent's launch block.
  def write_learning(dir, slug, index_domain: "tooling")
    skill_dir = File.join(dir, ".cursor", "skills", "learnings", slug)
    FileUtils.mkdir_p(skill_dir)
    File.write(File.join(skill_dir, "SKILL.md"), "---\nname: #{slug}\n---\nThe #{slug} lesson.\n")
    FileUtils.mkdir_p(File.join(dir, ".cursor", "rules"))
    line = "- [#{index_domain}/#{slug}] The #{slug} cue. → .cursor/skills/learnings/#{slug}/\n"
    File.open(File.join(dir, INDEX), "a") { |index| index.write(line) }
  end

  def org_configured_workdir(dir)
    FileUtils.mkdir_p(File.join(dir, ".github"))
    File.write(File.join(dir, ".github", "ai-flow.yml"), "knowledge_repo: d3mlabs/knowledge\n")
    dir
  end

  # Snapshots the capture worktree's learning files at its `git push`, since
  # the worktree is gone once the run returns (pushes from the org clone or a
  # removal worktree have other basenames and are ignored).
  class CaptureSnapshotExecutor < RecordingExecutor
    attr_reader :pushed_skills, :pushed_index

    def capture(*argv, stdin: nil, chdir: nil, env: {})
      if argv.take(2) == %w[git push] && File.basename(chdir.to_s) == "worktree"
        skills = File.join(chdir.to_s, ".cursor", "skills", "learnings")
        @pushed_skills = File.directory?(skills) ? Dir.children(skills).sort : []
        index = File.join(chdir.to_s, INDEX)
        @pushed_index = File.exist?(index) ? File.read(index) : ""
      end
      super
    end
  end

  test "a capture pass declaring PROMOTE routes the lesson org-ward and out of the repo PR" do
    Given "a knowledge-repo config, and a pass that drafted two lessons, one declared org-tier"
    dir = org_configured_workdir(Dir.mktmpdir("ai-flow-learn-test-"))
    github = FakeGitHub.new
    executor = CaptureSnapshotExecutor.new(staged_queue: [
      ["index.md", "skills/http-retries/SKILL.md"],
      [INDEX, ".cursor/skills/learnings/factory-x/SKILL.md"],
    ])
    agent = FakeAgent.new(["drafted two\nPROMOTE: http-retries", "placed under tooling"]) do |_prompt, workdir|
      write_learning(workdir, "http-retries")
      write_learning(workdir, "factory-x", index_domain: "design")
    end

    When "learning"
    run_learn(github: github, executor: executor, body: "/learn retries and factories", agent: agent, workdir: dir)

    Then "an org proposal opened on the knowledge repo; the repo PR carries only the local lesson"
    github.calls.include?([:create_pull_request, "d3mlabs/knowledge", "ai/learn-promote-demo-http-retries", "main"])
    executor.pushed_skills == ["factory-x"]
    !executor.pushed_index.include?("http-retries")
    executor.pushed_index.include?("factory-x")
    github.comment_edits.fetch(55).include?("🌐 `http-retries` → org-tier proposal on d3mlabs/knowledge")
    github.comment_edits.fetch(55).include?("`factory-x`")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a declared slug that exists on main gets the paired repo-local removal" do
    Given "typed-errors already admitted repo-local, and a pass declaring its promotion"
    dir = Dir.mktmpdir("ai-flow-learn-test-")
    promotable_workdir(dir)
    github = FakeGitHub.new
    executor = RecordingExecutor.new(staged_queue: [
      ["index.md", "skills/typed-errors/SKILL.md"],
      [INDEX, ".cursor/skills/learnings/typed-errors/SKILL.md"],
      [],
    ])
    agent = FakeAgent.new(["refined and promoted\nPROMOTE: typed-errors", "merged into ruby"]) do |_prompt, workdir|
      write_learning(workdir, "typed-errors", index_domain: "ruby")
    end

    When "learning"
    run_learn(github: github, executor: executor, body: "/learn typed errors everywhere", agent: agent, workdir: dir)

    Then "the org proposal and the paired removal both opened; the repo capture stayed empty"
    github.calls.include?([:create_pull_request, "d3mlabs/knowledge", "ai/learn-promote-demo-typed-errors", "main"])
    github.calls.include?([:create_pull_request, REPO, "ai/learn-promote-typed-errors", "main"])
    github.comment_edits.fetch(55).include?("🌐 `typed-errors` → org-tier proposal on d3mlabs/knowledge")
    github.comment_edits.fetch(55).include?("paired removal")
    github.comment_edits.fetch(55).include?("routed to the org tier")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a PROMOTE declaration without a knowledge_repo keeps the lesson repo-local" do
    Given "no knowledge-repo config, and a pass declaring an org-tier lesson"
    dir = Dir.mktmpdir("ai-flow-learn-test-")
    github = FakeGitHub.new
    executor = CaptureSnapshotExecutor.new(staged: [INDEX, ".cursor/skills/learnings/http-retries/SKILL.md"])
    agent = FakeAgent.new(["drafted\nPROMOTE: http-retries"]) do |_prompt, workdir|
      write_learning(workdir, "http-retries")
    end

    When "learning"
    run_learn(github: github, executor: executor, body: "/learn retries", agent: agent, workdir: dir)

    Then "no org PR; the lesson stays in the repo proposal and the panel points at the config key"
    github.calls.none? { |call| call.is_a?(Array) && call.first == :create_pull_request && call.fetch(1) == "d3mlabs/knowledge" }
    executor.pushed_skills == ["http-retries"]
    github.comment_edits.fetch(55).include?("no `knowledge_repo:` is configured")
    github.comment_edits.fetch(55).include?("kept repo-local")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a PROMOTE declaration naming a slug the pass never drafted is reported, not routed" do
    Given "a knowledge-repo config and a declaration with no matching files"
    dir = org_configured_workdir(Dir.mktmpdir("ai-flow-learn-test-"))
    github = FakeGitHub.new
    executor = RecordingExecutor.new(staged: [INDEX, SKILL])
    agent = FakeAgent.new(["drafted\nPROMOTE: ghost"])

    When "learning"
    run_learn(github: github, executor: executor, body: "/learn something", agent: agent, workdir: dir)

    Then "no org PR, one panel note, and the repo draft lands as usual"
    github.calls.none? { |call| call.is_a?(Array) && call.first == :create_pull_request && call.fetch(1) == "d3mlabs/knowledge" }
    github.comment_edits.fetch(55).include?("`PROMOTE: ghost`")
    github.comment_edits.fetch(55).include?("drafted no")
    github.comment_edits.fetch(55).include?("factory-over-class-methods")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failed org routing keeps the lesson in the repo proposal (best-effort per slug)" do
    Given "a knowledge-repo config and a routing whose knowledge-repo clone fails"
    dir = org_configured_workdir(Dir.mktmpdir("ai-flow-learn-test-"))
    github = FakeGitHub.new
    executor = CaptureSnapshotExecutor.new(
      staged: [INDEX, ".cursor/skills/learnings/http-retries/SKILL.md"],
      fail_on: ["gh repo clone"],
    )
    agent = FakeAgent.new(["drafted\nPROMOTE: http-retries"]) do |_prompt, workdir|
      write_learning(workdir, "http-retries")
    end

    When "learning"
    run_learn(github: github, executor: executor, body: "/learn retries", agent: agent, workdir: dir)

    Then "no org PR; the un-pruned lesson lands in the repo proposal and the panel carries the warning"
    github.calls.none? { |call| call.is_a?(Array) && call.first == :create_pull_request && call.fetch(1) == "d3mlabs/knowledge" }
    executor.pushed_skills == ["http-retries"]
    github.comment_edits.fetch(55).include?("⚠️ org routing for `http-retries` failed (kept repo-local)")
    github.comment_edits.fetch(55).include?("drafted 1 learning")

    Cleanup
    FileUtils.rm_rf(dir)
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
    executor = WorktreePlantingExecutor.new(staged: ["index.md", "skills/typed-errors/SKILL.md"])
    agent = FakeAgent.new(["placed under ruby"])

    When "promoting (domain prefix accepted and dropped)"
    run_learn(github: github, executor: executor, body: "/learn --promote ruby/typed-errors",
      agent: agent, workdir: dir)

    Then "the agent saw the verbatim learning; the knowledge repo was cloned; both proposal PRs opened"
    agent.prompts.first.include?("Raise typed errors, never bare strings.")
    agent.prompts.first.include?("[ruby/typed-errors]")
    executor.command_lines.any? { |line| line.start_with?("gh repo clone d3mlabs/knowledge") }
    github.calls.include?([:create_pull_request, "d3mlabs/knowledge", "ai/learn-promote-demo-typed-errors", "main"])
    github.calls.include?([:create_pull_request, REPO, "ai/learn-promote-typed-errors", "main"])
    github.pull_request_bodies.fetch(1).include?("Merge after that PR lands")
    github.comment_edits.fetch(55).include?("✅ **/learn --promote** — `typed-errors` → d3mlabs/knowledge")
    github.comment_edits.fetch(55).include?("🧹 paired removal draft")
    # The removal worktree's index (planted by the fake) lost only the
    # promoted slug's line.
    executor.index_after_removal == "- [design/one-seam] Keep me.\n"

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "--promote an unknown slug in a repo with no learnings says so" do
    Given "a configured workdir with no learnings directory at all"
    dir = Dir.mktmpdir("ai-flow-learn-test-")
    FileUtils.mkdir_p(File.join(dir, ".github"))
    File.write(File.join(dir, ".github", "ai-flow.yml"), "knowledge_repo: d3mlabs/knowledge\n")
    github = FakeGitHub.new
    agent = FakeAgent.new([])

    When "promoting"
    run_learn(github: github, executor: RecordingExecutor.new, body: "/learn --promote typed-errors",
      agent: agent, workdir: dir)

    Then "no agent pass; the panel says the repo has nothing to promote"
    agent.prompts.empty?
    github.comment_edits.fetch(55).include?("this repo has no learnings under `.cursor/skills/learnings/`")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "--promote reports a failed repo-local removal without losing the org draft" do
    Given "an org side that stages its files while the removal side stages nothing"
    dir = Dir.mktmpdir("ai-flow-learn-test-")
    promotable_workdir(dir)
    github = FakeGitHub.new
    executor = RecordingExecutor.new(staged_queue: [["index.md", "skills/typed-errors/SKILL.md"], []])
    agent = FakeAgent.new(["placed under ruby"])

    When "promoting"
    run_learn(github: github, executor: executor, body: "/learn --promote typed-errors",
      agent: agent, workdir: dir)

    Then "the org draft opened; the panel carries the removal failure instead of a removal link"
    github.calls.include?([:create_pull_request, "d3mlabs/knowledge", "ai/learn-promote-demo-typed-errors", "main"])
    github.calls.none? { |call| call == [:create_pull_request, REPO, "ai/learn-promote-typed-errors", "main"] }
    github.comment_edits.fetch(55).include?("⚠️ the paired repo-local removal failed: nothing to remove for `typed-errors`")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "--promote re-run refines the open org draft instead of opening a second one" do
    Given "an open promotion draft in the knowledge repo"
    dir = Dir.mktmpdir("ai-flow-learn-test-")
    promotable_workdir(dir)
    github = FakeGitHub.new
    github.seed_open_pull_request_for_head("ai/learn-promote-demo-typed-errors",
      AiFlow::GitHub::PullRequest.new(number: 12, html_url: "https://github.com/d3mlabs/knowledge/pull/12"))
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
