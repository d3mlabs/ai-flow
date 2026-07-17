# ai-flow

GitHub-side slash commands that run the headless Cursor agent on self-hosted
runners. Comment `/ask`, `/edit`, `/split`, or `/build` on an issue or PR and
a GitHub Actions job picks it up, runs the agent on our own hardware (normal
agent billing, fine model control, warm build environments), and lands the
result back on the comment thread with minimal noise.

The local half lives in [d3mlabs/dev](https://github.com/d3mlabs/dev) as
`dev plan` — Cursor plans sync with GitHub issues (the issue is the canonical
plan). This repo is the remote half: the reusable workflow, the Ruby command
scripts, and the templates each repo copies.

## Command surface

Commands are recognized only at the start of a comment line. Quote-reply
(select rendered text, press `r`) is the section anchor — the remote cmd+L.

| Command | Where | What it does |
|---|---|---|
| `/ask <question>` | issues + PRs (conversation and review comments) | Answers read-only. Standalone `/ask` gets a reply comment; inside a batch the answer lands in place. A quote (or review-comment line anchor) scopes the question. |
| `/edit <instruction>` | issues + PRs | On a plan issue: the agent edits the plan document as a file (a quote focuses the feedback but is not a boundary — implications land wherever the document needs them), the body PATCHes through a guarded sync, and one result section is appended to the command comment under a `---` rule: per-segment ✅ summary lines plus one combined collapsed "Word diff" (word-level `<ins>`/`<del>` prose, re-rendered mermaid) and "Source diff" (colored unified diff). On a code PR: applies the instruction on the PR branch, commits, pushes, and appends the commit link. |
| `/split` | issues | Proposes well-isolated subtasks and reconciles them against existing native sub-issues (create missing / close stale with comment / keep matching — idempotent). Dependencies land as `Depends on: #n` lines. |
| `/build` | issues | Runs the agent in an isolated worktree on branch `ai/<n>-<slug>`, pushes, and opens a PR whose body carries `Closes owner/repo#n` plus an `<!-- ai-flow:build -->` marker (deterministic back-references for Projects automation). |
| `/build --split` | issues | Orchestrates `/build` across the sub-issues in dependency order (topological waves), ensures a final integration sub-issue, and reports a live per-wave checklist edited in place. |

Batches: one comment may hold several quote+command pairs (`/ask`//`/edit`
only) — the review work unit. All quotes resolve against one body snapshot,
all edits integrate in one agent pass, one guarded PATCH, and per-segment
results append under each command in the same comment.

Noise protocol: acting commands never reply. The dispatcher edits the command
comment in place (👀 reaction while running); the one exception is a
standalone `/ask`, which gets a reply.

## Layout

Architecture (system diagram, job lifecycle, module map, command flows):
see [docs/architecture.md](docs/architecture.md).

- `.github/workflows/ai-commands.yml` — the reusable workflow (`workflow_call`).
- `bin/dispatch.rb` — job entry point; parses the event, gates, routes.
- `lib/ai_flow/` — comment parsing, anchor resolution, the `Agent#launch`
  seam (the one place that invokes the `agent` CLI — swap the backend here),
  GitHub API access via `gh`, and the four command implementations.
- `templates/caller-workflow.yml` — the ~10-line workflow each repo copies.
- `templates/hooks.json` — the Cursor `afterFileEdit` auto-push hook for
  repos using `dev plan`.
- `docs/` — [architecture.md](docs/architecture.md) (how it's put together)
  and [attribution.md](docs/attribution.md) (who authors what, and why).

## Identity: the ai-flow GitHub App

All GitHub writes (pushes, PRs, comments, body PATCHes) act as the org's
`ai-flow` GitHub App — a per-job token mint, no hosted component. The
comparison that settled it:

| | default `GITHUB_TOKEN` | dev PAT | GitHub App |
|---|---|---|---|
| /build PRs trigger CI | no (by design) | yes | yes |
| Acting identity | `github-actions[bot]` | the PAT's human — overclaims authorship | `ai-flow[bot]` — truthful |
| Expiry / rotation | per-job, automatic | 90d ceremony per dev | non-expiring key, 1h installation tokens minted per job |
| Scope | the one repo | the dev's whole account | exactly the repos the App is installed on |
| Audit trail | anonymous-ish | indistinguishable from the human | first-class bot actor |

Setup is a one-time org task: register the App (permissions: contents,
issues, pull requests — read/write), install it on participating repos, and
store `AI_FLOW_APP_ID` / `AI_FLOW_APP_PRIVATE_KEY` as org secrets. The App
is intrinsic to the attribution model, so a job without the secrets fails
loudly. Adopters who want to try ai-flow before registering an App can set
`allow_token_fallback: true` to knowingly run degraded on `github.token`
(writes act as `github-actions[bot]`, /build PRs don't trigger CI).

Attribution model (who authors what, and why): see
[docs/attribution.md](docs/attribution.md). Short form — local Cursor work is
dev-authored; web-initiated work (`/build`, `/edit` on PRs) is authored by
`ai-flow[bot]` with a `Co-authored-by` trailer crediting the requesting
human, whose accountability lives on the PR (`Requested by @login`, PR
assignee, merge record).

## Adoption checklist (per repo)

1. Copy `templates/caller-workflow.yml` to `.github/workflows/ai-commands.yml`
   (works for code repos and the org plans repo alike).
2. Ensure the org secrets are available to the repo (or add repo secrets):
   `CURSOR_API_KEY` (authenticates the headless `agent` CLI on the runner)
   and `AI_FLOW_APP_ID` / `AI_FLOW_APP_PRIVATE_KEY` (the ai-flow GitHub App —
   required unless the caller sets `allow_token_fallback: true`). Install
   the App on the repo. Our org secrets use `selected` visibility, so add
   the adopting repo to each secret's repository list (org settings →
   secrets, or `gh secret set <name> --org <org> --visibility selected
   --repos <list>`). Note `private` visibility excludes public repos
   entirely — a public caller's job fails at the "Require the ai-flow App"
   step until the secret is shared with it.
3. Register self-hosted runners with the labels the workflow routes on:
   `ai-light` (chat-heavy commands) and `ai-build` (build-heavy — a box with
   a warm native dev environment; /build runs the full agent loop including
   tests, so it needs a real dev machine, not a bare runner). One registered
   runner instance = one concurrent job; register N instances for N parallel
   jobs. Repos using `dev` can run `dev runner-setup`.
4. Install the Cursor `agent` CLI on each runner (`curl https://cursor.com/install -fsS | bash`)
   and make sure it — and a Ruby >= 3.0 — is on the runner service's PATH
   (the dispatcher is a stdlib-only Ruby script).
5. Optional: copy `templates/hooks.json` to `.cursor/hooks.json` for plan
   auto-push via `dev plan`.

Configuration inputs (set in the caller workflow's `with:`): `command_prefix`
(default none; set e.g. `ai-` if you run other slash-command bots),
`light_runner_labels`, `build_runner_labels`, `per_actor_runners`
(multi-dev orgs: route every job to the commenter's own runner, labeled
`dev-<login>`, instead of the shared pools — compute scoping without shared
hardware; per-dev runner registration tooling is deliberately deferred),
and `allow_token_fallback` (explicit opt-in to run without the App).

Shareability: if this repo is public, any org can reference
`d3mlabs/ai-flow/.github/workflows/ai-commands.yml@v1` with its own secret and
runner pool (same distribution model as action repos, one level up). Adopters
without warm-environment needs can point the label inputs at GitHub-hosted
runners.

## Development

```sh
bundle install
bundle exec rake test
```

The Ruby is stdlib-only at runtime (shells out to `gh`, `git`, and `agent`);
gems are test-only. Tests fake exactly those boundaries and exercise
everything else for real.
