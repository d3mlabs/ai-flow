# frozen_string_literal: true

module AiFlow
  module Commands
    # Runs an /ask///edit batch — the review work unit (plan, Component 4).
    #
    # Two-phase, because every quote was taken against the same body the
    # reviewer read, so segments must never be invalidated by their siblings'
    # edits:
    # - Phase 1 resolves all quotes against a snapshot taken at batch start;
    #   the only per-segment failure is a quote missing from that snapshot.
    # - Phase 2 is one agent pass applying all /edit instructions against the
    #   snapshot, producing one new body — one guarded PATCH for the whole
    #   batch. /ask segments answer against the same snapshot.
    #
    # On a code PR, /edit means "apply the instruction to the code": the agent
    # works on the PR branch, commits and pushes, and the in-place result is
    # the commit link plus a summary instead of a body rich diff.
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
      # @return [void]
      def run(segments)
        if @context.pull_request?
          run_on_pull_request(segments)
        else
          run_on_issue(segments)
        end
      end

      private

      # ---- Issue (plan) mode ----

      def run_on_issue(segments)
        issue = @github.issue(@context.owner_repo, @context.number)
        snapshot = PlanBody.from_issue_body(issue.body)

        resolved, stale = resolve_anchors(segments, snapshot)
        results = stale.map do |segment|
          [segment, "⚠️ The quoted text was not found in the current body — it changed between " \
                    "posting and execution. Re-quote against the current body and retry."]
        end

        if resolved.any?
          parsed = run_agent_pass(resolved, snapshot)
          results += issue_segment_results(resolved, parsed, snapshot)
          new_body = integrated_body(resolved, parsed, snapshot)
          patch_body(issue, snapshot, new_body) if new_body && edits?(resolved)
        end

        deliver(segments, results)
      end

      # The new document to PATCH. Anchored edits are spliced into the snapshot
      # deterministically from the per-segment rewrites — models reliably
      # rewrite the section they were pointed at but often return the BODY
      # echo unintegrated (observed in the wild: correct segments, untouched
      # 15KB document). The agent's BODY output is used only where splicing
      # can't work: unscoped edits, and spans invalidated by an earlier splice.
      #
      # @return [String, nil] nil when no change to write
      def integrated_body(resolved, parsed, snapshot)
        spliced = snapshot.dup
        needs_agent_body = false

        resolved.each_with_index do |(segment, span), index|
          next unless segment.command == "edit"

          text = parsed.segments[index + 1]
          next if text.nil? || text.start_with?("CONFLICT:")

          if span && spliced.include?(span)
            spliced = spliced.sub(span) { text }
          else
            needs_agent_body = true
          end
        end

        if needs_agent_body
          agent_body = parsed.body
          return agent_body if agent_body && agent_body.strip != snapshot.strip
        end
        spliced == snapshot ? nil : spliced
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

      # Phase 2: one agent pass over the snapshot with every segment.
      #
      # @return [AgentOutput::Parsed]
      def run_agent_pass(resolved, snapshot)
        output = @agent.launch(
          prompt: issue_batch_prompt(resolved, snapshot),
          workdir: @workdir,
          command: edits?(resolved) ? "edit" : "ask",
        )
        AgentOutput.parse(output)
      end

      def issue_batch_prompt(resolved, snapshot)
        segment_descriptions = resolved.each_with_index.map do |(segment, span), index|
          <<~SEGMENT
            <<<SEGMENT #{index + 1}: /#{segment.command}>>>
            #{span ? "Anchored section:\n#{span}" : "Scope: the whole document"}
            Instruction: #{segment.instruction.empty? ? "(none — the quote itself is the subject)" : segment.instruction}
          SEGMENT
        end.join("\n")

        <<~PROMPT
          You are ai-flow, processing a batch of review commands against a plan document (a GitHub issue body). Work strictly from the snapshot below — it is the body every reviewer quote was taken against.

          SNAPSHOT DOCUMENT:
          <<<DOCUMENT>>>
          #{snapshot}
          <<<END DOCUMENT>>>

          SEGMENTS:
          #{segment_descriptions}

          Rules:
          - /edit segments: rewrite the anchored section (or the whole document when unscoped) per the instruction. Integrate ALL edit segments holistically into ONE new document. If two segments genuinely contradict each other, apply neither, and say so in both segments' results starting with "CONFLICT:".
          - /ask segments: answer the question against the snapshot (and the repository you are checked out in, read-only). Make no document changes for /ask.
          - Preserve everything you were not asked to change, byte for byte.

          OUTPUT FORMAT — follow exactly, no other text before or after:
          #{edits?(resolved) ? "<<<AI-FLOW:BODY>>>\n(the full new document)\n" : ""}<<<AI-FLOW:SEGMENT 1>>>
          (for /edit: the rewritten section exactly as it appears in the new document; for /ask: the answer)
          <<<AI-FLOW:SEGMENT 2>>>
          (…one block per segment, in order)
        PROMPT
      end

      # @return [Array<Array(Segment, String)>]
      def issue_segment_results(resolved, parsed, snapshot)
        resolved.each_with_index.map do |(segment, span), index|
          text = parsed.segments[index + 1] || "⚠️ The agent returned no result for this segment."
          if segment.command == "edit" && !text.start_with?("CONFLICT:")
            diff = @rich_diff.render(
              before: span || snapshot,
              after: text,
              backlink_url: @context.subject_url,
            )
            # Header line stays visible (status + backlink); the diff views are
            # collapsed below it, so a segment scans as three compact lines.
            header = ["✅ **/#{segment.command}**", diff.backlink].compact.join(" — ")
            [segment, "#{header}\n\n#{diff.collapsed}"]
          else
            [segment, "✅ **/#{segment.command}**\n\n#{text}"]
          end
        end
      end

      # One guarded PATCH for the whole batch: refetch and refuse when the body
      # moved since the snapshot (the single updated_at race window).
      def patch_body(issue, snapshot, new_body)
        current = @github.issue(@context.owner_repo, @context.number)
        if PlanBody.from_issue_body(current.body) != snapshot
          raise GitHub::Error,
                "the issue body changed while the batch was running — no edits were applied; retry"
        end

        @github.update_issue_body(
          @context.owner_repo, @context.number,
          body: PlanBody.managed?(issue.body) ? PlanBody.to_issue_body(new_body) : new_body,
        )
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
      # batch — lands in place in the command comment.
      def deliver(segments, results)
        if segments.size == 1 && segments.first.command == "ask"
          reply(results.first.last)
        else
          @result_writer.write(@context, results)
        end
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
