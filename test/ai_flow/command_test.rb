# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "support/value_semantics_assertions"

transform!(RSpock::AST::Transformation)
class AiFlow::CommandTest < Minitest::Test
  include ValueSemanticsAssertions

  test "leaves are value objects: equal within a class, unequal across" do
    Expect "the full value-equality contract holds"
    assert_value_semantics command_class.new,
      equal_to: command_class.new,
      unequal_to: [other_class.new]

    Where
    command_class          | other_class
    AiFlow::Command::Ask   | AiFlow::Command::Edit
    AiFlow::Command::Edit  | AiFlow::Command::Ask
    AiFlow::Command::Split | AiFlow::Command::Build
    AiFlow::Command::Build | AiFlow::Command::Learn
    AiFlow::Command::Learn | AiFlow::Command::Split
  end
end
