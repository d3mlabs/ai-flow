# typed: strict
# frozen_string_literal: true

module AiFlow
  # A release series: the major of the tree's VERSION. Its tag (`v1`) is
  # the ref `dev deploy gh` moves to each deployed release of the series
  # and the one an adopter's caller workflow `uses:`: the reusable
  # workflows at that tag are the series' shell, and `ai-flow adopt`
  # writes the caller at it.
  class Series
    extend T::Sig
    include ValueEquality::Derived

    # The release's version, at the tree root — what `dev release` tags.
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

    sig { override.returns(T::Array[Object]) }
    def equality_members
      [@major]
    end
  end
end
