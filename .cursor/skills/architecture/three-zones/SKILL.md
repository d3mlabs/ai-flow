---
name: three-zones
description: >-
  MUST be used when changing where ai-flow work runs or writes — the
  dev-machine / GitHub / self-hosted-runner split and why each zone owns
  what it owns.
---

# ai-flow's three zones

The system has no always-on service. Work is split so each zone does what
it is uniquely cheap or authoritative at:

1. **Dev machine — transient working copies.** Cursor plan files under
   `.cursor/plans/` are scratch space; `dev plan` syncs them against the
   canonical issue. Nothing on a laptop is ever the source of truth.
2. **GitHub — canonical state and event plumbing.** Issues are the plans,
   comments carry the slash commands, PRs carry the proposals. GitHub
   Actions is the dispatcher infrastructure: webhook consumption, queueing,
   and routing are operated by GitHub and cost nothing on self-hosted
   runners. The reusable workflow (`.github/workflows/ai-commands.yml`,
   `workflow_call`-only) is called by a thin caller in each adopting repo —
   ai-flow itself has no caller, so there is no `/build` on ai-flow issues.
3. **Self-hosted runners — execution.** `bin/dispatch.rb` plus
   `lib/ai_flow` (stdlib-only Ruby) drive the headless Cursor agent CLI.
   Jobs route by per-command runner labels (ai-ask / ai-edit / ai-split /
   ai-build); one box can carry all labels. Runner machines are normal dev
   machines: `dev` keeps their org knowledge cache and skill links fresh,
   which is what `/build` prompt injection and `~/.cursor/skills` reads
   ride on.

The GitHub App is identity only: per-job installation tokens (1h cap) give
writes the ai-flow[bot] identity, and — unlike the default `GITHUB_TOKEN` —
App tokens trigger downstream workflows, which is what gives /build PRs
their CI runs.

Depth: docs/architecture.md (system overview and sequence diagrams),
docs/attribution.md (identity and token minting).

origin: seeded by ai-flow#13
date: 2026-07-25
