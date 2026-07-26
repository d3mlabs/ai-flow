---
name: dispatch-seams
description: >-
  MUST be used when adding an ai-flow command, changing agent invocation,
  or touching subprocess/auth handling — who owns which seam in
  lib/ai_flow.
---

# Dispatch seams: one owner per boundary

A comment travels `bin/dispatch.rb` → `Context.from_event_file` →
`Dispatcher#run` → a command object. Each boundary has exactly one owner;
a change at a boundary is a change in that one class:

- **`Dispatcher`** re-checks what the workflow's coarse filter can't
  (parseability, the permission gate, batch validity), acks with the 👀
  reaction, edits the ⏳ follow-along line onto the comment, and routes:
  batchable segments (/ask, /edit) to `Commands::Batch` as a single agent
  pass, `/split` and `/build [--split]` to their command objects. It also
  owns run-page telemetry that spans launches (the `GITHUB_STEP_SUMMARY`
  knowledge-applied list).
- **`Agent`** is the one seam to the headless Cursor CLI (the ai-flow
  plan's Decision 4): binary, model policy (`AI_FLOW_MODEL` env >
  `.github/ai-flow.yml` per-command > default > code fallback), stream-json
  parsing, and the per-event progress lines (including `knowledge:` lines
  for skill/rule reads). A different backend is a change here, not in the
  commands.
- **`Executor`** is the one subprocess boundary (`capture` buffered,
  `stream` line-by-line for the live run log). Auth freshness lives here:
  every spawn asks `TokenProvider` for an age-checked token and injects it
  per invocation (GH_TOKEN, git extraheader env) — never baked into a
  checkout, never on argv. Commands call `refresh_auth!` entering their
  write phase.
- **Command objects** (`Commands::*`) own semantics and prompts only; they
  never talk to a subprocess or the CLI directly.

Prompts are owned by the command that launches them; `/build` prompts also
splice in `OrgInvariants#prompt_block` (fresh checkouts carry no rendered
org-invariants.mdc).

Depth: docs/architecture.md (dispatcher structure), docs/commands.md
(per-command semantics).

origin: seeded by ai-flow#13
date: 2026-07-25
