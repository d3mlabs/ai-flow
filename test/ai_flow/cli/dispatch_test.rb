# typed: false — rspock exception captures (`e = raises`) are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "support/fakes"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class AiFlow::Cli::DispatchTest < Minitest::Test
  REPO = "d3mlabs/demo"

  # An issue_comment event as the runner finds it: the payload written to
  # GITHUB_EVENT_PATH, the job's env naming it and the target checkout.
  def job_env(dir, body:, workdir: dir, extra: {})
    payload = {
      "repository" => { "full_name" => REPO },
      "issue" => { "number" => 7 },
      "comment" => {
        "id" => 55, "body" => body, "author_association" => "OWNER",
        "html_url" => "https://github.com/#{REPO}/issues/7#issuecomment-55",
        "user" => { "login" => "jpduchesne", "id" => 111 },
      },
    }
    event_path = File.join(dir, "event.json")
    File.write(event_path, JSON.generate(payload))
    {
      "GITHUB_EVENT_NAME" => "issue_comment",
      "GITHUB_EVENT_PATH" => event_path,
      "AI_FLOW_WORKDIR" => workdir,
    }.merge(extra)
  end

  def build_dispatch(env:, github: FakeGitHub.new, agent: FakeAgent.new([]))
    stdout = StringIO.new
    dispatch = AiFlow::Cli::Dispatch.new(env: env, executor: AiFlow::Executor.new, github: github, agent: agent, stdout: stdout)
    [dispatch, stdout]
  end

  test "a non-command comment is a clean no-op: exit 0, no API call" do
    Given "a job for plain conversation"
    dir = Dir.mktmpdir("ai-flow-dispatch-")
    github = FakeGitHub.new
    dispatch, stdout = build_dispatch(env: job_env(dir, body: "looks good to me"), github: github)

    When "dispatching"
    status = dispatch.run([])

    Then "nothing happened, and the run log is unbuffered for the Actions page"
    status == AiFlow::Cli::EXIT_OK
    github.calls.empty?
    stdout.sync == true

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a command whose agent pass fails turns the exit red after the comment carries the panel" do
    Given "a /ask whose agent has nothing to say"
    dir = Dir.mktmpdir("ai-flow-dispatch-")
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Plan", body: "# Plan\n")
    dispatch, _stdout = build_dispatch(env: job_env(dir, body: "/ask why?"), github: github, agent: FakeAgent.new([]))

    When "dispatching"
    status = dispatch.run([])

    Then "the dispatcher reported on the comment and the job fails"
    status == AiFlow::Cli::EXIT_REPORTED
    github.comment_edits.fetch(55).include?("ai-flow failed")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "the caller's command prefix reaches the parser" do
    Given "a prefixed caller and a prefixed command"
    dir = Dir.mktmpdir("ai-flow-dispatch-")
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Plan", body: "# Plan\n")
    agent = FakeAgent.new(["<<<AI-FLOW:SEGMENT 1>>>\nBecause."])
    env = job_env(dir, body: "/ai-ask why?", extra: { "AI_FLOW_COMMAND_PREFIX" => "ai-" })
    dispatch, _stdout = build_dispatch(env: env, github: github, agent: agent)

    When "dispatching"
    status = dispatch.run([])

    Then "the command ran as /ask"
    status == AiFlow::Cli::EXIT_OK
    agent.prompts.size == 1

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "arguments are a usage error ending in dispatch's usage" do
    Given
    dispatch, _stdout = build_dispatch(env: {})

    When
    dispatch.run(["--now"])

    Then
    e = raises AiFlow::Cli::UsageError
    e.message.start_with?("dispatch takes no arguments\n")
    e.message.include?("usage: ai-flow dispatch")
  end

  test "a run outside an Actions job names the missing key and dispatch's usage" do
    Given "a terminal's env"
    dispatch, _stdout = build_dispatch(env: { "HOME" => "/home/me" })

    When
    dispatch.run([])

    Then
    e = raises AiFlow::Cli::Job::NotUnderActionsError
    e.message.start_with?("GITHUB_EVENT_NAME is not set")
    e.message.include?("usage: ai-flow dispatch")
  end
end
