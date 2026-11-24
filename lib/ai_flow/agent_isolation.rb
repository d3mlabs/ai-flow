# typed: strict
# frozen_string_literal: true

require "etc"
require "fileutils"

module AiFlow
  # The OS-user split's policy object (plans#26): everything ai-flow knows
  # about running the agent as a different, unprivileged user lives here —
  # the sudo spawn prefix, the env allowlist that survives sudo's env_reset,
  # the env overlay the agent's side needs (the CLI's credential store), and
  # the group-share applied to fresh workspaces so both identities can work
  # in them. Opt-in via AI_FLOW_AGENT_USER on runner boxes (written into the
  # runner service env by `dev runner register` — a LaunchAgent plist on a
  # Mac, a systemd unit drop-in on a Linux dev host, plans#59); unset means
  # today's behavior — dispatcher and agent share one user.
  #
  # Nothing here is platform-specific in mechanism: sudo with
  # `--preserve-env=<list>` under a SETENV rule, a world-traversable
  # workspace base, a group share on the leaf. The platform facts dev
  # converges differ — who the runner user is (the operator on a Mac,
  # `runner` on Linux), which group both identities share — and arrive
  # through the service env, never hardcoded here.
  class AgentIsolation
    extend T::Sig

    # AI_FLOW_AGENT_USER names a user this host does not have — the runner
    # box was never converged (`dev runner register`), so isolation must
    # fail closed rather than silently run the agent as the dispatcher.
    class UnknownAgentUserError < StandardError; end

    # The group assumed when the service env carries no AI_FLOW_AGENT_GROUP:
    # the Mac agent bootstrap's original group name. dev writes the
    # variable on every host it registers today (plans#59 — one group,
    # `dev`, across hosts), so this default serves only a Mac registered
    # before that and not re-registered since; a Linux host always has the
    # variable.
    LEGACY_GROUP = "ai"

    # The env keys that survive sudo's env_reset — exactly what
    # Executor injects (the auth header in GIT_CONFIG slot 0, the
    # workspace's safe.directory in slot 1 — see #safe_directory_config)
    # and Agent reads, nothing more. Values travel as env (not argv), so
    # tokens stay off process listings. The agent overlay's keys ride the
    # same allowlist (see #redirect_env). No gem or bundler key is here, and
    # none belongs: the agent's gem env is the caller's (ai-flow#107).
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

    # @return [String] the group both identities share — what
    #   #share_workspace hands fresh workspaces to
    sig { returns(String) }
    attr_reader :group

    class << self
      extend T::Sig

      # @return [AiFlow::AgentIsolation, nil] nil when AI_FLOW_AGENT_USER
      #   is unset (feature off); group from AI_FLOW_AGENT_GROUP (the data
      #   root's group dev writes), LEGACY_GROUP when absent
      # @raise [UnknownAgentUserError] when the configured user does not
      #   exist
      sig { returns(T.nilable(AgentIsolation)) }
      def from_env
        user = ENV["AI_FLOW_AGENT_USER"].to_s.strip
        return nil if user.empty?

        ensure_known!(user)
        group = ENV["AI_FLOW_AGENT_GROUP"].to_s.strip
        new(user: user, group: group.empty? ? LEGACY_GROUP : group)
      end

      private

      # @param user [String] the passwd name to check
      # @return [void]
      # @raise [UnknownAgentUserError]
      sig { params(user: String).void }
      def ensure_known!(user)
        # getpwnam raises ArgumentError for an unknown user rather than
        # returning nil; the rescue below is the real absence path.
        Etc.getpwnam(user)
        nil
      rescue ArgumentError
        raise UnknownAgentUserError,
          "AI_FLOW_AGENT_USER=#{user} but this host has no such user — " \
          "run `dev runner register` to converge the agent bootstrap"
      end
    end

    # @param user [String] the OS user the agent spawns as
    # @param group [String] the shared group both identities belong to
    sig { params(user: String, group: String).void }
    def initialize(user:, group:)
      @user = user
      @group = group
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

    # The env the agent's side of the split needs and the dispatcher's does
    # not: the agent CLI stores credentials in an owner-only file under the
    # agent's home instead of the macOS keychain — a hidden, never-logged-in
    # user has no login keychain, and securityd raises its "Keychain Not
    # Found" dialog in the *runner user's* GUI session (caught live at the
    # plans#36 ceremony). On Linux the file store is the only one a headless
    # user has anyway; the key is harmless there.
    #
    # Gems are not redirected (ai-flow#107): the project's shadowenv sets
    # GEM_HOME to dev's per-project, per-Ruby gem home under the data root
    # (dev#294), which the agent writes through the shared group, so
    # bundler installs there with no key from here. The GEM_HOME/BUNDLE_PATH
    # pair this used to carry pointed at one directory for every Ruby the
    # agent met — bundler keys it by ABI alone, so native extensions built
    # under one 4.0.x loaded under another — and it hid gems dev had already
    # provisioned on the project's GEM_PATH.
    #
    # @return [Hash{String => String}]
    sig { returns(T::Hash[String, String]) }
    def redirect_env
      { "AGENT_CLI_CREDENTIAL_STORE" => "file" }
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
    # spelling the dispatcher created it under; on Linux the realpath is
    # the spelling, and the call is a no-op.
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
    # the 2770 leaf from #share_workspace stays the actual boundary. On
    # Linux the same holds: /tmp's sticky bit governs only who removes the
    # leaf itself (the dispatcher, which created it), and the runner's
    # systemd unit (svc.sh's) sets no PrivateTmp, so the agent and the
    # dispatcher see one /tmp. A tmpfs-backed /tmp bounds a workspace by
    # RAM — fine for the repos that build on a Linux agent host today,
    # none of which carries an engine tree in its checkout.
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
