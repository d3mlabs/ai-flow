# frozen_string_literal: true

module AiFlow
  module Commands
    # Runs an /ask///edit batch — the review work unit (plan, Component 4).
    #
    # /ask and /edit always operate on the document: the issue body or the PR
    # description (the issues API covers both). /build owns code changes.
    #
    # The flow is file-based, mirroring how Cursor handles a chat message
    # with several cmd+L selections: the snapshot is written to a plan file,
    # one agent pass applies every /edit instruction to that file holistically
    # (quotes are focus anchors, not edit boundaries — an instruction's
    # implications land wherever the document needs them), and the file is
    # read back for one guarded PATCH. One comment is one unit of change:
    # per-segment result lines plus a single whole-document rich diff.
    #
    # Two-phase, because every quote was taken against the same body the
    # reviewer read:
    # - Phase 1 resolves all quotes against a snapshot taken at batch start;
    #   the only per-segment failure is a quote missing from that snapshot.
    # - Phase 2 is the single agent pass over the plan file.
    class Batch
      # @param context [AiFlow::Context]
      # @param github [AiFlow::GitHub]
      # @param agent [AiFlow::Agent]
      # @param rich_diff [AiFlow::RichDiff]
      # @param result_writer [AiFlow::ResultWriter]
      # @param workdir [String] the job's repo checkout
      def initialize(context:, github:, agent:, rich_diff:, result_writer:, workdir:)
        @context = context
        @github = github
        @agent = agent
        @rich_diff = rich_diff
        @result_writer = result_writer
        @workdir = workdir
      end

      # @param segments [Array<CommentParser::Segment>]
      # @return [Boolean] whether every segment succeeded (a ⚠️ result is a
      #   soft failure: it is reported on the comment, and the caller turns it
      #   into a red workflow run)
      def run(segments)
        issue = @github.issue(@context.owner_repo, @context.number)
        snapshot = PlanBody.from_issue_body(issue.body)

        resolved = resolve_anchors(segments, snapshot)
        parsed, new_body = run_plan_file_pass(resolved, snapshot)
        edits_applied = !new_body.nil?
        results = segment_results(resolved, parsed, edits_applied: edits_applied)

        appendix = nil
        if edits_applied
          patch_body(snapshot, new_body)
          appendix = plan_diff_appendix(snapshot, new_body)
        end

        deliver(segments, results, appendix: appendix)
      end

      private

      # The plan file the agent edits, at the root of the job's checkout (the
      # agent CLI works within its working directory) — never committed, and
      # deleted after the pass.
      #
      # @return [String] filename relative to the workdir
      def plan_filename
        "ai-flow-plan-#{@context.number}.md"
      end

      # Phase 2: write the snapshot to the plan file, run one agent pass that
      # edits it (and answers /ask segments), read the result back.
      #
      # @return [Array(AgentOutput::Parsed, String | nil)] the parsed segment
      #   results and the new body (nil when the document was not changed)
      def run_plan_file_pass(resolved, snapshot)
        path = File.join(@workdir, plan_filename)
        File.write(path, snapshot)

        output = @agent.launch(
          prompt: batch_prompt(resolved),
          workdir: @workdir,
          command: edits?(resolved) ? "edit" : "ask",
          force: edits?(resolved),
        )

        new_body = File.exist?(path) ? PlanBody.from_issue_body(File.read(path)) : nil
        new_body = nil if new_body == snapshot
        [AgentOutput.parse(output), new_body]
      ensure
        File.delete(path) if File.exist?(path)
      end

      # The batch's single whole-document diff, appended once at the bottom of
      # the command comment (one comment = one unit of change); per-segment
      # results interleave under their quotes.
      #
      # @return [String]
      def plan_diff_appendix(snapshot, new_body)
        diff = @rich_diff.render(before: snapshot, after: new_body, backlink_url: @context.subject_url)
        title = @context.pull_request? ? "**Description updated**" : "**Plan updated**"
        header = [title, diff.backlink].compact.join(" — ")
        "#{header}\n\n#{diff.collapsed}"
      end

      # Phase 1, the resolution ladder: each quote resolves to a document
      # span when it matches the snapshot (exact, then markdown-insensitive).
      # A quote that doesn't match is not an error — reviewers also quote
      # agent answers and discussion comments (text that was never in the
      # body) — so the thread is searched for its source comment as context;
      # the last rung is the quote verbatim. Unscoped segments focus the
      # whole document.
      #
      # @return [Array<Array(Segment, String | nil, Hash | nil)>]
      #   segment + resolved span + discussion source (see #discussion_source)
      def resolve_anchors(segments, snapshot)
        comments = nil
        segments.map do |segment|
          span = segment.quote && PlanBody.locate_quote(snapshot, segment.quote)
          if span || segment.quote.nil?
            [segment, span, nil]
          else
            # Fetched once per batch, and only when some quote missed the body.
            comments ||= discussion_comments
            [segment, span, discussion_source(segment.quote, comments)]
          end
        end
      end

      # The thread to search for quote sources: every comment except the one
      # carrying the slash command (its own "> " quote lines would match
      # trivially), with collapsed <details> blocks stripped — that's where
      # appended word/source diffs live, pure noise describing stale document
      # states.
      #
      # @return [Array<Hash>]
      def discussion_comments
        @github.issue_comments(@context.owner_repo, @context.number)
               .reject { |comment| comment["id"] == @context.comment_id }
               .map { |comment| comment.merge("body" => strip_details(comment["body"].to_s)) }
      end

      # The earliest comment containing the quote — later matches are usually
      # re-quotes of the original.
      #
      # @return [Hash{Symbol => String}, nil] author, url, text
      def discussion_source(quote, comments)
        comment = comments.find { |candidate| PlanBody.locate_quote(candidate["body"], quote) }
        return nil unless comment

        { author: comment.dig("user", "login"), url: comment["html_url"], text: comment["body"] }
      end

      # @return [String]
      def strip_details(text)
        text.gsub(%r{<details>.*?</details>}m, "(collapsed diff omitted)")
      end

      def batch_prompt(resolved)
        segment_descriptions = resolved.each_with_index.map do |(segment, span, source), index|
          <<~SEGMENT
            <<<SEGMENT #{index + 1}: /#{segment.command}>>>
            #{segment_focus(segment, span, source)}
            Instruction: #{segment.instruction.empty? ? "(none — the quote itself is the subject)" : segment.instruction}
          SEGMENT
        end.join("\n")

        <<~PROMPT
          You are ai-flow, processing a batch of review commands against a document (#{document_description}). The document is the file `#{plan_filename}` in your working directory; every reviewer quote below was taken against its current content.
          #{review_thread_anchor}
          SEGMENTS:
          #{segment_descriptions}

          Rules:
          - /edit segments: edit `#{plan_filename}` to apply the instruction. The quote marks where the feedback points, not a boundary — apply the instruction's implications wherever the document needs them, and keep the whole document internally consistent in logic and writing style.
          - Apply ALL /edit segments holistically in one editing pass. If two segments genuinely contradict each other, apply neither, and say so in both segments' results starting with "CONFLICT:".
          - /ask segments: answer the question against the document and the repository you are checked out in. Make no changes for /ask.
          - Do not modify any file other than `#{plan_filename}`.
          - Leave text the instructions do not touch as it is — no gratuitous rewording or reformatting.
          - File references in the document and in results must be GitHub URLs (https://github.com/<owner>/<repo>/blob/HEAD/<path>), never local filesystem paths.

          OUTPUT FORMAT — follow exactly, no other text before or after:
          <<<AI-FLOW:SEGMENT 1>>>
          (for /edit: a one-line summary of what you changed for this item; for /ask: the answer)
          <<<AI-FLOW:SEGMENT 2>>>
          (…one block per segment, in order)
        PROMPT
      end

      # @return [String] what the document is, for the agent's benefit
      def document_description
        @context.pull_request? ? "the description of a GitHub pull request" : "a GitHub issue body"
      end

      # A command posted from a code review thread carries a line anchor —
      # the code the reviewer was looking at. The document is still the edit
      # target; the hunk explains what prompted the feedback.
      #
      # @return [String] empty outside review threads
      def review_thread_anchor
        return "" unless @context.diff_hunk

        <<~ANCHOR
          The command was posted on a code review thread anchored at `#{@context.diff_path}` — this code is what prompted the feedback (the document is still the thing to edit or answer about):
          #{@context.diff_hunk}
        ANCHOR
      end

      # A quote that resolved to a document span is the feedback's location.
      # One that didn't is still real context the reviewer pointed at: when
      # its source comment was found in the thread, hand over the quote plus
      # that comment (author, link, text); otherwise the quote verbatim,
      # flagged as not-in-document.
      #
      # @return [String]
      def segment_focus(segment, span, source)
        if span
          "Focus (the quoted section this feedback concerns):\n#{span}"
        elsif source
          <<~FOCUS.strip
            Context (quoted from @#{source[:author]}'s comment #{source[:url]} on this issue — this text is NOT in the document):
            #{segment.quote}

            The full source comment, for context:
            #{source[:text]}
          FOCUS
        elsif segment.quote
          "Context (quoted by the reviewer from the discussion — this text is NOT in the document):\n#{segment.quote}"
        else
          "Focus: the whole document"
        end
      end

      # @param edits_applied [Boolean] whether the document changed —
      #   an /edit whose pass left the document untouched must not render ✅
      # @return [Array<Array(Segment, String)>]
      def segment_results(resolved, parsed, edits_applied:)
        resolved.each_with_index.map do |(segment, _span), index|
          text = parsed.segments[index + 1]
          if segment.command == "edit" && text&.start_with?("CONFLICT:")
            [segment, "⚠️ **/edit** — #{text}"]
          elsif segment.command == "edit" && !edits_applied
            [segment, "⚠️ **/edit** — the agent made no change to the document." \
                      "#{text ? " Its report: #{text}" : ""}"]
          elsif segment.command == "edit"
            # A missing summary is cosmetic when the edit itself landed — the
            # appended diff carries the change; don't fail the batch over it.
            [segment, "✅ **/edit** — #{text || "(the agent returned no summary — see the diff below)"}"]
          elsif text.nil?
            [segment, "⚠️ **/ask** — the agent returned no answer for this segment."]
          else
            [segment, "✅ **/ask**\n\n#{text}"]
          end
        end
      end

      # One guarded PATCH for the whole batch: refetch and refuse when the body
      # moved since the snapshot (the single updated_at race window).
      def patch_body(snapshot, new_body)
        current = @github.issue(@context.owner_repo, @context.number)
        if PlanBody.from_issue_body(current.body) != snapshot
          raise GitHub::Error,
                "the document changed while the batch was running — no edits were applied; retry"
        end

        @github.update_issue_body(@context.owner_repo, @context.number, body: new_body)
      end

      # @param resolved [Array<Array(Segment, String | nil)>]
      def edits?(resolved)
        resolved.any? { |segment, _span| segment.command == "edit" }
      end

      # Standalone /ask gets a reply (a question-and-answer is a legitimate
      # two-comment conversation); everything else — including /ask inside a
      # batch — lands interleaved in the command comment itself.
      #
      # @param appendix [String, nil] batch-level block (the plan diff)
      # @return [Boolean] whether every segment result is a success
      def deliver(segments, results, appendix: nil)
        if segments.size == 1 && segments.first.command == "ask" && appendix.nil?
          reply(with_footer(results.first.last))
          # The reply doesn't rewrite the command comment, so the dispatcher's
          # ⏳ status line (only added inside Actions, where run_url is set)
          # must be cleared explicitly.
          @result_writer.write_raw(@context, @context.comment_body) if @context.run_url
        else
          @result_writer.write(@context, results, appendix: appendix)
        end
        results.none? { |_segment, text| text.to_s.start_with?("⚠️") }
      end

      # @return [String] the text with the run-link footer, when in Actions
      def with_footer(text)
        footer = @result_writer.footer(@context.run_url)
        footer ? "#{text}\n\n#{footer}" : text
      end

      def reply(text)
        if @context.review_comment?
          @github.reply_to_review_comment(@context.owner_repo, @context.number, @context.comment_id, text)
        else
          @github.post_issue_comment(@context.owner_repo, @context.number, text)
        end
      end
    end
  end
end
