# frozen_string_literal: true

module AiFlow
  # Parses a GitHub comment into command segments.
  #
  # Grammar (see the ai-flow plan, Component 4):
  # - Commands are recognized only at the start of a line: /ask, /edit, /split,
  #   /build (optionally with a configured prefix, e.g. "ai-" → /ai-ask), so
  #   prose like "the /build passes" never matches mid-line.
  # - A comment may batch several quote+command pairs (the review work unit):
  #   each command binds to the quote block immediately above it and owns the
  #   free text after it, up to the next quote block or command.
  # - Batches are limited to /ask and /edit; /split and /build are lifecycle
  #   operations that must be a comment's only command.
  class CommentParser
    COMMANDS = %w[ask edit split build].freeze
    BATCHABLE_COMMANDS = %w[ask edit].freeze

    class ParseError < StandardError; end

    # One quote+command pair. `quote` is the anchor text (de-quoted, nil when
    # unscoped); `instruction` is the command line's remainder plus the free
    # text it owns; `flags` are leading --options (e.g. /build --split);
    # `end_line` is the 0-based index of the last line the segment owns —
    # the insertion point for its interleaved result.
    Segment = Struct.new(:command, :flags, :quote, :instruction, :end_line, keyword_init: true)

    # @param prefix [String] optional command prefix for adopters with clashing
    #   bots (we default to none, so commands are /ask etc.)
    def initialize(prefix: "")
      @command_pattern = /\A\/#{Regexp.escape(prefix)}(#{COMMANDS.join("|")})(?:\s+(.*))?\z/
    end

    # @param body [String] the comment body
    # @return [Array<Segment>] parsed segments; empty when the comment holds no
    #   command (not an error — most comments are plain conversation)
    # @raise [ParseError] when /split or /build shares a comment with another
    #   command
    def parse(body)
      segments = []
      pending_quote = []
      current_segment = nil

      body.to_s.gsub("\r\n", "\n").split("\n", -1).each_with_index do |line, index|
        if (match = @command_pattern.match(line.rstrip))
          flags, instruction = split_flags(match[2].to_s.strip)
          segments << (current_segment = Segment.new(
            command: match[1],
            flags: flags,
            quote: dequote(pending_quote),
            instruction: instruction,
            end_line: index,
          ))
          pending_quote = []
        elsif line.start_with?(">")
          # A new quote block ends the previous command's free text.
          current_segment = nil
          pending_quote << line
        elsif line.strip.empty?
          # Blank lines separate a quote from its command (GitHub's quote-reply
          # inserts one) without breaking the binding.
          current_segment.instruction = "#{current_segment.instruction}\n" if current_segment
        else
          pending_quote = [] unless pending_quote.empty?
          if current_segment
            current_segment.instruction = [current_segment.instruction, line].join("\n")
            current_segment.end_line = index
          end
        end
      end

      segments.each { |segment| segment.instruction = segment.instruction.to_s.strip }
      validate!(segments)
      segments
    end

    private

    # @param rest [String] everything after the command token
    # @return [Array(Array<String>, String)] leading --flags and the instruction
    def split_flags(rest)
      tokens = rest.split(" ")
      flags = tokens.take_while { |token| token.start_with?("--") }
      [flags, tokens.drop(flags.size).join(" ")]
    end

    # @param lines [Array<String>] raw "> …" lines
    # @return [String, nil] the anchor text without quote markers
    def dequote(lines)
      return nil if lines.empty?

      lines.map { |line| line.sub(/\A>\s?/, "") }.join("\n").strip
    end

    # @raise [ParseError] on invalid batches
    def validate!(segments)
      return if segments.size <= 1

      lifecycle = segments.map(&:command).reject { |command| BATCHABLE_COMMANDS.include?(command) }
      return if lifecycle.empty?

      raise ParseError,
            "/#{lifecycle.first} must be a comment's only command — " \
            "batches are limited to /ask and /edit."
    end
  end
end
