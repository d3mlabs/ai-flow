# frozen_string_literal: true

module AiFlow
  # Parses the delimiter-based output contract the batch prompt imposes on the
  # agent. Delimiters (not JSON) because the payload is a whole markdown
  # document — escaping it into JSON is where agent output goes to die.
  #
  #   <<<AI-FLOW:BODY>>>
  #   (full integrated document)
  #   <<<AI-FLOW:SEGMENT 1>>>
  #   (segment 1's answer / rewritten section)
  module AgentOutput
    BODY_DELIMITER = "<<<AI-FLOW:BODY>>>"
    SEGMENT_DELIMITER = /^<<<AI-FLOW:SEGMENT (\d+)>>>$/

    Parsed = Struct.new(:body, :segments, keyword_init: true)

    module_function

    # @param output [String] raw agent output
    # @return [Parsed] body (nil when absent) and segment-index → text map
    def parse(output)
      body = nil
      segments = {}
      current = nil
      buffer = []

      flush = lambda do
        text = buffer.join("\n").strip
        if current == :body
          body = text
        elsif current.is_a?(Integer)
          segments[current] = text
        end
        buffer = []
      end

      output.to_s.split("\n").each do |line|
        if line.strip == BODY_DELIMITER
          flush.call
          current = :body
        elsif (match = SEGMENT_DELIMITER.match(line.strip))
          flush.call
          current = Integer(match[1])
        else
          buffer << line
        end
      end
      flush.call

      Parsed.new(body: body, segments: segments)
    end
  end
end
