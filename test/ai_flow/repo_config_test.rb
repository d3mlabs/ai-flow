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

  test "the defaults: no knowledge repo, build capture on, auto-learn off" do
    Given "no ai-flow.yml at all"
    config = load_config(nil)

    Expect "the loop-friendly defaults"
    config.knowledge_repo.nil?
    config.learn_on_build? == true
    config.learn_auto? == false

    Cleanup
    nil
  end

  test "the learn section and knowledge_repo read through" do
    Given "a fully configured file"
    config = load_config("knowledge_repo: d3mlabs/knowledge\nlearn:\n  on_build: false\n  auto: true\n")

    Expect
    config.knowledge_repo == "d3mlabs/knowledge"
    config.learn_on_build? == false
    config.learn_auto? == true

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
end
