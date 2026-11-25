# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

transform!(RSpock::AST::Transformation)
class AiFlow::Adoption::DependencyPinTest < Minitest::Test
  SERIES = AiFlow::Series.new(major: 1)
  RELOCK = "run `dev deps update ai-flow` and commit it with deps.lock"
  PIN_LINE = '    gh "d3mlabs/ai-flow", "^1", assets: "ai-flow-*.zip"'

  # A manifest in the shape every org repo's has: a header, the define
  # block with a Ruby pin and a group, a constant after it (dev's own
  # manifest ends that way, so the file's last `end` is not the block's).
  MANIFEST = <<~RUBY
    # typed: false
    # frozen_string_literal: true

    require "dev/deps"

    Dev::Deps.define do
      ruby "4.0.6"

      group(:test) do
        gem "minitest"
      end
    end

    BUNDLER_VERSION = ">= 2.1" unless defined?(BUNDLER_VERSION)
  RUBY

  # The step against a checkout carrying `manifest` at dependencies.rb
  # (nothing when nil), a dev project unless said otherwise.
  def converge(manifest, dev_project: true, series: SERIES)
    Dir.mktmpdir("ai-flow-adopt-") do |checkout|
      File.write(File.join(checkout, "dev.yml"), "name: widgets\n") if dev_project
      File.write(File.join(checkout, "dependencies.rb"), manifest) unless manifest.nil?
      pin = AiFlow::Adoption::DependencyPin.new(repository: "d3mlabs/ai-flow", series: series)
      outcome = pin.converge(checkout)
      path = File.join(checkout, "dependencies.rb")
      return [outcome, File.exist?(path) ? File.read(path) : nil]
    end
  end

  test "a repo that is not a dev project gets a finding and no manifest: dev up would install nothing there" do
    When "converging a checkout with no dev.yml"
    outcome, written = converge(nil, dev_project: false)

    Then
    written.nil?
    outcome.is_a?(AiFlow::Adoption::Outcome::Finding)
    outcome.detail.include?("not a dev project (no dev.yml)")
    outcome.remedy.include?("add a dev.yml")
  end

  test "an absent manifest is written around the pin, as a define block dev loads" do
    When "converging a dev project with no dependencies.rb"
    outcome, written = converge(nil)

    Then "the manifest carries the pin in its group and the outcome says to re-lock"
    written.start_with?("# typed: false\n# frozen_string_literal: true\n")
    written.include?("require \"dev/deps\"\n\nDev::Deps.define do\n")
    written.include?("  group :agent do\n#{PIN_LINE}\n  end\nend\n")
    written.end_with?("end\n")
    outcome == AiFlow::Adoption::Outcome::Changed.new(
      step: "dependencies.rb",
      detail: "written with `gh \"d3mlabs/ai-flow\", \"^1\"` — #{RELOCK}",
    )
  end

  test "a manifest without the pin gains it before the define block's closing end, the rest untouched" do
    When "converging over the org-shaped manifest"
    outcome, after = converge(MANIFEST)

    Then "the group lands inside the block, after a blank line, and the trailing constant stays last"
    lines = after.lines(chomp: true)
    comment_at = lines.index("  # ai-flow, the slash-command dispatcher this repo's agent jobs run")
    group_at = lines.index("  group :agent do")
    lines.fetch(comment_at - 1) == ""
    comment_at > lines.index("  group(:test) do")
    group_at > comment_at
    lines.fetch(group_at + 1) == PIN_LINE
    lines.fetch(group_at + 2) == "  end"
    lines.fetch(group_at + 3) == "end"
    after.end_with?("end\n\nBUNDLER_VERSION = \">= 2.1\" unless defined?(BUNDLER_VERSION)\n")
    after.include?("  ruby \"4.0.6\"\n")
    outcome == AiFlow::Adoption::Outcome::Changed.new(
      step: "dependencies.rb",
      detail: "pinned `gh \"d3mlabs/ai-flow\", \"^1\"` — #{RELOCK}",
    )
  end

  test "a manifest already pinning the series is settled and left alone: #{spelling}" do
    Given "the pin in that spelling"
    manifest = MANIFEST.sub("  ruby \"4.0.6\"\n", "  ruby \"4.0.6\"\n  #{spelling}\n")

    When
    outcome, after = converge(manifest)

    Then
    after == manifest
    outcome == AiFlow::Adoption::Outcome::Settled.new(step: "dependencies.rb", detail: "pins d3mlabs/ai-flow ^1")

    Where
    spelling
    'gh "d3mlabs/ai-flow", "^1", assets: "ai-flow-*.zip"'
    "gh 'd3mlabs/ai-flow', '^1', assets: 'ai-flow-*.zip'"
    'gh "ai-flow", "^1", github: "d3mlabs/ai-flow", assets: "ai-flow-*.zip"'
    'gh "dispatcher", "^1", repo: "d3mlabs/ai-flow", assets: "ai-flow-*.zip"'
  end

  test "a pin at another range (#{range.inspect}) is re-pinned to the series in place" do
    Given "a manifest pinning ai-flow at that range, with its own options"
    line = "  gh \"d3mlabs/ai-flow\", #{range.inspect}, assets: \"ai-flow-*.zip\", host: :linux"
    manifest = MANIFEST.sub("  ruby \"4.0.6\"\n", "  ruby \"4.0.6\"\n#{line}\n")

    When
    outcome, after = converge(manifest)

    Then "only the requirement changed"
    after == manifest.sub(line, "  gh \"d3mlabs/ai-flow\", \"^1\", assets: \"ai-flow-*.zip\", host: :linux")
    outcome == AiFlow::Adoption::Outcome::Changed.new(
      step: "dependencies.rb",
      detail: "re-pinned d3mlabs/ai-flow from #{range.inspect} to \"^1\" — #{RELOCK}",
    )

    Where
    range
    "1.0.0"
    "~1.0"
    ">=1 <2"
    "^0.9"
  end

  test "a pin at the previous major is re-pinned to the current one" do
    Given "a manifest at ^1 and a tree at 2.0.0"
    manifest = MANIFEST.sub("  ruby \"4.0.6\"\n", "  ruby \"4.0.6\"\n  gh \"d3mlabs/ai-flow\", \"^1\", assets: \"ai-flow-*.zip\"\n")

    When
    _outcome, after = converge(manifest, series: AiFlow::Series.new(major: 2))

    Then
    after.include?("  gh \"d3mlabs/ai-flow\", \"^2\", assets: \"ai-flow-*.zip\"\n")
  end

  test "an exact pin (tag: or sha:) is the adopter's and is reported, not rewritten" do
    Given "a manifest pinning a tag"
    line = '  gh "d3mlabs/ai-flow", tag: "v1.0.0", assets: "ai-flow-*.zip"'
    manifest = MANIFEST.sub("  ruby \"4.0.6\"\n", "  ruby \"4.0.6\"\n#{line}\n")

    When
    outcome, after = converge(manifest)

    Then
    after == manifest
    outcome.is_a?(AiFlow::Adoption::Outcome::Finding)
    outcome.detail == "pins d3mlabs/ai-flow exactly (`tag:` or `sha:`), not the series ^1"
    outcome.remedy.include?("`gh \"d3mlabs/ai-flow\", \"^1\"`")
  end

  test "another repo's gh pin is not ai-flow's" do
    Given "a manifest pinning a different gh dependency"
    manifest = MANIFEST.sub("  ruby \"4.0.6\"\n", "  ruby \"4.0.6\"\n  gh \"d3mlabs/unreal-engine\", \"^5\", assets: \"*.zip\"\n")

    When
    outcome, after = converge(manifest)

    Then "ai-flow's pin is added beside it"
    outcome.is_a?(AiFlow::Adoption::Outcome::Changed)
    after.include?("  gh \"d3mlabs/unreal-engine\", \"^5\", assets: \"*.zip\"\n")
    after.include?(PIN_LINE)
  end

  test "a manifest with no define block to pin in is a finding carrying the line to add" do
    Given "a dependencies.rb that is not dev's shape"
    manifest = "require \"dev/deps\"\n\nDev::Deps.define { ruby \"4.0.6\" }\n"

    When
    outcome, after = converge(manifest)

    Then
    after == manifest
    outcome.is_a?(AiFlow::Adoption::Outcome::Finding)
    outcome.detail == "has no `Dev::Deps.define do … end` block to pin d3mlabs/ai-flow in"
    outcome.remedy.include?("`gh \"d3mlabs/ai-flow\", \"^1\"`")
    outcome.remedy.include?(RELOCK)
  end
end
