# Bitbucket Cloud as a third PR provider

Bitbucket Cloud is firstmate's third first-class PR provider alongside GitHub and GitLab.
It is addressed with `curl` against the Bitbucket Cloud REST API v2.0, with no CLI dependency and no MCP server, because Bitbucket Cloud has no comparable `gh`/`glab`-style CLI firstmate can rely on.
Bitbucket Server / Data Center is a different product with a different API and is explicitly out of scope; every path below is Bitbucket Cloud (`bitbucket.org`) only.

## Identity and URL shape

A Bitbucket Cloud pull request is addressed by `https://bitbucket.org/<workspace>/<repo>/pull-requests/<n>`.
`bin/fm-pr-lib.sh`'s `fm_pr_url_parse` tags it `provider=bitbucket`, `host=bitbucket.org`, `path=<workspace>/<repo>`, `number=<n>`, and additionally sets `FM_PR_OWNER`/`FM_PR_REPO` to the workspace and repository the same way a GitHub URL does.
Unlike GitLab's arbitrarily nested namespace, a Bitbucket Cloud project always sits at exactly that one two-segment path.
`fm_pr_bitbucket_slug_valid` enforces 1-62 characters, no leading or trailing hyphen, no bare `.` or `..`, and no character outside `[A-Za-z0-9._-]` for both the workspace and the repository slug.
`bitbucket.org` is refused by `fm_pr_gitlab_host_valid` the same way `github.com` already is.
So a GitLab-shaped URL under `bitbucket.org` (e.g. `.../-/merge_requests/1`) can never be armed as a self-hosted GitLab watch that can never succeed.

## Authentication

A Workspace or Repository Access Token is sent as `Authorization: Bearer <token>`.
The header is written to a `chmod 600` curl config file (`curl -K -`-style, one per call) rather than passed as a literal `-H` argument, so the token never appears on the process's argv where other same-uid processes could read it (`ps`, `/proc/<pid>/cmdline`); the config file is removed immediately after the call in every one of the three call sites (`fm_pr_bitbucket_api_get`, `fm_pr_bitbucket_api_post`, and `bin/fm-pr-poll.sh`'s inlined Bitbucket branch).
Bitbucket Cloud's deprecated app passwords are deliberately not supported.
`bin/fm-pr-lib.sh`'s `fm_pr_bitbucket_token` resolves the token in the same "ambient environment wins, the calling home's gitignored `.env` is the opt-in fallback" shape as the Relay pairing token and the mail-plane credentials (`docs/configuration.md` "Mail plane").
`FM_BITBUCKET_TOKEN` in the environment wins; otherwise a `FM_BITBUCKET_TOKEN=` line (optionally `export`-prefixed, optionally quoted) in the home's `.env` is read.
Unlike `gh` and `glab`, `curl` has no credential store of its own to fall back to, so a caller with no token configured gets a clean refusal rather than an unauthenticated request.
`bin/fm-pr-check.sh` refuses to arm a watch and `bin/fm-pr-merge.sh` refuses to merge, both before anything is recorded, exactly the way each already refuses when `glab` is missing for GitLab.

## Reading state: PR, statuses, and green

Two GET reads, both through `bin/fm-pr-lib.sh`'s `fm_pr_bitbucket_api_get` (`<fm_home> <api-path>`, base `https://api.bitbucket.org/2.0`):

- `GET /repositories/{workspace}/{repo}/pullrequests/{id}`.
  `.state` is `OPEN`, `MERGED`, `DECLINED`, or `SUPERSEDED`.
  `.source.commit.hash` is the head commit: a full 40-character hex SHA-1 in every response observed, though the schema's documented pattern is only `[0-9a-f]{7,}`, so `fm_pr_bitbucket_hash_valid` in `bin/fm-pr-merge.sh` accepts 7-64 lowercase hex characters rather than assuming a fixed length.
  `.destination.branch.name` is the target branch, and `.merge_commit.hash` appears once merged.
- `GET /repositories/{workspace}/{repo}/commit/{sha}/statuses`.
  A paginated list (`.values[]`, `.next`) of commit status objects, each with a `.key` (the status's stable identifier, Bitbucket's analogue of a GitHub check name) and a `.state` of `SUCCESSFUL`, `FAILED`, `INPROGRESS`, or `STOPPED`.

Bitbucket Cloud exposes no required-checks flag the way GitHub's branch protection or GitLab's pipeline-required setting do, so "green" is a policy definition rather than something the forge states directly.
`bitbucket_commit_statuses_not_green` in `bin/fm-pr-merge.sh` requires every present status to be `SUCCESSFUL`, refuses on any `FAILED`, `STOPPED`, or still-`INPROGRESS` status, and also refuses when zero statuses have reported for the head at all.
That last refusal mirrors GitLab's refusal of a `null` head pipeline rather than reading total silence as vacuously green.
The merge endpoint's own server-side checks (conflicts, branch restrictions) are relied on for everything this preflight cannot see, the same way GitLab's live `has_conflicts`/`detailed_merge_status` read is more direct than what GitHub's rollup alone proves.

