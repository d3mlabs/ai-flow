---
name: workflows-wall
description: >-
  MUST be used when a change touches .github/workflows anywhere ai-flow
  writes — why the App cannot push workflow files and what the fallback
  is.
---

# The workflows wall: the App cannot push workflow files

The ai-flow App deliberately lacks the `workflows` permission
(docs/attribution.md). Two reasons:

1. GitHub rejects any App push touching workflow files wholesale — the
   whole push fails, not just the workflow file.
2. A workflow pushed to a branch could execute on `pull_request` events
   before any human merges it — the permission gap is a safety boundary,
   not an oversight.

Consequences, and the pattern to preserve:

- **`Commands::Build` excludes `.github/workflows` from every commit**
  (`extract_workflows_patch`): the staged workflow diff is captured, then
  unstaged and reverted, and surfaces in the result panel as a collapsed
  suggested patch plus a `::group::` block in the run log. Apply it by
  hand if wanted.
- **Caller-workflow rollout is human work by construction.** Changes to
  adopting repos' `.github/workflows/ai-commands.yml` callers (new event
  types, filters, labels) ride a human-pushed credential — plan for a
  manual rollout step whenever the reusable workflow's interface grows.
- **ai-flow's own reusable workflow is `@main`-tracked** by callers, so
  dispatcher code and workflow YAML stay in lockstep; a tag pin would
  silently split the two versions.

Wrong: teaching /build to commit workflow files when the diff "looks
safe". Right: keep the exclusion absolute; the suggested-patch panel is
the only channel.

Depth: docs/attribution.md (App permissions), lib/ai_flow/commands/build.rb
(`WORKFLOWS_DIR` handling).

origin: seeded by ai-flow#13
date: 2026-07-25
