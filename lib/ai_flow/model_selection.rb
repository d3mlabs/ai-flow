# typed: strict
# frozen_string_literal: true

module AiFlow
  # The outcome of model resolution as a sealed value-object hierarchy: a
  # named handle, or the CLI's account default when no policy resolved.
  # Resolvers (Agent#model_for) coerce to this before returning — the
  # nil-means-default convention and its "cursor default" sentinel string
  # died here. Display words are context-dependent, so each boundary owns
  # its rendering (Agent's log label, ResultWriter's footer note); the
  # type carries no strings beyond the handle itself.
  #
  # sealed! makes case dispatch exhaustive: a third selection kind fails
  # `srb tc` at every `T.absurd`-terminated case site until handled.
  module ModelSelection
    extend T::Helpers
    include ValueEquality
    sealed!

    # An explicit handle from repo config or the AI_FLOW_MODEL override.
    # Unverified by design: ai-flow relays what the adopter wrote and the
    # CLI stays the authority that rejects unknown handles.
    class Named
      extend T::Sig
      include ModelSelection
      include ValueEquality::Derived

      # @return [String] the model handle as configured
      sig { returns(String) }
      attr_reader :handle

      # @param handle [String]
      sig { params(handle: String).void }
      def initialize(handle)
        @handle = handle
      end

      sig { override.returns(T::Array[T.untyped]) }
      def equality_members = [handle]
    end

    # No policy resolved anywhere in the chain — the run passes no --model
    # flag and the CLI applies its account default.
    class AccountDefault
      extend T::Sig
      include ModelSelection
      include ValueEquality::Derived

      # Stateless: memberwise equality over no members is class identity.
      sig { override.returns(T::Array[T.untyped]) }
      def equality_members = []
    end
  end
end
