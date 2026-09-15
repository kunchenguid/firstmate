# Azure DevOps Services pull requests

Firstmate can register, monitor and complete Azure DevOps Services PRs through its existing provider-tagged PR workflow.
GitHub and GitLab retain their existing paths.
Azure DevOps Server and arbitrary on-premises hosts are not supported by this integration.

## Setup

Install Python 3 and Azure CLI with the `azure-devops` extension, and authenticate Azure CLI for the organization using your existing Azure DevOps credentials.
The transport uses `az devops invoke` and REST 7.1; the extension must preserve response continuation headers as `continuation_token` (the contract provided by azure-devops 1.0.5).
Firstmate neither changes Azure defaults nor borrows GitHub credentials for Azure.
A failed identity read prevents registration; a failed later read never proves a merge.

Use the ordinary no-mistakes implementation and publication path when automated review is selected.
Initialize no-mistakes for the Azure repository using its current provider documentation and verify its destination before publishing.
Firstmate's merge support does not change no-mistakes publication support, select an account for its shared daemon, waive review, or grant merge authority.
Keep colleague approvals and required checks in Azure branch policies; Firstmate reads those policies instead of imposing a fixed approval count.

For a repository requiring `users/<username>/...`, select that prefix explicitly at task intake using the branch-prefix option owned by `bin/fm-brief.sh` and `bin/fm-promote.sh`.
No username is inferred from Azure login, GitHub login or Git author configuration.
Existing tasks still default to `fm/...`.
This is a per-task selection, not a global naming change or a reason to change the project's review or merge posture.

## Supported identities

Use the full HTTPS PR URL from Azure, with no query string or fragment.
Supported route examples use synthetic organization and repository names:

- `https://dev.azure.com/example/Project/_git/repo/pullrequest/7`
- `https://example.visualstudio.com/Project/_git/repo/pullrequest/7`
- `https://example.visualstudio.com/DefaultCollection/Project/_git/repo/pullrequest/7`

Project and repository names may contain canonically percent-encoded spaces or Unicode.
Encoded path separators, traversal, double encoding, credentials, ports and ambiguous URL spellings are refused.
The legacy collection component remains part of the requested identity; a differently spelled URL does not silently rebind a task.
`bin/fm-azure-pr.py` owns the exact accepted URL grammar and the scoped REST transport.

## Completion and cleanup

`bin/fm-pr-check.sh` owns PR registration, and `bin/fm-pr-merge.sh` remains the sole authorized task merge entrypoint.
The Azure transport verifies a non-draft active PR, successful mergeability, required reviewer approvals, applicable mandatory policy evaluations, checks, any mandatory comment-resolution policy, and the selected allowed merge strategy before requesting completion.
It rejects missing or outdated mandatory evaluations and binds required builds to the source or candidate merge commit.
A changed source, target, review or completion selection during verification stops the request.
Azure's `lastMergeSourceCommit` mechanism binds completion to the verified source commit, with policy bypass and source-branch deletion explicitly disabled.
Azure rechecks its mandatory policies at completion; the separate REST reads are not a server-side transaction and cannot freeze policies, the target branch, votes, or mandatory comment resolutions against concurrent changes.
Configure any requirement that must survive that final race as a mandatory Azure policy.

Firstmate preserves the PR-selected allowed merge strategy, or uses the sole allowed strategy when unambiguous.
If neither is available, select an allowed strategy on the PR and retry rather than overriding repository convention.
The Azure entrypoint accepts no extra completion flags, red-check waivers or policy bypass.
Completion is attended-only because Azure can finish the server operation asynchronously.
An accepted request with unconfirmed landing returns a diagnostic and leaves monitoring in place; it is never reported as merged work.

Only a `completed` PR with successful merge evidence is considered merged.
An `abandoned` PR is not a merge, even if its branch was pushed or equivalent content happens to be on the default branch.
Azure cleanup additionally proves that clean local work is contained in the completed PR or landed default-branch content; later unlanded edits and commits are preserved.
`bin/fm-teardown.sh` owns that complete cleanup test.

## Conservative limits and verification

An incomplete API response carrying a continuation token is refused rather than treating the first page as complete evidence.
For each check context, the newest status must be successful and bound to the current iteration; an older failed status can be superseded by a newer current-iteration success, but a newest unbound or old-iteration status requires reconciliation.
Unresolved user discussions stop completion only when a mandatory Azure comment-resolution policy makes them blocking.
An unsupported policy response or unknown merge strategy needs operator attention, never a guessed approval.
No optional tool installation or authentication repair is performed automatically.

`tests/azure-pr-contract.py`, invoked by `tests/fm-pr-merge.test.sh`, covers the Azure CLI boundary with synthetic REST responses, including identity parsing, current policy revisions, build/check failures, revision races and accepted-but-unconfirmed completion.
`tests/fm-teardown.test.sh` covers completed versus abandoned cleanup with real disposable Git repositories.
`tests/fm-task-delivery.test.sh` and `tests/fm-review-diff.test.sh` cover prefix selection through scaffold, promotion, and comparison.
These are deterministic regressions, not evidence that an Azure merge was performed live.
A live completion test requires a separately approved disposable Azure repository; reading an existing project never authorizes a test PR, vote, policy change or merge there.
