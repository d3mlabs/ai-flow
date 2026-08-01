# typed: strict
# frozen_string_literal: true

require "yaml"

module AiFlow
  # Per-repo ai-flow configuration, read from .github/ai-flow.yml in the
  # target repo checkout — the probot-style home for structured tool config
  # (workflow_call inputs are scalar-only, so nested policy can't ride the
  # caller workflow). Optional: a missing file is an empty config. Invalid
  # YAML fails loudly so a configuration error surfaces as the usual failure
  # panel instead of silently falling back to defaults.
  class RepoConfig
    extend T::Sig

    class Error < StandardError; end

    PATH = ".github/ai-flow.yml"

    # The models: section's vocabulary — this boundary's own mapping of
    # YAML keys to Command values, deliberately separate from
    # CommentParser's comment-word table (two boundaries, two tables; if
    # they ever diverge the drift is visible in two explicit constants).
    MODEL_KEYS = T.let(
      {
        "ask" => Command::Ask.new,
        "edit" => Command::Edit.new,
        "split" => Command::Split.new,
        "build" => Command::Build.new,
        "learn" => Command::Learn.new,
      }.freeze,
      T::Hash[String, Command],
    )

    class << self
      extend T::Sig

      # @param workdir [String] repo checkout root
      # @return [RepoConfig]
      # @raise [Error] when the file exists but is not a YAML mapping
      sig { params(workdir: String).returns(RepoConfig) }
      def load(workdir)
        path = File.join(workdir, PATH)
        return new({}) unless File.exist?(path)

        parsed = YAML.safe_load(File.read(path))
        raise Error, "#{PATH} must be a YAML mapping" unless parsed.is_a?(Hash)

        new(parsed)
      rescue Psych::Exception => e
        raise Error, "#{PATH} is not valid YAML: #{e.message}"
      end
    end

    # @param config [Hash]
    sig { params(config: T::Hash[T.untyped, T.untyped]).void }
    def initialize(config)
      @config = config
    end

    # Model policy, coerced at this boundary: only recognized command keys
    # with non-blank string values survive (unknown keys are ignored — it's
    # the adopter's file, same posture as the /split spec; blanks are unset
    # per link so `build: ""` falls through to the default). Values leave
    # as ModelSelection::Named — raw YAML strings don't outlive this class.
    #
    # @return [Hash{AiFlow::Command => AiFlow::ModelSelection::Named}]
    sig { returns(T::Hash[Command, ModelSelection::Named]) }
    def models
      models_section.each_with_object({}) do |(key, value), coerced|
        command = MODEL_KEYS[key.to_s]
        next unless command && value.is_a?(String) && !value.strip.empty?

        coerced[command] = ModelSelection::Named.new(value.strip)
      end
    end

    # The optional "default" blanket under models: — a config-schema
    # keyword, not a command, so it gets its own accessor.
    #
    # @return [AiFlow::ModelSelection::Named, nil] nil when unset (the
    #   resolver's chain then ends at AccountDefault)
    sig { returns(T.nilable(ModelSelection::Named)) }
    def default_model
      value = models_section["default"]
      value.is_a?(String) && !value.strip.empty? ? ModelSelection::Named.new(value.strip) : nil
    end

    # The org knowledge repo ("owner/repo") learnings promote into — where
    # /learn --promote opens its add PR. ai-flow stays independent of dev's
    # knowledge_repo config (dev/ai-flow are deliberately separate), so the
    # adopter declares it here. nil when unset (promotion refuses with a
    # pointer rather than guessing).
    #
    # @return [String, nil]
    sig { returns(T.nilable(String)) }
    def knowledge_repo
      value = @config["knowledge_repo"]
      value.is_a?(String) && !value.strip.empty? ? value.strip : nil
    end

    # Whether /build runs an opportunistic learning-capture pass after a
    # successful build (the proposal PR + human merge is the gate; the agent
    # drafts nothing when nothing generalizes). On by default — the loop is
    # the point — with an explicit off switch for repos that want quiet.
    #
    # @return [Boolean]
    sig { returns(T::Boolean) }
    def learn_on_build?
      learn["on_build"] != false
    end

    private

    # The raw models: mapping (or empty when absent/non-mapping).
    #
    # @return [Hash]
    sig { returns(T::Hash[T.untyped, T.untyped]) }
    def models_section
      section = @config["models"]
      section.is_a?(Hash) ? section : {}
    end

    # The optional `learn:` section (the build-capture switch). A
    # non-mapping value (or absence) means all defaults.
    #
    # @return [Hash]
    sig { returns(T::Hash[T.untyped, T.untyped]) }
    def learn
      section = @config["learn"]
      section.is_a?(Hash) ? section : {}
    end
  end
end
