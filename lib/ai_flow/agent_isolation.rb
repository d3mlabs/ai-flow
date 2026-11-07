# typed: strict
# frozen_string_literal: true

require "etc"
require "fileutils"

require "ai_flow/runner_slot"

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
    # Executor injects (the auth header in GIT_CONFIG slot 0, the
    # workspace's safe.directory in slot 1 — see #safe_directory_config)
    # and Agent reads, nothing more. Values travel as env (not argv), so
    # tokens stay off process listings. The redirected toolchain keys ride
    # the same allowlist (see #redirect_env).
    PRESERVED_ENV_KEYS = T.let(
      %w[
        GH_TOKEN
        GIT_CONFIG_COUNT
        GIT_CONFIG_KEY_0
        GIT_CONFIG_VALUE_0
        GIT_CONFIG_KEY_1
        GIT_CONFIG_VALUE_1
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
      #   "ai"; slot from AI_FLOW_RUNNER_SLOT (RunnerSlot), default the first
      # @raise [UnknownAgentUserError] when the configured user does not
      #   exist
      # @raise [RunnerSlot::InvalidSlotError] when dev's slot record is not a
      #   slot number
      sig { returns(T.nilable(AgentIsolation)) }
      def from_env
        user = ENV["AI_FLOW_AGENT_USER"].to_s.strip
        return nil if user.empty?

        group = ENV["AI_FLOW_AGENT_GROUP"].to_s.strip
        new(user: user, group: group.empty? ? "ai" : group, home: home_of(user), slot: RunnerSlot.from_env)
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
    # @param slot [RunnerSlot] the host slot this job runs on — per-slot
    #   toolchain state is keyed by it (ai-flow#116)
    sig { params(user: String, group: String, home: String, slot: RunnerSlot).void }
    def initialize(user:, group:, home:, slot: RunnerSlot.first)
      @user = user
      @group = group
      @home = home
      @slot = slot
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

    # Write redirection for the agent's side of the split: installs against
    # shared read-only toolchains (e.g. `bundle install` under the shared
    # ruby) land in agent-owned disposable space instead of failing on the
    # read-only store or widening it, and the agent CLI stores credentials
    # in an owner-only file under the agent's home instead of the macOS
    # keychain — a hidden, never-logged-in user has no login keychain, and
    # securityd raises its "Keychain Not Found" dialog in the *runner
    # user's* GUI session (caught live at the plans#36 ceremony).
    #
    # One gem tree per host slot (ai-flow#116): two slots run as this same
    # user at the same time, and two bundlers in one tree race on its
    # files. Slot 1 keeps the unsuffixed paths it always had — its warm
    # gems stay warm; slot n gets `.gem-<n>` / `.bundle-<n>`.
    #
    # @return [Hash{String => String}]
    sig { returns(T::Hash[String, String]) }
    def redirect_env
      {
        "GEM_HOME" => File.join(@home, ".gem#{@slot.suffix}"),
        "BUNDLE_PATH" => File.join(@home, ".bundle#{@slot.suffix}"),
        "AGENT_CLI_CREDENTIAL_STORE" => "file",
      }
    end

    # The git config entry that lets the agent run git in a workspace the
    # dispatcher created (#101). Git refuses a repository owned by another
    # uid regardless of permissions, so the group share alone is not
    # enough; `safe.directory` is the sanctioned exception, and it travels
    # as env config on the spawn — nothing written to either user's
    # ~/.gitconfig, gone with the run. One entry for the worktree path is
    # all git matches against (a linked worktree's common dir under the
    # job checkout needs no entry of its own). The realpath, because git
    # compares the resolved worktree (/private/tmp/... on macOS), not the
    # spelling the dispatcher created it under.
    #
    # @param workspace [String] the checkout the agent spawns in
    # @return [Array(String, String)] a git config key and value
    sig { params(workspace: String).returns([String, String]) }
    def safe_directory_config(workspace)
      ["safe.directory", File.realpath(workspace)]
    end

    # Where fresh workspaces are created when the agent is another user.
    # Dir.mktmpdir's default base is the dispatcher's per-user tempdir,
    # which macOS creates 0700 (/var/folders/...) — the group share on the
    # workspace leaf is worthless when the agent user cannot traverse the
    # parents to reach it (uv_cwd EACCES at agent startup, caught live at
    # the plans#36 ceremony). /tmp is world-traversable on every platform;
    # the 2770 leaf from #share_workspace stays the actual boundary.
    #
    # @return [String]
    sig { returns(String) }
    def workspace_base
      "/tmp"
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
