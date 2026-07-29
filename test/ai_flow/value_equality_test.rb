# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "support/value_semantics_assertions"

transform!(RSpock::AST::Transformation)
class AiFlow::ValueEqualityTest < Minitest::Test
  include ValueSemanticsAssertions

  # The memo member is deliberately excluded from equality — the
  # "irrelevant internals" case the derive must respect.
  class Coordinate
    extend T::Sig
    include AiFlow::ValueEquality::Derived

    def initialize(row:, column:)
      @row = row
      @column = column
      @render_memo = nil
    end

    attr_reader :row, :column

    # Populates the memo, mutating internal state that must never
    # participate in equality.
    def rendered = @render_memo ||= "(#{row},#{column})"

    sig { override.returns(T::Array[T.untyped]) }
    def equality_members = [row, column]
  end

  # Same member list as Coordinate, different class: proves the derive
  # keys equality and hash on the class, not just the member values.
  class Waypoint
    extend T::Sig
    include AiFlow::ValueEquality::Derived

    def initialize(row:, column:)
      @row = row
      @column = column
    end

    attr_reader :row, :column

    sig { override.returns(T::Array[T.untyped]) }
    def equality_members = [row, column]
  end

  test "a freeloading includer fails loudly instead of inheriting Object identity" do
    Given "a class including the interface without implementing it"
    freeloader = Class.new { include AiFlow::ValueEquality }.new

    Expect "==, eql?, and Hash-key use all raise instead of quietly comparing identity"
    assert_raises(NotImplementedError) { freeloader == freeloader }.message.include?("implement #==")
    assert_raises(NotImplementedError) { freeloader.eql?(freeloader) }.message.include?("implement #==")
    assert_raises(NotImplementedError) { { freeloader => 1 } }.message.include?("implement #hash")
  end

  test "Derived equality is memberwise over the declared members" do
    Expect "a single changed member — or a different class — breaks equality"
    assert_value_semantics Coordinate.new(row: 1, column: 2),
                           equal_to: Coordinate.new(row: 1, column: 2),
                           unequal_to: [variant]

    Where
    variant
    Coordinate.new(row: 9, column: 2)
    Coordinate.new(row: 1, column: 9)
    Waypoint.new(row: 1, column: 2)
  end

  test "memoized internals stay out of equality" do
    Given "a coordinate whose render memo has been populated"
    rendered = Coordinate.new(row: 1, column: 2)
    rendered.rendered

    Expect "it still satisfies the full contract against a pristine twin"
    assert_value_semantics rendered, equal_to: Coordinate.new(row: 1, column: 2)
  end

  test "every named includer in the codebase designs its own equality" do
    Given "all loaded classes that opted into the interface"
    # The sweep is the static check srb cannot do: Sorbet accepts Object's
    # ==/hash as satisfying any interface, so freeloading is only visible
    # by inspecting method owners. Anonymous classes are the raising-stub
    # fixtures above.
    includers = ObjectSpace.each_object(Class).select do |klass|
      klass < AiFlow::ValueEquality && !klass.name.nil?
    end

    When "collecting classes still on the raising stubs or Object identity"
    offenders = includers.select do |klass|
      [:==, :hash].any? do |method_name|
        [Object, AiFlow::ValueEquality].include?(klass.instance_method(method_name).owner)
      end
    end

    Then "the interface has includers and no freeloaders"
    !includers.empty?
    offenders == []
  end
end
