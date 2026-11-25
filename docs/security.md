# Security model

ai-flow runs slash commands from GitHub comments as agent passes on
self-hosted runners — machines the adopter owns, with the adopter's
toolchains and credentials on them. Anyone who can comment on a repo can
type a command. This document states what those two facts put at risk,
who can act on each surface, and which control closes each gap. Read it
before choosing a runner setup; the README's *Choosing your runner setup*
table applies it.

## What is at stake

- **The runner host.** Its filesystem, the runner user's `gh` login and
  its home, every toolchain and cache on the machine, and anything the
  host can reach on the network.
- **The ai-flow App's private key.** It transits the runner host in the
  token-mint step of every run.
- **Secrets.** `CURSOR_API_KEY` and the App credentials, as org or repo
  Actions secrets.
- **The agent's token.** What the agent subprocess can read and write on
  GitHub during a pass.
- **The repos' contents.** A pass commits, pushes and opens PRs as the
  App.

## Who can act

- **Commenters**, by their association with the repo: owners, members,
  collaborators, past contributors, and on a public repo anyone with a
  GitHub account.
- **Fork PR authors**, who control the workflow files on their PR's head
  branch.
- **The bot itself**, whose reply panels quote the commands they answer.
- **People who merge to the pinned workflow path** in the ai-flow repo.
- **Authors of text a pass reads**: review threads, conversation
  comments, parent-plan bodies, origin-firing replays.

## Gaps and controls

Each subsection names one way an actor reaches an asset, the control
that closes it, and whether the control is structural (holds without a
human decision) or a human gate (holds as long as the human decides
correctly).

### Fork workflow YAML reaching a self-hosted runner

Some events run the workflow file from the PR's head branch, and a fork
PR's head is the fork author's. A fork PR can therefore bring a workflow
with every guard removed and `runs-on: [self-hosted, ai-build]`. Nothing
written inside a workflow file defends against a fork that rewrites the
file.

Two controls, on the same path:

- **Fork-PR approval policy** — GitHub's "Require approval for all
  external contributors" (`all_external_contributors`), on the org or the
  repo. Fork workflow runs wait for a maintainer's "Approve and run".
  *Human gate.* Also guards hosted runners and free-minute abuse.
- **Runner-group workflow pin** — an org runner group with
  `restricted_to_workflows` naming
  `d3mlabs/ai-flow/.github/workflows/ai-commands.yml@v1` — the series tag
  every caller uses, written by `dev runner register` from the checkout's
  `VERSION`. A job defined in a reusable workflow is matched against the
  reusable workflow's path and ref, so a fork's own YAML never matches and
  gets no runner from the group, approved or not. *Structural.* Only org
  runner groups carry a pin.

### The pinned workflow as root of trust

