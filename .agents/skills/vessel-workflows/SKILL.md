---
name: vessel-workflows
description: >-
  Captain-installed vessel extension: dispatch Remy-style workflows to the crew with the captain's vessel agents.
  Use when the captain asks to implement or plan a Jira ticket, review a pull request, address PR feedback,
  resolve PR merge conflicts, update a PR description, or create a Jira ticket; when a request names a vessel
  agent (Snoop, Slim Charles, Proposition Joe, Conflict Resolver, Stringer, Ticket Creator, PR Description, or
  any agent in config/vessel/agents.json); and for every inbox note that starts with `[vessel]`.
user-invocable: false
metadata:
  internal: true
---

# vessel-workflows

This fork of firstmate ships a TUI called vessel (`vessel/`).
The captain defines **agents** in it (name, mode, harness, model, effort, instructions), and each agent does one kind of **workflow**.
This skill turns a workflow request into an ordinary firstmate task, using the agent's profile and instructions.
It adds no new lifecycle: intake, backlog, delivery mode, yolo, supervision, merge, and teardown stay exactly as `AGENTS.md` defines them.
The skill only decides *which* agent, *what* the brief says, and records the run so the TUI can show it under the ticket or PR.

This is a standing captain instruction: when a request matches, the agent's harness, model, and effort are the captain's explicit dispatch choice and win over `config/crew-dispatch.json` rules.

## 1. Parse the request

- Chat: read the captain's words, e.g. "implement AA4FI-1234 with Slim Charles", "review acme/webapp#42", "address the feedback on that PR".
- Inbox note starting with `[vessel]`: parse the canonical grammar in [`vessel/docs/requests.md`](../../../vessel/docs/requests.md). Keep the note's request id; it goes into the run record.

Resolve the **workflow** and the **target**:

| Workflow      | Target          | Agent mode  | Kind                |
| ------------- | --------------- | ----------- | ------------------- |
| `implement`   | Jira key        | Implement   | ship                |
| `plan`        | Jira key        | Plan        | scout               |
| `review`      | pull request    | Review      | scout               |
| `address`     | pull request    | Address     | ship on existing PR |
| `conflicts`   | pull request    | Conflicts   | ship on existing PR |
| `description` | pull request    | Description | scout               |
| `ticket`      | Jira feature    | Ticket      | scout               |
| `free`        | pull request    | none        | captain's prompt    |

If the workflow or target is ambiguous, ask one concise question instead of guessing.

## 2. Resolve the agent

Read `config/vessel/agents.json` (if it is missing, use `vessel/defaults/agents.json`):

```json
{"version":1,"agents":[{"name":"Snoop","mode":"Review","harness":"pi","model":"openrouter/meta/muse-spark-1.3-contributor","effort":"high","instructions_file":"snoop.md"}]}
```

- An agent the captain named wins (case-insensitive name match).
- Otherwise take the agents whose `mode` matches the workflow's mode, preferring the default names Snoop (Review), Slim Charles (Implement), Proposition Joe (Address), Conflict Resolver (Conflicts), Stringer (Plan), Ticket Creator (Ticket), PR Description (Description); else the first match.
- If no agent has that mode, say so and ask which agent to use; do not fall back silently.
- Instructions are the contents of `config/vessel/agents/<instructions_file>` (or `vessel/defaults/agents/…`). Empty is allowed.
- `model=` / `effort=` in the request override the agent's values for this run only.
- `free` uses no agent: resolve the profile the ordinary way (section 4 of `AGENTS.md`).

## 3. Resolve the project

Read `config/vessel/vessel.json` when it exists:

- `feature_projects`: Jira feature key or name → project name under `projects/`.
- `repo_projects`: GitHub `owner/repo` → project name.

Without a mapping, a PR's repository name matching a registered project is a confident match; a Jira ticket resolves through its feature mapping or the ordinary intake rules.
An unmatched or unregistered repository goes to the captain as an ordinary project-intake question (`project-management` skill).

## 4. Gather context (read-only)

- Jira: `acli jira workitem view <KEY> --fields key,summary,description,comment,parent --json`.
- PR: `gh pr view <url-or-number> -R <owner/repo> --json number,title,url,headRefName,headRefOid,baseRefName,headRepositoryOwner,isCrossRepository,mergeable,body`.
  If the PR title contains a Jira key, also fetch that ticket as ticket context.
