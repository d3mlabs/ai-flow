# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "support/fakes"
require "fileutils"
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

  def build_cli(github: seeded_github)
    stdout = StringIO.new
    stderr = StringIO.new
    [AiFlow::Cli.new(root: AI_FLOW_ROOT, stdout: stdout, stderr: stderr, github: github), stdout, stderr]
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
