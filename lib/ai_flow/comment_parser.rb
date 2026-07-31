# typed: strict
# frozen_string_literal: true

module AiFlow
  # Parses a GitHub comment into command segments.
  #
  # Grammar (see the ai-flow plan, Component 4):
  # - Commands are recognized only at the start of a line: /ask, /edit, /split,
  #   /build, /learn (optionally with a configured prefix, e.g. "ai-" →
  #   /ai-ask), so prose like "the /build passes" never matches mid-line.
  # - A comment may batch several quote+command pairs (the review work unit):
  #   each command binds to the quote block immediately above it and owns the
  #   free text after it, up to the next quote block or command.
  # - Batches are limited to /ask and /edit; /split, /build, and /learn are
  #   lifecycle operations that must be a comment's only command.
  # - Flags select machine-actionable mode only (the system-wide grammar,
  #   plans#13): everything after them — the rest of the line, following
  #   lines, and the quote block above — is verbatim context for the agent.
  class CommentParser
    extend T::Sig

    # The comment-surface vocabulary — this boundary's own mapping of
    # command words to Command values. Serialization is context-dependent
    # (RepoConfig keeps its own table for YAML keys), so the word "ask" is
    # a parser concern, not a property of Command::Ask.
    COMMAND_WORDS = T.let(
      {
        "ask" => Command::Ask.new,
        "edit" => Command::Edit.new,
        "split" => Command::Split.new,
        "build" => Command::Build.new,
        "learn" => Command::Learn.new,
      }.freeze,
      T::Hash[String, Command],
    )

    # Batching is a dispatch policy (which commands may share a comment),
    # not a property of the commands themselves, so the list lives here.
    BATCHABLE_COMMANDS = T.let(
      [Command::Ask.new, Command::Edit.new].freeze,
      T::Array[Command],
    )

    class ParseError < StandardError; end

    # The table inverted, for display sites that speak this boundary's
    # vocabulary (the "/ask" in log prefixes and error text).
    WORDS_BY_COMMAND = T.let(COMMAND_WORDS.invert.freeze, T::Hash[Command, String])

    class << self
      extend T::Sig

      # @param command [AiFlow::Command]
      # @return [String] the comment word for the command
      # @raise [KeyError] for a command missing from the table
      sig { params(command: Command).returns(String) }
      def word_for(command)
        WORDS_BY_COMMAND.fetch(command)
      end
    end

    # One quote+command pair. `quote` is the anchor text (de-quoted, nil when
    # unscoped); `instruction` is the command line's remainder plus the free
    # text it owns (a prop: parsing appends owned lines as it walks); `flags`
    # are leading --options (e.g. /build --split); `end_line` is the 0-based
    # index of the last line the segment owns — the insertion point for its
    # interleaved result.
    class Segment < T::Struct
      const :command, Command
      const :flags, T::Array[String]
      const :quote, T.nilable(String)
      prop :instruction, String
      prop :end_line, Integer
    end

    # @param prefix [String] optional command prefix for adopters with clashing
    #   bots (we default to none, so commands are /ask etc.)
    sig { params(prefix: String).void }
    def initialize(prefix: "")
      @command_pattern = T.let(
        /\A\/#{Regexp.escape(prefix)}(#{COMMAND_WORDS.keys.join("|")})(?:\s+(.*))?\z/,
        Regexp,
      )
    end

    # @param body [String] the comment body
    # @return [Array<Segment>] parsed segments; empty when the comment holds no
    #   command (not an error — most comments are plain conversation)
    # @raise [ParseError] when /split or /build shares a comment with another
    #   command
    sig { params(body: String).returns(T::Array[Segment]) }
    def parse(body)
      segments = T.let([], T::Array[Segment])
      pending_quote = T.let([], T::Array[String])
      current_segment = T.let(nil, T.nilable(Segment))

      body.to_s.gsub("\r\n", "\n").split("\n", -1).each_with_index do |line, index|
        if (match = @command_pattern.match(line.rstrip))
          flags, instruction = split_flags(match[2].to_s.strip)
          segments << (current_segment = Segment.new(
            command: COMMAND_WORDS.fetch(T.must(match[1])),
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
    sig { params(rest: String).returns([T::Array[String], String]) }
    def split_flags(rest)
      tokens = rest.split(" ")
      flags = tokens.take_while { |token| token.start_with?("--") }
      [flags, tokens.drop(flags.size).join(" ")]
    end

    # @param lines [Array<String>] raw "> …" lines
    # @return [String, nil] the anchor text without quote markers
    sig { params(lines: T::Array[String]).returns(T.nilable(String)) }
    def dequote(lines)
      return nil if lines.empty?

      lines.map { |line| line.sub(/\A>\s?/, "") }.join("\n").strip
    end

    # @raise [ParseError] on invalid batches
    sig { params(segments: T::Array[Segment]).void }
    def validate!(segments)
      return if segments.size <= 1

      lifecycle = segments.map(&:command).reject { |command| BATCHABLE_COMMANDS.include?(command) }
      first_lifecycle = lifecycle.first
      return unless first_lifecycle

      raise ParseError,
        "/#{self.class.word_for(first_lifecycle)} must be a comment's only command — " \
        "batches are limited to /ask and /edit."
    end
  end
end
