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
      unless @context.authorized?
        warn "ai-flow: comment author is #{@context.author_association} — not authorized, ignoring."
        return
      end

      segments = CommentParser.new(prefix: @prefix).parse(@context.comment_body)
      return if segments.empty?

      acknowledge
      route(segments)
    rescue CommentParser::ParseError, GitHub::Error, Agent::Error => e
      report_failure(segments, e)
    end

    private

    # 👀 while running — acknowledgement is a reaction, never a status comment.
    def acknowledge
      @github.react_to_comment(
        @context.owner_repo, @context.comment_id, "eyes",
        review_comment: @context.review_comment?,
      )
    rescue GitHub::Error
      # A failed reaction must not block the command.
    end

    def route(segments)
      if segments.all? { |segment| CommentParser::BATCHABLE_COMMANDS.include?(segment.command) }
        batch.run(segments)
      elsif segments.first.command == "split"
        split.run(segments.first)
      elsif segments.first.flags.include?("--split")
        build_split.run(segments.first)
      else
        build.run(segments.first)
      end
    end

    def batch
      Commands::Batch.new(
        context: @context, github: @github, agent: @agent, executor: @executor,
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
        result_writer: @result_writer, workdir: @workdir,
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
        @github.post_issue_comment(@context.owner_repo, @context.number, message)
      end
      warn "ai-flow: #{error.class}: #{error.message}"
      exit 1
    end
  end
end
