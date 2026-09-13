# typed: true
# frozen_string_literal: true

require "test_helper"

transform!(RSpock::AST::Transformation)
class AiFlow::DenialsTest < Minitest::Test
  def isolation
    AiFlow::AgentIsolation.new(user: "ai-agent", group: "ai", home: "/tmp")
  end

  # ---- prompt contract ----

  test "prompt contract is empty when isolation is off" do
    Expect "off means empty"
    AiFlow::Denials.prompt_contract(nil) == ""
  end

  test "prompt contract names the agent user and the WANTED line form" do
    Given "an isolation posture"
    contract = AiFlow::Denials.prompt_contract(isolation)

    Expect "the contract carries the user, the form, and the no-workaround rule"
    contract.include?("ai-agent")
    contract.include?("WANTED: <path or capability> — <why it would have helped>")
    contract.match?(/never work around/i)
  end

  # ---- declared extraction ----

  test "extracts WANTED lines into wants and strips them from the text" do
    Given "a final text carrying two wants amid the answer"
    text = <<~TEXT
      Implemented the feature; tests green.
      WANTED: /Users/human/notes.md — the issue referenced design notes there
      All segments addressed.
      WANTED: shellcheck — lint pass configured in CI but the binary is missing
    TEXT

    When "extracting"
    wants, remainder = AiFlow::Denials.extract_declared(text)

    Then "both wants parse subject/reason and the remainder keeps only the answer"
    wants.map(&:subject) == ["/Users/human/notes.md", "shellcheck"]
    wants.map(&:reason) == ["the issue referenced design notes there", "lint pass configured in CI but the binary is missing"]
    wants.all? { |want| want.channel == :declared }
    remainder == "Implemented the feature; tests green.\nAll segments addressed.\n"
  end

  test "a WANTED line without a reason separator keeps the whole rest as subject" do
    When "extracting a separator-less line"
    wants, _remainder = AiFlow::Denials.extract_declared("WANTED: docker socket access\n")

    Then "the whole rest is the subject"
    wants.map(&:subject) == ["docker socket access"]
    wants.map(&:reason) == [""]
  end

  test "double-hyphen separates like the em dash" do
    When "extracting an ASCII-separator line"
    wants, _remainder = AiFlow::Denials.extract_declared("WANTED: gh auth -- to read the org board\n")

    Then "it splits like the em dash"
    wants.map(&:subject) == ["gh auth"]
    wants.map(&:reason) == ["to read the org board"]
  end

  test "duplicate WANTED lines dedupe" do
    When "extracting duplicates"
    wants, _remainder = AiFlow::Denials.extract_declared("WANTED: jq — parse\nWANTED: jq — parse\n")

    Then "one want survives"
    wants.length == 1
  end

  test "text without WANTED lines passes through untouched" do
    When "extracting plain text"
    wants, remainder = AiFlow::Denials.extract_declared("plain answer\n")

    Then "nothing collects and nothing changes"
    wants.empty?
    remainder == "plain answer\n"
  end

  # ---- observed extraction ----

  test "denial signatures in tool output become observed wants keyed by path" do
    Given "output with a classic unix denial"
    text = "rm: /Users/Shared/dev/cache/x: Permission denied\nall good otherwise\n"

    When "scanning"
    wants = AiFlow::Denials.observed_in(text)

    Then "the touched path is the subject, channel observed"
    wants.map(&:subject) == ["/Users/Shared/dev/cache/x"]
    wants.map(&:channel) == [:observed]
  end

  test "EACCES and Operation not permitted match too" do
    When "scanning both signatures"
    wants = AiFlow::Denials.observed_in(
      "Error: EACCES: permission denied, open '/etc/foo'\nchmod: /tmp/x: Operation not permitted\n",
    )

    Then
    wants.map(&:subject) == ["/etc/foo", "/tmp/x"]
  end

  test "a ruby errno crash names the denied path, not the backtrace frame" do
    Given "a ruby EACCES crash line: the source frame leads, the denied path trails after the dash"
    text = "/opt/homebrew/Cellar/dev-core/0.2.82/libexec/dev/lib/dev/deps/gh_integration.rb:44:in " \
      "'symlink': Permission denied @ rb_file_s_symlink - /Users/Shared/dev/engines/ue5-mac/current " \
      "(Errno::EACCES)\n"

    When "scanning"
    wants = AiFlow::Denials.observed_in(text)

    Then "the subject is what the OS denied — not the code that tripped over it (caught live at the " \
         "plans#36 ceremony: the frame path dodged the category-4/5 classifier and rendered the wrong menu)"
    wants.map(&:subject) == ["/Users/Shared/dev/engines/ue5-mac/current"]
  end

  test "a GitHub-API 403 is by design (plans#25), never an observed want" do
    When "scanning a read-only-token write denial"
    wants = AiFlow::Denials.observed_in(
      "gh: HTTP 403: Resource not accessible by integration (https://api.github.com/repos/x/y/issues)\n",
    )

    Then
    wants.empty?
  end

  test "a pathless denial line falls back to the trimmed line as subject" do
    When
    wants = AiFlow::Denials.observed_in("docker: permission denied while trying to connect\n")

    Then "the line itself carries the story"
    wants.map(&:subject) == ["docker: permission denied while trying to connect"]
  end

  test "repeated denials on one path dedupe" do
    When
    wants = AiFlow::Denials.observed_in("cat: /etc/foo: Permission denied\ncp: /etc/foo: Permission denied\n")

    Then
    wants.length == 1
  end

  # ---- rendering hygiene (agent-authored text lands in GitHub comments) ----

  test "rendered subjects and reasons are sanitized: no code-span breakout, bounded length" do
    Given "a want whose subject tries to escape its backtick span"
    want = AiFlow::Denials::Want.new(
      subject: "x` [click me](https://evil.example) `#{"y" * 300}",
      reason: "b`c",
      channel: :declared,
    )

    When "rendering"
    lines = AiFlow::Denials.render([want])

    Then "backticks are gone and the line is capped"
    !T.must(lines.first).include?("`x` [")
    !T.must(lines.first).include?("b`c")
    T.must(lines.first).length < 200
  end

  test "rendering caps the want count so a flood cannot drown the panel" do
    Given "far more wants than anyone will triage"
    wants = (1..30).map do |i|
      AiFlow::Denials::Want.new(subject: "/opt/tool-#{i}", reason: "", channel: :observed)
    end

    When "rendering"
    lines = AiFlow::Denials.render(wants)

    Then "ten render, the rest fold into a count"
    lines.count { |line| line.start_with?("- ") } == 11
    T.must(lines.last).include?("20 more")
  end

  # ---- Want value object ----

  test "wants carry value equality" do
    Given "three wants, two equal"
    a = AiFlow::Denials::Want.new(subject: "jq", reason: "parse", channel: :declared)
    b = AiFlow::Denials::Want.new(subject: "jq", reason: "parse", channel: :declared)
    c = AiFlow::Denials::Want.new(subject: "jq", reason: "parse", channel: :observed)

    Expect "equality is memberwise including channel"
    a == b
    a.hash == b.hash
    a != c
  end

  # ---- triage-ladder rendering ----

  test "a tool want renders the class-1/class-2 menu" do
    Given "a tool want"
    want = AiFlow::Denials::Want.new(subject: "shellcheck", reason: "CI lints with it", channel: :declared)

    When "rendering"
    lines = AiFlow::Denials.render([want])

    Then "the want line and the Brewfile/dependencies.rb menu render"
    lines.first&.include?("shellcheck")
    lines.first&.include?("CI lints with it")
    lines.any? { |line| line.include?("Brewfile") && line.include?("dependencies.rb") }
  end

  test "a shared-root path want renders the category-4/5 note, never a widening menu" do
    Given "a shared-root path want"
    want = AiFlow::Denials::Want.new(subject: "/Users/Shared/dev/ddc", reason: "warm cook", channel: :declared)

    When "rendering"
    lines = AiFlow::Denials.render([want])

    Then "the by-design note renders, no menu"
    lines.any? { |line| line.include?("plans#26") }
    lines.none? { |line| line.include?("Brewfile") }
  end

  test "a socket want renders the category-4/5 note" do
    Given "a socket want"
    want = AiFlow::Denials::Want.new(subject: "/var/run/docker.sock", reason: "build image", channel: :observed)

    When "rendering"
    lines = AiFlow::Denials.render([want])

    Then "the note names the per-user engine and marks the observed channel"
    lines.any? { |line| line.include?("container engine") }
    lines.first&.include?("observed")
  end

  test "rendering an empty list is empty" do
    Expect "empty in, empty out"
    AiFlow::Denials.render([]).empty?
  end
end
