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
The consistency rule: `/ask` and `/edit` always operate on the document (the
issue body or the PR description); `/build` always operates on code (open a
PR from an issue, iterate on the branch from a PR).

| Command | One line |
|---|---|
| `/ask <question>` | Read-only Q&A against the document + repo; standalone gets a reply, in a batch it lands in place. |
| `/edit <instruction>` | Edits the document as a file through one agent pass and one guarded PATCH, with interleaved results and a collapsed diff. |
| `/split [--dry\|--apply]` | Two-phase plan/apply over sub-issues: `--dry` stages an editable `## Subtasks` yaml spec in the plan body, `--apply` executes it deterministically (per-subtask repo routing, `existing:` adoption); bare does both. |
| `/build` (issue) | Builds the plan into a PR on branch `ai/<n>-<slug>` — state-aware: refuses on a staged split spec, notes open sub-issues. |
| `/build [instruction]` (PR) | Iterates on the head branch, sweeping unresolved threads + fresh comments; replies per thread with disposition + commit link. |
| `/build --split` (issue) | Orchestrates `/build` across sub-issues in dependency waves with a live checklist; skips undrivable nodes with warnings. |

The normative reference — every command per surface, flags, decision
tables, and each refusal message verbatim — is
[docs/commands.md](docs/commands.md). The end-to-end story (author,
canonize, split, build, iterate, close) with all body conventions is
[docs/plan-lifecycle.md](docs/plan-lifecycle.md).

Batches: one comment may hold several quote+command pairs (`/ask`//`/edit`
only) — the review work unit. Noise protocol: acting commands never reply;
the dispatcher edits the command comment in place (👀 reaction while
running); the one exception is a standalone `/ask`, which gets a reply.
While a command runs, the linked Actions run page streams the agent's
activity live — one line per assistant message and tool call.

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
- `docs/` — [commands.md](docs/commands.md) (the normative command
  reference), [plan-lifecycle.md](docs/plan-lifecycle.md) (the end-to-end
  narrative and body conventions), [architecture.md](docs/architecture.md)
  (how it's put together), and [attribution.md](docs/attribution.md) (who
  authors what, and why).

## Identity: the ai-flow GitHub App

All GitHub writes (pushes, PRs, comments, body PATCHes) act as the org's
`ai-flow` GitHub App — a per-job token mint, no hosted component. The
comparison that settled it:

| | default `GITHUB_TOKEN` | dev PAT | GitHub App |
|---|---|---|---|
| /build PRs trigger CI | no (by design) | yes | yes |
| Acting identity | `github-actions[bot]` | the PAT's human — overclaims authorship | `ai-flow[bot]` — truthful |
| Expiry / rotation | per-job, automatic | 90d ceremony per dev | non-expiring key; 1h installation tokens minted lazily per call (long runs outlive any single token) |
| Scope | the one repo | the dev's whole account | exactly the repos the App is installed on |
| Audit trail | anonymous-ish | indistinguishable from the human | first-class bot actor |

