# Forgejo pull request watch and merge verification

Empirical record for the merge watch and the merge path on Forgejo, alongside the existing GitHub and GitLab ones (`docs/gitlab-merge-watch.md`).
Every finding here was verified against a real, disposable Forgejo instance rather than assumed from `tea --help`, because several of them contradict what the help text alone would suggest.
All evidence below was collected on 2026-09-13.

## Versions

```
$ tea --version
Version: development	golang: 1.26.4
```

This is a locally built development binary; its exact source revision could not be determined from the binary (no embedded VCS stamp).

```
$ jq --version
jq-1.7

$ bash --version | head -1
GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)

$ docker --version
Docker version 29.8.0, build 88096ef
```

## The evidence instance

Unlike the GitLab doc's public fixture project, a self-hosted Forgejo instance is not something a reader can be pointed at over the network: that is the entire reason firstmate needs to support it.
The evidence here instead comes from a disposable, throwaway Forgejo 7 instance (`codeberg.org/forgejo/forgejo:7`) run locally in Docker for exactly this verification and destroyed afterward, with one repository (`fixture/fixture-repo`) and several pull requests created through the same `tea` CLI a real task would use.
Nothing here depends on any private or production instance, and none of it is reproducible by a reader without standing up an equivalent throwaway instance themselves.

## Why tea needed real verification before writing any code

`tea --help` documents `--fields`/`-f` and `--output`/`-o` on `tea pulls`, which looks at first glance like `glab mr view <n> -R <url> -F json`.
It is not:

```
$ tea pulls 1 --login fm-fixture --repo fixture/fixture-repo -f state -o simple
  # #1 Add the merged example file (merged)
  @fixture created 2026-09-13 22:08	**main** <- **merged-branch**
  merges
  --------
  http://localhost:3980/fixture/fixture-repo/pulls/1
```

`tea pulls <index>` always renders the same free-text detail view regardless of `-f`/`-o` - the help text's "will show it in detail" is the whole story, and field/output selection is silently ignored.
Only the list form honors them:

```
$ tea pulls list --login fm-fixture --repo fixture/fixture-repo --state all -f index,state -o csv
index,state
2,open
1,merged
```

The merge watch (`bin/fm-pr-poll.sh`) therefore reads `tea pulls list ... -o csv`, not `tea pulls <n>`, and filters to the matching index client-side.

## Why the login is resolved fresh, and how

`tea pulls`/`tea api` address a repository by `owner/repo` slug only.
The host comes from a named `tea login` (`tea login add --name <name> --url <host> --token <token>`), selected by `--login <name>`; there is no flag that takes a bare host or full URL the way `glab -R <url>` does:

```
$ tea pulls ls --repo https://example.com/owner/repo -o simple
Error: path segment [1] is empty
```

Three logins were registered on the verification machine, real production ones plus the throwaway fixture:

```
$ tea login list --output json
[
  { "name": "forgejo", "url": "http://git.hipponix.local:3000", ... },
  { "name": "forgejo-admin", "url": "http://192.168.2.190:3000", ... },
  { "name": "fm-fixture", "url": "http://localhost:3980", ... }
]
```

`bin/fm-pr-check.sh`, `bin/fm-pr-poll.sh`, and `bin/fm-pr-merge.sh` each independently match the validated PR host against this list's bare hostnames (stripping scheme and port) and refuse when zero or more than one login matches, rather than guessing.
`bin/fm-pr-poll.sh` is a static, standalone watcher body with no sourced dependency, so it re-derives this match on every poll instead of trusting a name recorded anywhere durable; the other two duplicate the same match deliberately, for the same reason.

## URL shape

Forgejo (and Gitea) serve pull requests at `https://<host>/<owner>/<repo>/pulls/<number>` - plural "pulls", no `/-/` route separator, confirmed by the fixture's own PR-creation output:

```
$ tea pulls create --login fm-fixture --repo fixture/fixture-repo --head merged-branch --base main --title "..."
  ...
  http://localhost:3980/fixture/fixture-repo/pulls/1
```

This never collides with GitHub's `.../pull/<n>` (singular) or GitLab's `.../-/merge_requests/<n>`.

## End to end: arming and polling a real pull request

```
$ fm-pr-check.sh task-f1 https://localhost/fixture/fixture-repo/pulls/4
armed: state/task-f1.check.sh

$ cat state/task-f1.pr-poll
forgejo
https://localhost/fixture/fixture-repo/pulls/4
localhost
fixture/fixture-repo
4

$ state/task-f1.check.sh
(nothing - PR 4 is still open)
```

