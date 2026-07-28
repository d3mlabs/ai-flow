# typed: strict
# frozen_string_literal: true

require "erb"

module AiFlow
  # Commit identity for web-initiated work (see docs/attribution.md): the
  # commit layer answers "who created these bytes", so author = committer =
  # the ai-flow bot. The requesting human is credited with a Co-authored-by
  # trailer — contribution-graph credit without an authorship claim — and
  # accountability lives at the PR layer (Requested by + assignee + merge).
  module CommitIdentity
    extend T::Sig

    DEFAULT_BOT_LOGIN = "ai-flow[bot]"

    # extend self (not module_function): module_function copies methods onto
    # the singleton before sorbet-runtime wraps them, silently skipping every
    # runtime sig validation. extend self keeps one wrapped method in the chain.
    extend self

    # App names are globally unique, so an adopter's App slug may differ from
    # ours; the workflow derives the login from the minted token's app-slug
    # output and passes it down as AI_FLOW_BOT_LOGIN.
    #
    # @return [String]
    sig { returns(String) }
    def bot_login
      ENV.fetch("AI_FLOW_BOT_LOGIN", DEFAULT_BOT_LOGIN)
    end

    # @param github [AiFlow::GitHub]
    # @return [Array<String>] `git -c` flags setting author and committer
    sig { params(github: GitHub).returns(T::Array[String]) }
    def git_flags(github)
      ["-c", "user.name=#{bot_login}", "-c", "user.email=#{bot_email(github)}"]
    end

    # The canonical <id>+<login>@users.noreply.github.com form is what links
    # commits to the bot's identity on GitHub; the plain form is a safe
    # fallback when the lookup fails (still a valid noreply address).
    #
    # @param github [AiFlow::GitHub]
    # @return [String]
    sig { params(github: GitHub).returns(String) }
    def bot_email(github)
      bot_id = github.api("users/#{ERB::Util.url_encode(bot_login)}").fetch("id")
      "#{bot_id}+#{bot_login}@users.noreply.github.com"
    rescue StandardError
      "#{bot_login}@users.noreply.github.com"
    end

    # @param message [String]
    # @param context [AiFlow::Context]
    # @return [String] the message with the requesting human's co-author
    #   trailer (unchanged when the payload carried no user)
    sig { params(message: String, context: Context).returns(String) }
    def message_with_requester(message, context)
      return message unless context.commenter_login

      "#{message}\n\nCo-authored-by: #{context.commenter_login} <#{requester_email(context)}>"
    end

    # The <id>+<login> noreply form links for all accounts (the plain login@
    # form predates 2017 accounts).
    #
    # @param context [AiFlow::Context]
    # @return [String]
    sig { params(context: Context).returns(String) }
    def requester_email(context)
      return "#{context.commenter_login}@users.noreply.github.com" unless context.commenter_id

      "#{context.commenter_id}+#{context.commenter_login}@users.noreply.github.com"
    end
  end
end
