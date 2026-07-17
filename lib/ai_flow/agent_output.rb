# frozen_string_literal: true

module AiFlow
  # Parses the delimiter-based output contract the batch prompt imposes on the
  # agent. Delimiters (not JSON) because a segment's payload can be multi-line
  # markdown — escaping it into JSON is where agent output goes to die.
  #
  #   <<<AI-FLOW:SEGMENT 1>>>
  #   (segment 1's answer / edit summary)
  module AgentOutput
    SEGMENT_DELIMITER = /^<<<AI-FLOW:SEGMENT (\d+)>>>$/

    Parsed = Struct.new(:segments, keyword_init: true)

    module_function

    # @param output [String] raw agent output
    # @return [Parsed] segment-index → text map
    def parse(output)
      segments = {}
      current = nil
      buffer = []

      flush = lambda do
        segments[current] = buffer.join("\n").strip if current
        buffer = []
      end

      output.to_s.split("\n").each do |line|
        if (match = SEGMENT_DELIMITER.match(line.strip))
          flush.call
          current = Integer(match[1])
        else
          buffer << line
        end
      end
      flush.call

      Parsed.new(segments: segments)
    end
  end
end