PR 4 was then merged directly through the head-bound API call described below, and the same published check was run again with no other change:

```
$ state/task-f1.check.sh
merged
```

The `localhost:3980` login's actual port never appears in the canonical PR URL or the poll's host comparison - login matching only ever compares bare hostnames - so this reproduces correctly for an instance reachable on the standard port with no explicit port in its URL, which is the realistic self-hosted shape.

## A missing tea produces no wake, never a false merge

```
$ PATH="$notea" bin/fm-pr-poll.sh --validated forgejo https://localhost/fixture/fixture-repo/pulls/1 localhost fixture/fixture-repo 1
(nothing)

$ PATH="$notea" bin/fm-pr-check.sh task-x https://localhost/fixture/fixture-repo/pulls/1
error: watching a Forgejo pull request requires tea on PATH
```

## Merging: tea's merge subcommand cannot bind a head, but the API can

`tea pulls merge --help` documents no `--sha`/head-commit flag, unlike `gh pr merge --match-head-commit` and `glab mr merge --sha`.
Forgejo/Gitea's underlying REST API does support one, as an undocumented-by-tea `head_commit_id` field on the merge request body (confirmed against the instance's own served Swagger definition, `MergePullRequestOption`), so `bin/fm-pr-merge.sh` calls that API directly through `tea api` instead of `tea pulls merge`:

```
$ tea api --login fm-fixture --repo fixture/fixture-repo -X POST '/repos/{owner}/{repo}/pulls/2/merge' \
    -f Do=merge -f head_commit_id=0000000000000000000000000000000000000000 -i
HTTP/1.1 409 Conflict
{"message":"head out of date", ...}

$ tea api --login fm-fixture --repo fixture/fixture-repo -X POST '/repos/{owner}/{repo}/pulls/2/merge' \
    -f Do=merge -f head_commit_id=<the real head sha> -i
HTTP/1.1 200 OK
```

A stale or wrong head is refused with `409 head out of date`; the exact current head succeeds and actually merges (`state` read back as `closed`, `merged: true`).
This exactly parities `--match-head-commit`/`--sha`: a push landing between the verifying read and the merge call is refused rather than merged un-reviewed.

**`tea api` reports an HTTP-level failure with exit status 0.** Both calls above exited 0; only the JSON body differed.
This was the single most consequential finding of this verification pass: a naive implementation gating success on `tea api`'s exit status would treat every rejected merge as a success.
`bin/fm-pr-merge.sh` therefore never trusts that exit status - it always re-reads the pull request afterward (`forgejo_confirm_merged`) and treats `merged == true` as the only evidence a merge landed.

## Pre-merge conditions

Read live from `tea api ... /repos/{owner}/{repo}/pulls/{n}` (`state`, `mergeable`, `head.sha`) and `tea api ... /repos/{owner}/{repo}/commits/{sha}/status` (the combined commit status).
An already-merged pull request is correctly refused for a second merge attempt:

```
$ fm-pr-merge.sh task-f1 https://localhost/fixture/fixture-repo/pulls/4
error: refusing to merge https://localhost/fixture/fixture-repo/pulls/4
  - state is "closed", not open
  - the combined commit status is "none", not success
```

An open, mergeable pull request with no configured CI reports the combined status as empty with `total_count: 0`:

```
$ curl .../repos/fixture/fixture-repo/commits/<sha>/status
{"state":"","sha":"","total_count":0,"statuses":null,...}
```

This is read as `none`, the same way GitLab's null `head_pipeline` is read as `none` in `docs/gitlab-merge-watch.md`, and refuses the merge rather than treating an absent check as nothing to verify:

```
$ fm-pr-merge.sh task-f2 https://localhost/fixture/fixture-repo/pulls/<open-mergeable-pr>
error: refusing to merge ...
  - the combined commit status is "none", not success
```

**Not verified here:** the shape of a populated (non-empty) combined-status response from a real Forgejo Actions run.
Standing up a Forgejo Actions runner was out of scope for this pass; the merge gate requires the combined status's `state` field to read exactly `success`, matching GitHub's and GitLab's own state enums, and refuses on anything else including an unrecognized value - the same fail-safe-refuse posture as every other condition here.

## Registered `tea login`s used

`fm-fixture` (`http://localhost:3980`) was created solely for this verification and removed afterward, along with the fixture instance itself.
The two pre-existing real logins listed above (`forgejo`, `forgejo-admin`) were read only through `tea login list` to prove the host-matching logic against real data; no pull request on either was read, merged, or otherwise touched.
