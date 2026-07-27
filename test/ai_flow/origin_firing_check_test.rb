# frozen_string_literal: true

require "test_helper"
require "support/fakes"
require "fileutils"
require "open3"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class AiFlow::OriginFiringCheckTest < Minitest::Test
  ORIGIN_REPO = "d3mlabs/dev"

  ORG_INDEX = "index.md"
  ORG_SKILL = "skills/typed-errors/SKILL.md"
  REPO_INDEX = ".cursor/rules/learnings-index.mdc"
  REPO_SKILL = ".cursor/skills/learnings/typed-errors/SKILL.md"

  # A real learning-repo checkout shaped like the check sees it in CI: a
  # seeded base commit, origin/<base> pointing at it, and the draft branch
  # checked out on top.
  def seeded_repo(dir, index_path:)
    git(dir, "init", "-q", "-b", "main")
    write(dir, index_path, "## design\n- [design/one-seam] Existing cue. → skills/one-seam/\n")
    commit(dir, "seed corpus")
    git(dir, "update-ref", "refs/remotes/origin/main", "HEAD")
    git(dir, "checkout", "-q", "-b", "ai/learn-pr-12")
    dir
  end

  def add_draft_learning(dir, index_path:, skill_path:)
    write(dir, skill_path, "---\nname: typed-errors\n---\nRaise typed errors, never bare strings.\n")
    index = File.join(dir, index_path)
    File.write(index, "#{File.read(index)}- [ruby/typed-errors] Raising an error? Use a typed class. → skills/typed-errors/\n")
    commit(dir, "capture typed-errors")
  end

  def edit_index_only(dir, index_path:)
    index = File.join(dir, index_path)
    File.write(index, File.read(index).sub("Existing cue.", "Existing cue, reworded."))
    commit(dir, "reindex")
  end

  def write(dir, relative, content)
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def git(dir, *argv)
    _out, err, status = Open3.capture3("git", "-C", dir, *argv)
    raise "git #{argv.first} failed: #{err}" unless status.success?
  end

  def commit(dir, message)
    git(dir, "add", "-A")
    git(dir, "-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-q", "-m", message)
  end

  def origin_github(comments: [])
    github = FakeGitHub.new
    github.seed_issue(ORIGIN_REPO, 12, title: "Error handling cleanup", body: "Raising bare strings broke retries.")
    comments.each_with_index do |(login, body), index|
      github.seed_issue_comment(ORIGIN_REPO, 12, id: 70 + index, body: body, login: login)
    end
    github
  end

  def run_check(workdir:, github: origin_github, agent: FakeAgent.new(["FIRED: typed-errors"]),
    pr_body: "Draft learning(s).\n\nlearned-from: #{ORIGIN_REPO}#12 (learn-sweep)")
    AiFlow::OriginFiringCheck.new(
      github: github, agent: agent, executor: AiFlow::Executor.new,
      workdir: workdir, pr_body: pr_body, base_ref: "main",
    ).run
  end

  test "a changed learning that fires on its origin context passes" do
    Given "an org-layout draft adding typed-errors, whose origin thread the retrieval pass fires on"
    dir = seeded_repo(Dir.mktmpdir("origin-firing-"), index_path: ORG_INDEX)
    add_draft_learning(dir, index_path: ORG_INDEX, skill_path: ORG_SKILL)
    github = origin_github(comments: [["jpduchesne", "always raise typed errors"], ["ai-flow[bot]", "✅ panel noise"]])
    agent = FakeAgent.new(["I would consult these.\n\nFIRED: typed-errors, one-seam"])

    When "checking"
    result = run_check(workdir: dir, github: github, agent: agent)

    Then "the check passes and the pass replayed the origin (index + human thread, no bot noise) in the checkout"
    result.status == :pass
    result.pass?
    result.new_slugs == ["typed-errors"]
    result.fired.include?("typed-errors")
    agent.launches.first[:command] == "learn"
    agent.launches.first[:force] == false
    agent.launches.first[:workdir] == dir
    agent.prompts.first.include?("- [ruby/typed-errors] Raising an error? Use a typed class.")
    agent.prompts.first.include?("Error handling cleanup")
    agent.prompts.first.include?("Raising bare strings broke retries.")
    agent.prompts.first.include?("always raise typed errors")
    !agent.prompts.first.include?("panel noise")

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "a cue that does not fire on the origin fails and names the learning" do
    Given "a draft whose retrieval pass loads nothing"
    dir = seeded_repo(Dir.mktmpdir("origin-firing-"), index_path: ORG_INDEX)
    add_draft_learning(dir, index_path: ORG_INDEX, skill_path: ORG_SKILL)
    agent = FakeAgent.new(["Nothing matched.\n\nFIRED: (none)"])

    When "checking"
    result = run_check(workdir: dir, agent: agent)

    Then "the check fails, naming the silent learning"
    result.status == :fail
    !result.pass?
    result.fired == []
    result.detail.include?("`typed-errors`")
    result.detail.include?("reword the index cue")

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "a structure-only diff skips green without an agent pass" do
    Given "a draft that only rewords the index"
    dir = seeded_repo(Dir.mktmpdir("origin-firing-"), index_path: ORG_INDEX)
    edit_index_only(dir, index_path: ORG_INDEX)
    agent = FakeAgent.new([])

    When "checking"
    result = run_check(workdir: dir, agent: agent)

    Then "the check skips as a pass and never launched the agent"
    result.status == :skip
    result.pass?
    result.detail.include?("structure-only")
    agent.launches.empty?

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "a PR without a learned-from marker skips green" do
    Given "a skill-adding PR with no capture provenance (migration/manual)"
    dir = seeded_repo(Dir.mktmpdir("origin-firing-"), index_path: ORG_INDEX)
    add_draft_learning(dir, index_path: ORG_INDEX, skill_path: ORG_SKILL)
    agent = FakeAgent.new([])

    When "checking"
    result = run_check(workdir: dir, agent: agent, pr_body: "Seeded by the migration pass.")

    Then "the check skips as a pass and never launched the agent"
    result.status == :skip
    result.pass?
    result.detail.include?("learned-from")
    agent.launches.empty?

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "the per-repo layout is detected and its index feeds the prompt" do
    Given "a repo-layout draft (.cursor skills + learnings-index.mdc)"
    dir = seeded_repo(Dir.mktmpdir("origin-firing-"), index_path: REPO_INDEX)
    add_draft_learning(dir, index_path: REPO_INDEX, skill_path: REPO_SKILL)
    agent = FakeAgent.new(["FIRED: `typed-errors`"])

    When "checking"
    result = run_check(workdir: dir, agent: agent)

    Then "the slug is picked up from the .cursor path, backticks stripped from the declaration"
    result.status == :pass
    result.new_slugs == ["typed-errors"]
    agent.prompts.first.include?("- [design/one-seam] Existing cue.")

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "a retrieval pass that never declares FIRED raises" do
    Given "an agent that rambles without the contract line"
    dir = seeded_repo(Dir.mktmpdir("origin-firing-"), index_path: ORG_INDEX)
    add_draft_learning(dir, index_path: ORG_INDEX, skill_path: ORG_SKILL)
    agent = FakeAgent.new(["I read some files and have thoughts."])

    When "checking"
    error = assert_raises(AiFlow::OriginFiringCheck::Error) { run_check(workdir: dir, agent: agent) }

    Then "the failure names the missing contract"
    error.message.include?("FIRED")

    Cleanup
    FileUtils.remove_entry(dir)
  end

  test "a skill change without any learnings index raises" do
    Given "a checkout with a skill diff but no index file in either layout"
    dir = Dir.mktmpdir("origin-firing-")
    git(dir, "init", "-q", "-b", "main")
    write(dir, "README.md", "seed\n")
    commit(dir, "seed")
    git(dir, "update-ref", "refs/remotes/origin/main", "HEAD")
    git(dir, "checkout", "-q", "-b", "ai/learn-pr-12")
    write(dir, ORG_SKILL, "---\nname: typed-errors\n---\nRule.\n")
    commit(dir, "capture")

    When "checking"
    error = assert_raises(AiFlow::OriginFiringCheck::Error) { run_check(workdir: dir) }

    Then "the failure names the index candidates"
    error.message.include?("index.md")

    Cleanup
    FileUtils.remove_entry(dir)
  end
end
