# typed: true
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

    Expect "only the recognized non-blank string links survive, keyed by value object"
    config.models == { AiFlow::Command::Build.new => "opus" }
    config.default_model == "gpt-5"

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
end
