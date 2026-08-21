# typed: strict
# frozen_string_literal: true

require "etc"
require "fileutils"

module AiFlow
  # The OS-user split's policy object (plans#26): everything ai-flow knows
  # about running the agent as a different, unprivileged user lives here —
  # the sudo spawn prefix, the env allowlist that survives sudo's env_reset,
  # the toolchain-write redirection into the agent's own home, and the
  # group-share applied to fresh workspaces so both identities can work in
  # them. Opt-in via AI_FLOW_AGENT_USER on runner boxes (written into the
  # runner service env by `dev runner register`); unset means today's
  # behavior — dispatcher and agent share one user.
  class AgentIsolation
    extend T::Sig

    # AI_FLOW_AGENT_USER names a user this host does not have — the runner
    # box was never converged (`dev runner register`), so isolation must
    # fail closed rather than silently run the agent as the dispatcher.
    class UnknownAgentUserError < StandardError; end

    # The env keys that survive sudo's env_reset — exactly what
    # Executor#auth_overlay injects and Agent reads, nothing more. Values
    # travel as env (not argv), so tokens stay off process listings. The
    # redirected toolchain keys ride the same allowlist (see #redirect_env).
    PRESERVED_ENV_KEYS = T.let(
      %w[
        GH_TOKEN
        GIT_CONFIG_COUNT
        GIT_CONFIG_KEY_0
        GIT_CONFIG_VALUE_0
        CURSOR_API_KEY
        AI_FLOW_MODEL
        AI_FLOW_AGENT_BIN
        PATH
      ].freeze,
      T::Array[String],
    )

    # @return [String] the OS user the agent spawns as
    sig { returns(String) }
    attr_reader :user

    class << self
      extend T::Sig

      # @return [AiFlow::AgentIsolation, nil] nil when AI_FLOW_AGENT_USER
      #   is unset (feature off); group from AI_FLOW_AGENT_GROUP, default
      #   "ai"
      # @raise [UnknownAgentUserError] when the configured user does not
      #   exist
      sig { returns(T.nilable(AgentIsolation)) }
      def from_env
        user = ENV["AI_FLOW_AGENT_USER"].to_s.strip
        return nil if user.empty?

        group = ENV["AI_FLOW_AGENT_GROUP"].to_s.strip
        new(user: user, group: group.empty? ? "ai" : group, home: home_of(user))
      end

      private

      # @param user [String] the passwd name to resolve
      # @return [String] the user's home directory
      # @raise [UnknownAgentUserError]
      sig { params(user: String).returns(String) }
      def home_of(user)
        # T.must: getpwnam raises ArgumentError for an unknown user rather
        # than returning nil; the rescue below is the real absence path.
        T.must(Etc.getpwnam(user)).dir
      rescue ArgumentError
        raise UnknownAgentUserError,
          "AI_FLOW_AGENT_USER=#{user} but this host has no such user — " \
          "run `dev runner register` to converge the agent bootstrap"
      end
    end

    # @param user [String] the OS user the agent spawns as
    # @param group [String] the shared group both identities belong to
    # @param home [String] the agent user's home directory
    sig { params(user: String, group: String, home: String).void }
    def initialize(user:, group:, home:)
      @user = user
      @group = group
      @home = home
    end

    # The argv prefix that re-executes the agent as @user. No wrapper
    # script (a pinned wrapper that execs arbitrary argv restricts
    # nothing): one sudoers SETENV rule, with the allowlist traveling on
    # the command so it lives here, not in sudoers — dev provisions a
    # generic sidecar-user posture. -n never prompts (the rule is
    # NOPASSWD; anything else is a hard failure), -H + env_reset give the
    # agent its own HOME.
    #
    # @return [Array<String>]
    sig { returns(T::Array[String]) }
    def spawn_prefix
      preserved = PRESERVED_ENV_KEYS + redirect_env.keys
      ["sudo", "-n", "-H", "-u", @user, "--preserve-env=#{preserved.join(",")}", "--"]
    end

    # Toolchain-write redirection: installs against shared read-only
    # toolchains (e.g. `bundle install` under the shared ruby) land in
    # agent-owned disposable space instead of failing on the read-only
    # store or widening it.
    #
    # @return [Hash{String => String}]
    sig { returns(T::Hash[String, String]) }
    def redirect_env
      {
        "GEM_HOME" => File.join(@home, ".gem"),
        "BUNDLE_PATH" => File.join(@home, ".bundle"),
      }
    end

    # Open a freshly created (still empty) workspace parent to both
    # identities: group-owned, setgid, group-writable — everything
    # populated inside inherits the shared group, and the dispatcher's
    # 0o002 umask keeps its own writes group-rw.
    #
    # @param dir [String] the workspace parent, right after mktmpdir
    # @return [void]
    sig { params(dir: String).void }
    def share_workspace(dir)
      FileUtils.chown(nil, @group, dir)
      FileUtils.chmod(0o2770, dir)
    end
  end
end