Setup is a one-time org task: register the App (permissions: contents,
issues, pull requests — read/write; **never** `workflows`, a deliberate
security wall — see [docs/attribution.md](docs/attribution.md)), install it
on participating repos, and store `AI_FLOW_APP_ID` /
`AI_FLOW_APP_PRIVATE_KEY` as org secrets. The App is intrinsic to the
attribution model, so a job without the secrets fails loudly. Adopters who
want to try ai-flow before registering an App can set
`allow_token_fallback: true` to knowingly run degraded on `github.token`
(writes act as `github-actions[bot]`, /build PRs don't trigger CI).

GitHub caps App installation tokens at 1 hour — shorter than a long
`/build` — so the dispatcher never trusts a pre-minted token: the private
key enters the Dispatch step, a `TokenProvider` mints lazily with an age
check on every subprocess spawn, and the write phase (push, comments)
re-mints unconditionally. The key is scrubbed from the environment before
the agent (or any subprocess) starts; the agent only ever sees short-lived
installation tokens. Because the App lacks the `workflows` scope, `/build`
excludes `.github/workflows/**` from its commits and panels the diff as a
suggested patch for a human — with a human's credential — to apply.

Attribution model (who authors what, and why): see
[docs/attribution.md](docs/attribution.md). Short form — local Cursor work is
dev-authored; web-initiated code work (`/build` on issues and PRs) is
authored by `ai-flow[bot]` with a `Co-authored-by` trailer crediting the
requesting human, whose accountability lives on the PR (`Requested by
@login`, PR assignee, merge record).

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
3. Register self-hosted runners with the per-command labels the workflow
   routes on: `ai-ask`, `ai-edit`, `ai-split`, `ai-build`. The topology is a
   deployment choice — one box can carry all four labels, or a beefy box
   takes `ai-build` alone (/build runs the full agent loop including tests,
   so it needs a real dev machine, not a bare runner) while a light box
   takes the rest. One registered runner instance = one concurrent job;
   register N instances for N parallel jobs. Repos using `dev` can run
   `dev runner-setup`.
4. Install the Cursor `agent` CLI on each runner (`curl https://cursor.com/install -fsS | bash`)
   and make sure it — and a Ruby >= 3.0 — is on the runner service's PATH
   (the dispatcher is a stdlib-only Ruby script).
5. Optional: copy `templates/ai-flow.yml` to `.github/ai-flow.yml` to set
   model policy (`models.default`, per-command overrides — see
   [docs/architecture.md](docs/architecture.md#per-repo-config-githubai-flowyml));
   valid names come from `agent --list-models`, which every run also prints
   in its job log. Without the file, the agent CLI's account default applies.
6. Optional: copy `templates/hooks.json` to `.cursor/hooks.json` for plan
   auto-push via `dev plan`.

Configuration inputs (set in the caller workflow's `with:`): `command_prefix`
(default none; set e.g. `ai-` if you run other slash-command bots),
`per_actor_runners` (multi-dev orgs: route every job to the commenter's own
runner, labeled `dev-<login>`, instead of the shared pools — compute scoping
without shared hardware; per-dev runner registration tooling is deliberately
deferred), and `allow_token_fallback` (explicit opt-in to run without the
App). Runner labels are deliberately not configurable (convention over
configuration), and model policy lives in `.github/ai-flow.yml`, not in
workflow inputs — inputs are scalar-only, and the config file keeps the
caller workflow an untouched copy-paste.

Why self-hosted runners are the contract (not just our preference): (a) warm
machines — engine toolchains, derived-data caches, checkouts, and the agent
CLI stay resident, where ephemeral hosted runners start cold every command;
(b) billing — GitHub's standard hosted runners are free on public repos but
too small for build workloads (2-core/7GB/14GB SSD), and larger runners bill
even on public repos (Linux 8-core $0.032/min, 16-core $0.064/min — a 30-min
/build on 16-core is ~$1.92/run, ~$288/mo at 150 runs, vs $0 marginal on
boxes we already own); (c) model control — the CLI exposes the full
`--list-models` menu including parameterized bracket overrides, where Cursor
Cloud Agents run a curated model subset at API pricing. Hosted-runner mode
(a CLI install step plus a routing escape hatch) is a possible future
feature, not a current one — today a job on a runner without the agent CLI
fails at the first agent invocation.

Shareability: if this repo is public, any org can reference
`d3mlabs/ai-flow/.github/workflows/ai-commands.yml@main` with its own secret
and runner pool (same distribution model as action repos, one level up).
Callers reference `@main` deliberately: the dispatcher
checkout inside the workflow always runs main, so pinning the YAML to a tag
or SHA would only freeze half the system and silently split the two versions.

## Development

```sh
bundle install
bundle exec rake test
```

The Ruby is stdlib-only at runtime (shells out to `gh`, `git`, and `agent`);
gems are test-only. Tests fake exactly those boundaries and exercise
everything else for real.
