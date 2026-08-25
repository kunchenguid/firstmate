# Gitea pull request watch and merge verification

Empirical record for the merge watch and the merge path on Gitea, alongside the existing GitHub and GitLab ones.
Every command below was run in one session on 2026-08-24 against a disposable local Gitea instance (`gitea/gitea:latest`, Docker), because unlike the GitLab record there is no standing public Gitea fixture project to read against.
The instance, its repository, and every credential used against it were destroyed at the end of the session; every output is reproduced exactly, in the order it was produced.

## Versions

```
$ tea --version
Version: 0.14.0	golang: 1.26.5	built with: nixpkgs	go-sdk: 0.23.2

$ docker exec gitea-doc gitea --version
gitea version 1.27.2 built with go1.26.5-X:jsonv2 : bindata, timetzdata,

$ bash --version | head -1
GNU bash, version 5.3.9(1)-release (x86_64-pc-linux-gnu)
```

## Why the host is data rather than a constant, and why owner/repository is still a fixed pair

Gitea, like GitLab, runs mostly on self-hosted instances, so a pull request can live under any host: the stored record carries `provider`, `url`, `host`, `path`, and `number`, and every consumer rebuilds the URL from those parts and refuses any record that does not reconstruct it exactly, exactly as for GitLab.
Unlike GitLab, a Gitea repository has no subgroup nesting: it is always a fixed `owner/repository` pair, the same shape as GitHub.
`fm_pr_url_parse` therefore also sets `FM_PR_OWNER`/`FM_PR_REPO` for a Gitea URL, which `bin/fm-pr-merge.sh` passes straight through to `tea`'s `--repo owner/repository` flag.
`tests/fm-pr-check-security.test.sh` asserts that the Gitea pattern can never match a `github.com` or `gitlab.com` host, or a URL shape either other provider owns.

## How tea addresses a server, and why a login is resolved rather than assumed

`gh` and `glab` both take a repository or project locator that names the host directly (`--repo owner/repo` against the ambient GitHub host, or a full project URL passed to `-R`), so firstmate can rebuild that locator from the parsed URL alone.
`tea` addresses a server by a **login name** instead: every command that reaches a Gitea instance takes `--login <name>`, where `<name>` is whatever the operator called it when they ran `tea logins add`, and there is no flag that takes a host or URL directly.
Assuming a fixed login name, or relying on `tea`'s own "current default login" fallback, would either silently address the wrong instance or require every operator to name their login the same way.
Instead, `fm_pr_gitea_resolve_login` (`bin/fm-pr-lib.sh`) reads `tea logins list --output json` and matches the parsed host against each login's stored `url` field, refusing to guess when zero or more than one login matches:

```
$ tea logins add --name verifyhost --url http://localhost:13500 --token <redacted>
Login as tester on http://localhost:13500 successful. Added this login as verifyhost

$ tea logins list --output json
[
  {
    "name": "verifyhost",
    "url": "http://localhost:13500",
    "ssh_host": "localhost:13500",
    "user": "tester",
    "default": "false"
  }
]
```

The byte-static watcher poll (`bin/fm-pr-poll.sh`) resolves the login the same way but without a JSON processor for that step, reading `tea logins list --output tsv` instead, a plain tab-separated table:

```
$ tea logins list --output tsv
Name	URL	SSHHost	User	Default
verifyhost	http://localhost:13500	localhost:13500	tester	false
```

## End to end: three real pull requests, from open through merge and refusal

A repository with three pull requests, created directly against the disposable instance (`tea repos create`, three pushed branches, `tea pulls create`).
`feature-branch` and `conflict-a`/`conflict-b` all append a line to the same file, so once one of them merges into `main` the other two can no longer merge cleanly - deliberately, to show the refusal path on genuinely conflicting branches rather than a synthetic error:

