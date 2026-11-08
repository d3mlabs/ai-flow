# typed: true
# frozen_string_literal: true

require "test_helper"
require "support/fakes"
require "tmpdir"
require "fileutils"

transform!(RSpock::AST::Transformation)
class AiFlow::Commands::BuildSplitTest < Minitest::Test
  REPO = "d3mlabs/demo"

  # The children are /build comments the orchestrator posts and reads back
  # (ai-flow#115); the fake GitHub plays them. `script_children` decides
  # what each child's panel reports once read: a PR per repo in `repos_for`
  # (one, or two for a multi-target sub-issue), no changes, busy, or
  # failed. `slow` numbers report nothing on their first read, so the
  # orchestrator has to poll again. The orchestrator never sleeps here:
  # the sleeper records the intervals it was asked for.
  Children = Struct.new(:no_changes_on, :busy_on, :failed_on, :multi_on, :slow, keyword_init: true) do
    def trailer_for(number, reads)
      return nil if (slow || []).include?(number) && reads < 2

      kind =
        if (busy_on || []).include?(number) then AiFlow::Commands::Build::Outcome::Trailer::Kind::Busy
        elsif (failed_on || []).include?(number) then AiFlow::Commands::Build::Outcome::Trailer::Kind::Failed
        elsif (no_changes_on || []).include?(number) then AiFlow::Commands::Build::Outcome::Trailer::Kind::NothingToBuild
        else AiFlow::Commands::Build::Outcome::Trailer::Kind::PrOpened
        end
      repos = ["d3mlabs/demo"]
      repos << "d3mlabs/other" if (multi_on || []).include?(number)
      urls = kind == AiFlow::Commands::Build::Outcome::Trailer::Kind::PrOpened ? repos.map { |repo| "https://github.com/#{repo}/pull/#{number}" } : []
      AiFlow::Commands::Build::Outcome::Trailer.new(kind: kind, pr_urls: urls)
    end
  end

  class RecordingSleeper
    attr_reader :intervals

    def initialize
      @intervals = []
    end

    def call(seconds)
      @intervals << seconds
    end
  end

  # Runs the orchestrator over the seeded fake with scripted children.
  #
  # @return [Array(Array<Integer>, Hash{Integer => String})] the sub-issue
  #   numbers in the order their /build was posted, and each one's posted
  #   command body
  def orchestrate(github, children: Children.new, sleeper: RecordingSleeper.new, body: "/build --split", log: [], summary_path: nil)
    github.script_children { |_repo, number, _body, reads| children.trailer_for(number, reads) }
    context = ContextBuilder.issue_comment(number: 7, body: body, env: APP_ENV)
    segment = AiFlow::CommentParser.new.parse(body).fetch(0)
    AiFlow::Commands::BuildSplit.new(
      context: context, github: github, result_writer: AiFlow::ResultWriter.new(github: github),
      interval: 30, sleeper: sleeper.method(:call).to_proc, log: ->(line) { log << line }, summary_path: summary_path,
    ).run(segment)
    posted = github.posted_comments.values.reject { |_repo, number, _body| number == 7 }
    [posted.map { |_repo, number, _body| number }, posted.to_h { |_repo, number, body| [number, body] }]
  end

  # The job env of a run with the App configured — fan-out posts as the App.
  APP_ENV = { "AI_FLOW_APP_ID" => "424242" }.freeze

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

    When "orchestrating"
    order, commands = orchestrate(github)

    Then "waves respect Depends on, integration is last, and each child command stacks on its dependencies' PRs"
    order == [1, 2, 3, 4]
    github.comment_edits.fetch(55).include?("✅ **/build --split**")
    github.comment_edits.fetch(55).include?("[x] #{REPO}#4 Integration: Parent")
    commands.fetch(1) == "/build --for=jpduchesne"
    commands.fetch(2) == "/build --for=jpduchesne"
    commands.fetch(3) == "/build --base=https://github.com/#{REPO}/pull/1,https://github.com/#{REPO}/pull/2 --for=jpduchesne"
    commands.fetch(4) == "/build --base=https://github.com/#{REPO}/pull/1,https://github.com/#{REPO}/pull/2," \
      "https://github.com/#{REPO}/pull/3 --for=jpduchesne"

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

    When "orchestrating"
    _order, commands = orchestrate(github, children: Children.new(no_changes_on: [1]))

    Then "the checklist marks the no-changes build distinctly from a built one"
    github.comment_edits.fetch(55).include?("[-] #{REPO}#1 Server API — no changes needed")
    github.comment_edits.fetch(55).include?("[x] #{REPO}#4 Integration: Parent")
    # A no-changes dependency has no PR to stack on — the dependent forks
    # from the default branch.
    commands.fetch(4) == "/build --for=jpduchesne"

    Cleanup
    nil
  end

  # ai-flow#116: a child that found its persistent workspace held is not a
  # failure — the run that holds it is doing the repo's work — and not
  # done either. It is deferred, its dependents wait, and the rest of the
  # plan proceeds; a later `/build --split` picks the deferred node up.
  test "a sub-issue whose workspace was busy is deferred, its dependents blocked, the rest built" do
    Given "three sub-issues: one busy, one depending on it, one independent"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "Server API", "Build the API.\n"),
      sub_issue(2, "Client", "Build the client.\n"),
      sub_issue(3, "Wiring", "Wire them.\n\nDepends on: #1\n"),
      sub_issue(4, "Integration: Parent", "Integrate.\n\nDepends on: #1, #2, #3\n"),
    ])

    When "orchestrating"
    order, _commands = orchestrate(github, children: Children.new(busy_on: [1]))
    checklist = github.comment_edits.fetch(55)

    Then "the busy node is deferred with the re-run hint, its dependents are blocked on it, the independent one built"
    checklist.include?(
      "[ ] #{REPO}#1 Server API — deferred: its persistent workspace was held by another run " \
      "(https://github.com/#{REPO}/issues/1#issuecomment-1001); re-run `/build --split` when it is free",
    )
    checklist.include?("[x] #{REPO}#2 Client")
    checklist.include?("[!] #{REPO}#3 Wiring — blocked until #{REPO}#1 is resolved")
    checklist.include?("[!] #{REPO}#4 Integration: Parent — blocked until #{REPO}#1 is resolved")
    order == [1, 2]

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

    When "orchestrating"
    _order, commands = orchestrate(github, children: Children.new(multi_on: [1]))

    Then "the checklist line carries both PR urls, and the dependent stacks on both"
    github.comment_edits.fetch(55).include?(
      "[x] #{REPO}#1 Cross-repo work — " \
        "https://github.com/d3mlabs/demo/pull/1, https://github.com/d3mlabs/other/pull/1",
    )
    commands.fetch(4).include?("--base=https://github.com/d3mlabs/demo/pull/1,https://github.com/d3mlabs/other/pull/1")

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

    When "orchestrating"
    order, _commands = orchestrate(github)

    Then "an integration issue was created, attached as a sub-issue, and built last"
    github.calls.any? { |kind, _repo, title| kind == :create_issue && title.to_s.start_with?("Integration:") }
    github.calls.map(&:first).include?(:add_sub_issue)
    order.size == 3
    T.must(order.last) > 100
    # Same-repo plan: the issue's own repo is the implicit target.
    !github.issue(REPO, T.must(order.last)).body.include?("Target repos:")

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

    When "orchestrating"
    order, _commands = orchestrate(github)

    Then "the integration issue targets the code repo, so its build gets a real checkout"
    github.issue(REPO, T.must(order.last)).body.include?("Target repos: d3mlabs/dev")

    Cleanup
    nil
  end

  test "a created integration issue inherits the parent's declared Target repos line" do
    Given "a parent plan declaring its target repo"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\nTarget repos: d3mlabs/dev\n")
    github.seed_sub_issues(REPO, 7, [sub_issue(1, "Server API", "Build the API.\n")])

    When "orchestrating"
    order, _commands = orchestrate(github)

    Then "the integration issue carries the parent's declared targets"
    github.issue(REPO, T.must(order.last)).body.include?("Target repos: d3mlabs/dev")

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

    When "orchestrating"
    order, _commands = orchestrate(github)

    Then "nothing undrivable was built and the checklist names every skip and block"
    order == []
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

    When "orchestrating"
    order, _commands = orchestrate(github)

    Then "only the code node was built; the manual one is a human step, not a skip; the integration waits on it"
    order == [1]
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

    When "orchestrating"
    order, _commands = orchestrate(github)

    Then "the integration built after the code work; the closed manual step is satisfied and no longer listed"
    order == [1, 4]
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

    When "orchestrating"
    order, commands = orchestrate(github)

    Then "the closed dependency is satisfied; the open one blocks its dependent and the integration"
    order == [2]
    # A satisfied external dependency has no PR in the set — nothing to
    # stack on.
    commands.fetch(2) == "/build --for=jpduchesne"
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

    When "orchestrating"
    orchestrate(github)

    Then
    raises AiFlow::GitHub::Error

    Cleanup
    nil
  end

  # The fan-out itself (ai-flow#115): a wave's members are posted together
  # and the orchestrator waits for all of them before the next wave — the
  # children run concurrently on whatever slots the repo sees.
  test "a wave is posted whole, then polled until every member reports; the next wave waits" do
    Given "two independent sub-issues, one slow to report, and an integration on both"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "Server API", "Build the API.\n"),
      sub_issue(2, "Client UI", "Build the UI.\n"),
      sub_issue(4, "Integration: Parent", "Integrate.\n\nDepends on: #1, #2\n"),
    ])
    sleeper = RecordingSleeper.new

    When "orchestrating"
    order, _commands = orchestrate(github, children: Children.new(slow: [2]), sleeper: sleeper)
    posts = github.third_args(:post_issue_comment)
    reads = github.third_args(:issue_comment)
    first_integration_post = github.calls.index([:post_issue_comment, REPO, 4])
    last_wave_one_read = github.calls.rindex([:issue_comment, REPO, 1002])

    Then "both wave-one children were posted before either was read; the slow one was read twice; wave two came after"
    order == [1, 2, 4]
    posts.first(2) == [1, 2]
    reads.count(1001) == 1
    reads.count(1002) == 2
    T.must(first_integration_post) > T.must(last_wave_one_read)
    sleeper.intervals == [30, 30, 30]

    Cleanup
    nil
  end

  test "while children run, the checklist links each one's command comment" do
    Given "a slow child"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "Server API", "Build the API.\n"),
      sub_issue(4, "Integration: Parent", "Integrate.\n\nDepends on: #1\n"),
    ])

    When "orchestrating"
    orchestrate(github, children: Children.new(slow: [1]))
    mid_run = github.comment_edit_history.find { |body| body.include?("— running:") }

    Then "an intermediate checklist showed the child as running, linked"
    T.must(mid_run).include?("🔄 **/build --split**")
    T.must(mid_run).include?("[ ] #{REPO}#1 Server API — running: https://github.com/#{REPO}/issues/1#issuecomment-1001")

    Cleanup
    nil
  end

  test "once a child's panel names its workflow run, the checklist's running line links it too (ai-flow#128)" do
    Given "a slow child, whose dispatcher has posted its ⏳ panel by the first poll"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "Server API", "Build the API.\n"),
      sub_issue(4, "Integration: Parent", "Integrate.\n\nDepends on: #1\n"),
    ])

    When "orchestrating"
    orchestrate(github, children: Children.new(slow: [1]))
    with_run = github.comment_edit_history.find { |body| body.include?("(run: ") }

    Then "the running line carries the comment and the run"
    T.must(with_run).include?(
      "[ ] #{REPO}#1 Server API — running: https://github.com/#{REPO}/issues/1#issuecomment-1001 (run: https://github.com/#{REPO}/actions/runs/9001)",
    )

    Cleanup
    nil
  end

  test "the orchestrator narrates the run to its log: waves as groups, each child posted, each run found, each outcome (ai-flow#128)" do
    Given "two wave-one children (one slow, one failing) and an integration"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "Server API", "Build the API.\n"),
      sub_issue(2, "Client UI", "Build the UI.\n"),
      sub_issue(4, "Integration: Parent", "Integrate.\n\nDepends on: #1, #2\n"),
    ])
    log = []

    When "orchestrating"
    orchestrate(github, children: Children.new(slow: [1], failed_on: [2]), log: log)

    Then "the log reads as the run page should: headline, wave groups, posts, runs, outcomes, the blocked dependent"
    log.first == "/build --split: 3 sub-issues in 2 waves"
    log.include?("::group::wave 1/2 — 2 children")
    log.include?("#{REPO}#1 posted → https://github.com/#{REPO}/issues/1#issuecomment-1001")
    log.include?("#{REPO}#2 posted → https://github.com/#{REPO}/issues/2#issuecomment-1002")
    log.include?("#{REPO}#1 run: https://github.com/#{REPO}/actions/runs/9001")
    log.count("#{REPO}#1 run: https://github.com/#{REPO}/actions/runs/9001") == 1
    log.include?("#{REPO}#1 built: https://github.com/#{REPO}/pull/1")
    log.include?("#{REPO}#2 failed: https://github.com/#{REPO}/issues/2#issuecomment-1002")
    log.include?("::endgroup::")
    log.include?("#{REPO}#4 blocked until #{REPO}#2 is resolved")
    T.must(log.index("::group::wave 1/2 — 2 children")) < T.must(log.index("::endgroup::"))

    Cleanup
    nil
  end

  test "the default log is the job log: stdout, one line each" do
    Given "the default log"
    log = AiFlow::Commands::BuildSplit::DEFAULT_LOG

    When "narrating a line"
    out, _err = capture_io { log.call("d3mlabs/demo#1 posted → somewhere") }

    Then "it reached stdout, newline-terminated"
    out == "d3mlabs/demo#1 posted → somewhere\n"

    Cleanup
    nil
  end

  test "every checklist publish also lands on the run page's step summary, latest wins (ai-flow#128)" do
    Given "a step summary file and one child"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_sub_issues(REPO, 7, [sub_issue(1, "Server API", "Build the API.\n")])
    dir = Dir.mktmpdir
    path = File.join(dir, "summary.md")

    When "orchestrating"
    orchestrate(github, summary_path: path)
    summary = File.read(path)

    Then "the summary is the final checklist, once — not every intermediate one appended"
    summary.include?("✅ **/build --split**")
    summary.scan("**/build --split**").length == 1
    summary.include?("[x] #{REPO}#1 Server API — https://github.com/#{REPO}/pull/1")

    Cleanup
    FileUtils.rm_rf(dir)
  end

  test "a failed child blocks its dependents like any undrivable node; the rest of the plan proceeds" do
    Given "a child that fails, a dependent, an independent sibling, and the integration"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_sub_issues(REPO, 7, [
      sub_issue(1, "Server API", "Build the API.\n"),
      sub_issue(2, "Client", "Build the client.\n"),
      sub_issue(3, "Wiring", "Wire them.\n\nDepends on: #1\n"),
      sub_issue(4, "Integration: Parent", "Integrate.\n\nDepends on: #1, #2, #3\n"),
    ])

    When "orchestrating"
    order, _commands = orchestrate(github, children: Children.new(failed_on: [1]))
    checklist = github.comment_edits.fetch(55)

    Then "the failure is named with its comment, dependents are blocked on it, the sibling built"
    order == [1, 2]
    checklist.include?("[!] #{REPO}#1 Server API — failed: https://github.com/#{REPO}/issues/1#issuecomment-1001")
    checklist.include?("[x] #{REPO}#2 Client")
    checklist.include?("[!] #{REPO}#3 Wiring — blocked until #{REPO}#1 is resolved")
    checklist.include?("[!] #{REPO}#4 Integration: Parent — blocked until #{REPO}#1 is resolved")

    Cleanup
    nil
  end

  test "a cross-repo sub-issue's child is posted on its own repo" do
    Given "a sub-issue living in another repo"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\nTarget repos: d3mlabs/dev\n")
    code_sub = AiFlow::GitHub::Issue.new(
      number: 1, title: "Server API", body: "Build the API.\n",
      html_url: "https://github.com/d3mlabs/dev/issues/1", state: "open", repo: "d3mlabs/dev",
    )
    github.seed_sub_issues(REPO, 7, [code_sub])

    When "orchestrating"
    orchestrate(github)

    Then
    github.calls.include?([:post_issue_comment, "d3mlabs/dev", 1])

    Cleanup
    nil
  end

  test "without the App there is no identity to post children as — /build --split refuses" do
    Given "a job env with no App id"
    github = FakeGitHub.new
    github.seed_issue(REPO, 7, title: "Parent", body: "# Parent\n")
    github.seed_sub_issues(REPO, 7, [sub_issue(1, "Server API", "Build the API.\n")])
    context = ContextBuilder.issue_comment(number: 7, body: "/build --split", env: {})
    segment = AiFlow::CommentParser.new.parse("/build --split").fetch(0)

    When
    error = assert_raises(AiFlow::Commands::BuildSplit::NoAppError) do
      AiFlow::Commands::BuildSplit.new(
        context: context, github: github, result_writer: AiFlow::ResultWriter.new(github: github),
      ).run(segment)
    end

    Then "nothing was posted, and the reason names the App"
    error.message.include?("App")
    github.third_args(:post_issue_comment).empty?

    Cleanup
    nil
  end
end