The pin makes whatever `ai-commands.yml@v1` resolves to the thing every
pinned runner will execute. `v1` is the gh channel's series head: `dev
deploy gh` moves it to an immutable release, and a merge to `main` moves
nothing — so a change reaches adopters' runners only through a review and
then a deploy. The YAML there is a shell (check out the adopter, `dev up`,
a series check, `dev runner status --check`, `ai-flow dispatch`); the
dispatcher it runs is the release the adopter's own dependency declaration
names, installed into the adopter's checkout by the job's `dev up`, which
reads nothing of ai-flow's from the runner's environment. The series check
fails the job when that dispatcher is not of the shell's major. Deploying
the previous release rolls the shell back for every caller; a dispatcher
rolls back per adopter, by installing the previous release.

Control: **CODEOWNERS + required review** on `.github/workflows/**` in the
ai-flow repo (a repo ruleset with one required approving review and
code-owner review). PR authors cannot approve their own PRs but can
approve bot-authored ones, which is the case that matters: a `/build`
proposing workflow changes must not become runner-trusted on a casual
merge. *Human gate, on a path with a small, known set of writers.*
Adopters mirror the same entry on their own `.github/workflows/` to keep
the caller workflow's conditions from quiet loosening.

### ai-flow as its own adopter

ai-flow carries a caller (`ai-commands-caller.yml`) and takes `/build`s on
its own issues. Here ai-flow is the checkout: it cannot install itself,
so the job's `ai-flow dispatch` resolves to the checkout's `exe/ai-flow` —
the tree on the build branch, at the sha the comment's event carried, not
a release. What that tree may do is bounded the same way as anywhere else:
the agent's only output is a PR; `main` moves only on a human merge, and
no caller runs `main` — adopters run the deployed release, through the
shell at `v1`. Workflow-file edits are lifted out of the commit as a patch
(`Build#extract_workflows_patch`) and need the code-owner review above, so
the bot cannot author the root of trust even on its own repo. The agent
subprocess's read-only token cannot post a command, so a `/build` on
ai-flow cannot trigger another. `ci.yml` runs on GitHub-hosted runners: a
test change the bot proposes never executes on an agent host.

### Unauthorized commenters

On a public repo anyone can comment, and the job-level `if` has to admit
`CONTRIBUTOR` (review-comment payloads under-report membership — an org
member can arrive as a contributor), so association alone admits anyone
who ever landed a PR.

Control: the **hosted `authorize` job**. Before any self-hosted second,
a GitHub-hosted job checks the author's permission on the repo through
the collaborator-permission API and fails closed; dispatch starts only on
`authorized == 'true'`. The dispatcher repeats the check in Ruby as
defense in depth. *Structural.* A denied command costs a few hosted
seconds and never reaches a runner.

### The bot triggering itself

The bot's reply panels quote the command they answer. A panel that
re-triggered the workflow would loop, and would be a surface a hostile
quote could reach.

Control: a **Bot-type filter** on the job conditions — a `Bot` author
never starts a run. *Structural.*

### Third-party text in prompts

Commands splice text the command author never wrote into the agent's
prompt — review threads, conversation comments, the parent plan, the
origin-firing replay — and the pass runs with force. A hostile comment
on a public surface is a prompt-injection vector.

Controls:

- **Provenance filter** — every auto-ingested piece is kept only when its
  author holds write or admin on the repo it came from; verdicts are
  logged in the job log. *Structural.* The command's own body is trusted
  because a write-authorized human pointed the command at it; a trusted
  user quoting untrusted text in their own comment vouches for it.
- **Prompt fence and log** — spliced content is declared data, not
  instructions, in the prompt, and every assembled prompt prints in the
  run log. *Defense in depth.*

### The agent on the dispatcher's host

The agent subprocess runs code and shell with `--force` on the runner
host. As the runner user it could read the runner's `gh` state, home and
process environment.

Controls:

- **OS-user split** — `AI_FLOW_AGENT_USER` makes the dispatcher re-execute
  the agent as a separate OS user through one non-interactive sudoers
  rule; the agent cannot read the runner user's home or auth state.
  `dev runner register` converges this on every agent host. *Structural.*
- **Read-only agent token** — the agent's GitHub token is minted with
  every permission at read, installation-wide; pushes, PRs and comments
  are the dispatcher's. *Structural.*
- **Per-slot state** — each runner slot has its own persistent workspace,
  so two slots never share a working tree. Gems install into dev's
  per-project gem home under the data root, which the agent writes through
  the shared group; the spawn redirects no toolchain write and grants the
  agent nothing under the brew prefix.
- **Rotation rule** — treat a runner-host compromise as an App-key
  rotation event; the key transits the host.

## Why the approval policy alone is not the control for self-hosted runners

The approval policy's failure mode is one click: a maintainer approves
a fork PR whose workflow change looks like any other CI tweak — one
`runs-on` line among the rest. GitHub presents "Approve and run" on the
PR without the workflow diff in front of the approver.

The same misclick costs different things depending on where the job
lands. On a GitHub-hosted runner it costs a throwaway VM and some
minutes — the risk every public repo without self-hosted runners accepts.
On a self-hosted runner it costs the host: the runner user's `gh` login,
the toolchains, the caches, the network the box sits on, and the App key
in transit.

The pin is the control that holds after the click. It needs an org
runner group, because only runner groups carry a workflow pin. A
repo-scoped runner has no pin, and a user account has no runner groups;
there the approval policy is the only layer, and that is why ai-flow
refuses self-hosted registration for a public repo outside a pinned
group.

## What each registration scope gets

A runner registered **at an org**, in a runner group, takes jobs from the
repos the group selects, through the workflows the group pins, on the
labels it advertises. The group fixes the first two clauses; the
registration fixes the third.

A runner registered **at a repo** takes that repo's jobs, through any of
its workflows, on the labels it advertises. Nothing pins the workflows.
This is the right shape for a private repo with slots of its own; `dev
runner register` refuses it for a public repo.

## Further reading

The analysis these controls came out of, with each gap numbered and the
alternatives weighed, is
[plans#5](https://github.com/d3mlabs/plans/issues/5). The job graph and
the dispatcher's module map are in
[architecture.md](architecture.md).
