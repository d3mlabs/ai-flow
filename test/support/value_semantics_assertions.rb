# typed: false — the assertion methods live on the host Minitest class.
# frozen_string_literal: true

# The value-equality contract — the laws no compiler checks. Rust hangs
# them on the Eq marker trait; Java tests them with EqualsVerifier; here
# they are one assertion, included per test class.
module ValueSemanticsAssertions
  # Asserts the full Eq promise on subject: equivalence relation with
  # equal_to, eql?/hash agreement, Hash-key interchangeability, and
  # strict unequality against unequal_to plus foreign types and nil.
  #
  # @param subject [Object] the instance under test
  # @param equal_to [Object, Array] instance(s) subject must equal —
  #   distinct objects, or every law passes vacuously via identity
  # @param unequal_to [Array] values that must compare unequal
  # @return [true] exactly true, so the call can stand alone as an RSpock
  #   Expect/Then statement (which asserts the statement evaluates to true)
  def assert_value_semantics(subject, equal_to:, unequal_to: [])
    equal = [subject, *(equal_to.is_a?(Array) ? equal_to : [equal_to])]

    # Precondition: identity satisfies every law vacuously.
    equal.combination(2) do |a, b|
      refute_same a, b, "equal_to must hold objects distinct from the subject"
    end

    equal.each do |a|
      assert a == a, "reflexivity violated: #{a.inspect} != itself"
    end

    # All-pairs equality is the observable content of transitivity: a
    # verifier can only sample instances, and every pair is the strongest
    # sample there is (the a == c "conclusion" is asserted directly).
    equal.combination(2) do |a, b|
      assert a == b, "expected #{a.inspect} == #{b.inspect}"
      assert b == a, "symmetry violated: #{b.inspect} != #{a.inspect}"
      assert a.eql?(b), "eql? disagrees with == for #{a.inspect} and #{b.inspect}"
      assert_equal a.hash, b.hash, "equal instances hash differently: #{a.inspect}, #{b.inspect}"
    end

    # The real lookup path: Hash uses eql? + hash together, so prove the
    # instances interchange as keys instead of trusting the methods alone.
    equal.drop(1).each do |other|
      assert_equal :hit, { subject => :hit }[other],
        "Hash lookup miss: #{other.inspect} does not find the entry keyed by #{subject.inspect}"
    end

    # Foreign types prove instance_of? strictness; nil the nil-safety.
    (unequal_to + [nil, Object.new, ""]).each do |other|
      equal.each do |a|
        refute a == other, "expected #{a.inspect} != #{other.inspect}"
        refute other == a, "symmetry violated: #{other.inspect} == #{a.inspect}"
        refute a.eql?(other), "eql? disagrees with == for #{a.inspect} and #{other.inspect}"
      end
    end

    true
  end
end
