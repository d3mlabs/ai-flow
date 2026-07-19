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
  end
end
