# typed: strict
# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module AiFlow
  module Commands
    # /learn — capture a lesson as a learning (an index line in
    # .cursor/rules/learnings-index.mdc plus a detail skill under
    # .cursor/skills/learnings/<slug>/), landed as a draft PR the human
    # merges. The GitHub-comment twin of dev's capture-learning skill: same
    # distillation rubric, same output shape, one pipeline behind both.
    #
    # Four forms (plans#13, ai-flow#15):
    # - **dictated** (`/learn <statement>`): the human already distilled the
    #   lesson; the agent only formats it into the two-tier shape, dedups
    #   against the existing corpus, and applies the scope rubric. Works from
    #   any comment surface — its source is the single comment, so it opens a
    #   fresh draft each time.
    # - **bare sweep** (`/learn`): distill the surface's feedback — a PR's
    #   description, review threads, and conversation, or an issue's body and
    #   discussion. Re-running on the same surface refines that surface's open
    #   draft (branch ai/learn-<source>) instead of duplicating.
    # - **survey** (`/learn --scan [context…]`): input is the codebase + docs
    #   instead of review threads — seeds/refreshes the architecture section
    #   and distills practices already visible in code. Steering and targets
    #   are free text the agent judges (flags select mode only). One
    #   repo-scoped branch (ai/learn-scan), so rescans refine.
    # - **promotion** (`/learn --promote <slug>`): curation, not capture —
    #   moves an existing learning to the org tier (`knowledge_repo:` in
    #   .github/ai-flow.yml): a draft PR adding it there, paired with a
    #   deterministic removal draft in this repo.
    #
    # This class also owns /build's build-time capture (see the capture
    # section below): same rubric, same branches, produced in the build's own
    # hot pass.
    #
    # Distillation and file-writing are the agent's (it holds the rubric and
    # the corpus); the branch, commit, and draft-PR mechanics are the
    # script's — deterministic, like /build.
    class Learn
      extend T::Sig

      SCAN_FLAG = "--scan"
      PROMOTE_FLAG = "--promote"

      SKILLS_DIR = ".cursor/skills/learnings"
      INDEX_PATH = ".cursor/rules/learnings-index.mdc"

      # Learning artifacts live under these trees — the per-repo layout, then
      # the org knowledge repo's root layout (index.md + skills/). The panel
      # names what changed by reading the staged file list, never by trusting
      # agent prose.
      LEARNING_PATHS = T.let(
        [
          %r{\A\.cursor/skills/(?:learnings|architecture)/([^/]+)/},
          %r{\A\.cursor/rules/learnings-index\.mdc\z},
          %r{\Askills/([^/]+)/},
          %r{\Aindex\.md\z},
        ].freeze,
        T::Array[Regexp],
      )

      # Pathspecs the /build capture extraction sweeps out of the code
      # commit (repo layout only — build capture lands in the built repo).
      CAPTURE_PATHSPECS = T.let(
        [
          INDEX_PATH,
          SKILLS_DIR,
          ".cursor/skills/architecture",
        ].freeze,
        T::Array[String],
      )

      # @param context [AiFlow::Context]
      # @param github [AiFlow::GitHub]
      # @param agent [AiFlow::Agent]
      # @param result_writer [AiFlow::ResultWriter]
      # @param executor [AiFlow::Executor]
      # @param workdir [String] the job's repo checkout
      # @param prefix [String] configured command prefix
      # @param org_invariants [AiFlow::OrgInvariants] injected into the prompt
      #   — the learning worktree is fresh, so the rendered org-invariants.mdc
      #   is never present (same reasoning as /build, plans#13)
      sig do
        params(
          context: Context,
          github: GitHub,
          agent: Agent,
          result_writer: ResultWriter,
          executor: Executor,
          workdir: String,
          prefix: String,
          org_invariants: OrgInvariants,
        ).void
      end
      def initialize(context:, github:, agent:, result_writer:, executor:, workdir:, prefix: "",
        org_invariants: OrgInvariants.new)
        @context = context
        @github = github
        @agent = agent
        @result_writer = result_writer
        @executor = executor
        @workdir = workdir
        @prefix = prefix
        @org_invariants = org_invariants
        # Build-capture state, seeded/extracted/consumed per build pass.
        @capture_source = T.let(nil, T.nilable(T::Hash[Symbol, T.untyped]))
        @capture_existing = T.let(nil, T.nilable(T::Hash[String, T.untyped]))
        @capture_patch = T.let(nil, T.nilable(String))
      end

      # @param segment [CommentParser::Segment]
      # @return [void]
      sig { params(segment: CommentParser::Segment).void }
      def run(segment)
        return scan(segment) if segment.flags.include?(SCAN_FLAG)
        return promote(segment) if segment.flags.include?(PROMOTE_FLAG)

        capture(segment)
      end

      # ---- /build build-time capture (plans#13 capture path 2) ----
      # The build pass ingested the context once, so the finished learning
      # artifacts are produced in that same pass: /build's prompt carries the
      # capture rubric (capture_prompt_section), the agent writes learning
      # files straight into the code worktree, and the commit step splits
      # them out (same mechanics as the workflows exclusion) to land on the
      # surface's own learning branch as a separate draft PR.

      # @return [String] the rubric section /build appends to its prompts
      sig { returns(String) }
      def capture_prompt_section
        <<~SECTION.strip
          LEARNING CAPTURE (side quest — the code work above stays the priority):
          This repo keeps durable learnings: an index line in `#{INDEX_PATH}` plus a detail skill at `#{SKILLS_DIR}/<slug>/SKILL.md`. While your context is hot, distill anything from this pass that generalizes beyond the immediate diff — recurring style/API corrections, architecture constraints the feedback revealed, process rules. Diff-local fixes (typos, renames, one-off bugs) are NOT learnings, and most passes yield nothing — write learning files only when something truly generalizes.
          #{shared_rubric}
          Write the learning files directly in this checkout; the tooling automatically splits them out of the code commit into a separate draft learning PR. If the checkout already contains learning files from this surface's open draft, they are yours to refine — or delete, if this pass dissolved their generalization.
        SECTION
      end

      # Bring an open draft's files into the build worktree so the hot pass
      # refines (or dissolves) them instead of drafting blind duplicates.
      #
      # @param dir [String] the build worktree
      # @param source [Hash] the built surface — :branch (the refine key,
      #   e.g. ai/learn-issue-12; keyed on the built issue so --split
      #   sub-builds never force-push over each other's drafts), :ref
      #   ("owner/repo#n" for the marker), :url (the PR-body link)
      # @return [void]
      sig { params(dir: String, source: T::Hash[Symbol, T.untyped]).void }
      def seed_capture(dir, source)
        @capture_source = source
        @capture_existing = @github.open_pull_request_for_head(@context.owner_repo, source.fetch(:branch))
        return unless @capture_existing

        _out, _err, ok = @executor.capture("git", "fetch", "origin", source.fetch(:branch), chdir: dir)
        unless ok
          # Without the draft's files in the tree, "the agent deleted them"
          # can't be inferred — forget the draft so an empty capture stays a
          # no-op instead of closing a PR the agent never saw.
          @capture_existing = nil
          return
        end

        # T.unsafe: splatting the pathspec constant into capture's rest param
        # is beyond Sorbet's static splat support (srb.help/7019).
        T.unsafe(@executor).capture(
          "git", "checkout", "origin/#{source.fetch(:branch)}", "--", *CAPTURE_PATHSPECS, chdir: dir,
        )
      end

      # Pull the staged learning diff out of the pending code commit — the
      # code PR and the learning PR stay separate by construction.
      #
      # @param dir [String] the build worktree, right after `git add -A`
      # @return [void]
      sig { params(dir: String).void }
      def extract_capture(dir)
        @capture_patch = nil
        # T.unsafe: splatting the pathspec constant into capture's rest param
        # is beyond Sorbet's static splat support (srb.help/7019).
        patch, = T.unsafe(@executor).capture(
          "git", "diff", "--cached", "--binary", "--", *CAPTURE_PATHSPECS, chdir: dir,
        )
        return if patch.strip.empty?

        @capture_patch = patch
        run!(["git", "reset", "-q", "HEAD", "--", *CAPTURE_PATHSPECS], chdir: dir)
        # Working-tree restore is hygiene and best-effort: checkout errors
        # when the agent only *added* learning files, which clean covers.
        T.unsafe(@executor).capture("git", "checkout", "-q", "--", *CAPTURE_PATHSPECS, chdir: dir)
        T.unsafe(@executor).capture("git", "clean", "-fdq", "--", *CAPTURE_PATHSPECS, chdir: dir)
      end

      # Land the extracted diff as the surface's draft learning PR — create,
      # refine (the branch is regenerated as base + current state, force
      # pushed), or close a dissolved draft (seeded files deleted by the
      # pass). Best-effort by contract: capture never fails the code build.
      #
      # @return [String, nil] a panel note, nil when there was nothing to land
      sig { returns(T.nilable(String)) }
      def land_capture
        # Consume the extraction state: a Build instance is reused across
        # --split sub-builds, and one build's capture must not haunt the next.
        patch = @capture_patch
        existing = @capture_existing
        source = @capture_source
        @capture_patch = nil
        @capture_existing = nil
        @capture_source = nil
        return close_dissolved_draft(existing) if patch.nil? && existing
        # A patch only exists after seed_capture set the source; the nil
        # check doubles as the narrowing Sorbet needs.
        return nil if patch.nil? || source.nil?

        note = land_patch(patch, existing, source)
        $stdout.puts note if note
        note
      rescue GitHub::Error => e
        warning = "⚠️ learning capture failed (the code change itself is unaffected): #{e.message}"
        $stdout.puts warning
        warning
      end

      private

      # ---- Dictated + bare sweep ----

      # @param segment [CommentParser::Segment]
      # @return [void]
      sig { params(segment: CommentParser::Segment).void }
      def capture(segment)
        source = source_descriptor(segment)
        draft(segment, source, learn_prompt(segment, source))
      end

      # The branch + marker naming per form (the branch is the refine key;
      # the marker records the source surface and form in the PR body).
      #
      # @return [Hash] :branch, :marker, :title, :dictated
      sig { params(segment: CommentParser::Segment).returns(T::Hash[Symbol, T.untyped]) }
      def source_descriptor(segment)
        repo_ref = "#{@context.owner_repo}##{@context.number}"
        if dictated?(segment)
          # Source is the single comment, so each dictation is its own draft.
          { branch: "ai/learn-c#{@context.comment_id}", marker: "learned-from: #{repo_ref} (dictated)",
            title: "dictated learning", dictated: true }
        else
          { branch: surface_branch, marker: "learned-from: #{repo_ref} (learn-sweep)",
            title: "learnings from #{repo_ref}", dictated: false }
        end
      end

      # The sweep-form branch for this surface — shared with /build's
      # build-time capture, so a later /build refines the sweep's draft and
      # vice versa (the linked-update rule keys on the branch).
      #
      # @return [String]
      sig { returns(String) }
      def surface_branch
        @context.pull_request? ? "ai/learn-pr-#{@context.number}" : "ai/learn-issue-#{@context.number}"
      end

      # @return [Boolean] a statement was dictated (vs a bare surface sweep)
      sig { params(segment: CommentParser::Segment).returns(T::Boolean) }
      def dictated?(segment)
        !segment.instruction.empty?
      end

      # ---- --scan (survey) ----

      # @param segment [CommentParser::Segment]
      # @return [void]
      sig { params(segment: CommentParser::Segment).void }
      def scan(segment)
        source = {
          branch: "ai/learn-scan",
          marker: "learned-from: #{@context.owner_repo}##{@context.number} (scan)",
          title: "learnings from a codebase survey",
          dictated: false,
        }
        draft(segment, source, scan_prompt(segment))
      end

      # @return [String] the survey pass's prompt
      sig { params(segment: CommentParser::Segment).returns(String) }
      def scan_prompt(segment)
        <<~PROMPT
          You are ai-flow, surveying this repository checkout to capture durable learnings.

          #{learning_definition}

          SURVEY MISSION — the input is the codebase and its docs, not review threads: distill what is already true. Architecture knowledge first — module ownership, layering rules, key seams — as digest skills under `.cursor/skills/architecture/<topic>/SKILL.md`, indexed under an `architecture` section (docs stay canonical where they exist; the digest points into them, never forks them — flag in your summary when the canonical doc itself needs a change). Then recurring coding and process practices visible in code and existing docs.

          STEERING (free text from the requesting comment — targets, focus areas, exclusions; judge and apply it):
          #{scan_steering(segment)}

          This pass writes into this checkout only. When the steering names other repositories, read them via `gh` for context and dedup, and note in your summary which deserve their own scan — never draft files for them here.

          #{org_invariants_section}#{shared_rubric}

          Dedup makes rescans cheap: unchanged areas draft nothing; changed areas draft revisions of the existing entries. If nothing new or stale turns up, WRITE NOTHING and say so.

          #{agent_rules}

          OUTPUT: a short summary — one line per learning drafted or revised (or "no learning: <why>").
        PROMPT
      end

      # @return [String]
      sig { params(segment: CommentParser::Segment).returns(String) }
      def scan_steering(segment)
        quote = segment.quote ? "Quoted context:\n#{segment.quote}\n\n" : ""
        steering = "#{quote}#{segment.instruction}".strip
        steering.empty? ? "(none — survey this repository)" : steering
      end

      # ---- --promote (org-tier curation) ----

      # @param segment [CommentParser::Segment]
      # @return [void]
      sig { params(segment: CommentParser::Segment).void }
      def promote(segment)
        knowledge_repo = RepoConfig.load(@workdir).knowledge_repo
        unless knowledge_repo
          return refuse(segment, "ℹ️ **/learn --promote** — no `knowledge_repo:` configured in " \
                                 "`#{RepoConfig::PATH}`. Add `knowledge_repo: <owner>/<repo>` naming the org " \
                                 "knowledge repo, then re-run.")
        end
        slug = promoted_slug(segment)
        return refuse(segment, "ℹ️ **/learn --promote** — name the learning: `/learn --promote <slug>`.") unless slug

        skill_path = File.join(@workdir, SKILLS_DIR, slug, "SKILL.md")
        return refuse(segment, unknown_slug_message(slug)) unless File.exist?(skill_path)

        org = promote_into_org(slug, knowledge_repo, File.read(skill_path))
        removal = drop_local_entry(slug, org.fetch(:pr))
        @result_writer.write(@context, [[segment, promote_result(slug, knowledge_repo, org, removal)]])
      end

      # The slug is the learning's name — its skill folder. A domain prefix
      # (`testing/rspock-bare-assertions`) is accepted and dropped: folders
      # are unprefixed and unique per repo.
      #
      # @return [String, nil]
      sig { params(segment: CommentParser::Segment).returns(T.nilable(String)) }
      def promoted_slug(segment)
        token = segment.instruction.split.first.to_s.split("/").last.to_s
        token.empty? ? nil : token
      end

      # @return [String] the refusal panel, listing near matches so a typo'd
      #   slug is a one-edit fix
      sig { params(slug: String).returns(String) }
      def unknown_slug_message(slug)
        known = local_learning_slugs
        near = known.select { |name| name.include?(slug) || slug.include?(name) }
        candidates = near.empty? ? known : near
        listing =
          if candidates.empty?
            "this repo has no learnings under `#{SKILLS_DIR}/`"
          else
            "known: #{candidates.first(10).map { |name| "`#{name}`" }.join(", ")}"
          end
        "ℹ️ **/learn --promote** — no learning named `#{slug}` in #{@context.owner_repo} (#{listing})."
      end

      # @return [Array<String>]
      sig { returns(T::Array[String]) }
      def local_learning_slugs
        dir = File.join(@workdir, SKILLS_DIR)
        File.directory?(dir) ? Dir.children(dir).sort : []
      end

      # The org-side draft: an agent pass in a fresh knowledge-repo clone
      # (the App installation spans the org, same mechanics as /build's
      # cross-repo path), adapting the learning to org-general wording.
      #
      # @return [Hash] :pr, :refined
      sig do
        params(slug: String, knowledge_repo: String, skill_text: String)
          .returns(T::Hash[Symbol, T.untyped])
      end
      def promote_into_org(slug, knowledge_repo, skill_text)
        branch = "ai/learn-promote-#{@context.owner_repo.split("/").last}-#{slug}"
        existing = @github.open_pull_request_for_head(knowledge_repo, branch)
        in_clone(knowledge_repo, branch, refine: !existing.nil?) do |clone|
          @agent.launch(
            prompt: promote_prompt(slug, knowledge_repo, skill_text), workdir: clone, command: "learn", force: true,
          )
          @executor.refresh_auth!
          slugs = commit_learnings(clone, message: "ai-flow /learn: promote #{slug} to the org tier")
          raise GitHub::Error, "the agent staged no org learning files for `#{slug}`" if slugs.empty?

          push_branch(clone, branch)
          pr = existing || open_promotion_pr(slug, knowledge_repo, branch)
          { pr: pr, refined: !existing.nil? }
        end
      end

      # @return [String] the promotion pass's prompt
      sig { params(slug: String, knowledge_repo: String, skill_text: String).returns(String) }
      def promote_prompt(slug, knowledge_repo, skill_text)
        <<~PROMPT
          You are ai-flow, promoting a repo-local learning to the org knowledge tier in this checkout of #{knowledge_repo} (layout: `index.md` at the root, detail skills at `skills/<slug>/SKILL.md`).

          THE LEARNING, verbatim from #{@context.owner_repo}:
          Index line: #{index_line_for(slug) || "(none found — derive one from the skill)"}
          <<<SKILL>>>
          #{skill_text}
          <<<END SKILL>>>

          Adapt it to the org tier: strip repo-specific references so the lesson reads org-general; keep its learned-from origin and note it was promoted from #{@context.owner_repo}. DEDUP first — read `index.md` and the skills under `skills/`; if an equivalent org learning exists, merge into or revise it instead of duplicating. Place the index line under the fitting domain section of `index.md` and the skill at `skills/#{slug}/SKILL.md`.

          #{agent_rules}

          OUTPUT: one line describing the promotion (placed where, merged with what).
        PROMPT
      end

      # @return [String, nil] the learning's line in this repo's index
      sig { params(slug: String).returns(T.nilable(String)) }
      def index_line_for(slug)
        path = File.join(@workdir, INDEX_PATH)
        return nil unless File.exist?(path)

        File.readlines(path).find { |line| line.include?("learnings/#{slug}/") }&.strip
      end

      # @return [Hash] the created proposal PR (ordinary, not GitHub draft
      #   state — see open_learning_pr)
      sig do
        params(slug: String, knowledge_repo: String, branch: String)
          .returns(T::Hash[String, T.untyped])
      end
      def open_promotion_pr(slug, knowledge_repo, branch)
        requested_by = @context.commenter_login ? "Requested by @#{@context.commenter_login}.\n\n" : ""
        body = <<~BODY
          Promotes the `#{slug}` learning from #{@context.owner_repo} to the org tier (requested on #{source_link}).

          #{requested_by}learned-from: #{@context.owner_repo}##{@context.number} (promote)
        BODY
        @github.create_pull_request(
          knowledge_repo,
          title: "ai-flow /learn: promote #{slug} from #{@context.owner_repo}",
          body: body, head: branch, base: @github.default_branch(knowledge_repo),
        )
      end

      # The paired repo-local removal — deterministic (delete the skill
      # folder, drop the index line), no agent pass. Best-effort: a failed
      # removal must not lose the org PR from the panel.
      #
      # @return [Hash] :pr on success, :error on failure
      sig do
        params(slug: String, org_pr: T::Hash[String, T.untyped])
          .returns(T::Hash[Symbol, T.untyped])
      end
      def drop_local_entry(slug, org_pr)
        branch = "ai/learn-promote-#{slug}"
        existing = @github.open_pull_request_for_head(@context.owner_repo, branch)
        pr = in_worktree(branch, refine: false) do |worktree|
          FileUtils.rm_rf(File.join(worktree, SKILLS_DIR, slug))
          drop_index_line(worktree, slug)
          slugs = commit_learnings(worktree, message: "ai-flow /learn: drop #{slug} (promoted to the org tier)")
          raise GitHub::Error, "nothing to remove for `#{slug}`" if slugs.empty?

          push_branch(worktree, branch)
          existing || open_removal_pr(slug, branch, org_pr)
        end
        { pr: pr }
      rescue GitHub::Error => e
        { error: e.message }
      end

      # @param worktree [String]
      # @param slug [String]
      # @return [void]
      sig { params(worktree: String, slug: String).void }
      def drop_index_line(worktree, slug)
        path = File.join(worktree, INDEX_PATH)
        return unless File.exist?(path)

        kept = File.readlines(path).reject { |line| line.include?("learnings/#{slug}/") }
        File.write(path, kept.join)
      end

      # @return [Hash] the created proposal PR (ordinary, not GitHub draft
      #   state — see open_learning_pr)
      sig do
        params(slug: String, branch: String, org_pr: T::Hash[String, T.untyped])
          .returns(T::Hash[String, T.untyped])
      end
      def open_removal_pr(slug, branch, org_pr)
        requested_by = @context.commenter_login ? "Requested by @#{@context.commenter_login}.\n\n" : ""
        body = <<~BODY
          Drops the repo-local `#{slug}` learning — promoted to the org tier by #{org_pr.fetch("html_url")}. Merge after that PR lands and the knowledge sync has shipped it machine-wide.

          #{requested_by}learned-from: #{@context.owner_repo}##{@context.number} (promote)
        BODY
        @github.create_pull_request(
          @context.owner_repo,
          title: "ai-flow /learn: drop #{slug} (promoted to the org tier)",
          body: body, head: branch, base: @github.default_branch(@context.owner_repo),
        )
      end

      # @return [String]
      sig do
        params(
          slug: String,
          knowledge_repo: String,
          org: T::Hash[Symbol, T.untyped],
          removal: T::Hash[Symbol, T.untyped],
        ).returns(String)
      end
      def promote_result(slug, knowledge_repo, org, removal)
        verb = org[:refined] ? "refined the open org draft" : "opened an org draft"
        lines = ["✅ **/learn --promote** — `#{slug}` → #{knowledge_repo}: #{verb} #{org.fetch(:pr).fetch("html_url")}"]
        lines <<
          if removal[:error]
            "⚠️ the paired repo-local removal failed: #{removal[:error]}"
          else
            "🧹 paired removal draft in #{@context.owner_repo}: #{removal.fetch(:pr).fetch("html_url")} — " \
              "merge after the org PR lands and the knowledge sync ships it."
          end
        lines.join("\n")
      end

      # ---- The shared draft pipeline (dictated, sweep, scan) ----

      # @return [void]
      sig do
        params(
          segment: CommentParser::Segment,
          source: T::Hash[Symbol, T.untyped],
          prompt: String,
        ).void
      end
      def draft(segment, source, prompt)
        existing = @github.open_pull_request_for_head(@context.owner_repo, source[:branch])

        outcome = in_worktree(source[:branch], refine: !existing.nil?) do |worktree|
          @agent.launch(prompt: prompt, workdir: worktree, command: "learn", force: true)
          # The agent may have run close to the token's lifetime; the write
          # phase (commit, push, PR) starts on a fresh mint.
          @executor.refresh_auth!
          slugs = commit_learnings(worktree)
          next { slugs: [] } if slugs.empty?

          push_branch(worktree, source[:branch])
          pr = existing || open_learning_pr(source, segment)
          { slugs: slugs, pr: pr, refined: !existing.nil? }
        end

        @result_writer.write(@context, [[segment, learn_result(outcome)]])
      end

      # @return [String] the capture pass's prompt
      sig do
        params(segment: CommentParser::Segment, source: T::Hash[Symbol, T.untyped])
          .returns(String)
      end
      def learn_prompt(segment, source)
        <<~PROMPT
          You are ai-flow, capturing a durable learning in this repository checkout.

          #{learning_definition}

          #{evidence_section(segment, source)}
          #{org_invariants_section}#{shared_rubric}

          If nothing here generalizes into a learning, WRITE NOTHING and say so — an empty capture is a valid, common outcome.

          #{agent_rules}

          OUTPUT: a short summary — one line per learning drafted (or "no learning: <why>").
        PROMPT
      end

      # @return [String]
      sig { returns(String) }
      def learning_definition
        "A learning is one lesson materialized two ways: an index line in `#{INDEX_PATH}` (always-on " \
          "awareness) and a detail skill at `#{SKILLS_DIR}/<slug>/SKILL.md` (loaded on demand). This is " \
          "the GitHub twin of the capture-learning skill — identical rubric and output."
      end

      # The distillation + dedup + scope + format rubric every capture form
      # shares (including /build's build-time capture).
      #
      # @return [String]
      sig { returns(String) }
      def shared_rubric
        <<~RUBRIC.strip
          DISTILLATION RUBRIC — only lessons that generalize beyond the immediate diff or discussion become learnings. Three kinds, one format: coding practices (style/API corrections that recur), architecture knowledge (constraints and shapes of the system — "X must never call Y directly", "this subsystem owns that lifecycle"), and process rules. Diff-local fixes (typos, renames, one-off bugs) are NOT learnings.

          Before writing, DEDUP: read `#{INDEX_PATH}` and skills under `~/.cursor/skills/` (the org tier); if an equivalent learning exists, revise it rather than adding a duplicate; if swept feedback contradicts one, edit or remove it. Revision always beats a contradictory sibling.

          SCOPE: ask whether the lesson is about THIS repo's code or about how we build software. Repo-specific lessons land here. A repo-agnostic lesson (SRP-class principles, universal testing/error-handling posture) belongs in the org knowledge tier — note that in your summary and still draft it repo-local (org promotion is `/learn --promote <slug>`, a separate reviewed step); borderline calls default to repo-local.

          FORMAT:
          - Index line under a `## <domain>` section: `- [domain/slug] One-sentence trigger. → #{SKILLS_DIR}/<slug>/`
          - Detail skill (hard cap ~40 lines): frontmatter `name` matching its folder and an imperative `description` ("MUST be used when …"); the rule in two sentences; one wrong/right pair; a `learned-from:` origin line; a `date:`.
          - Soft cap ~50 index entries: at the cap, propose a retirement, consolidation, or glob-scoped sub-index split alongside any addition.
        RUBRIC
      end

      # @return [String]
      sig { returns(String) }
      def agent_rules
        <<~RULES.strip
          Rules:
          - Write only learning files (the index and skill files). Do not create commits, branches, or PRs — the surrounding tooling owns git. Work only inside this checkout.
          - In any text destined for GitHub, reference files as GitHub URLs, never as local filesystem paths.
        RULES
      end

      # The evidence the pass distills, per form.
      #
      # @return [String]
      sig do
        params(segment: CommentParser::Segment, source: T::Hash[Symbol, T.untyped])
          .returns(String)
      end
      def evidence_section(segment, source)
        return "DICTATED LESSON (the human already distilled it — format, dedup, and place it):\n#{dictated_evidence(segment)}\n" if source[:dictated]

        <<~EVIDENCE
          SWEEP THIS SURFACE — distill what generalizes from the #{@context.pull_request? ? "pull request" : "issue"} below. The diff and code are in this checkout; read them for what the feedback is about.
          #{surface_evidence}
        EVIDENCE
      end

      # @return [String]
      sig { params(segment: CommentParser::Segment).returns(String) }
      def dictated_evidence(segment)
        quote = segment.quote ? "Quoted context:\n#{segment.quote}\n\n" : ""
        "#{quote}#{segment.instruction}"
      end

      # PR: description + unresolved review threads + conversation. Issue:
      # body + comment discussion. Comments carry the lessons; the checkout
      # carries the code they're about.
      #
      # @return [String]
      sig { returns(String) }
      def surface_evidence
        subject = @github.issue(@context.owner_repo, @context.number)
        blocks = ["#{@context.pull_request? ? "PR" : "ISSUE"} #{@context.owner_repo}##{@context.number}: #{subject.title}",
                  "<<<BODY>>>\n#{subject.body}\n<<<END BODY>>>"]
        blocks.concat(thread_blocks) if @context.pull_request?
        blocks.concat(comment_blocks)
        blocks.join("\n\n")
      end

      # @return [Array<String>]
      sig { returns(T::Array[String]) }
      def thread_blocks
        @github.unresolved_review_threads(@context.owner_repo, @context.number).map do |thread|
          conversation = thread["comments"].map { |comment| "@#{comment["author"]}: #{comment["body"]}" }.join("\n")
          "REVIEW THREAD (#{thread["path"]})\n#{thread["diff_hunk"]}\n#{conversation}"
        end
      end

      # @return [Array<String>]
      sig { returns(T::Array[String]) }
      def comment_blocks
        @github.issue_comments(@context.owner_repo, @context.number)
               .reject { |comment| comment["id"] == @context.comment_id }
               .reject { |comment| comment.dig("user", "login") == CommitIdentity.bot_login }
               .map { |comment| "Comment from @#{comment.dig("user", "login")}:\n#{comment["body"]}" }
      end

      # @return [String] org invariants block with trailing blank line, empty
      #   on unconfigured machines
      sig { returns(String) }
      def org_invariants_section
        block = @org_invariants.prompt_block
        block ? "#{block}\n\n" : ""
      end

      # ---- Landing mechanics (shared by every form + build capture) ----

      # Stage the learning files in the given checkout and commit them. The
      # learning branch carries only learnings by construction, so a blanket
      # add is safe; .ai-flow is the dispatcher's own nested checkout, never
      # ours.
      #
      # @return [Array<String>] changed learning slugs (skill folders +
      #   "index" for the index edit), empty when nothing was written
      sig { params(dir: String, message: String).returns(T::Array[String]) }
      def commit_learnings(dir, message: "ai-flow /learn: capture learnings")
        run!(["git", "add", "-A", "--", ":(exclude).ai-flow"], chdir: dir)
        staged, = @executor.capture("git", "diff", "--cached", "--name-only", chdir: dir)
        slugs = learning_slugs(staged)
        # Key the "did we capture" decision on learning files, not any staged
        # path: an empty capture (nothing generalized) is the common outcome,
        # and stray non-learning writes are discarded with the worktree.
        return [] if slugs.empty?

        full_message = CommitIdentity.message_with_requester(message, @context)
        run!(["git", *CommitIdentity.git_flags(@github), "commit", "-m", full_message], chdir: dir)
        slugs
      end

      # @param staged [String] git diff --cached --name-only output
      # @return [Array<String>] deduped slugs, "index" standing in for the
      #   index-line edit
      sig { params(staged: String).returns(T::Array[String]) }
      def learning_slugs(staged)
        staged.split("\n").each_with_object(T.let([], T::Array[String])) do |path, slugs|
          LEARNING_PATHS.each do |pattern|
            match = pattern.match(path)
            next unless match

            slugs << (match[1] || "index")
          end
        end.uniq
      end

      # Proposals open as ordinary PRs, not GitHub draft state: they are
      # ready for the gate's attention, and draft state would mute
      # CODEOWNERS review requests while reading as not-ready. If
      # unsolicited proposals ever get noisy, `draft: true` on these
      # creations is the ready-made valve.
      #
      # @return [Hash] the created proposal PR
      sig do
        params(source: T::Hash[Symbol, T.untyped], segment: CommentParser::Segment)
          .returns(T::Hash[String, T.untyped])
      end
      def open_learning_pr(source, segment)
        requested_by = @context.commenter_login ? "Requested by @#{@context.commenter_login}.\n\n" : ""
        body = <<~BODY
          Draft learning(s) captured from #{source_link}.

          #{requested_by}#{evidence_quote(segment, source)}#{source[:marker]}
        BODY
        @github.create_pull_request(
          @context.owner_repo,
          title: "ai-flow /learn: #{source[:title]}",
          body: body,
          head: source[:branch],
          base: @github.default_branch(@context.owner_repo),
        )
      end

      # The draft embeds the motivating evidence (a dictation's statement, or
      # a pointer to the swept surface) so it is reviewable without reopening
      # the source.
      #
      # @return [String]
      sig do
        params(segment: CommentParser::Segment, source: T::Hash[Symbol, T.untyped])
          .returns(String)
      end
      def evidence_quote(segment, source)
        return "" unless source[:dictated]

        "> #{segment.instruction.gsub("\n", "\n> ")}\n\n"
      end

      # @return [String]
      sig { returns(String) }
      def source_link
        "#{@context.subject_url} (#{@context.owner_repo}##{@context.number})"
      end

      # @return [String]
      sig { params(outcome: T::Hash[Symbol, T.untyped]).returns(String) }
      def learn_result(outcome)
        return "ℹ️ **/learn** — no learning: nothing here generalized beyond the immediate change." if outcome[:slugs].empty?

        pr = outcome.fetch(:pr)
        verb = outcome[:refined] ? "refined" : "drafted"
        lines = ["✅ **/learn** — #{verb} #{learning_count(outcome[:slugs])} in a draft PR: #{pr.fetch("html_url")}"]
        named_slugs(outcome[:slugs]).each { |slug| lines << "- `#{slug}`" }
        lines.join("\n")
      end

      # @return [String]
      sig { params(slugs: T::Array[String]).returns(String) }
      def learning_count(slugs)
        named = named_slugs(slugs)
        count = named.size
        count.zero? ? "the learnings index" : "#{count} learning#{"s" unless count == 1}"
      end

      # The index edit isn't itself a named learning — drop the "index"
      # sentinel for the human-facing list.
      #
      # @return [Array<String>]
      sig { params(slugs: T::Array[String]).returns(T::Array[String]) }
      def named_slugs(slugs)
        slugs.reject { |slug| slug == "index" }
      end

      # ---- Build-capture landing (private half) ----

      # @return [String, nil]
      sig do
        params(
          patch: String,
          existing: T.nilable(T::Hash[String, T.untyped]),
          source: T::Hash[Symbol, T.untyped],
        ).returns(T.nilable(String))
      end
      def land_patch(patch, existing, source)
        in_worktree(source.fetch(:branch), refine: false) do |worktree|
          apply_patch(worktree, patch)
          slugs = commit_learnings(worktree, message: "ai-flow /build: capture learnings from the build pass")
          next nil if slugs.empty?

          push_branch(worktree, source.fetch(:branch))
          pr = existing || open_capture_pr(source)
          verb = existing ? "refined" : "drafted"
          lines = ["🧠 #{verb} #{learning_count(slugs)} in a draft learning PR: #{pr.fetch("html_url")}"]
          named_slugs(slugs).each { |slug| lines << "- `#{slug}`" }
          lines.join("\n")
        end
      end

      # The extracted diff was taken against the same origin/<default> base
      # the landing worktree starts from; --3way covers a mid-run base move.
      #
      # @return [void]
      sig { params(worktree: String, patch: String).void }
      def apply_patch(worktree, patch)
        _out, err, ok = @executor.capture(
          "git", "apply", "--index", "--3way", stdin: patch, chdir: worktree,
        )
        raise GitHub::Error, "applying the learning diff failed: #{err.strip}" unless ok
      end

      # @return [Hash] the created proposal PR (ordinary, not GitHub draft
      #   state — see open_learning_pr)
      sig { params(source: T::Hash[Symbol, T.untyped]).returns(T::Hash[String, T.untyped]) }
      def open_capture_pr(source)
        requested_by = @context.commenter_login ? "Requested by @#{@context.commenter_login}.\n\n" : ""
        body = <<~BODY
          Draft learning(s) captured by the /build pass on #{source.fetch(:url)} (#{source.fetch(:ref)}).

          #{requested_by}learned-from: #{source.fetch(:ref)} (build-sweep)
        BODY
        @github.create_pull_request(
          @context.owner_repo,
          title: "ai-flow /learn: learnings from #{source.fetch(:ref)}",
          body: body, head: source.fetch(:branch), base: @github.default_branch(@context.owner_repo),
        )
      end

      # The pass deleted the seeded draft files: its generalization dissolved,
      # so the draft closes instead of lingering half-refined.
      #
      # @return [String]
      sig { params(existing: T::Hash[String, T.untyped]).returns(String) }
      def close_dissolved_draft(existing)
        @github.close_pull_request(@context.owner_repo, existing.fetch("number"))
        note = "🧠 closed the draft learning PR #{existing.fetch("html_url")} — this pass dissolved its generalization."
        $stdout.puts note
        note
      rescue GitHub::Error => e
        "⚠️ closing the dissolved learning draft failed: #{e.message}"
      end

      # ---- Workspaces ----

      # An isolated worktree per capture (never disturbs the job's checked-out
      # PR branch, safe under concurrency). Refine bases on the existing
      # draft's branch; a fresh capture bases on the default branch.
      #
      # @yieldparam worktree [String] the worktree's path
      # @return [Object] the block's value
      sig do
        type_parameters(:Result)
          .params(
            branch: String,
            refine: T::Boolean,
            blk: T.proc.params(worktree: String).returns(T.type_parameter(:Result)),
          ).returns(T.type_parameter(:Result))
      end
      def in_worktree(branch, refine:, &blk)
        default = @github.default_branch(@context.owner_repo)
        base_ref = refine ? branch : default
        Dir.mktmpdir("ai-flow-learn-") do |dir|
          worktree = File.join(dir, "worktree")
          run!(["git", "fetch", "origin", base_ref], chdir: @workdir)
          run!(["git", "worktree", "prune"], chdir: @workdir)
          run!(["git", "worktree", "add", "--detach", worktree, "origin/#{base_ref}"], chdir: @workdir)
          run!(["git", "checkout", "-B", branch], chdir: worktree)
          begin
            yield worktree
          ensure
            @executor.capture("git", "worktree", "remove", "--force", worktree, chdir: @workdir)
          end
        end
      end

      # Cross-repo drafts (org promotion) work in a fresh clone via gh — the
      # App installation spans the org, same mechanics as /build's cross-repo
      # path.
      #
      # @yieldparam clone [String] the clone's path
      # @return [Object] the block's value
      sig do
        type_parameters(:Result)
          .params(
            repo: String,
            branch: String,
            refine: T::Boolean,
            blk: T.proc.params(clone: String).returns(T.type_parameter(:Result)),
          ).returns(T.type_parameter(:Result))
      end
      def in_clone(repo, branch, refine:, &blk)
        Dir.mktmpdir("ai-flow-learn-") do |dir|
          clone = File.join(dir, "clone")
          run!(["gh", "repo", "clone", repo, clone], chdir: dir)
          base = refine ? ["origin/#{branch}"] : []
          run!(["git", "checkout", "-B", branch, *base], chdir: clone)
          yield clone
        end
      end

      # @param dir [String]
      # @param branch [String]
      # @return [void]
      sig { params(dir: String, branch: String).void }
      def push_branch(dir, branch)
        _out, err, ok = @executor.capture(
          "git", "push", "-u", "origin", branch, "--force-with-lease", chdir: dir,
        )
        return if ok

        raise GitHub::Error,
              "git push failed: #{err.strip} — if this repo enforces signed commits, " \
              "see d3mlabs/ai-flow docs/attribution.md (createCommitOnBranch upgrade path)"
      end

      # @return [void]
      sig { params(segment: CommentParser::Segment, message: String).void }
      def refuse(segment, message)
        @result_writer.write(@context, [[segment, message]])
      end

      # @param argv [Array<String>] command and arguments
      # @param chdir [String] working directory
      # @raise [GitHub::Error] when the command fails
      sig { params(argv: T::Array[String], chdir: String).void }
      def run!(argv, chdir:)
        # T.unsafe: splatting a runtime-built argv into capture's rest param
        # is beyond Sorbet's static splat support (srb.help/7019).
        _out, err, ok = T.unsafe(@executor).capture(*argv, chdir: chdir)
        raise GitHub::Error, "#{argv.take(2).join(" ")} failed: #{err.strip}" unless ok
      end
    end
  end
end
