# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"

transform!(RSpock::AST::Transformation)
class AiFlow::RunnerSlotTest < Minitest::Test
  # dev#470 enrolls a host's N slots as N runners; dev writes which one a
  # job landed on into that slot's service env (AI_FLOW_RUNNER_SLOT),
  # because only dev knows the naming (a hostname may itself end in -2).
  # ai-flow keys per-slot state by it — and slot 1 keeps every path it had
  # before slots existed, so nothing warm is evicted on upgrade.
  test "from_env reads the slot dev wrote; absent means the first slot" do
    Expect
    AiFlow::RunnerSlot.from_env(env).number == number
    AiFlow::RunnerSlot.from_env(env).suffix == suffix

    Where
    env                            | number | suffix
    {}                             | 1      | ""
    { "AI_FLOW_RUNNER_SLOT" => "" }  | 1      | ""
    { "AI_FLOW_RUNNER_SLOT" => "1" } | 1      | ""
    { "AI_FLOW_RUNNER_SLOT" => "2" } | 2      | "-2"
    { "AI_FLOW_RUNNER_SLOT" => "12" } | 12    | "-12"
  end

  test "a slot that is not a positive integer fails closed — dev wrote it, so garbage is a broken host" do
    Expect
    error = assert_raises(AiFlow::RunnerSlot::InvalidSlotError) { AiFlow::RunnerSlot.from_env({ "AI_FLOW_RUNNER_SLOT" => value }) }
    error.message.include?(value)

    Where
    value
    "0"
    "-1"
    "two"
    "1.5"
  end
end
