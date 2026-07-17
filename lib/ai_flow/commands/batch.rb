# frozen_string_literal: true

module AiFlow
  module Commands
    # Runs an /ask///edit batch — the review work unit (plan, Component 4).
    #
    # Issue mode is file-based, mirroring how Cursor handles a chat message
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
    #
    # On a code PR, /edit means "apply the instruction to the code": the agent
    # works on the PR branch, commits and pushes, and the result is the commit
    # link plus a summary instead of a body rich diff.
    class Batch
      # @param context [AiFlow::Context]
      # @param github [AiFlow::GitHub]
      # @param agent [AiFlow::Agent]
      # @param rich_diff [AiFlow::RichDiff]
      # @param result_writer [AiFlow::ResultWriter]
      # @param executor [AiFlow::Executor]
      # @param workdir [String] the job's repo checkout
      def initialize(context:, github:, agent:, rich_diff:, result_writer:, executor:, workdir:)
        @context = context
        @github = github
        @agent = agent
        @rich_diff = rich_diff
        @result_writer = result_writer
        @executor = executor
        @workdir = workdir
      end

      # @param segments [Array<CommentParser::Segment>]
      # @return [Boolean] whether every segment succeeded (a ⚠️ result is a
      #   soft failure: it is reported on the comment, and the caller turns it
      #   into a red workflow run)
      def run(segments)
        if @context.pull_request?
          run_on_pull_request(segments)
        else
          run_on_issue(segments)
        end
      end

      private

      # ---- Issue (plan) mode ----

      # The plan file the agent edits, at the root of the job's checkout (the
      # agent CLI works within its working directory) — never committed in
      # issue mode, and deleted after the pass.
      #
      # @return [String] filename relative to the workdir
      def plan_filename
        "ai-flow-plan-#{@context.number}.md"
      end

      def run_on_issue(segments)
        issue = @github.issue(@context.owner_repo, @context.number)
        snapshot = PlanBody.from_issue_body(issue.body)

        resolved, stale = resolve_anchors(segments, snapshot)
        stale_results = stale.map do |segment|
          [segment, "⚠️ The quoted text was not found in the current body — it changed between " \
                    "posting and execution. Re-quote against the current body and retry."]
        end

        results = stale_results
        appendix = nil
        if resolved.any?
          parsed, new_body = run_plan_file_pass(resolved, snapshot)
          edits_applied = !new_body.nil?
          results += issue_segment_results(resolved, parsed, edits_applied: edits_applied)
          if edits_applied
            patch_body(snapshot, new_body)
            appendix = plan_diff_appendix(snapshot, new_body)
          end
        end

        deliver(segments, results, appendix: appendix)
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
          prompt: issue_batch_prompt(resolved, snapshot),
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
        header = ["**Plan updated**", diff.backlink].compact.join(" — ")
        "#{header}\n\n#{diff.collapsed}"
      end

      # Phase 1: every quote resolves against the snapshot, or the segment is
      # reported stale. Unscoped segments resolve to the whole document.
      #
      # @return [Array(Array<Array(Segment, String | nil)>, Array<Segment>)]
      def resolve_anchors(segments, snapshot)
        resolved = []
        stale = []
        segments.each do |segment|
          if segment.quote.nil?
            resolved << [segment, nil]
          elsif (span = PlanBody.locate_quote(snapshot, segment.quote))
            resolved << [segment, span]
          else
            stale << segment
          end
        end
        [resolved, stale]
      end

      def issue_batch_prompt(resolved, snapshot)
        segment_descriptions = resolved.each_with_index.map do |(segment, span), index|
          <<~SEGMENT
            <<<SEGMENT #{index + 1}: /#{segment.command}>>>
            #{span ? "Focus (the quoted section this feedback concerns):\n#{span}" : "Focus: the whole document"}
            Instruction: #{segment.instruction.empty? ? "(none — the quote itself is the subject)" : segment.instruction}
          SEGMENT
        end.join("\n")

        <<~PROMPT
          You are ai-flow, processing a batch of review commands against a plan document (a GitHub issue body). The document is the file `#{plan_filename}` in your working directory; every reviewer quote below was taken against its current content.

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

      # @param edits_applied [Boolean] whether the plan document changed —
      #   an /edit whose pass left the document untouched must not render ✅
      # @return [Array<Array(Segment, String)>]
      def issue_segment_results(resolved, parsed, edits_applied:)
        resolved.each_with_index.map do |(segment, _span), index|
          text = parsed.segments[index + 1]
          if segment.command == "edit" && text&.start_with?("CONFLICT:")
            [segment, "⚠️ **/edit** — #{text}"]
          elsif segment.command == "edit" && !edits_applied
            [segment, "⚠️ **/edit** — the agent made no change to the plan document." \
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
                "the issue body changed while the batch was running — no edits were applied; retry"
        end

        @github.update_issue_body(@context.owner_repo, @context.number, body: new_body)
      end

      # ---- Code-PR mode ----

      def run_on_pull_request(segments)
        checkout_pr_branch if segments.any? { |segment| segment.command == "edit" }

        results = segments.map do |segment|
          text =
            case segment.command
            when "ask" then pr_ask(segment)
            when "edit" then pr_edit(segment)
            end
          [segment, text]
        end

        deliver(segments, results)
      end

      def pr_ask(segment)
        answer = @agent.launch(prompt: pr_prompt(segment, action: :answer), workdir: @workdir, command: "ask")
        "✅ **/ask**\n\n#{answer}"
      end

      # /edit on a code PR: apply the instruction on the PR branch, commit and
      # push; the result is the commit link plus a short summary.
      def pr_edit(segment)
        summary = @agent.launch(
          prompt: pr_prompt(segment, action: :apply), workdir: @workdir, command: "edit", force: true,
        )
        sha = commit_and_push(segment)
        commit_note = sha ? "Committed [`#{sha[0, 7]}`](https://github.com/#{@context.owner_repo}/commit/#{sha})." : "No file changes were needed."
        "✅ **/edit**\n\n#{commit_note}\n\n#{summary}"
      end

      def pr_prompt(segment, action:)
        anchor =
          if @context.diff_hunk
            "Line anchor (#{@context.diff_path}):\n#{@context.diff_hunk}"
          elsif segment.quote
            "Quoted context:\n#{segment.quote}"
          else
            "Scope: the whole pull request"
          end
        task =
          if action == :answer
            "Answer the question. Do not modify any files."
          else
            "Apply the instruction to the code on the current branch. Reply with a short summary of what you changed."
          end
        <<~PROMPT
          You are ai-flow, acting on pull request #{@context.owner_repo}##{@context.number} in this checkout.

          #{anchor}

          Instruction: #{segment.instruction.empty? ? "(none — the anchor itself is the subject)" : segment.instruction}

          #{task}
        PROMPT
      end

      def checkout_pr_branch
        branch = @context.pr_head_ref || pr_head_ref_from_api
        run_git("fetch", "origin", branch)
        run_git("checkout", branch)
      end

      def pr_head_ref_from_api
        @github.api("repos/#{@context.owner_repo}/pulls/#{@context.number}").fetch("head").fetch("ref")
      end

      # @return [String, nil] the pushed commit sha, or nil when nothing changed
      def commit_and_push(segment)
        run_git("add", "-A")
        status, = @executor.capture("git", "status", "--porcelain", chdir: @workdir)
        return nil if status.strip.empty?

        message = CommitIdentity.message_with_requester(
          "ai-flow /edit: #{segment.instruction.lines.first.to_s.strip[0, 60]}", @context
        )
        run_git(*CommitIdentity.git_flags(@github), "commit", "-m", message)
        run_git("push")
        sha, = @executor.capture("git", "rev-parse", "HEAD", chdir: @workdir)
        sha.strip
      end

      def run_git(*argv)
        _out, err, ok = @executor.capture("git", *argv, chdir: @workdir)
        raise GitHub::Error, "git #{argv.first} failed: #{err.strip}" unless ok
      end

      # ---- Shared ----

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
          reply(results.first.last)
        else
          @result_writer.write(@context, results, appendix: appendix)
        end
        results.none? { |_segment, text| text.to_s.start_with?("⚠️") }
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
