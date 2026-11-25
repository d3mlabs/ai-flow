# typed: strict
# frozen_string_literal: true

module AiFlow
  class Adoption
    # The adopting repo's pin on ai-flow in its `dependencies.rb`:
    # `gh "d3mlabs/ai-flow", "^1"`, the dependency the job's `dev up`
    # installs the dispatcher from. It is the other spelling of the caller
    # workflow's `@v1` — dev resolves `^1` through the same series tag — so
    # the two are converged together: absent, the pin is written (and a
    # manifest around it when the repo has none); present at another range,
    # it is re-pinned in place; present as a `tag:` or `sha:` pin, it is
    # the adopter's deliberate exact pin and is reported. Every write ends
    # in the same instruction, because a manifest edit is not a lock edit:
    # `dev deps update <name>` re-locks through the head.
    #
    # The repo must be a dev project (a `dev.yml`) for `dev up` to install
    # anything; without one the pin would be dead text, so that is a
    # finding, not a write.
    class DependencyPin
      extend T::Sig

      MANIFEST_PATH = "dependencies.rb"
      DEV_PROJECT_FILE = "dev.yml"

      # The release asset `dev release` attaches, as dev's `assets:` glob.
      ASSETS = "ai-flow-*.zip"

      # dev's `gh` directive in either spelling — the slug first, or a name
      # first with the slug under `github:`/`repo:` — with the requirement
      # as the second positional when there is one.
      DIRECTIVE = /^(?<lead>[ \t]*gh[ \t]+["'](?<first>[^"']+)["'])(?:[ \t]*,[ \t]*["'](?<requirement>[^"']*)["'])?(?<rest>.*)$/
      SLUG_KEYWORD = /\b(?:github|repo):[ \t]*["'](?<slug>[^"']+)["']/

      # The manifest's one block, and the column-0 `end` that closes it —
      # where a new group goes.
      DEFINE_LINE = /\ADev::Deps\.define do[ \t]*\z/
      CLOSING_LINE = /\Aend[ \t]*\z/

      # @param repository [String] `owner/repo` of the ai-flow being adopted
      #   — the reusable workflow's, so a fork's adopter pins the fork
      # @param series [Series]
      sig { params(repository: String, series: Series).void }
      def initialize(repository:, series:)
        @repository = repository
        @series = series
        @name = T.let(T.must(repository.split("/").last), String)
      end

      # @param checkout [String] the adopting repo's working tree
      # @return [Outcome]
      sig { params(checkout: String).returns(Outcome) }
      def converge(checkout)
        unless File.exist?(File.join(checkout, DEV_PROJECT_FILE))
          return Outcome::Finding.new(
            step: MANIFEST_PATH,
            detail: "the repo is not a dev project (no #{DEV_PROJECT_FILE}), so a job's `dev up` would install no lock",
            remedy: "add a #{DEV_PROJECT_FILE} (`name: <repo>`) and re-run adopt — it then writes the pin",
          )
        end

        path = File.join(checkout, MANIFEST_PATH)
        return write_manifest(path) unless File.exist?(path)

        lines = File.readlines(path, chomp: true)
        index = lines.index { |line| pins_ai_flow?(line) }
        return add_pin(path, lines) if index.nil?

        converge_directive(path, lines, index)
      end

      private

      # @param line [String]
      # @return [Boolean] whether the line is a `gh` directive on ai-flow
      sig { params(line: String).returns(T::Boolean) }
      def pins_ai_flow?(line)
        match = DIRECTIVE.match(line)
        return false if match.nil?

        first = T.must(match[:first])
        return first == @repository if first.include?("/")

        keyword = SLUG_KEYWORD.match(T.must(match[:rest]))
        !keyword.nil? && keyword[:slug] == @repository
      end

      # @param path [String]
      # @return [Outcome::Changed]
      sig { params(path: String).returns(Outcome::Changed) }
      def write_manifest(path)
        File.write(path, <<~RUBY)
          # typed: false
          # frozen_string_literal: true

          # Dependency manifest for dev: what a checkout of this repo installs with
          # `dev up`. Edit here, then `dev deps update` (re-lock) and `dev up`.
          require "dev/deps"

          Dev::Deps.define do
          #{pin_block.chomp}
          end
        RUBY
        Outcome::Changed.new(step: MANIFEST_PATH, detail: "written with #{directive} — #{relock}")
      end

      # @param path [String]
      # @param lines [Array<String>] the manifest, without a pin
      # @return [Outcome]
      sig { params(path: String, lines: T::Array[String]).returns(Outcome) }
      def add_pin(path, lines)
        closing_at = closing_line_of_define_block(lines)
        if closing_at.nil?
          return Outcome::Finding.new(
            step: MANIFEST_PATH,
            detail: "has no `Dev::Deps.define do … end` block to pin #{@repository} in",
            remedy: "add #{directive} inside the manifest's define block, then #{relock}",
          )
        end

        before = lines.take(closing_at)
        before << "" unless before.last.to_s.empty?
        File.write(path, "#{(before + pin_block.lines(chomp: true) + lines.drop(closing_at)).join("\n")}\n")
        Outcome::Changed.new(step: MANIFEST_PATH, detail: "pinned #{directive} — #{relock}")
      end

      # The column-0 `end` after `Dev::Deps.define do` — every member of
      # the block is indented by convention (rubocop's), so the first
      # unindented `end` closes it.
      #
      # @param lines [Array<String>]
      # @return [Integer, nil] its index, nil when the manifest has no such
      #   block
      sig { params(lines: T::Array[String]).returns(T.nilable(Integer)) }
      def closing_line_of_define_block(lines)
        define_at = lines.index { |line| DEFINE_LINE.match?(line) }
        return nil if define_at.nil?

        offset = lines.drop(define_at).index { |line| CLOSING_LINE.match?(line) }
        offset && define_at + offset
      end

      # @param path [String]
      # @param lines [Array<String>]
      # @param index [Integer] the line pinning ai-flow
      # @return [Outcome]
      sig { params(path: String, lines: T::Array[String], index: Integer).returns(Outcome) }
      def converge_directive(path, lines, index)
        line = lines.fetch(index)
        match = T.must(DIRECTIVE.match(line))
        requirement = match[:requirement]
        if requirement.nil?
          return Outcome::Finding.new(
            step: MANIFEST_PATH,
            detail: "pins #{@repository} exactly (`tag:` or `sha:`), not the series #{@series.requirement}",
            remedy: "pin #{directive} so a deploy reaches this repo on its next re-lock, then #{relock}",
          )
        end
        return Outcome::Settled.new(step: MANIFEST_PATH, detail: "pins #{@repository} #{requirement}") if requirement == @series.requirement

        lines[index] = "#{match[:lead]}, #{@series.requirement.inspect}#{match[:rest]}"
        File.write(path, "#{lines.join("\n")}\n")
        Outcome::Changed.new(
          step: MANIFEST_PATH,
          detail: "re-pinned #{@repository} from #{requirement.inspect} to #{@series.requirement.inspect} — #{relock}",
        )
      end

      # @return [String] the directive as the manifest spells it
      sig { returns(String) }
      def directive
        "`gh #{@repository.inspect}, #{@series.requirement.inspect}`"
      end

      # @return [String] what follows every write
      sig { returns(String) }
      def relock
        "run `dev deps update #{@name}` and commit it with deps.lock"
      end

      # The pin, with the group it lives in and the sentence an adopter
      # needs when reading their own manifest — indented as a member of the
      # define block.
      #
      # @return [String]
      sig { returns(String) }
      def pin_block
        block = <<~RUBY
          # ai-flow, the slash-command dispatcher this repo's agent jobs run
          # (`uses: …@#{@series.tag}` in .github/workflows/ai-commands.yml): a job's
          # `dev up` installs it from this lock, self-contained. `#{@series.requirement}` resolves
          # through the series head `#{@series.tag}`, the ref the caller workflow names, so
          # the two cannot disagree; `dev deps update #{@name}` takes a deploy, and
          # `ai-flow adopt` keeps both lines in step.
          group :agent do
            gh #{@repository.inspect}, #{@series.requirement.inspect}, assets: #{ASSETS.inspect}
          end
        RUBY
        block.lines.map { |line| "  #{line}" }.join
      end
    end
  end
end
