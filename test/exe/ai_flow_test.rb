# typed: true
# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

# exe/ai-flow's contract with the tree dev installs it in: when the tree
# carries its closure (`vendor/bundle/ruby/<ruby_version>`, bundler's
# layout), the executable finds its gems there — by position, with
# nothing from the environment — and a source checkout with no closure
# keeps the shell's gem environment. Run as a subprocess under a gem
# environment that cannot supply sorbet-runtime, so the only way the
# executable boots is through the tree.
transform!(RSpock::AST::Transformation)
class AiFlow::ExeTest < Minitest::Test
  EXE = File.join(AI_FLOW_ROOT, "exe", "ai-flow")

  # A tool tree laid out as `bin/install` plus dev's install leave it: the
  # exe and lib, and — when asked — the running Ruby's sorbet-runtime
  # linked into the tree's own gem home as bundler would have laid it.
  def tool_tree(dir, closure:)
    FileUtils.mkdir_p(File.join(dir, "exe"))
    FileUtils.cp(EXE, File.join(dir, "exe", "ai-flow"))
    FileUtils.cp_r(File.join(AI_FLOW_ROOT, "lib"), dir)
    return dir unless closure

    gem_home = File.join(dir, "vendor", "bundle", "ruby", RbConfig::CONFIG["ruby_version"])
    FileUtils.mkdir_p(File.join(gem_home, "gems"))
    FileUtils.mkdir_p(File.join(gem_home, "specifications"))
    spec = Gem::Specification.find_by_name("sorbet-runtime")
    FileUtils.ln_s(spec.full_gem_path, File.join(gem_home, "gems", spec.full_name))
    FileUtils.ln_s(spec.spec_file, File.join(gem_home, "specifications", File.basename(spec.spec_file)))
    dir
  end

  # The executable, run the way the generated wrapper runs it — no harness
  # activation — under a gem environment holding nothing.
  def run_exe(tree, *args)
    empty = File.join(tree, "empty-gem-home")
    FileUtils.mkdir_p(empty)
    env = {
      "GEM_HOME" => empty, "GEM_PATH" => empty,
      "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_PATH" => nil, "BUNDLE_APP_CONFIG" => nil,
      "BUNDLER_SETUP" => nil,
    }
    # T.unsafe: splatting a runtime-built argv is beyond Sorbet's static
    # splat support (srb.help/7019).
    out, err, status = T.unsafe(Open3).capture3(env, RbConfig.ruby, File.join(tree, "exe", "ai-flow"), *args)
    [out, err, status.exitstatus]
  end

  test "a tree carrying its closure boots from it, with nothing from the environment" do
    Given "a deployed tree"
    dir = tool_tree(Dir.mktmpdir("ai-flow-exe-"), closure: true)

    When "running help under an empty gem environment"
    out, err, status = run_exe(dir, "help")

    Then "the tree's gems booted it and it printed its usage"
    status == 0
    err.empty?
    out == AiFlow::Cli::USAGE

    Cleanup "the tree"
    FileUtils.rm_rf(dir)
  end

  test "a tree without a closure takes the environment's gems — and fails when it has none" do
    Given "a source-checkout shape"
    dir = tool_tree(Dir.mktmpdir("ai-flow-exe-"), closure: false)

    When "running help under an empty gem environment"
    _out, err, status = run_exe(dir, "help")

    Then "the runtime gem was looked for in the environment, not in the tree"
    status == 1
    err.include?("sorbet-runtime")

    Cleanup "the tree"
    FileUtils.rm_rf(dir)
  end
end