## Merging: no head precondition, and a possibly-asynchronous result

`POST /repositories/{workspace}/{repo}/pullrequests/{id}/merge` with a JSON body of `{"merge_strategy": "...", "close_source_branch": true|false}`.
Two invariants the implementation preserves, using the GitLab path's pattern rather than a weaker one:

1. **No native required-checks flag.** Covered above: green is every present status `SUCCESSFUL`, none `INPROGRESS`/`FAILED`/`STOPPED`, and at least one status must have reported, with the merge endpoint's own checks relied on for the rest.
2. **No head-SHA precondition, and a possibly-asynchronous result.** Unlike `gh pr merge --match-head-commit` and `glab mr merge --sha`, Bitbucket's merge endpoint takes no head-binding parameter at all.
   So `bitbucket_head_unchanged` in `bin/fm-pr-merge.sh` re-reads the live head immediately before the merge call and refuses if it no longer matches the head `bitbucket_verify_mergeable` verified, closing the same race by hand that the other two providers close through the forge itself.
   The merge call itself may return synchronously (HTTP 200, body is the merged pull request object) or asynchronously (HTTP 202, no landed outcome yet, only a `Location` header naming a poll-able `/pullrequests/{id}/merge/task-status/{task_id}` endpoint that returns `{"task_status": "PENDING"|"SUCCESS", ...}`).
   This implementation does not chase that task-status endpoint.
   After the merge call returns, `bitbucket_confirm_merged` does one live re-read of the pull request itself (the same resource `bitbucket_verify_mergeable` already reads), and only `state=MERGED` is ever reported as landed, exactly mirroring `gitlab_confirm_merged`'s one-shot confirm-or-leave-the-poll-armed shape.
   An unconfirmed result (whether from a synchronous 200 that has not yet propagated or a still-pending 202 task) is reported as `actionable` with the merge poll left armed.
   `bin/fm-pr-poll.sh`'s own Bitbucket branch (same GET, same token resolution) is what eventually observes `state=MERGED` and produces the durable outcome, the same relationship the GitLab path already has to its poll.

The default `merge_strategy` is `merge_commit`, Bitbucket Cloud's own documented API default.
This is not firstmate's GitHub-specific squash-by-default convention, because GitHub's own flag vocabulary maps directly onto its own three methods while Bitbucket's six-value enum does not.
`--squash` and `--merge` map to Bitbucket's `squash` and `merge_commit`.
`--method <value>` passes any of the six enum values (`merge_commit`, `squash`, `fast_forward`, `squash_fast_forward`, `rebase_fast_forward`, `rebase_merge`) directly.
`--rebase` has no single unambiguous Bitbucket equivalent and is refused rather than guessed.
`--allow-red` does not apply to Bitbucket, the same restriction GitLab already has, because every present status is already required green with no per-name waiver concept to reuse.

## Watching: `bin/fm-pr-poll.sh`'s Bitbucket branch

The static, byte-identical watcher poll (`bin/fm-pr-poll.sh`) reads GitHub through `gh` and GitLab through `glab`.
Bitbucket has no comparable CLI, so its branch uses `curl` and `jq` directly, re-deriving every URL component from the validated sidecar exactly as the other two branches do.
Because `curl` needs a token and has no credential store of its own, the poll needs to resolve `FM_HOME` to find a `.env` fallback.
It uses the environment's `FM_HOME` when the caller already set one (`bin/fm-watch.sh`'s validated invocation passes it explicitly, the one change this required outside the PR-provider files themselves), and otherwise derives it from its own path (`$FM_HOME/state/<id>.check.sh` when copied out as a task's own poll, so the parent of the containing `state/` directory is the home).
A home with no token configured - and any other read or parse failure - stays silent exactly like a missing `glab` does for GitLab.
The poll's silence-on-every-error contract means an authentication gap must never be read as "not merged" turning into a false negative that never wakes.
It is instead simply indistinguishable from "not merged yet" until the token is supplied, the same tradeoff GitLab already accepts for a missing `glab`.

## Bounded research this task settled

- **Access-token type and scopes**: a Workspace or Repository Access Token (`Authorization: Bearer <token>`), never a deprecated app password.
  Reading a pull request and its statuses needs `repository`/`pullrequest` read scope, and merging needs `pullrequest:write`.
- **The exact 202 shape**: confirmed against Bitbucket Cloud's own OpenAPI-derived reference (`developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/`).
  A 202 carries no body of its own but a `Location` header pointing at `/repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}/merge/task-status/{task_id}`, which returns `{"task_status": "PENDING", ...}` while pending and `{"task_status": "SUCCESS", "merge_result": <merged pull request>, ...}` once done.
  This implementation does not poll that endpoint (see above); it is documented here so a future change that does chase it starts from a confirmed shape rather than guessing.
