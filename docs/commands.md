# Command reference

The normative reference for ai-flow's five commands: each one per surface,
with flags, the state-dependent decision tables, and every refusal message
verbatim (refusals are UX — if you got one, you should be able to find it
here by searching). The end-to-end story of a plan — authoring, splitting,
building, iterating — lives in [plan-lifecycle.md](plan-lifecycle.md);
internals live in [architecture.md](architecture.md).

## The consistency rule

`/ask` and `/edit` always operate on the **document** — the issue body or
the PR description. `/build` always operates on **code** — open a PR from
an issue, iterate on the head branch from a PR. `/split` operates on the
plan's **decomposition** — its native sub-issues. `/learn` operates on the
repo's **learnings** — the always-on index and its detail skills.

Commands are recognized only at the start of a comment line (prose mentions
never fire). Quote-reply (select rendered text, press `r`) is the section
anchor — the remote cmd+L.

## Flag grammar

Flags select **machine-actionable mode only** — the tokens the dispatcher
acts on before launching the agent (which evidence to assemble, which run
cost to expect): `/split --dry`/`--apply` pick a phase, `/build --split`
picks a shape, `/learn --scan`/`--promote` pick an input mode. Everything
after the flags — the rest of the line, following lines, the quoted block
above — is **content the agent judges**: statements, targets, steering. So
`/learn --scan the backend and its clients, focus on error handling` parses
one flag (`--scan`) and hands the rest to the agent verbatim.

## Surfaces at a glance

| | Issue | PR conversation | PR review thread | PR review summary |
|---|---|---|---|---|
| `/ask` | ✅ answers on the plan | ✅ answers on the description | ✅ answers threaded, line anchor as scope | ✅ answers on the review panel |
| `/edit` | ✅ edits the plan body | ✅ edits the description | ✅ edits the description, anchor as focus | ✅ edits the description |
| `/split` | ✅ dry / apply / bare | — | — | — |
| `/build` | ✅ plan → PR (state-aware) | ✅ iterates the head branch | ℹ️ refused, sweep picks the thread up | ✅ iterates the head branch |
| `/build --split` | ✅ orchestrates sub-issues | ℹ️ refused | ℹ️ refused | ℹ️ refused |
| `/learn` | ✅ sweeps body + discussion | ✅ sweeps the PR | ✅ sweeps the PR | ✅ sweeps the PR |
| `/learn <statement>` | ✅ dictated, any surface | ✅ dictated | ✅ dictated | ✅ dictated |

A **review summary** is the top-level text of a submitted review
(`pull_request_review`), as opposed to its line-anchored threads. It behaves
as a PR-conversation surface with one delivery difference: reviews accept
neither reactions nor in-place edits, so there is no 👀 ack and the ⏳
status + results land in one bot-owned **review panel** comment quoting the
review, posted when the run starts and edited in place thereafter.

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

## /learn

Captures a **learning** — a lesson distilled from feedback, stored as an
index line in `.cursor/rules/learnings-index.mdc` (always-on awareness) plus
a detail skill under `.cursor/skills/learnings/<slug>/` (loaded on demand).
Learnings always land as a **draft PR** the human merges — the curation gate
that keeps the always-on tier trustworthy. `/learn` is the GitHub-comment
twin of dev's `capture-learning` skill: same distillation rubric, same
output shape, one pipeline behind both.

What qualifies (the rubric the agent applies): only lessons that generalize
beyond the immediate diff or discussion — coding practices that will recur,
architecture constraints, process rules. Diff-local fixes (typos, renames,
one-off bugs) are not learnings. Before writing, the agent dedups against
the existing index and the org tier and revises rather than duplicating; if
nothing generalizes it drafts nothing and says so (a common, valid outcome).

### `/learn <statement>` — dictated

You already distilled the lesson; the agent only formats it into the
two-tier shape, dedups, and applies the scope rubric. Works from any
surface. Its source is the single comment, so each dictation opens its own
draft PR (branch `ai/learn-c<comment-id>`):

> ✅ **/learn** — drafted 1 learning in a draft PR: https://github.com/owner/repo/pull/N
> - `design/factory-over-class-methods`

### `/learn` — bare sweep

Distills the surface's feedback: on a PR, its description, unresolved review
threads, and conversation (the diff is in the checkout, so the agent reads
what the feedback is *about*); on an issue, the body and comment discussion.
Re-running on the same surface **refines that surface's open draft** (branch
`ai/learn-pr-<n>` / `ai/learn-issue-<n>`) instead of duplicating — the push
updates the existing draft PR:

> ✅ **/learn** — refined 2 learnings in a draft PR: https://github.com/owner/repo/pull/N

With nothing that generalizes:

> ℹ️ **/learn** — no learning: nothing here generalized beyond the immediate change.

### `/learn --scan` and `/learn --promote <slug>`

Reserved in the grammar; not available yet (a follow-up in
d3mlabs/ai-flow#15). Until then they answer, verbatim:

> ℹ️ **/learn --scan** — not available yet; codebase surveys (`/learn --scan`) are a follow-up in d3mlabs/ai-flow#15. For now, `/learn <statement>` captures a dictated lesson and bare `/learn` sweeps this surface.

Every draft learning PR carries a `learned-from: <repo>#<n> (dictated|learn-sweep)`
marker naming its source and form, and is itself an ordinary ai-flow surface
— `/build` iterates the wording, review threads sweep it, `/ask` challenges a
generalization.

## Cross-cutting behavior

- **Permission gate**: only users with effective write access run commands
  (payload `author_association` first, collaborator-permission API as the
  authoritative fallback; a failed lookup denies).
- **Noise protocol**: acting commands never reply — results append into the
  command comment (👀 reaction while running, a ⏳ "follow the run" status
  line during execution, a permanent ⚙️ workflow-run footer with the
  results). Both the ⏳ line (as a pre-launch prediction) and the footer
  name the model the agent runs on — one model per job, since a batch is a
  single agent pass (run under the /edit policy when any edit is present).
  Standalone `/ask` is the one reply exception.
- **Failures land on the comment** as a ⚠️ panel and the Actions run goes
  red — never silent.