```
$ tea pulls create --login verifyhost --repo tester/testrepo --head feature-branch --base main --title "Test PR" --description "test description"
  # #1 Test PR (open)

  @tester created 2026-08-24 23:01	main <- feature-branch

  test description

  --------

  • No Conflicts
  • Maintainers are allowed to edit

http://localhost:13500/tester/testrepo/pulls/1

$ tea pulls create --login verifyhost --repo tester/testrepo --head conflict-a --base main --title "Conflict A"
  # #2 Conflict A (open)
  ...
http://localhost:13500/tester/testrepo/pulls/2

$ tea pulls create --login verifyhost --repo tester/testrepo --head conflict-b --base main --title "Conflict B"
  # #3 Conflict B (open)
  ...
http://localhost:13500/tester/testrepo/pulls/3
```

`tea pulls create` ignores `--output json` for its own summary, which is why neither `bin/fm-pr-check.sh` nor `bin/fm-pr-merge.sh` ever calls `create`; both only ever read and merge a pull request that already exists.

Reading a single pull request by index, with `--output json`, is what `bin/fm-pr-check.sh`'s optional `pr_head` lookup and `bin/fm-pr-merge.sh`'s login resolution both build on:

```
$ tea pulls 1 --login verifyhost --repo tester/testrepo --output json
{
	"id": 1,
	"index": 1,
	"title": "Test PR",
	"state": "open",
	"created": "2026-08-24T22:01:01Z",
	"updated": "2026-08-24T22:01:01Z",
	"labels": [],
	"user": "tester",
	"body": "test description",
	"assignees": [],
	"url": "http://localhost:13500/tester/testrepo/pulls/1",
	"base": "main",
	"head": "feature-branch",
	"headSha": "32ea653922d0ee924149b4010c6029772b425f64",
	"diffUrl": "http://localhost:3000/tester/testrepo/pulls/1.diff",
	"mergeable": true,
	"hasMerged": false,
	"mergedAt": null,
	"closedAt": null,
	"reviews": [],
	"comments": []
}
```

The byte-static poll calls this exact single-index view and reads `hasMerged` out of it with `jq`, the same field `bin/fm-pr-check.sh`'s optional `pr_head` lookup already reads `headSha` from above. A list-based read was considered first, to keep the poll free of a JSON processor the way the GitHub and GitLab polls are, but `tea pulls list` paginates (30 rows per page by default) with no resume checkpoint, so the watched pull request's offset from page 1 grows with every newer pull request created in the repository while it stays open; a single-index lookup by contrast never lists anything; there is no page ordering to account for at all, so the poll depends on `jq` for this one read instead. Every other Gitea code path in this project already requires `jq` unconditionally for the login table lookup (`fm_pr_gitea_resolve_login`), so this costs no new dependency:

```
$ tea pulls 1 --login verifyhost --repo tester/testrepo --output json | jq -r '.hasMerged // empty'
false
```

Merging is silent on success and reports a generic failure on any refusal, distinguishable by exit code rather than message text:

```
$ tea pulls merge 1 --login verifyhost --repo tester/testrepo --style squash
$ echo $?
0

$ tea pulls 1 --login verifyhost --repo tester/testrepo --output json | jq -r '.hasMerged // empty'
true

$ tea pulls merge 1 --login verifyhost --repo tester/testrepo --style squash
Error: failed to merge PR, is it still open?
$ echo $?
1
```

With `feature-branch` now squash-merged into `main`, both remaining pull requests conflict with the updated `main` and are refused with the identical message and exit code - "already merged" and "genuinely unmergeable" are indistinguishable by design, which is exactly why `bin/fm-pr-merge.sh`'s Gitea case only ever needs the exit code:

```
$ tea pulls merge 2 --login verifyhost --repo tester/testrepo --style squash
Error: failed to merge PR, is it still open?
$ echo $?
1

$ tea pulls 3 --login verifyhost --repo tester/testrepo --output json
{
	"id": 3,
	"index": 3,
	"title": "Conflict B",
	"state": "open",
	"created": "2026-08-24T22:01:02Z",
	"updated": "2026-08-24T22:01:02Z",
	"labels": [],
	"user": "tester",
	"body": "",
	"assignees": [],
	"url": "http://localhost:13500/tester/testrepo/pulls/3",
	"base": "main",
	"head": "conflict-b",
	"headSha": "3529b16277e9d505d821583db35d7a585001e09e",
	"diffUrl": "http://localhost:3000/tester/testrepo/pulls/3.diff",
	"mergeable": false,
	"hasMerged": false,
	"mergedAt": null,
	"closedAt": null,
	"reviews": [],
	"comments": []
}

$ tea pulls merge 3 --login verifyhost --repo tester/testrepo --style squash
Error: failed to merge PR, is it still open?
$ echo $?
1
```

