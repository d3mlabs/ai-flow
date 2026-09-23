# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class AiFlow::RepoConfigTest < Minitest::Test
  def load_config(content)
    Dir.mktmpdir("ai-flow-config-test-") do |dir|
      unless content.nil?
        FileUtils.mkdir_p(File.join(dir, ".github"))
        File.write(File.join(dir, ".github", "ai-flow.yml"), content)
      end
      return AiFlow::RepoConfig.load(dir)
    end
  end

  test "the defaults: no knowledge repo, build capture on" do
    Given "no ai-flow.yml at all"
    config = load_config(nil)

    Expect "the loop-friendly defaults"
    config.knowledge_repo.nil?
    config.learn_on_build? == true

    Cleanup
    nil
  end

  test "the learn section and knowledge_repo read through" do
    Given "a fully configured file"
    config = load_config("knowledge_repo: d3mlabs/knowledge\nlearn:\n  on_build: false\n")

    Expect
    config.knowledge_repo == "d3mlabs/knowledge"
    config.learn_on_build? == false

    Cleanup
    nil
  end

  test "a blank knowledge_repo counts as unset" do
    Given "an empty-string value"
    config = load_config("knowledge_repo: \"\"\n")

    Expect
    config.knowledge_repo.nil?

    Cleanup
    nil
  end

  test "models coerces to Command keys, dropping unknown, blank, and non-string entries" do
    Given "a models section mixing valid links with every kind of junk"
    config = load_config("models:\n  default: gpt-5\n  build: opus\n  ask: \"\"\n  split: 3\n  potato: nope\n")

    Expect "only the recognized non-blank string links survive, as value objects"
    config.models == { AiFlow::Command::Build.new => AiFlow::ModelSelection::Named.new("opus") }
    config.default_model == AiFlow::ModelSelection::Named.new("gpt-5")

    Cleanup
    nil
  end

  test "a blank default counts as unset" do
    Given "a models section whose only value is a blank default"
    config = load_config("models:\n  default: \"\"\n")

    Expect
    config.default_model.nil?
    config.models == {}

    Cleanup
    nil
  end

  test "mcp and workspace defaults: deny-all, no session hooks, disposable tmpdirs" do
    Given "no ai-flow.yml at all"
    config = load_config(nil)

    Expect "the closed defaults"
    config.mcp_configured? == false
    config.mcp_allowlist == []
    config.mcp_session_start.nil?
    config.mcp_session_stop.nil?
    config.persistent_workspace? == false

    Cleanup
    nil
  end

  test "a full mcp + workspace section reads through" do
    Given "the cb3d-shaped opt-in"
    config = load_config(<<~YAML)
      workspace: persistent
      mcp:
        allow: [unreal-mcp]
        session:
          start: bin/agent-editor start
          stop: bin/agent-editor stop
    YAML

    Expect
    config.mcp_configured? == true
    config.mcp_allowlist == ["unreal-mcp"]
    config.mcp_session_start == "bin/agent-editor start"
    config.mcp_session_stop == "bin/agent-editor stop"
    config.persistent_workspace? == true

    Cleanup
    nil
  end

  test "mcp junk coerces closed: #{name}" do
    Given "a config with a malformed mcp value"
    config = load_config(yaml)

    Expect "deny-all / unset rather than a crash or an accidental grant"
    config.mcp_allowlist == allowlist
    config.mcp_session_start.nil?
    config.mcp_session_stop.nil?

    Where
    name                      | yaml                                            | allowlist
    "allow is a string"       | "mcp:\n  allow: unreal-mcp\n"                   | []
    "allow mixes junk"        | "mcp:\n  allow: [unreal-mcp, \"\", 3, null]\n"  | ["unreal-mcp"]
    "mcp is a scalar"         | "mcp: yes\n"                                    | []
    "session is a scalar"     | "mcp:\n  session: bin/start\n"                  | []
    "session values blank"    | "mcp:\n  session:\n    start: \"\"\n"           | []
  end

  test "workspace junk never opts in: #{name}" do
    Given "a workspace value that is not the literal opt-in"
    config = load_config(yaml)

    Expect
    config.persistent_workspace? == false

    Where
    name             | yaml
    "a boolean"      | "workspace: true\n"
    "another word"   | "workspace: shared\n"
    "a mapping"      | "workspace:\n  mode: persistent\n"
  end
end