- `address`: fetch the requested comments or threads (`gh api graphql` on `reviewThreads`/`comments`, or `gh pr view --comments`). With no `comments=`, take the unresolved review threads. Format each as
  `- kind: <review summary|review thread|standalone PR comment>` followed by `id`, `url`, `location: <path>:<line>`, `author`, `body` lines.
- `plan=<task>` (implement): the plan is `data/<task>/report.md`.

Never mutate Jira or GitHub while gathering context.

## 5. Write the brief

Task id: `<workflow>-<target-slug>` lowercase (`implement-aa4fi-1234`, `review-webapp-42`); if `data/<id>/` already exists, append `-2`, `-3`, ….

Follow the backlog step this home requires before spawning (section 7 of `AGENTS.md`), then scaffold with `bin/fm-brief.sh`:

- ship (`implement`, `address`, `conflicts`): `bin/fm-brief.sh <id> <project> --mode <mode>`, with the delivery mode resolved exactly as section 7 says.
- scout (`plan`, `review`, `description`, `ticket`): `bin/fm-brief.sh <id> <project> --scout`.

Fill `## Captain's intent` with the ask and the gathered context (ticket key, title, and description; PR URL and title; selected feedback; the approved plan; `extra=` text).
Fill `## Firstmate spec` with an `Agent: <name>` line, then `Agent instructions:` followed by the agent's instructions (omit the block when empty), then the workflow's contract:

- **implement**: implement the ticket as described (and follow the approved plan when one is given).
- **plan**: produce a concrete implementation plan for review in `report.md`. Inspect the repository as needed, but do not modify files.
- **review**: check out the PR (`gh pr checkout <url> --detach`) in the scratch worktree, inspect the changes, and report actionable findings in `report.md`. Do not modify the code or submit a GitHub review.
- **address**: work on the existing PR's head branch (`gh pr checkout <url>`), address the listed feedback, run the relevant tests, commit, and push to that same head branch. Do not open a new PR, do not merge or close the PR, and do not resolve or reply to review threads unless the captain asked.
- **conflicts**: use `gh pr view` to identify the base branch, head branch, and head repository; merge the latest base branch into the checked-out PR branch; resolve every conflict preserving the intent of both sides; run the relevant tests; commit the resolution; push HEAD to the PR's actual head branch. Do not merge or close the PR.
- **description**: inspect every commit and the complete diff from the base branch; update the PR body with `gh pr edit --body-file` so it accurately reflects all current changes, preserving useful context and removing stale claims (leave it unchanged if already accurate). Put the final body in `report.md`. Do not modify repository files, create commits, or submit a review.
- **ticket**: explore the feature's repository (and relevant sibling projects) and create a concise, evidence-based Jira ticket under the feature with `acli jira workitem create` (check `--help`), including summary, problem or outcome, codebase evidence, implementation direction, acceptance criteria, and tests. Verify it and put the new key in `report.md`. Do not modify source files or create commits.
- **free**: the captain's `prompt=` is the task.

For `address` and `conflicts`, adjust the ship scaffold's delivery sections for working an existing PR, as `bin/fm-brief.sh` allows: the branch is the PR's head branch, and "PR opened" means "pushed to the existing PR". Record the PR on the task the way the ordinary PR flow does so `fm-pr-check`, `fm-pr-merge`, and teardown track it.

## 6. Spawn

`bin/fm-spawn.sh <id> <project-dir> …` exactly as section 7 of `AGENTS.md` requires, plus the agent's `--harness <harness> --model <model> --effort <effort>` (omit empty values).
If `fm-spawn.sh` refuses the harness, model, or effort, report the refusal to the captain; do not substitute another profile.

## 7. Record the run

Right after a successful spawn:

```sh
vessel/bin/vessel-record-run.sh --task <id> --workflow <workflow> --agent "<name>" \
  --harness <harness> --model <model> --effort <effort> --project <project> --title "<ticket or PR title>" \
  [--ticket <KEY>] [--repo <owner/repo>] [--pr <n>] [--pr-url <url>] [--pr-head <headRefOid>] \
  [--plan-task <task>] [--request-id <inbox note id>]
```

Include `--ticket` whenever a Jira key is known (also for PR workflows whose PR title names one) and `--repo`/`--pr`/`--pr-head` for every PR workflow.
For an inbox request, acknowledge the note and reply with the task id through `bin/fm-inbox.sh` as usual.

Everything after this point is ordinary firstmate supervision.