`mergeable: false` was already visible in the read above, before the merge was even attempted: Gitea's own `mergeable` field reflects branch protection, required reviews, and conflicts server-side, so `bin/fm-pr-merge.sh`'s Gitea case needs no pre-merge verification step of its own, unlike the GitLab case.
It calls `tea pulls merge` directly and trusts the exit code, the same way the GitHub case trusts `gh-axi pr merge`'s own server-side check rather than pre-verifying.
`tea` also exposes no equivalent of `glab mr merge --sha`: there is no flag to bind a merge to a specific head commit, so unlike GitLab there is no race guard to add, again leaving the Gitea case closer to the GitHub shape than the GitLab one.

## A missing tool, or an unresolvable login, produces no wake and no merge - never a guess

The poll is silent on every error by design, so a missing `tea` or `jq` would otherwise be indistinguishable from a pull request that is never merged, and an ambiguous login would otherwise risk answering from the wrong server entirely.
`tests/fm-pr-check-security.test.sh`'s `test_gitea_merge_watch` proves, hermetically, that an already-armed poll stays silent when `tea` is absent from `PATH`, when `jq` is absent from `PATH`, when the parsed host resolves to zero configured logins, and when it resolves to more than one; `bin/fm-pr-check.sh` refuses to arm a watch in the first place under either missing-tool condition (the one point where a missing tool can still be reported) with:

```
error: watching a Gitea pull request requires tea on PATH
error: watching a Gitea pull request requires jq on PATH
error: watching a Gitea pull request requires tea and jq on PATH
```

`tests/fm-pr-merge.test.sh`'s `test_gitea_missing_tool_refuses_before_recording` and `test_gitea_ambiguous_login_refuses_before_recording` prove the equivalent refusals on the merge path, before anything is recorded:

```
error: merging a Gitea pull request requires tea on PATH
error: merging a Gitea pull request requires jq on PATH
error: no single tea login is configured for host <host>
```

## Why pr_head is optional here too

`bin/fm-pr-check.sh` records `pr_head=` for Gitea on a best-effort basis, the same way it does for GitHub: when `tea` and `jq` are both on `PATH` and the login resolves unambiguously, it reads the pull request's `headSha` through the single-index JSON view above and records it; otherwise it records nothing, exactly as a GitLab task always does.
Every consumer already treats it as optional: `bin/fm-teardown.sh` reads the head from the forge at teardown (through `gh`, which fails harmlessly for a non-GitHub URL) and falls back to its provider-agnostic content check regardless of provider, and `bin/fm-review-diff.sh` resolves the head from a live `refs/pull/<n>/head` fetch when the URL shape lets it, or from the recorded value otherwise.
A Gitea URL's `pulls/<n>` shape does not match the `/pull/` pattern `bin/fm-review-diff.sh` looks for, so it falls back to the recorded `pr_head=` exactly as a GitLab task does when no live fetch resolves - the one place a recorded Gitea head is worth having, and the reason `bin/fm-pr-check.sh` records it when it can rather than leaving it unset like GitLab always does.

## Full test coverage

The URL parser matrix, the byte-static poll (arming, silent/merged states, missing-tool and ambiguous-login refusals, doctored-sidecar refusal, watcher-driven retirement), and the merge path (successful merge, default `--style squash`, an explicit style not overridden, extra-argument forwarding, merge failure propagation, missing-tool and ambiguous-login refusals, and both long- and bundled-short-form repository-override refusal) are all covered by `tests/fm-pr-check-security.test.sh` and `tests/fm-pr-merge.test.sh` against hermetic fixtures, run on every change to `bin/fm-pr-lib.sh`, `bin/fm-pr-check.sh`, `bin/fm-pr-merge.sh`, and `bin/fm-pr-poll.sh`.
