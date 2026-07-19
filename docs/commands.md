# Command reference

The normative reference for ai-flow's four commands: each one per surface,
with flags, the state-dependent decision tables, and every refusal message
verbatim (refusals are UX — if you got one, you should be able to find it
here by searching). The end-to-end story of a plan — authoring, splitting,
building, iterating — lives in [plan-lifecycle.md](plan-lifecycle.md);
internals live in [architecture.md](architecture.md).

## The consistency rule

`/ask` and `/edit` always operate on the **document** — the issue body or
the PR description. `/build` always operates on **code** — open a PR from
an issue, iterate on the head branch from a PR. `/split` operates on the
plan's **decomposition** — its native sub-issues.

Commands are recognized only at the start of a comment line (prose mentions
never fire). Quote-reply (select rendered text, press `r`) is the section
anchor — the remote cmd+L.

## Surfaces at a glance

| | Issue | PR conversation | PR review thread |
|---|---|---|---|
| `/ask` | ✅ answers on the plan | ✅ answers on the description | ✅ answers threaded, line anchor as scope |
| `/edit` | ✅ edits the plan body | ✅ edits the description | ✅ edits the description, anchor as focus |
| `/split` | ✅ dry / apply / bare | — | — |
| `/build` | ✅ plan → PR (state-aware) | ✅ iterates the head branch | ℹ️ refused, sweep picks the thread up |
| `/build --split` | ✅ orchestrates sub-issues | ℹ️ refused | ℹ️ refused |

## /ask

Read-only Q&A against the document plus the repo checkout.

- **Standalone** `/ask` gets a **reply comment** (threaded when posted in a
  review thread — the one exception to the noise protocol, since a question
  and answer is a legitimate two-comment conversation).
- **In a batch** (a comment mixing several quote+`/ask`/`/edit` pairs) the
  answer lands **in place**, interleaved under its quote+command.
- A quote scopes the question; in a review thread the line anchor
  (path + diff hunk) is carried as scope automatically.

## /edit

Edits the document as a file: one agent pass owns the whole document's
consistency, then one guarded PATCH lands it. Quotes are focus anchors, not
edit boundaries — implications land wherever the document needs them. Each
segment's ✅ one-line summary interleaves under its quote+command; one
combined collapsed Word diff + Source diff appends at the bottom.

Batches are limited to `/ask` and `/edit`; `/split` and `/build` are
lifecycle operations that must be a comment's only command:

> /split must be a comment's only command — batches are limited to /ask and /edit.

If the body moved while the batch ran, nothing is written:

> the document changed while the batch was running — no edits were applied; retry

## /split

Plan/apply over sub-issues, like Terraform: the LLM participates only in
the propose phase; the execute phase is a deterministic parse of the frozen
artifact.

| Invocation | What runs |
|---|---|
| `/split --dry` | One agent pass proposes the full subtask set, then a guarded PATCH stages it as a fenced-yaml `## Subtasks` section in the plan body — human-editable escrow. Nothing is created. |
| `/split --apply` | **No agent call.** Parses the `## Subtasks` section as it exists at apply time and reconciles sub-issues against it. Human edits between the phases are honored as intent. Re-running is idempotent. |
| `/split` (bare) | Both phases in one run. |
| `/split <instruction>` | The instruction feeds the propose phase (with `--dry` or bare). |

### Per-subtask repo routing

Every proposal entry carries a `repo:` — the repository its work lands in.
The agent sees the full repo menu of the plan's owner (a `Target repos:`
line in the plan body narrows it — declared scope), each annotated with
whether the ai-flow App is installed there. The agent is never blindfolded
into a subset; deterministic Ruby enforces reality at apply time:

- App installed on the target → the sub-issue is created there (native
  cross-repo sub-issue of the plan).
- App **not** installed → the sub-issue is created on the parent's repo
  instead, with an `Intended repo: <owner/repo>` line in its body, and the
  result panel warns: install the App there and re-run `/split` to move it.
  Never a silent reroute.

Dependencies always render fully qualified — `Depends on: owner/repo#n` —
one format, no branching (GitHub autolinks it everywhere and shortens the
same-repo form visually).

### The `## Subtasks` section (v1)

~~~markdown
## Subtasks
<!-- ai-flow:subtasks v1 — edit freely, then comment `/split --apply` -->

```yaml
- title: "Hosted authorize job gating dispatch"
  repo: d3mlabs/ai-flow

- title: "Restrict Default runner group"
  repo: d3mlabs/plans
  depends_on: [0]
  existing: d3mlabs/plans#9
  # possible match: d3mlabs/plans#12 "Runner group hardening"
```
~~~

- Entries are **title-only** — the parent plan is the spec, and sub-issues
  are thin tracking shards of it, so titles must be self-explanatory about
  their scope. There is no per-subtask body in the interface; keys outside
  it are ignored. Bespoke context belongs on the created sub-issue, added
  after apply.
- `title` is the reconciliation key — editing a title means "different
  subtask" (the old one closes as stale, a new one is created). Because
  matching sub-issues are kept untouched, context added directly to a
  sub-issue survives later reconciliations.
- `depends_on` holds 0-based entry indices within the section; rendered as
  qualified `Depends on:` lines only at apply time, once numbers exist.
- `existing: owner/repo#n` marks a subtask already tracked by an open
  issue — set by the agent, the human, or promoted from a
  `# possible match:` comment (Ruby-added suggestions from a per-title
  search; resolve or delete them, they are never decisions).
