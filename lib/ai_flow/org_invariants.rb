# typed: strict
# frozen_string_literal: true

module AiFlow
  # The org invariants block a /build prompt carries into fresh checkouts.
  #
  # In IDE sessions and long-lived checkouts, dev renders the always-on
  # invariants into .cursor/rules/org-invariants.mdc from its machine-local
  # knowledge cache (dev's hooks own that render). A /build worktree is
  # created fresh — gitignored files don't ride `git worktree add` — so the
  # rendered rule is never there; the prompt is the one surface we fully
  # control, and this class reads the same machine cache the render does.
  #
  # An unconfigured runner (no cache) injects nothing: dev ships only the
  # mechanism, and a machine without the knowledge repo has no invariants
  # to carry.
  class OrgInvariants
    extend T::Sig

    # Layout mirrors dev's Dev::Knowledge::Cache: the clone lives at
    # $XDG_DATA_HOME/dev/knowledge (~/.local/share/dev/knowledge) with the
    # always-on index at its root.
    INDEX_FILE = "index.md"

    # The heading the invariant lines live under in the knowledge index,
    # and where the next section cuts them off (same extraction as dev's
    # InvariantsRenderer).
    INVARIANTS_HEADING = /^## Invariants\b/
    SECTION_HEADING = /^## /

    # @param cache_dir [String] override for tests; defaults to the machine
    #   cache dev maintains
    sig { params(cache_dir: String).void }
    def initialize(cache_dir: default_cache_dir)
      @cache_dir = cache_dir
    end

    # @return [String, nil] the prompt section carrying the invariants, nil
    #   when the machine has no synced knowledge cache (or no invariants)
    sig { returns(T.nilable(String)) }
    def prompt_block
      lines = invariant_lines
      return nil unless lines

      <<~BLOCK.strip
        ORG INVARIANTS — always-on engineering rules for this organization (this fresh checkout has no generated .cursor/rules/org-invariants.mdc render):

        #{lines}

        Each → pointer is an on-demand skill installed under ~/.cursor/skills/ — read it before working in that entry's territory.
      BLOCK
    end

    private

    # The invariants section body, or nil when the cache, the index, or the
    # section doesn't exist — all normal states of the world, not errors.
    #
    # @return [String, nil]
    sig { returns(T.nilable(String)) }
    def invariant_lines
      index = File.join(@cache_dir, INDEX_FILE)
      return nil unless File.file?(index)

      section = []
      in_section = T.let(false, T::Boolean)
      File.read(index).each_line do |line|
        if line.match?(INVARIANTS_HEADING)
          in_section = true
        elsif in_section && line.match?(SECTION_HEADING)
          break
        elsif in_section
          section << line
        end
      end
      return nil unless in_section

      body = section.join.strip
      body.empty? ? nil : body
    end

    # @return [String]
    sig { returns(String) }
    def default_cache_dir
      data_home = ENV.fetch("XDG_DATA_HOME", File.join(Dir.home, ".local", "share"))
      File.join(data_home, "dev", "knowledge")
    end
  end
end
