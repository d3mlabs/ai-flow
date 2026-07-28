# typed: true
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
    class Error < StandardError; end

    PATH = ".github/ai-flow.yml"

    # @param workdir [String] repo checkout root
    # @return [RepoConfig]
    # @raise [Error] when the file exists but is not a YAML mapping
    def self.load(workdir)
      path = File.join(workdir, PATH)
      return new({}) unless File.exist?(path)

      parsed = YAML.safe_load(File.read(path))
      raise Error, "#{PATH} must be a YAML mapping" unless parsed.is_a?(Hash)

      new(parsed)
    rescue Psych::Exception => e
      raise Error, "#{PATH} is not valid YAML: #{e.message}"
    end

    # @param config [Hash]
    def initialize(config)
      @config = config
    end

    # Model policy: command name => model, plus an optional "default"
    # blanket. Unknown keys elsewhere in the file are ignored — it's the
    # adopter's file (same posture as the /split spec).
    #
    # @return [Hash]
    def models
      section = @config["models"]
      section.is_a?(Hash) ? section : {}
    end

    # The org knowledge repo ("owner/repo") learnings promote into — where
    # /learn --promote opens its add PR. ai-flow stays independent of dev's
    # knowledge_repo config (dev/ai-flow are deliberately separate), so the
    # adopter declares it here. nil when unset (promotion refuses with a
    # pointer rather than guessing).
    #
    # @return [String, nil]
    def knowledge_repo
      value = @config["knowledge_repo"]
      value.is_a?(String) && !value.strip.empty? ? value.strip : nil
    end

    # Whether /build runs an opportunistic learning-capture pass after a
    # successful build (the draft PR + human merge is the gate; the agent
    # drafts nothing when nothing generalizes). On by default — the loop is
    # the point — with an explicit off switch for repos that want quiet.
    #
    # @return [Boolean]
    def learn_on_build?
      learn["on_build"] != false
    end

    private

    # The optional `learn:` section (the build-capture switch). A
    # non-mapping value (or absence) means all defaults.
    #
    # @return [Hash]
    def learn
      section = @config["learn"]
      section.is_a?(Hash) ? section : {}
    end
  end
end