- The HTML comment carries the format version.

Created sub-issues get a thin templated body: a `Part of owner/repo#n.`
line (human-facing decoration — `/build` trusts the native parent
relationship, not prose), plus the `Depends on:` / `Intended repo:` lines
when applicable.

At apply, an `existing:` entry is never created: a **parentless** issue is
*adopted* as a native sub-issue of the plan; one already owned by another
parent is *referenced* in the map without adoption (GitHub allows one
parent per issue).

**Canonicity transfers at apply.** Before apply, the yaml spec is
canonical. At apply, canonicity moves to the sub-issues and the section is
rewritten into a linked map (`- owner/repo#12 — <title>`, with
`(adopted)`/`(referenced)` annotations). The section is never a spec future
runs must keep synced — re-splitting later means a fresh `--dry`.

### /split refusals, verbatim

> /split takes --dry or --apply, not both.

> no staged `## Subtasks` spec found — run `/split --dry` first.

> the `## Subtasks` spec is not valid yaml (…) — fix it or re-run `/split --dry`.

(A malformed hand-edit fails `--apply` loudly by design — the desired
failure mode for an executable artifact.)

> the plan body changed while /split was running — nothing was written; retry

## /build

### On an issue — state-aware, never state-driven

`/build` never implicitly runs `/split --apply`; the simple-plan path stays
first-class (one issue, one `/build`, one PR, no split required). But it
reads the split state and reacts:

| Plan state | /build's reaction |
|---|---|
| No sub-issues, no `## Subtasks` spec | Proceed: agent in an isolated worktree on branch `ai/<n>-<slug>`, push, open the PR (body carries `Closes owner/repo#n` + the `ai-flow:build` marker). |
| Unapplied `## Subtasks` spec staged | **Refuse** — an unapplied proposal makes the plan-of-record ambiguous; building past it would silently discard the human's own staging. |
| Open sub-issues exist | **Proceed**, with the result panel noting them — `--split` is a scoping choice (blast radius, reviewability), never an obligation. |

The asymmetry is principled: an unapplied spec is the human's own staging
left in limbo (refuse); applied sub-issues are a committed valid state
(inform and proceed).

**On a sub-issue**, the prompt reconstructs the subtask's scope from the
plan: the parent's body rides along as `<<<PARENT PLAN>>>` (located via the
native parent relationship, so it works for adopted issues too) and the
sibling subtask titles are listed as explicitly out of scope — the
sub-issue's own thin body never has to duplicate the plan.

The refusal, verbatim:

> ℹ️ **/build** — this plan has a staged /split proposal. `/split --apply` it or delete the `## Subtasks` section, then re-run /build.

The open-sub-issues note, verbatim:

> ℹ️ This plan has N open sub-issue(s) (owner/repo#n, …) — this /build covered the whole plan; close or /build them individually if they were meant to scope the work.

### On a PR (top-level conversation comment) — iterate

Iterates on the head branch. Bare `/build` sweeps the outstanding
feedback — unresolved review threads plus conversation comments newer than
the last ai-flow commit — and addresses it; `/build <instruction>` executes
the instruction with the sweep as context (CI is fair game: the agent can
inspect failing checks with `gh`). Commits, pushes, and replies in each
swept review thread with its disposition + the commit link. Resolving
threads stays with the human.

With nothing outstanding and no instruction:

> ℹ️ **/build** — nothing to address: no instruction, no unresolved review threads, and no new discussion since the last ai-flow commit.

### In a review thread — refused

`/build` is PR-scoped (the sweep), so firing it from one thread would look
thread-scoped and act PR-scoped:

> ℹ️ **/build** — /build runs from the PR conversation, not a review thread. Leave the feedback as a plain comment here and post /build as a top-level comment — the sweep picks this thread up.

## /build --split

Orchestrates `/build` across the plan's open sub-issues: topological waves
over their `Depends on:` lines, a final integration sub-issue ensured
(created if the split didn't), and a live per-wave checklist edited in
place — one comment for the whole orchestration.

Non-buildable nodes — the ones the orchestrator cannot drive — are skipped
with an explicit warning, and their dependents are reported blocked until
those issues close. No silent skips. Two kinds:

- **Intended-repo fallbacks**: sub-issues whose body carries
  `Intended repo:` (created on the parent's repo because the App wasn't
  installed where the work must land).
- **Adopted/referenced external issues** (recorded in the applied
  `## Subtasks` map): owned by another effort or a human.

A dependency on an issue outside the sub-issue set blocks the dependent
while that issue is open; a closed one is satisfied.

Refusals, verbatim:

> /build --split runs on plan issues, not pull requests.

> no open sub-issues — run /split first

> dependency cycle among sub-issues: …

## Cross-cutting behavior

- **Permission gate**: only users with effective write access run commands
  (payload `author_association` first, collaborator-permission API as the
  authoritative fallback; a failed lookup denies).
- **Noise protocol**: acting commands never reply — results append into the
  command comment (👀 reaction while running, a ⏳ "follow the run" status
  line during execution, a permanent ⚙️ workflow-run footer with the
  results). Both the ⏳ line (as a pre-launch prediction) and the footer
  name the model the agent runs on (per command when a batch uses distinct
  models). Standalone `/ask` is the one reply exception.
- **Failures land on the comment** as a ⚠️ panel and the Actions run goes
  red — never silent.
