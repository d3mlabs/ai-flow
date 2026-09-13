# typed: strict
# frozen_string_literal: true

module AiFlow
  # Denial surfacing (plans#26 WS3, plans#33): the OS-user split must not
  # create silent dead-ends, so when a permission boundary blocks useful
  # work the run surfaces it as a proposal a human judges — permission never
  # widens silently or mid-run.
  #
  # Two collection channels feed one renderer. Declared (primary): the
  # isolated-mode prompt carries a contract line and the agent states
  # `WANTED: <path or capability> — <why>` in its final output; Agent
  # extracts those lines (and strips them, so structured outputs like batch
  # segments never leak them into comment panels). Observed
  # (corroboration): denial signatures in tool output and rejected
  # permission requests, marked observed rather than declared.
  #
  # The renderer speaks the triage ladder: a want is resolved through the
  # declarative layers — the org Brewfile or the repo's dependencies.rb —
  # never through one box's ACLs. Ready-to-apply diffs (draft PRs) arrive
  # with plans#31's quarantined-discovery channel; until then the menu is
  # rendered as guidance. Expensive derived caches and authority-bearing
  # endpoints (shared DDC, container engines) get the category-4/5 note:
  # they are covered by design and never become widening proposals.
  class Denials
    extend T::Sig

    # One surfaced boundary hit: something the agent wanted and could not
    # reach. channel is :declared (a WANTED line) or :observed (a denial
    # signature in tool output, or a rejected permission request).
    class Want
      extend T::Sig
      include ValueEquality::Derived

      # @return [String] the path or capability that was out of reach
      sig { returns(String) }
      attr_reader :subject

      # @return [String] why it would have helped ("" when unstated)
      sig { returns(String) }
      attr_reader :reason

      # @return [Symbol] :declared or :observed
      sig { returns(Symbol) }
      attr_reader :channel

      # @param subject [String]
      # @param reason [String]
      # @param channel [Symbol] :declared or :observed
      sig { params(subject: String, reason: String, channel: Symbol).void }
      def initialize(subject:, reason:, channel:)
        @subject = subject
        @reason = reason
        @channel = channel
      end

      # @return [Array<Object>]
      sig { override.returns(T::Array[Object]) }
      def equality_members = [@subject, @reason, @channel]
    end

    # The declared channel's line form, anchored to the line start so prose
    # mentioning the word never collects.
    WANTED_LINE = /\A\s*WANTED:\s*(?<rest>.+?)\s*\z/

    # Subject/reason separators, em dash first (the contract's form), the
    # ASCII fallback second.
    SEPARATORS = T.let([" — ", " -- "].freeze, T::Array[String])

    # The observed channel's tool-output signatures (plans#26 WS3). The
    # unix denial family only — a permission wall the OS put up, not an
    # application-level 403.
    DENIAL_LINE = /Permission denied|permission denied|Operation not permitted|EACCES|EPERM/

    # GitHub-API write denials are the read-only agent token working as
    # designed (plans#25), never a boundary want.
    GITHUB_403 = /api\.github\.com|github\.com\/graphql|HTTP(?:\/[\d.]+)?\s*403/i

    # An absolute path inside a denial line — the deduplication key when
    # parseable. #observed_in takes the LAST match in the line:
    # runtime errno crashes (ruby/node/python) lead with the source frame
    # and trail with the denied path, so the first match names the code
    # that tripped over the boundary, not the boundary (caught live at the
    # plans#36 ceremony — the frame path also dodged the category-4/5
    # classifier). Single-path shell denials are unaffected.
    TOUCHED_PATH = %r{/[A-Za-z0-9_./@+~-]+}

    # Subjects resolved by design rather than by widening (plans#26 access
    # categories 4–5): the shared data root (dev's DataRoot::SHARED_ROOT —
    # cross-repo constant, duplicated knowingly), DDC trees, and sockets /
    # container-engine endpoints.
    CATEGORY_NOTE_PATTERNS = T.let(
      [
        %r{\A/Users/Shared/dev(/|\z)},
        /\bddc\b/i,
        /\.sock\b/,
        /\bsocket\b/i,
        /\bdocker\b/i,
        /\bcolima\b/i,
      ].freeze,
      T::Array[Regexp],
    )

    class << self
      extend T::Sig

      # The isolated-mode prompt contract (empty when isolation is off, so
      # non-split hosts see zero prompt change). Appended by Agent#launch to
      # every pass's prompt — the one seam all commands cross.
      #
      # @param isolation [AiFlow::AgentIsolation, nil]
      # @return [String] "" or the contract block (no trailing newline)
      sig { params(isolation: T.nilable(AgentIsolation)).returns(String) }
      def prompt_contract(isolation)
        return "" unless isolation

        <<~CONTRACT.strip
          PERMISSION BOUNDARIES: you run as the unprivileged user `#{isolation.user}`; some paths and capabilities are deliberately out of reach. A denial is not a dead-end and not an error to fight: note it and continue with everything you can reach. When a permission boundary blocks useful work, end your final output with one line per blocked need, exactly this form:
          WANTED: <path or capability> — <why it would have helped>
          Never work around a boundary (no privilege escalation, no permission changes, no copying protected files); the WANTED line is the escalation path — a human reviews every want.
        CONTRACT
      end

      # Extract the declared channel from a final result text: the WANTED
      # lines become wants and are stripped, so downstream consumers of the
      # text (segment parsing, FIRED: lines, comment panels) never see them.
      #
      # @param text [String]
      # @return [Array(Array<Want>, String)] deduped wants in first-seen
      #   order, and the text without its WANTED lines
      sig { params(text: String).returns([T::Array[Want], String]) }
      def extract_declared(text)
        wants = T.let([], T::Array[Want])
        kept = text.split("\n", -1).reject do |line|
          match = WANTED_LINE.match(line)
          next false unless match

          want = parse_want(T.must(match[:rest]))
          wants << want unless wants.include?(want)
          true
        end
        [wants, kept.join("\n")]
      end

      # The observed channel: denial signatures in tool output, one want
      # per touched path (the line itself when no path parses), GitHub-API
      # 403s excluded.
      #
      # @param text [String] a tool call's output
      # @return [Array<Want>] deduped observed wants
      sig { params(text: String).returns(T::Array[Want]) }
      def observed_in(text)
        wants = T.let([], T::Array[Want])
        text.split("\n").each do |line|
          next unless DENIAL_LINE.match?(line)
          next if GITHUB_403.match?(line)

          # scan with a groupless regexp yields strings; Sorbet only knows
          # the union shape, hence the cast.
          subject = T.cast(line.scan(TOUCHED_PATH).last, T.nilable(String)) || line.strip
          want = Want.new(subject: subject, reason: "", channel: :observed)
          wants << want unless wants.any? { |seen| seen.subject == subject }
        end
        wants
      end

      # Wants are agent-authored text landing on GitHub surfaces, so the
      # renderer is a boundary: at most this many render (the rest fold
      # into a count) and each field is sanitized before markdown.
      MAX_RENDERED = 10

      # Render wants for both surfaces (step summary and result panel): one
      # want line plus its triage-ladder resolution line. Subjects and
      # reasons are sanitized (no code-span breakout, bounded length) —
      # the agent writes them, a human reads them, and nothing in between
      # should be able to restyle the panel.
      #
      # @param wants [Array<Want>]
      # @return [Array<String>] markdown lines, empty for no wants
      sig { params(wants: T::Array[Want]).returns(T::Array[String]) }
      def render(wants)
        shown = T.must(wants[0, MAX_RENDERED])
        lines = shown.flat_map do |want|
          reason = want.reason.empty? ? "" : " — #{sanitize(want.reason)}"
          [
            "- `#{sanitize(want.subject)}`#{reason} _(#{want.channel})_",
            "  - #{resolution(want)}",
          ]
        end
        overflow = wants.length - shown.length
        lines << "- …and #{overflow} more (see the run log)" if overflow.positive?
        lines
      end

      private

      # One rendered field: backticks out (they would close the code
      # span), whitespace collapsed, length bounded.
      #
      # @param text [String]
      # @return [String]
      sig { params(text: String).returns(String) }
      def sanitize(text)
        clean = text.delete("`").gsub(/\s+/, " ").strip
        clean.length > 120 ? "#{clean[0, 119]}…" : clean
      end

      # @param rest [String] the WANTED line after the marker
      # @return [Want]
      sig { params(rest: String).returns(Want) }
      def parse_want(rest)
        SEPARATORS.each do |separator|
          subject, reason = rest.split(separator, 2)
          if reason
            return Want.new(subject: T.must(subject).strip, reason: reason.strip, channel: :declared)
          end
        end
        Want.new(subject: rest, reason: "", channel: :declared)
      end

      # The triage ladder, spoken per want. Category-4/5 subjects get the
      # by-design note; everything else gets the declarative-layer menu the
      # human picks from. Neither is ever a host mutation.
      #
      # @param want [Want]
      # @return [String]
      sig { params(want: Want).returns(String) }
      def resolution(want)
        if CATEGORY_NOTE_PATTERNS.any? { |pattern| pattern.match?(want.subject) }
          "covered by design (plans#26 categories 4–5: cooperative shared DDC, per-user container engine) — not a widening"
        else
          "resolve declaratively: org-wide → tap Brewfile PR; this project → dependencies.rb PR (ready-to-apply drafts arrive with plans#31)"
        end
      end
    end
  end
end
