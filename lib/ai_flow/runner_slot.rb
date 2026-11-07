# typed: strict
# frozen_string_literal: true

module AiFlow
  # Which of a host's runner slots this job landed on (dev#470: a host
  # offering N jobs at once enrolls N runners — slot 1 is `<name>`, slot n
  # is `<name>-<n>`). dev writes the number into each slot's service env as
  # AI_FLOW_RUNNER_SLOT when it registers the slot, the same way it writes
  # AI_FLOW_AGENT_USER: only dev knows the naming (a hostname may itself end
  # in `-2`), so ai-flow never parses RUNNER_NAME for it.
  #
  # Per-slot state — the agent's gem home, a persistent workspace — is keyed
  # by #suffix, and slot 1's suffix is empty: every path slot 1 uses is the
  # path the host used before slots existed, so an upgrade evicts nothing
  # warm (ai-flow#116).
  class RunnerSlot
    extend T::Sig

    # The variable dev writes into the slot's runner service env.
    ENV_KEY = "AI_FLOW_RUNNER_SLOT"

    # dev wrote the slot, so a value that is not a positive integer is a
    # broken host, not a preference — fail closed.
    class InvalidSlotError < StandardError; end

    # @return [Integer] 1-based
    sig { returns(Integer) }
    attr_reader :number

    class << self
      extend T::Sig

      # @param env [Hash{String => String}] process env (injectable)
      # @return [RunnerSlot] the slot dev recorded; the first when none
      # @raise [InvalidSlotError]
      sig { params(env: T::Hash[String, T.nilable(String)]).returns(RunnerSlot) }
      def from_env(env = ENV.to_h)
        raw = env[ENV_KEY].to_s.strip
        return first if raw.empty?

        number = Integer(raw, 10)
        raise InvalidSlotError, "#{ENV_KEY}=#{raw} is not a slot number (1, 2, …)" if number < 1

        new(number: number)
      rescue ArgumentError
        raise InvalidSlotError, "#{ENV_KEY}=#{raw} is not a slot number (1, 2, …)"
      end

      # @return [RunnerSlot] slot 1 — the one every host has
      sig { returns(RunnerSlot) }
      def first
        new(number: 1)
      end
    end

    # @param number [Integer] 1-based
    sig { params(number: Integer).void }
    def initialize(number:)
      @number = number
    end

    # @return [Boolean] whether this is the slot every host has
    sig { returns(T::Boolean) }
    def first?
      @number == 1
    end

    # What per-slot state appends to the path slot 1 uses: nothing for
    # slot 1, `-<n>` for the rest — dev's own slot-naming shape.
    #
    # @return [String]
    sig { returns(String) }
    def suffix
      first? ? "" : "-#{@number}"
    end
  end
end
