# typed: strict
# frozen_string_literal: true

module AiFlow
  # Value equality as deliberate class design: including this module makes
  # instances unusable for comparison until the class implements its own
  # `==` and `hash`, choosing exactly which members constitute identity.
  # This is Rust's PartialEq discipline retrofitted onto Ruby — no equality
  # until someone designs it.
  #
  # Ruby's universal Object#== makes the obvious mechanism (Sorbet abstract
  # methods) unenforceable: sorbet-runtime's abstract stub delegates to
  # `super` when one exists — and for ==/hash Object always provides one —
  # while `srb tc` likewise accepts the inherited Object implementations as
  # satisfying the abstract. So the stubs here are concrete and raise
  # unconditionally; a freeloading includer fails loudly on first
  # comparison or Hash insertion, and the value-equality sweep test (see
  # test/ai_flow/value_equality_test.rb) catches it at test time.
  #
  # The contract every implementation must satisfy — equivalence relation,
  # ==/eql? agreement, equal implies same hash — is asserted by
  # ValueSemanticsAssertions#assert_value_semantics.
  module ValueEquality
    extend T::Sig
    # Includers are ordinary Objects; Kernel gives the stubs raise and
    # self.class under srb without the experimental requires_ancestor.
    include Kernel

    # @param other [BasicObject]
    # @return [Boolean]
    # @raise [NotImplementedError] until the including class designs its own
    sig { overridable.params(other: BasicObject).returns(T::Boolean) }
    def ==(other)
      raise NotImplementedError, "#{self.class} includes ValueEquality: implement #== (and #hash) deliberately"
    end

    # @return [Integer]
    # @raise [NotImplementedError] until the including class designs its own
    sig { overridable.returns(Integer) }
    def hash
      raise NotImplementedError, "#{self.class} includes ValueEquality: implement #hash (and #==) deliberately"
    end

    # The one method with a single correct answer: Hash lookups use eql?,
    # and it must agree with ==. Overridable for the rare deliberate split
    # (Numeric's 1 == 1.0 but not 1.eql?(1.0) being the stdlib example).
    #
    # @param other [BasicObject]
    # @return [Boolean]
    sig { overridable.params(other: BasicObject).returns(T::Boolean) }
    def eql?(other) = self == other

    # The derive(PartialEq) analog: opt in explicitly, enumerate the
    # members, and == and hash both generate from that one list — so they
    # cannot drift apart. equality_members is member VALUES (ivar reads or
    # method calls, never symbols): under typed: strict either form makes a
    # typo'd member a static srb error, where a symbol list fetched
    # reflectively would silently compare nil == nil.
    #
    # A memoization ivar or other irrelevant internal simply stays off the
    # list; when equality is not memberwise at all, implement ==/hash by
    # hand against the parent module instead.
    module Derived
      extend T::Sig
      extend T::Helpers
      include ValueEquality
      abstract!

      # @param other [BasicObject]
      # @return [Boolean] whether other is the exact same class with equal members
      sig { override.params(other: BasicObject).returns(T::Boolean) }
      def ==(other)
        # T.unsafe: the param must type as BasicObject to stay
        # override-compatible with BasicObject#==, but instance_of? lives on
        # Object. No Object guard needed — sorbet-runtime's sig validation
        # itself calls is_a? on the argument, so a true BasicObject can
        # never reach this body. instance_of? (not is_a?): strict same-class
        # equality keeps == symmetric in the presence of subclasses.
        return false unless T.unsafe(other).instance_of?(self.class)

        equality_members == T.cast(other, Derived).equality_members
      end

      # @return [Integer] combines the class so distinct memberless types
      #   do not collide as Hash keys
      sig { override.returns(Integer) }
      def hash = [self.class, *equality_members].hash

      # The members that constitute identity — effectively the struct
      # declaration a compile-time derive would read. Elements are Object
      # (not BasicObject or T.anything) because the derive delegates == and
      # hash to every member, and Object is where both are guaranteed —
      # BasicObject lacks hash. That members implement them value-
      # semantically (Rust's recursive PartialEq bound) is not typeable;
      # assert_value_semantics covers that residue at test time.
      #
      # @return [Array<Object>] the member values, in a stable order
      sig { abstract.returns(T::Array[Object]) }
      def equality_members; end
    end
  end
end
