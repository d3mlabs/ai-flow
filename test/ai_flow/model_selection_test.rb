# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "support/value_semantics_assertions"

transform!(RSpock::AST::Transformation)
class AiFlow::ModelSelectionTest < Minitest::Test
  include ValueSemanticsAssertions

  test "selections are value objects: handle-wise for Named, class-wise for AccountDefault" do
    Expect "the full value-equality contract holds"
    assert_value_semantics subject, equal_to: twin, unequal_to: [foreign]

    Where
    subject                                    | twin                                       | foreign
    AiFlow::ModelSelection::Named.new("gpt-5") | AiFlow::ModelSelection::Named.new("gpt-5") | AiFlow::ModelSelection::Named.new("opus")
    AiFlow::ModelSelection::Named.new("gpt-5") | AiFlow::ModelSelection::Named.new("gpt-5") | AiFlow::ModelSelection::AccountDefault.new
    AiFlow::ModelSelection::AccountDefault.new | AiFlow::ModelSelection::AccountDefault.new | AiFlow::ModelSelection::Named.new("gpt-5")
  end
end
