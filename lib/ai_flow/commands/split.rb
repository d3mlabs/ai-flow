# frozen_string_literal: true

require "json"

module AiFlow
  module Commands
    # /split — the agent proposes well-isolated subtasks; the script reconciles
    # them against existing native sub-issues: create missing ones (GraphQL
    # createIssue with parentIssueId), close stale ones with a comment (never
    # delete), leave matching ones untouched. Idempotent re-runs. Dependencies
    # are recorded as a "Depends on: #n" line in each sub-issue body — the
    # convention /build --split consumes.
    class Split
      REPOSITORY_ID_QUERY = <<~GRAPHQL
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) { id }
        }
      GRAPHQL

      ISSUE_ID_QUERY = <<~GRAPHQL
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) { issue(number: $number) { id } }
        }
      GRAPHQL

      CREATE_SUB_ISSUE_MUTATION = <<~GRAPHQL
        mutation($repositoryId: ID!, $title: String!, $body: String!, $parentIssueId: ID!) {
          createIssue(input: { repositoryId: $repositoryId, title: $title, body: $body, parentIssueId: $parentIssueId }) {
            issue { number url }
          }
        }
      GRAPHQL

      # @param context [AiFlow::Context]
      # @param github [AiFlow::GitHub]
      # @param agent [AiFlow::Agent]
      # @param result_writer [AiFlow::ResultWriter]
      # @param workdir [String]
      def initialize(context:, github:, agent:, result_writer:, workdir:)
        @context = context
        @github = github
        @agent = agent
        @result_writer = result_writer
        @workdir = workdir
      end

      # @param segment [CommentParser::Segment]
      # @return [void]
      def run(segment)
        parent = @github.issue(@context.owner_repo, @context.number)
        existing = @github.sub_issues(@context.owner_repo, @context.number)
        proposal = propose(parent, existing, segment)

        target_repo = target_repo_for(parent)
        created = create_missing(proposal, existing, target_repo)
        closed = close_stale(proposal, existing)
        kept = existing.reject { |issue| closed.include?(issue) }

        @result_writer.write(@context, [[segment, summary(created, closed, kept)]])
      end

      private

      # Ask the agent for the full desired subtask set; reconciliation against
      # what exists is deterministic Ruby, which is what makes re-runs
      # idempotent (matching = same title).
      #
      # @return [Array<Hash>] subtasks: {"title", "body", "depends_on" => [indices]}
      def propose(parent, existing, segment)
        existing_list = existing.map { |issue| "- ##{issue.number} #{issue.title} (#{issue.state})" }.join("\n")
        output = @agent.launch(prompt: <<~PROMPT, workdir: @workdir, command: "split")
          You are ai-flow, splitting a plan into well-isolated subtasks.

          PARENT ISSUE: #{parent.title}
          <<<BODY>>>
          #{PlanBody.from_issue_body(parent.body)}
          <<<END BODY>>>

          EXISTING SUB-ISSUES:
          #{existing_list.empty? ? "(none)" : existing_list}

          #{segment.instruction.empty? ? "" : "Additional instruction: #{segment.instruction}"}

          Propose the FULL desired set of subtasks (not a delta): well-isolated, independently buildable where possible. When a subtask depends on another, reference it by its 0-based index in your list. Reuse the exact title of any existing sub-issue that should stay — titles are the reconciliation key. If integration work across subtasks is needed, include a final integration subtask depending on the others.

          OUTPUT FORMAT — exactly one JSON array, no other text:
          [{"title": "…", "body": "…", "depends_on": [0, 2]}, …]
        PROMPT
        parse_proposal(output)
      end

      # @return [Array<Hash>]
      def parse_proposal(output)
        json = output[/\[.*\]/m]
        raise Agent::Error, "the agent returned no subtask JSON:\n#{output}" unless json

        JSON.parse(json)
      end

      # Org-wide plans that target code declare it explicitly; sub-issues can
      # live in the target code repo as long as the owner matches.
      #
      # @return [String] "owner/repo" for new sub-issues
      def target_repo_for(parent)
        target_line = parent.body[/^Target repos?:\s*(.+)$/, 1]
        return @context.owner_repo unless target_line

        first_target = target_line.split(",").first.to_s.strip
        first_target.empty? ? @context.owner_repo : first_target
      end

      # @return [Array<Hash>] created subtasks (with "number", "url")
      def create_missing(proposal, existing, target_repo)
        existing_titles = existing.map(&:title)
        parent_id = issue_node_id(@context.owner_repo, @context.number)
        repository_id = repository_node_id(target_repo)

        index_to_number = {}
        proposal.each_with_index do |subtask, index|
          match = existing.find { |issue| issue.title == subtask.fetch("title") }
          index_to_number[index] = match.number if match
        end

        created = []
        proposal.each_with_index do |subtask, index|
          next if existing_titles.include?(subtask.fetch("title"))

          data = @github.graphql(CREATE_SUB_ISSUE_MUTATION, {
            repositoryId: repository_id,
            title: subtask.fetch("title"),
            body: subtask.fetch("body", ""),
            parentIssueId: parent_id,
          })
          issue = data.fetch("createIssue").fetch("issue")
          index_to_number[index] = issue.fetch("number")
          created << subtask.merge("number" => issue.fetch("number"), "url" => issue.fetch("url"), "repo" => target_repo)
        end

        annotate_dependencies(proposal, created, index_to_number)
        created
      end

      # Second pass, once every index has a number: append the "Depends on:"
      # convention line to each newly created sub-issue that has dependencies.
      def annotate_dependencies(proposal, created, index_to_number)
        created.each do |subtask|
          index = proposal.index { |candidate| candidate.fetch("title") == subtask.fetch("title") }
          depends_on = proposal.fetch(index).fetch("depends_on", [])
          numbers = depends_on.filter_map { |dep_index| index_to_number[dep_index] }
          next if numbers.empty?

          depends_line = "Depends on: #{numbers.map { |number| "##{number}" }.join(", ")}"
          @github.update_issue_body(
            subtask.fetch("repo"), subtask.fetch("number"),
            body: "#{subtask.fetch("body", "").rstrip}\n\n#{depends_line}\n",
          )
        end
      end

      # Close-with-comment, never delete: sub-issues absent from the proposal
      # are stale.
      #
      # @return [Array<GitHub::Issue>]
      def close_stale(proposal, existing)
        proposed_titles = proposal.map { |subtask| subtask.fetch("title") }
        stale = existing.select { |issue| issue.state == "open" && !proposed_titles.include?(issue.title) }
        stale.each do |issue|
          @github.close_issue(
            issue.repo || @context.owner_repo, issue.number,
            comment: "Closed by /split reconciliation: no longer part of the parent plan's subtask set.",
          )
        end
        stale
      end

      # @return [String] the reconciliation summary appended in place
      def summary(created, closed, kept)
        lines = ["✅ **/split** — reconciled sub-issues (created #{created.size}, closed #{closed.size}, kept #{kept.size})"]
        created.each { |subtask| lines << "- created [##{subtask.fetch("number")} #{subtask.fetch("title")}](#{subtask.fetch("url")})" }
        closed.each { |issue| lines << "- closed ##{issue.number} #{issue.title} (stale)" }
        kept.each { |issue| lines << "- kept ##{issue.number} #{issue.title}" }
        lines.join("\n")
      end

      # @return [String] GraphQL node id
      def repository_node_id(owner_repo)
        owner, name = owner_repo.split("/", 2)
        @github.graphql(REPOSITORY_ID_QUERY, { owner: owner, name: name }).fetch("repository").fetch("id")
      end

      # @return [String] GraphQL node id
      def issue_node_id(owner_repo, number)
        owner, name = owner_repo.split("/", 2)
        @github.graphql(ISSUE_ID_QUERY, { owner: owner, name: name, number: number })
          .fetch("repository").fetch("issue").fetch("id")
      end
    end
  end
end
