require("test_helper")

class RspockProbeTest < Minitest::Test
  (begin
    extend(RSpock::Declarative)
    test("probe inspect") {
      begin
        calls = [:a, 1], [:b, 2]
        File.write("/tmp/probe.txt", calls.inspect)
        assert_equal(true, true, "Expected \"true\" to be true")
      ensure
        (nil)
      end
    }
  rescue StandardError => e
    ::RSpock::BacktraceFilter.new.filter_exception(e)
    raise
  end)
end
