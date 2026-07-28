# typed: strict
# frozen_string_literal: true

module AiFlow
  # Parses the delimiter-based output contract the batch prompt imposes on the
  # agent. Delimiters (not JSON) because a segment's payload can be multi-line
  # markdown — escaping it into JSON is where agent output goes to die.
  #
  #   <<<AI-FLOW:SEGMENT 1>>>
  #   (segment 1's answer / edit summary)
  module AgentOutput
    # Sorbet models bare modules without Object's ancestry, so Kernel methods
    # (lambda, Integer) need the explicit include (srb.help/7003).
    include Kernel
    extend T::Sig

    SEGMENT_DELIMITER = /<<<AI-FLOW:SEGMENT (\d+)>>>/

    # Segment-index → text map.
    class Parsed < T::Struct
      const :segments, T::Hash[Integer, String]
    end

    module_function

    # @param output [String] raw agent output
    # @return [Parsed] segment-index → text map
    sig { params(output: String).returns(Parsed) }
    def parse(output)
      segments = T.let({}, T::Hash[Integer, String])
      current = T.let(nil, T.nilable(Integer))
      buffer = []

      flush = lambda do
        segments[current] = buffer.join("\n").strip if current
        buffer = []
      end

      normalize_delimiters(output).split("\n").each do |line|
        if (match = SEGMENT_DELIMITER.match(line.strip)) && match[0] == line.strip
          flush.call
          current = Integer(match[1])
        else
          buffer << line
        end
      end
      flush.call

      Parsed.new(segments: segments)
    end

    # The agent CLI's result field concatenates progress narration, observed
    # running straight into a delimiter mid-line ("…done.<<<AI-FLOW:SEGMENT
    # 1>>>"). Force every delimiter onto its own line before line-wise parsing.
    #
    # @param output [String]
    # @return [String]
    sig { params(output: String).returns(String) }
    def normalize_delimiters(output)
      output.to_s.gsub(SEGMENT_DELIMITER) { "\n#{Regexp.last_match(0)}\n" }
    end
  end
end
