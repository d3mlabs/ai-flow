# typed: true
# frozen_string_literal: true

require "test_helper"
require "support/fakes"

transform!(RSpock::AST::Transformation)
class AiFlow::Commands::BuildSplitTest < Minitest::Test
  REPO = "d3mlabs/demo"

  # A build stand-in recording the order sub-issues were built in and the
  # base PRs each was stacked on; `multi_on` numbers report a second PR (a
  # multi-target sub-issue). Subclasses the real command so sorbet-runtime's
  # sig checks accept it.
  class RecordingBuild < AiFlow::Commands::Build
    attr_reader :built, :base_prs_by_number

    def initialize(no_changes_on: [], multi_on: [])
      @built = []
      @base_prs_by_number = {}
      @no_changes_on = no_changes_on
      @multi_on = multi_on
    end

    def build_issue(issue, extra_instruction: "", base_prs: [])
      @built << issue.number
      @base_prs_by_number[issue.number] = base_prs
      if @no_changes_on.include?(issue.number)
        AiFlow::Commands::Build::Outcome::NothingToBuild.new(capture_notes: [], workflows_patch: nil)
      else
        repos = ["d3mlabs/demo"]
        repos << "d3mlabs/other" if @multi_on.include?(issue.number)
        prs = repos.map do |repo|
          AiFlow::GitHub::PullRequest.new(
            number: issue.number, html_url: "https://github.com/#{repo}/pull/#{issue.number}",
            repo: repo, head_ref: "ai/#{issue.number}-branch",
          )
        end
        AiFlow::Commands::Build::Outcome::PrOpened.new(prs: prs, capture_notes: [], workflows_patch: nil)
      end
    end
  end

  def sub_issue(number, title, body)
    AiFlow::GitHub::Issue.new(
      number: number, title: title, body: body,
      html_url: "https://github.com/#{REPO}/issues/#{number}", state: "open", repo: REPO,
    )
  end

  test "builds waves in dependency order and finishes with the integration sub-issue" do
    Given "sub-issues where 3 depends on 1 and 2, plus an existing integration issue depending on all"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "Server API", "Build the API.\n"),
      sub_issue(2, "Client UI", "Build the UI.\n"),
      sub_issue(3, "Wiring", "Wire them.\n\nDepends on: #1, #2\n"),
      sub_issue(4, "Integration: Parent", "Integrate.\n\nDepends on: #1, #2, #3\n"),
    ])
    build = RecordingBuild.new
    context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
    segment = AiFlow::CommentParser.new.parse("/build --split").fetch(0)

    When "orchestrating"
    AiFlow::Commands::BuildSplit.new(
      context: context, github: github, build: build,
      result_writer: AiFlow::ResultWriter.new(github: github),
    ).run(segment)

    Then "waves respect Depends on, integration is last, and each build stacks on its dependencies' PRs"
    build.built == [1, 2, 3, 4]
    github.comment_edits.fetch(55).include?("✅ **/build --split**")
    github.comment_edits.fetch(55).include?("[x] #{REPO}#4 Integration: Parent")
    build.base_prs_by_number.fetch(1) == []
    build.base_prs_by_number.fetch(2) == []
    build.base_prs_by_number.fetch(3).map(&:head_ref) == ["ai/1-branch", "ai/2-branch"]
    build.base_prs_by_number.fetch(4).map(&:head_ref) == ["ai/1-branch", "ai/2-branch", "ai/3-branch"]

    Cleanup
    nil
  end

  test "a sub-issue the agent had nothing to build for is checked off as no-changes" do
    Given "two sub-issues, one of which will produce no changes"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "Server API", "Build the API.\n"),
      sub_issue(4, "Integration: Parent", "Integrate.\n\nDepends on: #1\n"),
    ])
    build = RecordingBuild.new(no_changes_on: [1])
    context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
    segment = AiFlow::CommentParser.new.parse("/build --split").fetch(0)

    When "orchestrating"
    AiFlow::Commands::BuildSplit.new(
      context: context, github: github, build: build,
      result_writer: AiFlow::ResultWriter.new(github: github),
    ).run(segment)

    Then "the checklist marks the no-changes build distinctly from a built one"
    github.comment_edits.fetch(55).include?("[-] #{REPO}#1 Server API — no changes needed")
    github.comment_edits.fetch(55).include?("[x] #{REPO}#4 Integration: Parent")
    # A no-changes dependency has no PR to stack on — the dependent forks
    # from the default branch.
    build.base_prs_by_number.fetch(4) == []

    Cleanup
    nil
  end

  test "a multi-target sub-issue's checklist line lists every opened PR" do
    Given "a sub-issue whose build opens two coordinated PRs"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "Cross-repo work", "Do it in both repos.\n"),
      sub_issue(4, "Integration: Parent", "Integrate.\n\nDepends on: #1\n"),
    ])
    build = RecordingBuild.new(multi_on: [1])
    context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
    segment = AiFlow::CommentParser.new.parse("/build --split").fetch(0)

    When "orchestrating"
    AiFlow::Commands::BuildSplit.new(
      context: context, github: github, build: build,
      result_writer: AiFlow::ResultWriter.new(github: github),
    ).run(segment)

    Then "the checklist line carries both PR urls"
    github.comment_edits.fetch(55).include?(
      "[x] #{REPO}#1 Cross-repo work — " \
        "https://github.com/d3mlabs/demo/pull/1, https://github.com/d3mlabs/other/pull/1",
    )

    Cleanup
    nil
  end

  test "creates the integration sub-issue when the split didn't" do
    Given "two independent sub-issues and no integration issue"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "Server API", "Build the API.\n"),
      sub_issue(2, "Client UI", "Build the UI.\n"),
    ])
    build = RecordingBuild.new
    context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
    segment = AiFlow::CommentParser.new.parse("/build --split").fetch(0)

    When "orchestrating"
    AiFlow::Commands::BuildSplit.new(
      context: context, github: github, build: build,
      result_writer: AiFlow::ResultWriter.new(github: github),
    ).run(segment)

    Then "an integration issue was created, attached as a sub-issue, and built last"
    github.calls.any? { |kind, _repo, title| kind == :create_issue && title.to_s.start_with?("Integration:") }
    github.calls.map(&:first).include?(:add_sub_issue)
    build.built.size == 3
    build.built.last > 100
    # Same-repo plan: the issue's own repo is the implicit target.
    !github.issue(REPO, T.must(build.built.last)).body.include?("Target repos:")

    Cleanup
    nil
  end

  test "a created integration issue declares the sub-issues' repos as its targets" do
    Given "a plans-style parent whose sub-issues route to a code repo"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    code_sub = AiFlow::GitHub::Issue.new(
      number: 1, title: "Server API", body: "Build the API.\n",
      html_url: "https://github.com/d3mlabs/dev/issues/1", state: "open", repo: "d3mlabs/dev",
    )
    github.seed_sub_issues(REPO, 7, [code_sub])
    build = RecordingBuild.new
    context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
    segment = AiFlow::CommentParser.new.parse("/build --split").fetch(0)

    When "orchestrating"
    AiFlow::Commands::BuildSplit.new(
      context: context, github: github, build: build,
      result_writer: AiFlow::ResultWriter.new(github: github),
    ).run(segment)

    Then "the integration issue targets the code repo, so its build gets a real checkout"
    github.issue(REPO, T.must(build.built.last)).body.include?("Target repos: d3mlabs/dev")

    Cleanup
    nil
  end

  test "a created integration issue inherits the parent's declared Target repos line" do
    Given "a parent plan declaring its target repo"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\nTarget repos: d3mlabs/dev\n")
    github.seed_sub_issues(REPO, 7, [sub_issue(1, "Server API", "Build the API.\n")])
    build = RecordingBuild.new
    context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
    segment = AiFlow::CommentParser.new.parse("/build --split").fetch(0)

    When "orchestrating"
    AiFlow::Commands::BuildSplit.new(
      context: context, github: github, build: build,
      result_writer: AiFlow::ResultWriter.new(github: github),
    ).run(segment)

    Then "the integration issue carries the parent's declared targets"
    github.issue(REPO, T.must(build.built.last)).body.include?("Target repos: d3mlabs/dev")

    Cleanup
    nil
  end

  test "non-buildable nodes are skipped with a warning and their dependents reported blocked" do
    Given "an intended-repo fallback, an adopted external issue, and dependents on both"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: <<~BODY)
      # Parent

      ## Subtasks
      #{AiFlow::SubtasksSection::APPLIED_MARKER}

      - #{REPO}#1 — Fallback work
      - d3mlabs/other#42 — External work (adopted)
      - #{REPO}#3 — Dependent wiring
      - #{REPO}#4 — Integration: Parent
    BODY
    external = AiFlow::GitHub::Issue.new(
      number: 42, title: "External work", body: "",
      html_url: "https://github.com/d3mlabs/other/issues/42", state: "open", repo: "d3mlabs/other",
    )
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "Fallback work", "Do it.\n\nIntended repo: d3mlabs/private\n"),
      external,
      sub_issue(3, "Dependent wiring", "Wire.\n\nDepends on: #1\n"),
      sub_issue(4, "Integration: Parent", "Integrate.\n\nDepends on: #1, d3mlabs/other#42, #3\n"),
    ])
    build = RecordingBuild.new
    context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
    segment = AiFlow::CommentParser.new.parse("/build --split").fetch(0)

    When "orchestrating"
    AiFlow::Commands::BuildSplit.new(
      context: context, github: github, build: build,
      result_writer: AiFlow::ResultWriter.new(github: github),
    ).run(segment)

    Then "nothing undrivable was built and the checklist names every skip and block"
    build.built == []
    checklist = github.comment_edits.fetch(55)
    checklist.include?("⚠️ **/build --split**")
    checklist.include?("[!] #{REPO}#1 Fallback work — fallback placeholder — the work lands in d3mlabs/private")
    checklist.include?("[!] d3mlabs/other#42 External work — adopted external issue")
    checklist.include?("[!] #{REPO}#3 Dependent wiring — blocked until #{REPO}#1 is resolved")
    checklist.include?("[!] #{REPO}#4 Integration: Parent — blocked until")

    Cleanup
    nil
  end

  test "a manual sub-issue is never dispatched, is listed as a human step, and blocks its dependents while open" do
    Given "a manual node (annotated in the applied map), a code node, and an integration depending on both"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: <<~BODY)
      # Parent

      ## Subtasks
      #{AiFlow::SubtasksSection::APPLIED_MARKER}

      - #{REPO}#1 — Code work
      - #{REPO}#2 — Ruleset: require codecov/patch (manual)
      - #{REPO}#4 — Integration: Parent
    BODY
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "Code work", "Part of #{REPO}#7.\n"),
      sub_issue(2, "Ruleset: require codecov/patch", "Part of #{REPO}#7.\n\n#{AiFlow::SubtasksSection::MANUAL_LINE}\n"),
      sub_issue(4, "Integration: Parent", "Integrate.\n\nDepends on: #1, #2\n"),
    ])
    build = RecordingBuild.new
    context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
    segment = AiFlow::CommentParser.new.parse("/build --split").fetch(0)

    When "orchestrating"
    AiFlow::Commands::BuildSplit.new(
      context: context, github: github, build: build,
      result_writer: AiFlow::ResultWriter.new(github: github),
    ).run(segment)

    Then "only the code node was built; the manual one is a human step, not a skip; the integration waits on it"
    build.built == [1]
    checklist = github.comment_edits.fetch(55)
    checklist.include?("(2 not driven by this run)")
    checklist.include?("[ ] #{REPO}#2 Ruleset: require codecov/patch — manual: a human does this step; close it when done")
    !checklist.include?("no changes needed")
    checklist.include?("[!] #{REPO}#4 Integration: Parent — blocked until #{REPO}#2 is resolved")

    Cleanup
    nil
  end

  test "once the human closed the manual sub-issue, its dependents build on the next run" do
    Given "the same plan after the ruleset step was done and closed"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: <<~BODY)
      # Parent

      ## Subtasks
      #{AiFlow::SubtasksSection::APPLIED_MARKER}

      - #{REPO}#1 — Code work
      - #{REPO}#2 — Ruleset: require codecov/patch (manual)
      - #{REPO}#4 — Integration: Parent
    BODY
    github.seed_issue(REPO, 2, title: "Ruleset: require codecov/patch", body: "", state: "closed")
    closed_manual = AiFlow::GitHub::Issue.new(
      number: 2, title: "Ruleset: require codecov/patch", body: "Part of #{REPO}#7.\n\n#{AiFlow::SubtasksSection::MANUAL_LINE}\n",
      html_url: "https://github.com/#{REPO}/issues/2", state: "closed", repo: REPO,
    )
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "Code work", "Part of #{REPO}#7.\n"),
      closed_manual,
      sub_issue(4, "Integration: Parent", "Integrate.\n\nDepends on: #1, #2\n"),
    ])
    build = RecordingBuild.new
    context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
    segment = AiFlow::CommentParser.new.parse("/build --split").fetch(0)

    When "orchestrating"
    AiFlow::Commands::BuildSplit.new(
      context: context, github: github, build: build,
      result_writer: AiFlow::ResultWriter.new(github: github),
    ).run(segment)

    Then "the integration built after the code work; the closed manual step is satisfied and no longer listed"
    build.built == [1, 4]
    checklist = github.comment_edits.fetch(55)
    checklist.include?("✅ **/build --split** — built 2 sub-issues in 2 waves")
    !checklist.include?("Ruleset")

    Cleanup
    nil
  end

  test "out-of-set dependencies gate on the referenced issue's open state" do
    Given "one sub-issue gated on an open external issue, another on a closed one"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_issue("d3mlabs/other", 42, title: "Still open", body: "", state: "open")
    github.seed_issue("d3mlabs/other", 43, title: "Done", body: "", state: "closed")
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "Gated", "Wait for it.\n\nDepends on: d3mlabs/other#42\n"),
      sub_issue(2, "Cleared", "Go.\n\nDepends on: d3mlabs/other#43\n"),
      sub_issue(3, "Integration: Parent", "Integrate.\n\nDepends on: #1, #2\n"),
    ])
    build = RecordingBuild.new
    context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
    segment = AiFlow::CommentParser.new.parse("/build --split").fetch(0)

    When "orchestrating"
    AiFlow::Commands::BuildSplit.new(
      context: context, github: github, build: build,
      result_writer: AiFlow::ResultWriter.new(github: github),
    ).run(segment)

    Then "the closed dependency is satisfied; the open one blocks its dependent and the integration"
    build.built == [2]
    # A satisfied external dependency has no PR in the set — nothing to
    # stack on.
    build.base_prs_by_number.fetch(2) == []
    checklist = github.comment_edits.fetch(55)
    checklist.include?("[!] #{REPO}#1 Gated — blocked until d3mlabs/other#42 is resolved")
    checklist.include?("[x] #{REPO}#2 Cleared")
    checklist.include?("[!] #{REPO}#3 Integration: Parent — blocked until")

    Cleanup
    nil
  end

  test "a dependency cycle is a hard error" do
    Given "sub-issues depending on each other"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "A", "Depends on: #2\n"),
      sub_issue(2, "B", "Depends on: #1\n"),
      sub_issue(3, "Integration: Parent", "Depends on: #1, #2\n"),
    ])
    context = ContextBuilder.issue_comment(number: 7, body: "/build --split")
    segment = AiFlow::CommentParser.new.parse("/build --split").fetch(0)

    When "orchestrating"
    AiFlow::Commands::BuildSplit.new(
      context: context, github: github, build: RecordingBuild.new,
      result_writer: AiFlow::ResultWriter.new(github: github),
    ).run(segment)

    Then
    raises AiFlow::GitHub::Error

    Cleanup
    nil
  end
end
