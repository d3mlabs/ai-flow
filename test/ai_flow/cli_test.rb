# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "support/fakes"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class AiFlow::CliTest < Minitest::Test
  # An org one run away from adopted, the App on a selection without the
  # repo — the first-run shape.
  def seeded_github
    github = FakeGitHub.new
    github.seed_repository("acme/widgets", id: 777)
    AiFlow::Adoption::SECRETS.each do |name|
      github.seed_org_secret("acme", name, visibility: "selected", repositories: [])
    end
    github.seed_app_installation("acme", id: 55, app_slug: "ai-flow", repository_selection: "selected", repositories: [])
    github
  end

  # A git whose diff against the base names no file: the origin-firing
  # check's structure-only shape, reached through the real ProposalChecks.
  class NoDiffExecutor < AiFlow::Executor
    def capture(*argv, stdin: nil, chdir: nil, env: {})
      ["", "", true]
    end
  end

  def build_cli(github: seeded_github, env: {}, executor: AiFlow::Executor.new, agent: FakeAgent.new([]))
    stdout = StringIO.new
    stderr = StringIO.new
    cli = AiFlow::Cli.new(
      root: AI_FLOW_ROOT, stdout: stdout, stderr: stderr, env: env, executor: executor, github: github, agent: agent,
    )
    [cli, stdout, stderr]
  end

  # The job's env for one event payload written under +dir+.
  def job_env(dir, event_name:, payload:)
    event_path = File.join(dir, "event.json")
    File.write(event_path, JSON.generate(payload))
    { "GITHUB_EVENT_NAME" => event_name, "GITHUB_EVENT_PATH" => event_path, "AI_FLOW_WORKDIR" => dir }
  end

  test "building the exe's wiring removes the App private key from the environment it was given" do
    Given "a job env carrying the key"
    env = { "AI_FLOW_APP_PRIVATE_KEY" => "-----BEGIN RSA PRIVATE KEY-----", "GITHUB_REPOSITORY" => "acme/widgets" }

    When "the exe wires itself from it"
    AiFlow::Cli.new(root: AI_FLOW_ROOT, stdout: StringIO.new, stderr: StringIO.new, env: env)

    Then "no subprocess spawned from here can read the key"
    !env.key?("AI_FLOW_APP_PRIVATE_KEY")
  end

  test "dispatch routes the job's event through the dispatcher and exits with its verdict" do
    Given "a job for a non-command comment"
    dir = Dir.mktmpdir("ai-flow-cli-")
    github = FakeGitHub.new
    payload = {
      "repository" => { "full_name" => "acme/widgets" },
      "issue" => { "number" => 7 },
      "comment" => {
        "id" => 55, "body" => "no command here", "author_association" => "OWNER",
        "html_url" => "https://github.com/acme/widgets/issues/7#issuecomment-55",
        "user" => { "login" => "jpduchesne", "id" => 111 },
      },
    }
    cli, stdout, stderr = build_cli(github: github, env: job_env(dir, event_name: "issue_comment", payload: payload))

    When
    status = cli.run(["dispatch"])

    Then "a clean no-op: exit 0, nothing written anywhere"
    status == 0
    github.calls.empty?
    stdout.string.empty?
    stderr.string.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "gate routes the job's pull request through the origin-firing check and prints its verdict" do
    Given "a job on a PR whose diff touches no skill"
    dir = Dir.mktmpdir("ai-flow-cli-")
    payload = { "repository" => { "full_name" => "acme/knowledge" }, "pull_request" => { "number" => 3, "base" => { "ref" => "main" } } }
    env = job_env(dir, event_name: "pull_request", payload: payload)
    cli, stdout, stderr = build_cli(github: FakeGitHub.new, env: env, executor: NoDiffExecutor.new)

    When
    status = cli.run(["gate"])

    Then "out of scope is green, said on stdout"
    status == 0
    stdout.string.start_with?("ℹ️ origin-firing (skip): no skill files added or edited")
    stderr.string.empty?

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a job entry point run at a terminal is a usage error naming the job, exit 2: #{command}" do
    Given "no Actions env"
    cli, stdout, stderr = build_cli(env: {})

    When
    status = cli.run([command])

    Then
    status == 2
    stdout.string.empty?
    stderr.string.start_with?("ai-flow: #{key} is not set — this command runs under an Actions job")
    stderr.string.include?("usage: ai-flow #{command}")

    Where
    command    | key
    "dispatch" | "GITHUB_EVENT_NAME"
    "gate"     | "GITHUB_EVENT_PATH"
  end

  test "no command, help, or a help flag prints the usage and exits 0: #{argv.inspect}" do
    Given
    cli, stdout, _stderr = build_cli

    When
    status = cli.run(argv)

    Then
    status == 0
    stdout.string == printed

    Where
    argv       | printed
    []         | AiFlow::Cli::USAGE
    ["help"]   | AiFlow::Cli::USAGE
    ["--help"] | AiFlow::Cli::USAGE
    ["-h"]     | AiFlow::Cli::USAGE
  end

  test "an unknown command is a usage error on stderr, exit 2" do
    Given
    cli, stdout, stderr = build_cli

    When
    status = cli.run(["deploy"])

    Then
    status == 2
    stdout.string.empty?
    stderr.string.start_with?("ai-flow: unknown command: deploy\n")
    stderr.string.include?("usage: ai-flow <command>")
  end

  test "adopt refuses args that are not one owner/repo, exit 2: #{argv.inspect}" do
    Given
    cli, _stdout, stderr = build_cli

    When
    status = cli.run(["adopt", *argv])

    Then "adopt's own usage follows the complaint"
    status == 2
    stderr.string.start_with?("ai-flow: #{complaint}")
    stderr.string.include?("usage: ai-flow adopt <owner/repo>")

    Where
    argv                                      | complaint
    []                                        | "adopt takes exactly one <owner/repo>"
    ["acme/widgets", "acme/other"]            | "adopt takes exactly one <owner/repo>"
    ["widgets"]                               | "\"widgets\" is not an owner/repo"
    ["acme/widgets/extra"]                    | "\"acme/widgets/extra\" is not an owner/repo"
    ["acme/widgets", "--bogus"]               | "invalid option: --bogus"
    ["acme/widgets", "--knowledge-repo", "k"] | "\"k\" is not an owner/repo"
  end

  test "adopt renders one line per step, a remedy line under each finding, and exits 1 while anything is reported" do
    Given "an empty checkout"
    checkout = Dir.mktmpdir("ai-flow-adopt-")
    cli, stdout, stderr = build_cli

    When "adopting into it"
    status = cli.run(["adopt", "acme/widgets", "--checkout", checkout, "--knowledge-repo", "acme/knowledge"])

    Then "the report reads top to bottom in step order"
    status == 1
    stderr.string.empty?
    stdout.string == <<~REPORT
      ai-flow adopt acme/widgets
        changed  .github/workflows/ai-commands.yml: written from templates/caller-workflow.yml — commit and push it
        changed  .github/ai-flow.yml: written from templates/ai-flow.yml with knowledge_repo: acme/knowledge — commit and push it
        changed  org secret CURSOR_API_KEY: acme/widgets added to its selected repositories
        changed  org secret AI_FLOW_APP_ID: acme/widgets added to its selected repositories
        changed  org secret AI_FLOW_APP_PRIVATE_KEY: acme/widgets added to its selected repositories
        finding  ai-flow App: installed in acme but not on acme/widgets
                 → add the repository at https://github.com/organizations/acme/settings/installations/55
      Runner-group admission is dev's: `dev runner register --org` from the repo's checkout.
    REPORT

    Cleanup
    FileUtils.rm_rf(checkout)
  end

  test "adopt exits 0 once every step is settled" do
    Given "a repo adopted in full: files present, secrets shared, App on it"
    checkout = Dir.mktmpdir("ai-flow-adopt-")
    github = seeded_github
    github.seed_app_installation("acme", id: 56, app_slug: "acme-ai-flow", repository_selection: "all")
    cli, stdout, _stderr = build_cli(github: github)
    cli.run(["adopt", "acme/widgets", "--checkout", checkout, "--app", "acme-ai-flow"])
    stdout.truncate(0)
    stdout.rewind

    When "running again"
    status = cli.run(["adopt", "acme/widgets", "--checkout", checkout, "--app", "acme-ai-flow"])

    Then
    status == 0
    stdout.string.lines.count { |line| line.include?("  settled  ") } == 6
    !stdout.string.include?("finding")

    Cleanup
    FileUtils.rm_rf(checkout)
  end

  test "adopt defaults the checkout to the working directory" do
    Given "a checkout as the working directory"
    checkout = Dir.mktmpdir("ai-flow-adopt-")
    cli, _stdout, _stderr = build_cli

    When "adopting from inside it"
    Dir.chdir(checkout) { cli.run(["adopt", "acme/widgets"]) }

    Then "the files landed there"
    File.exist?(File.join(checkout, AiFlow::Adoption::CALLER_WORKFLOW_PATH))
    File.exist?(File.join(checkout, AiFlow::RepoConfig::PATH))

    Cleanup
    FileUtils.rm_rf(checkout)
  end

  test "a repository GitHub does not know is one stderr line, exit 1" do
    Given
    cli, stdout, stderr = build_cli(github: FakeGitHub.new)

    When
    status = cli.run(["adopt", "acme/typo", "--checkout", Dir.tmpdir])

    Then
    status == 1
    stdout.string.empty?
    stderr.string == "ai-flow: gh api repos/acme/typo failed: HTTP 404\n"
  end

  test "a checkout that is not a directory is one stderr line, exit 1" do
    Given
    cli, _stdout, stderr = build_cli

    When
    status = cli.run(["adopt", "acme/widgets", "--checkout", "/nonexistent/checkout"])

    Then
    status == 1
    stderr.string.include?("/nonexistent/checkout is not a directory")
  end
end
