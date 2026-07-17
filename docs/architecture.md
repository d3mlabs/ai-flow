# Architecture

How ai-flow is put together: the system's three halves, what happens between
a slash-command comment and its in-place result, and how the Ruby dispatcher
is structured. Identity and authorship live in their own doc —
[attribution.md](attribution.md).

## System overview

Three zones. The dev's machine holds the transient working copy (Cursor
plans synced by `dev plan`); GitHub holds the canonical state (issues are
the plans) and operates all event plumbing; self-hosted runners do the
thinking (the headless Cursor agent) and the writing (as the ai-flow App).

```mermaid
flowchart LR
    subgraph localZone [Dev machine]
        planFile[".cursor/plans/*.plan.md<br/>(transient working copy)"]
        devPlan["dev plan<br/>new / link / pull / push / status"]
        hook["Cursor afterFileEdit hook<br/>(auto-push on agent edits)"]
    end

    subgraph githubZone [GitHub — canonical state + event plumbing]
        issue["Issue = canonical plan<br/>(sub-issues, Depends on:)"]
        comments["Comments<br/>/ask /edit /split /build"]
        pr["PRs (Closes owner/repo#n)"]
        actions["Actions: reusable workflow<br/>ai-commands.yml"]
        app["ai-flow GitHub App<br/>(identity; per-job token mint)"]
    end

    subgraph runnerZone [Self-hosted runners]
        dispatcher["bin/dispatch.rb + lib/ai_flow<br/>(stdlib-only Ruby)"]
        agentCli["headless Cursor agent CLI<br/>(CURSOR_API_KEY)"]
    end

    planFile <--> devPlan
    hook --> devPlan
    devPlan <-->|"guarded body sync (gh api)"| issue
    comments -->|"issue_comment /<br/>pull_request_review_comment"| actions
    actions -->|"routes by labels<br/>(ai-light / ai-build)"| dispatcher
    app -->|"1h installation token"| actions
    dispatcher --> agentCli
    dispatcher -->|"writes as ai-flow[bot]"| issue
    dispatcher -->|writes| comments
    dispatcher -->|"/build opens"| pr
```

Division of labor, and why:

- **GitHub Actions is the dispatcher infrastructure** — webhook consumption,
  queueing, and routing are operated by GitHub and cost nothing on
  self-hosted runners. There is no always-on service anywhere in ai-flow.
- **Self-hosted runners are the execution layer** — normal agent billing,
  per-command model control (`Agent::MODELS`), and warm dev environments
  for `/build`.
- **The GitHub App is identity only** — no hosted component; the workflow
  mints a short-lived installation token each job. App tokens (unlike the
  default `GITHUB_TOKEN`) trigger downstream workflows, which is what gives
  /build PRs their CI runs.

## Job lifecycle

From comment to in-place result:

```mermaid
sequenceDiagram
    participant Human
    participant GitHub
    participant Workflow as ai-commands.yml (runner)
    participant Dispatcher as dispatch.rb
    participant Agent as agent CLI

    Human->>GitHub: comment "/edit tighten this section"
    GitHub->>Workflow: issue_comment event (job-level if filter passed)
    Note over Workflow: runs-on picks the pool:<br/>/build to ai-build, rest to ai-light<br/>(or dev-login when per_actor_runners)
    Workflow->>GitHub: mint App installation token (required)
    Workflow->>Workflow: checkout target repo + ai-flow
    Workflow->>Dispatcher: ruby dispatch.rb (GH_TOKEN = App token)
    Dispatcher->>Dispatcher: re-parse grammar + permission gate
    Dispatcher->>GitHub: react with eyes (ack, not a comment)
    Dispatcher->>Agent: prompt (workdir = checkout or worktree)
    Agent-->>Dispatcher: result text
    Dispatcher->>GitHub: guarded writes (body PATCH, push, PR, sub-issues)
    Dispatcher->>GitHub: edit the command comment in place with results
```

Two deliberate layers of filtering: the workflow-level `if` is a coarse
`contains()` check so non-command comments never start a job; the Ruby
dispatcher re-checks the exact line-start grammar and the permission gate
(`OWNER`/`MEMBER`/`COLLABORATOR`), exiting quietly on prose mentions. A
`concurrency` group serializes jobs per issue/PR, because batches assume a
stable body snapshot.

The noise protocol shapes every write: acting commands never reply. The
dispatcher appends results into the command comment itself
(`ResultWriter`), so one comment carries both the ask and the outcome. The
single exception is a standalone `/ask`, which gets a reply comment —
a question and answer is a legitimate two-comment conversation.

## Dispatcher module map

Everything under `lib/ai_flow/`, stdlib-only at runtime. The two injectable
boundaries are `Executor` (every subprocess: `gh`, `git`, `agent`) and the
classes built on it — tests fake exactly those and run everything else for
real.

