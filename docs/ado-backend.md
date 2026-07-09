# Azure DevOps projects (reference)

firstmate ships to GitHub and Azure DevOps (ADO) from the same lifecycle scripts.
The provider is auto-detected per project from its `origin` remote - there is no new delivery mode or registry tag - so an ADO-origin project moves through the same intake, spawn, supervise, review, and teardown flow as a GitHub one.
This doc is the reference for the ADO-specific behaviour; the provider abstraction that implements it lives in [`bin/fm-scm-lib.sh`](../bin/fm-scm-lib.sh).

## What is first-party today

- **Provider detection** from the origin URL: `github.com` -> GitHub; `dev.azure.com`, `ssh.dev.azure.com`, and `*.visualstudio.com` -> Azure DevOps; anything else -> unknown (treated like GitHub for host calls, so a non-github, non-ado remote keeps the pre-existing fallthrough).
- **PR reads** for review and teardown: PR state, PR head sha, merged-PR-for-a-branch lookup, and making a PR head commit resolvable locally, all via the `az` CLI for ADO projects.
- **PR-ready wiring**: `bin/fm-pr-check.sh` records `pr=`/`pr_head=` and arms the merge poll for both providers.
- **Provider-aware crewmate briefs**: `bin/fm-brief.sh` renders `az repos` / Azure DevOps wording for an ADO project's host-operations rule and direct-PR done-line.
- **Bootstrap**: an ADO-origin project adds `az` (with the `azure-devops` extension) to the dependency set and prompts `az login` when unauthenticated (`NEEDS_AZ_AUTH`), analogous to `NEEDS_GH_AUTH`.

## What firstmate deliberately does NOT do for ADO

- **firstmate never merges/completes an ADO PR.** `bin/fm-pr-merge.sh` refuses an ADO PR URL and points the captain at the Azure DevOps UI. ADO completion is commonly gated behind required branch policies and reviewer rules that belong to a human, so the firstmate ship path ends at "gates verified green -> ready" and the captain completes the PR themselves (squash to match GitHub; do not delete the source branch, so teardown's landed-work check can still resolve the head).
- **Fork-based ADO contribution is not supported.** If an ADO project needs a fork-and-PR flow, refuse and escalate to the captain rather than guessing an org/fork topology.

## Prerequisites

- The Azure CLI `az` (`brew install azure-cli`, or your platform's package manager) with the Azure DevOps extension: `az extension add --name azure-devops`.
- Authentication: `az login`. firstmate surfaces `NEEDS_AZ_AUTH` at session start when an ADO-origin project is present and `az` is not authenticated.
- `jq`, used to read `az ... --output json` responses.

firstmate detects missing `az` tooling and unauthenticated `az` at session start and reports it through the normal consent flow; it never runs `az login` for you.

## Recognized URL and command shapes

PR URL forms parsed by [`bin/fm-scm-lib.sh`](../bin/fm-scm-lib.sh):

- `https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<n>`
- `https://<org>.visualstudio.com/<project>/_git/<repo>/pullrequest/<n>`

The `az` reads used, and the JSON fields consumed:

- PR state and head: `az repos pr show --id <n> --org <org-url> --output json`, reading `.status` (`completed` -> `MERGED`, `active` -> `OPEN`, `abandoned` -> `CLOSED`) and `.lastMergeSourceCommit.commitId` (head sha).
- Merged PR for a branch: `az repos pr list --source-branch refs/heads/<branch> --status completed --detect true --output json`, reading `.[0].pullRequestId`.
- Making the head resolvable: fetch the PR's `.sourceRefName` from the same `pr show` JSON, then `git fetch origin <sourceRefName>`.

When a PR is referenced by a bare number rather than a full URL (the branch-discovery path), `az repos pr show --id <n> --detect true` auto-detects the org/project/repo from the worktree's git remote.

## Manual end-to-end verification

Live ADO end-to-end (a real PR against a real ADO org) is out of scope for automated CI and is verified manually.
To verify a change against a real ADO project:

1. Clone an ADO project into `projects/<name>` (its `origin` will be a `dev.azure.com` or `*.visualstudio.com` URL) and confirm bootstrap reports `az`/`NEEDS_AZ_AUTH` as expected.
2. Dispatch a small ship task; confirm the crewmate brief renders `az repos` / Azure DevOps wording.
3. On `done`, open the PR in ADO, run `bin/fm-pr-check.sh <id> <ado-pr-url>` and confirm `pr=`/`pr_head=` land in meta and the merge poll arms.
4. Run `bin/fm-review-diff.sh <id>` and confirm it diffs against the PR head.
5. Confirm `bin/fm-pr-merge.sh <id> <ado-pr-url>` refuses and names the ADO UI.
6. Complete the PR in the ADO UI (squash, keep the source branch), then confirm `bin/fm-teardown.sh <id>` recognizes the landed work and tears down cleanly.
