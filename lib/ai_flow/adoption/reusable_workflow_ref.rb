# typed: strict
# frozen_string_literal: true

module AiFlow
  class Adoption
    # What a caller workflow's job `uses:` — GitHub's reference to a reusable
    # workflow, `{owner}/{repo}/.github/workflows/{file}@{ref}`. Two parts
    # matter to adoption: the workflow (which repo's file), and the ref it
    # resolves at. The same workflow at another ref is a pin to converge;
    # another workflow is the adopter's own choice, reported.
    class ReusableWorkflowRef
      extend T::Sig
      include ValueEquality::Derived

      # The text is not `owner/repo/path@ref`.
      class InvalidReferenceError < StandardError; end

      SHAPE = %r{\A(?<owner>[^/@\s]+)/(?<repo>[^/@\s]+)/(?<path>[^@\s]+)@(?<ref>\S+)\z}

      # @return [String] `owner/repo` — the repository the workflow lives in
      sig { returns(String) }
      attr_reader :repository

      # @return [String] the workflow's path in that repository
      sig { returns(String) }
      attr_reader :path

      # @return [String] the ref it resolves at — a branch, a tag, a SHA
      sig { returns(String) }
      attr_reader :ref

      # @param repository [String]
      # @param path [String]
      # @param ref [String]
      sig { params(repository: String, path: String, ref: String).void }
      def initialize(repository:, path:, ref:)
        @repository = repository
        @path = path
        @ref = ref
      end

      class << self
        extend T::Sig

        # @param text [String] the `uses:` value
        # @return [ReusableWorkflowRef]
        # @raise [InvalidReferenceError]
        sig { params(text: String).returns(ReusableWorkflowRef) }
        def parse(text)
          match = SHAPE.match(text) or raise InvalidReferenceError, "#{text.inspect} is not owner/repo/path@ref"
          new(repository: "#{match[:owner]}/#{match[:repo]}", path: T.must(match[:path]), ref: T.must(match[:ref]))
        end
      end

      # The same workflow at another ref.
      #
      # @param ref [String]
      # @return [ReusableWorkflowRef]
      sig { params(ref: String).returns(ReusableWorkflowRef) }
      def at(ref)
        self.class.new(repository: @repository, path: @path, ref: ref)
      end

      # @param other [ReusableWorkflowRef]
      # @return [Boolean] whether both name the same file of the same repo
      sig { params(other: ReusableWorkflowRef).returns(T::Boolean) }
      def same_workflow?(other)
        @repository == other.repository && @path == other.path
      end

      # @return [String] the `uses:` spelling
      sig { returns(String) }
      def to_s
        "#{@repository}/#{@path}@#{@ref}"
      end

      sig { override.returns(T::Array[Object]) }
      def equality_members
        [@repository, @path, @ref]
      end
    end
  end
end