```mermaid
flowchart TD
    entry["bin/dispatch.rb"] --> ctx["Context<br/>(normalized webhook payload:<br/>surface, number, commenter)"]
    entry --> disp["Dispatcher<br/>(gate, ack, route)"]
    disp --> parser["CommentParser<br/>(line-start grammar, quote+command<br/>segments, batch validation)"]
    disp --> batchCmd["Commands::Batch<br/>(/ask + /edit)"]
    disp --> splitCmd["Commands::Split"]
    disp --> buildCmd["Commands::Build"]
    disp --> buildSplitCmd["Commands::BuildSplit<br/>(orchestrates Build per wave)"]

    batchCmd --> planBody["PlanBody<br/>(body normalization, quote anchors)"]
    batchCmd --> richDiff["RichDiff<br/>(collapsed Word diff + Source diff,<br/>text-fragment backlink)"]
    batchCmd --> resultWriter["ResultWriter<br/>(in-place comment edits,<br/>blockquoted result panels)"]
    splitCmd --> resultWriter
    buildCmd --> resultWriter
    buildSplitCmd --> resultWriter
    buildCmd --> commitIdentity["CommitIdentity<br/>(bot author, human co-author<br/>trailer — attribution.md)"]
    batchCmd --> commitIdentity

    batchCmd --> agent["Agent#launch<br/>(the one seam invoking the CLI;<br/>swap the backend here)"]
    splitCmd --> agent
    buildCmd --> agent
    batchCmd --> gh["GitHub<br/>(REST + GraphQL via gh)"]
    splitCmd --> gh
    buildCmd --> gh
    buildSplitCmd --> gh
    agent --> exec["Executor<br/>(subprocess boundary)"]
    gh --> exec
```

Routing rules (in `Dispatcher#route`): a comment whose segments are all
`/ask`//`/edit` runs as one `Batch` — the review work unit. `/split` and
`/build` are lifecycle operations and must be a comment's only command
(enforced by `CommentParser#validate!`); `/build --split` goes to the
orchestrator.

## The batch two-phase flow

Every quote in a batch was taken against the same rendered body the
reviewer read, so segments must never be invalidated by their siblings'
edits:

```mermaid
flowchart TD
    snapshot["Take one body snapshot"] --> resolve["Phase 1: resolve every quote<br/>against the snapshot<br/>(exact, then markdown-insensitive;<br/>widened to paragraph spans)"]
    resolve -->|stale quote| staleResult["Segment fails alone:<br/>re-quote and retry"]
    resolve --> agentPass["Phase 2: ONE agent pass<br/>integrates all /edit segments<br/>into one new document"]
    agentPass --> patch["ONE guarded PATCH<br/>(refuse if body moved<br/>since the snapshot)"]
    agentPass --> results["Per-segment results append in place<br/>as blockquoted panels (/edit gets a backlink<br/>header + collapsed Word/Source diffs)"]
```

## The /build flow

`/build` runs the agent in a disposable worktree so concurrent builds never
share a workspace, then authors the PR itself — deterministic
back-references, not agent-written ones:

```mermaid
flowchart TD
    issueRead["Read the issue<br/>(org-wide plans: Target repos: line<br/>picks the code repo)"] --> wt["git worktree prune + add<br/>(same repo: branch off the warm checkout;<br/>cross-repo: gh clone)"]
    wt --> branch["checkout -B ai/n-slug"]
    branch --> agentRun["agent implements the issue<br/>(code, tests, docs; no git)"]
    agentRun -->|no changes| noPr["Report: no PR opened"]
    agentRun --> commit["Commit as ai-flow[bot]<br/>+ Co-authored-by: requester"]
    commit --> push["push -u --force-with-lease<br/>(as the App, so CI triggers)"]
    push --> openPr["Open PR: Closes owner/repo#n,<br/>Requested by, assignee = requester,<br/>ai-flow:build marker"]
```

`/build --split` wraps this: it reads the parent's native sub-issues,
topologically sorts them by their `Depends on: #n` lines into waves, runs
`Build#build_issue` per sub-issue, ensures a final integration sub-issue
exists, and reports a live per-wave checklist edited in place.

## Extension points

- **Agent backend**: `Agent#launch` is the single seam that invokes the
  `agent` CLI — an alternative backend (cloud REST API, another vendor's
  CLI) is a change here, not in the command scripts.
- **Model policy**: `Agent::MODELS` maps command to model; `AI_FLOW_MODEL`
  overrides per run.
- **Runner routing**: `light_runner_labels` / `build_runner_labels` inputs,
  or `per_actor_runners` for per-dev pools.
- **Command prefix**: `command_prefix` input for orgs with clashing
  slash-command bots.
- **Identity**: the App secrets; the bot login self-configures from the
  App's slug (`AI_FLOW_BOT_LOGIN`).
