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
| `/edit <instruction>` | issues + PRs | On a plan issue: rewrites the quoted section (whole document when unscoped), PATCHes the body through a guarded sync, and appends a rendered rich diff (word-level `<ins>`/`<del>`, re-rendered mermaid, collapsed source diff, text-fragment backlink) to the command comment. On a code PR: applies the instruction on the PR branch, commits, pushes, and appends the commit link. |
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

- `.github/workflows/ai-commands.yml` — the reusable workflow (`workflow_call`).
- `bin/dispatch.rb` — job entry point; parses the event, gates, routes.
- `lib/ai_flow/` — comment parsing, anchor resolution, the `Agent#launch`
  seam (the one place that invokes the `agent` CLI — swap the backend here),
  GitHub API access via `gh`, and the four command implementations.
- `templates/caller-workflow.yml` — the ~10-line workflow each repo copies.
- `templates/hooks.json` — the Cursor `afterFileEdit` auto-push hook for
  repos using `dev plan`.

## Adoption checklist (per repo)

1. Copy `templates/caller-workflow.yml` to `.github/workflows/ai-commands.yml`
   (works for code repos and the org plans repo alike).
2. Ensure the org secret `CURSOR_API_KEY` is available to the repo (or add a
   repo secret) — it authenticates the headless `agent` CLI on the runner.
3. Register self-hosted runners with the labels the workflow routes on:
   `ai-light` (chat-heavy commands) and `ai-build` (build-heavy, e.g. warm
   Unreal environments). One registered runner instance = one concurrent job;
   register N instances for N parallel jobs. Repos using `dev` can run
   `dev runner-setup`.
4. Install the Cursor `agent` CLI on each runner (`curl https://cursor.com/install -fsS | bash`)
   and make sure it — and a Ruby >= 3.0 — is on the runner service's PATH
   (the dispatcher is a stdlib-only Ruby script).
5. Optional: copy `templates/hooks.json` to `.cursor/hooks.json` for plan
   auto-push via `dev plan`.

Configuration inputs (set in the caller workflow's `with:`): `command_prefix`
(default none; set e.g. `ai-` if you run other slash-command bots),
`light_runner_labels`, `build_runner_labels`.

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
