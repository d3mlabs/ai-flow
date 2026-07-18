# frozen_string_literal: true

module AiFlow
  # Routes a parsed comment to its command. The workflow-level filter already
  # dropped non-command comments (no billed no-op runs); this re-checks
  # everything server-side state depends on: parseability, the permission
  # gate, and batch validity. Failures are reported on the comment itself.
  class Dispatcher
    # @param context [AiFlow::Context]
    # @param workdir [String] the job's repo checkout
    # @param prefix [String] configured command prefix ("" by default)
    # @param github [AiFlow::GitHub]
    # @param agent [AiFlow::Agent]
    # @param executor [AiFlow::Executor]
    def initialize(context:, workdir:, prefix: "", github: nil, agent: nil, executor: Executor.new)
      @context = context
      @workdir = workdir
      @prefix = prefix
      @executor = executor
      @github = github || GitHub.new(executor: executor)
      @agent = agent || Agent.new(executor: executor)
      @result_writer = ResultWriter.new(github: @github)
    end

    # @return [void]
    def run
      unless authorized?
        warn "ai-flow: comment author is #{@context.author_association} — not authorized, ignoring."
        return
      end

      segments = CommentParser.new(prefix: @prefix).parse(@context.comment_body)
      return if segments.empty?

      acknowledge
      announce_running
      return if route(segments)

      # Soft failure: the per-segment ⚠️ is already on the comment; the run
      # itself must still go red so a failed command is visible from Actions.
      warn "ai-flow: one or more segments failed — see the command comment."
      exit 1
    rescue CommentParser::ParseError, GitHub::Error, Agent::Error, SubtasksSection::Error => e
      report_failure(segments, e)
    end

    private

    # The payload's author_association is the cheap first gate, but
    # review-comment payloads under-report it (an org MEMBER can arrive as
    # CONTRIBUTOR), so a miss falls back to the collaborator-permission API —
    # the authoritative answer. A failed lookup denies (fail closed).
    def authorized?
      return true if @context.authorized?
      return false unless @context.commenter_login

      permission = @github.collaborator_permission(@context.owner_repo, @context.commenter_login)
      %w[admin write].include?(permission)
    rescue GitHub::Error
      false
    end

    # 👀 while running — acknowledgement is a reaction, never a status comment.
    def acknowledge
      @github.react_to_comment(
        @context.owner_repo, @context.comment_id, "eyes",
        review_comment: @context.review_comment?,
      )
    rescue GitHub::Error
      # A failed reaction must not block the command.
    end

    # Temporary "follow along" link on the command comment. Every final
    # render starts from the payload body, so this line vanishes when the
    # results land (the run link persists as the ResultWriter footer); the
    # standalone-/ask reply path reverts it explicitly. Placed after the
    # exact parse, so prose mentions never get it.
    def announce_running
      url = @context.run_url
      return unless url

      @result_writer.write_raw(
        @context,
        "#{@context.comment_body.rstrip}\n\n> ⏳ ai-flow is running — [follow the run](#{url})",
      )
    rescue GitHub::Error
      # A failed status line must not block the command.
    end

    # @return [Boolean] whether the command(s) fully succeeded — only batches
    #   have per-segment soft failures; the other commands raise on failure.
    def route(segments)
      if segments.all? { |segment| CommentParser::BATCHABLE_COMMANDS.include?(segment.command) }
        batch.run(segments)
      elsif segments.first.command == "split"
        split.run(segments.first)
        true
      elsif segments.first.flags.include?("--split")
        if @context.pull_request?
          raise CommentParser::ParseError, "/build --split runs on plan issues, not pull requests."
        end

        build_split.run(segments.first)
        true
      else
        build.run(segments.first)
        true
      end
    end

    def batch
      Commands::Batch.new(
        context: @context, github: @github, agent: @agent,
        rich_diff: RichDiff.new(executor: @executor),
        result_writer: @result_writer, workdir: @workdir,
      )
    end

    def split
      Commands::Split.new(
        context: @context, github: @github, agent: @agent,
        result_writer: @result_writer, workdir: @workdir,
      )
    end

    def build
      Commands::Build.new(
        context: @context, github: @github, agent: @agent, executor: @executor,
        result_writer: @result_writer, workdir: @workdir, prefix: @prefix,
      )
    end

    def build_split
      Commands::BuildSplit.new(
        context: @context, github: @github, build: build, result_writer: @result_writer,
      )
    end

    # Failures land on the command comment too (in place when we know the
    # segments, as a note otherwise) — never silent, never a separate thread.
    def report_failure(segments, error)
      message = "⚠️ **ai-flow failed:** #{error.message}"
      if segments && !segments.empty?
        @result_writer.write(@context, [[segments.first, message]])
      else
        footer = @result_writer.footer(@context.run_url)
        message = "#{message}\n\n#{footer}" if footer
        @github.post_issue_comment(@context.owner_repo, @context.number, message)
      end
      warn "ai-flow: #{error.class}: #{error.message}"
      exit 1
    end
  end
end
