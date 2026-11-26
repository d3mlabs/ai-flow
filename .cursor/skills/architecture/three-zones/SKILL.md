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
   `workflow_call`-only) is called by a thin caller in each adopting repo
   at the series tag `@v1`; ai-flow's own caller is the one exception that
   cannot pin itself (there, the checkout's `exe/ai-flow` runs).
3. **Self-hosted runners — execution.** `exe/ai-flow dispatch` plus
   `lib/ai_flow` drive the headless Cursor agent CLI. ai-flow reaches a
   job as the released tree the adopter's lock pins (`gh
   "d3mlabs/ai-flow", "^1"`), installed into the adopter's checkout by the
   job's own `dev up` — nothing of ai-flow's is read from the runner's
   environment and a host records no version of it — and the host's shape
   — the `agent` and `orchestrator` roles, labels, groups, the `ai-agent`
   job identity, `cursor-cli` — is declared in this repo's `dev.yml` and
   `dependencies.rb`, not in dev. Jobs route by per-command runner labels
   (ai-ask / ai-edit / ai-split / ai-build / ai-learn); one box can carry
   all labels. Runner machines are normal dev machines: `dev` keeps their
   org knowledge cache and skill links fresh, which is what `/build`
   prompt injection and `~/.cursor/skills` reads ride on.

The GitHub App is identity only: per-job installation tokens (1h cap) give
writes the ai-flow[bot] identity, and — unlike the default `GITHUB_TOKEN` —
App tokens trigger downstream workflows, which is what gives /build PRs
their CI runs.

Depth: docs/architecture.md (system overview and sequence diagrams),
docs/attribution.md (identity and token minting).

origin: seeded by ai-flow#13; the runner zone's install path revised by
ai-flow#186 (the adopter's lock, not a per-job head install)
date: 2026-11-25
