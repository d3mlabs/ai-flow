# typed: strict
# frozen_string_literal: true

module AiFlow
  # The command vocabulary as a sealed value-object hierarchy. The type
  # carries no strings: serialization is context-dependent, so each
  # boundary owns its own vocabulary table — CommentParser maps comment
  # words ("/ask") to instances, RepoConfig maps model-policy YAML keys.
  # Renaming a user-facing word touches one boundary table; every identity
  # comparison and dispatch in between stays untouched.
  #
  # sealed! makes case dispatch exhaustive: a new command added here fails
  # `srb tc` at every `T.absurd`-terminated case site until handled.
  module Command
    extend T::Sig
    extend T::Helpers
    include ValueEquality
    sealed!

    # A command's identity is its class — the leaves are stateless, so this
    # is the hierarchy's hand-written equality, designed once at the root.
    #
    # @param other [BasicObject]
    # @return [Boolean] whether other is the exact same leaf class
    sig { override.params(other: BasicObject).returns(T::Boolean) }
    def ==(other)
      # T.unsafe: the param must type as BasicObject to stay
      # override-compatible with BasicObject#==, but instance_of? lives on
      # Object. No guard needed — sorbet-runtime's sig validation itself
      # calls is_a? on the argument, so a true BasicObject can never reach
      # this body. instance_of? (not is_a?): every Command leaf includes
      # this module, so an ancestry check would equate distinct commands.
      T.unsafe(other).instance_of?(self.class)
    end

    # @return [Integer] the class's hash, matching class-identity equality
    sig { override.returns(Integer) }
    def hash = self.class.hash

    # Answer a question on the thread; no working-tree changes.
    class Ask
      include Command
    end

    # Edit the plan document in place.
    class Edit
      include Command
    end

    # Split a plan issue into sub-issues.
    class Split
      include Command
    end

    # Build a plan (or sub-issue) into a PR.
    class Build
      include Command
    end

    # Capture or promote a learning.
    class Learn
      include Command
    end
  end
end
