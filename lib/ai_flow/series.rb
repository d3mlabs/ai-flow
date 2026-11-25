# typed: strict
# frozen_string_literal: true

module AiFlow
  # A release series: the major of the tree's VERSION, and the one
  # constraint every consumer of ai-flow follows — this major, any minor or
  # patch. It has two spellings because it crosses two doors: the series
  # tag an adopter's caller workflow `uses:` (`v1`, the ref `dev deploy gh`
  # moves to each deployed release of the series) and the range the
  # adopter's dependencies.rb pins (`^1`, which dev resolves through that
  # same tag). The two must agree; `ai-flow adopt` writes both from here.
  class Series
    extend T::Sig
    include ValueEquality::Derived

    # The release's version, at the tree root — what `dev release` tags and
    # what an adopter's lock pins.
    VERSION_FILE = "VERSION"

    # The file holds no `MAJOR.MINOR.PATCH`.
    class InvalidVersionError < StandardError; end

    # @return [Integer]
    sig { returns(Integer) }
    attr_reader :major

    # @param major [Integer]
    sig { params(major: Integer).void }
    def initialize(major:)
      @major = major
    end

    class << self
      extend T::Sig

      # The series of the tree at +root+, from its VERSION file.
      #
      # @param root [String] the ai-flow tree
      # @return [Series]
      # @raise [InvalidVersionError] when VERSION is not a semver version
      sig { params(root: String).returns(Series) }
      def of_tree(root)
        parse(File.read(File.join(root, VERSION_FILE)))
      end

      # @param version [String] a semver version, `1.1.0`
      # @return [Series]
      # @raise [InvalidVersionError] when the text is not one
      sig { params(version: String).returns(Series) }
      def parse(version)
        match = /\A(?<major>\d+)\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/.match(version.strip) or
          raise InvalidVersionError, "#{version.strip.inspect} is not a MAJOR.MINOR.PATCH version"
        new(major: Integer(T.must(match[:major])))
      end
    end

    # The series tag: what `uses: …@<tag>` resolves and `dev deploy gh` moves.
    #
    # @return [String] `v1`
    sig { returns(String) }
    def tag
      "v#{@major}"
    end

    # The same constraint as a dependencies.rb range.
    #
    # @return [String] `^1`
    sig { returns(String) }
    def requirement
      "^#{@major}"
    end

    sig { override.returns(T::Array[Object]) }
    def equality_members
      [@major]
    end
  end
end
