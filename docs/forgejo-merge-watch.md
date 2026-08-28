# Forgejo pull request watch and merge verification

Empirical record for the merge watch and the merge path on Forgejo, alongside the existing GitHub and GitLab ones.
Every command below was run on 2026-08-28.
Every output is reproduced exactly.

## Versions

```
$ forgejo-axi --version
1.3.0

$ jq --version
jq-1.8.1

$ bash --version | head -1
GNU bash, version 5.3.9(1)-release (x86_64-redhat-linux-gnu)
```

## The evidence instance

All live evidence here reads <https://codeberg.org>, the public Forgejo instance Forgejo itself is developed on.
Every command against it reads a public pull request and needs no credential, so a reader can rerun each one and see the same output.

Two pull requests in `forgejo/forgejo` are used, both in a terminal state that cannot change:

- `pulls/1000` is merged, so it is the one outcome that must produce a wake.
- `pulls/14141` is closed without being merged, so it is an outcome that must never produce one.

A non-default host appears below only as the placeholder `forgejo.example`, which resolves nowhere.

```
$ forgejo-axi status --base-url https://codeberg.org
host:
  url: "https://codeberg.org"
  api_url: "https://codeberg.org/api/v1"
auth:
  configured: false
  authenticated: false
  source: null
server:
  version: 16.0.0-dev-714-11075108+gitea-1.22.0
```

## Why the host is data rather than a constant

Forgejo is self-hosted and has no host of its own, so a pull request can live under any host.
The stored record therefore carries `provider`, `url`, `host`, `path`, and `number`, exactly as the GitLab record does, and every consumer rebuilds the URL from those parts and refuses any record that does not reconstruct the stored URL exactly.
A Forgejo project is always one owner and one repository, so `path` is an `owner/repository` pair and `bin/fm-pr-merge.sh` can address it directly, which a GitLab namespace at arbitrary depth never allows.

## Why `--base-url` is passed rather than the pull request URL

`forgejo-axi` accepts a pull request URL, but it reads only the owner, repository, and number out of one and still sends the request to whatever host its own configuration resolves.
Passing the URL alone would therefore let an ambient default answer for the host the record names.
A `forgejo.example` URL answered from Codeberg proves it:

```
$ forgejo-axi pr merged --base-url https://codeberg.org https://forgejo.example/forgejo/forgejo/pulls/1000
proof:
  merged: true
  number: 1000
  url: "https://codeberg.org/forgejo/forgejo/pulls/1000"
  head_sha: 355add5cd7a842beb494cf9afad05f0f59331aa7
  merge_commit_sha: 355add5cd7a842beb494cf9afad05f0f59331aa7
  merged_at: "2023-07-10T09:30:05+02:00"
  merged_by: caesar
```

Both the poll and the merge path therefore pass the host from the validated record as `--base-url` and the parsed pair as `--repo`, and never hand a URL to the CLI at all.

## Why the plural `pulls` matters

A Forgejo pull request URL carries `/pulls/`, while GitHub's carries the singular `/pull/`.
That single segment is what tells the two apart on a host that is not `github.com`, so each provider keeps its own spelling and neither accepts the other's.
`github.com` and `gitlab.com` are additionally refused as Forgejo hosts even though their shape is otherwise valid: they are those forges' own hosts and never a Forgejo instance, so `https://github.com/o/r/pulls/1` would otherwise arm a watch that can never succeed.
`tests/fm-pr-check-security.test.sh` covers the plural, the singular, both cross-provider spoofs, and the Forgejo owner and repository name rules.

## End to end: arming and polling a real pull request

Three tasks were armed, two against Codeberg and one against the placeholder host:

```
$ fm-pr-check.sh e1 https://codeberg.org/forgejo/forgejo/pulls/1000
armed: state/e1.check.sh
$ fm-pr-check.sh e2 https://codeberg.org/forgejo/forgejo/pulls/14141
armed: state/e2.check.sh
$ fm-pr-check.sh e3 https://forgejo.example/my-org/tools/pulls/7
armed: state/e3.check.sh
```

The stored record for each, showing the host and the owner/repository pair as data:

```
$ cat state/e1.pr-poll
forgejo
https://codeberg.org/forgejo/forgejo/pulls/1000
codeberg.org
forgejo/forgejo
1000

$ cat state/e3.pr-poll
forgejo
https://forgejo.example/my-org/tools/pulls/7
forgejo.example
my-org/tools
7
```

The provenance record for the non-default host, on the same version tag the other providers use:

```
$ cat state/e3.pr-poll-registration
fm-pr-poll-registration-v2
e3
forgejo
https://forgejo.example/my-org/tools/pulls/7
forgejo.example
my-org/tools
7
8141a5928e52af1e2b80ab27b594635583bbb13f935900f5105e1873e79142aa
4df03972907646e0d88f3ff1c98bc2cef30858cea409d372743b9aab41af1bfc
49:410182
49:410183
```

A Forgejo task records `pr_head=` too, because `forgejo-axi` exposes the head commit as a selectable field and needs no repository on disk to read it:

```
$ cat state/e1.meta
window=fm-e1
kind=ship
pr=https://codeberg.org/forgejo/forgejo/pulls/1000
pr_head=355add5cd7a842beb494cf9afad05f0f59331aa7
```

Running each published poll the way the watcher does, where an empty result means the poll stayed silent and produced no wake:

```
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
merged
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e2.pr-poll)
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e3.pr-poll)
```

The merged pull request produces exactly one `merged` line.
The closed one produces nothing, and the unreachable placeholder host produces nothing rather than a false merge.

The same bytes work in the watcher's sidecar-driven mode, where the published check locates its own record:

```
$ state/e1.check.sh
merged
```

## A missing CLI produces no wake, never a false merge

The poll is silent on every error by design, so a missing `forgejo-axi` would otherwise be indistinguishable from a pull request that is never merged.
With `forgejo-axi` removed from `PATH`, the poll stays silent even for the pull request that is genuinely merged:

```
$ PATH="$nofj" fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
```

Arming is the one point where that can be reported, so it refuses there instead of arming a watch that can never fire:

```
$ PATH="$nofj" fm-pr-check.sh e4 https://codeberg.org/forgejo/forgejo/pulls/1000
error: watching a Forgejo pull request requires forgejo-axi on PATH
$ echo $?
1
```

## Merging a pull request

`bin/fm-pr-merge.sh` merges a Forgejo pull request through the shared recording helper and one live pre-merge read.
Every run below used a throwaway `FM_HOME`, so no live task record was touched, and a `forgejo-axi` wrapper that refused any `pr merge` subcommand outright, so no merge could reach the forge even if a check were wrong.

A closed pull request is refused, and every failing condition is listed rather than just the first, followed by the forge's own reasons:

```
$ fm-pr-merge.sh e2 https://codeberg.org/forgejo/forgejo/pulls/14141
armed: state/e2.check.sh
error: refusing to merge https://codeberg.org/forgejo/forgejo/pulls/14141
  - the forge reports mergeable as "false", not true
  - the checks at head 910556df46e2bfb2f8547c57568ef45bc5f47683 report passing as "false", not true
  - the merged verdict is "false", not true
error:   - the forge names: forgejo_not_mergeable, checks_failure
```

A pull request whose state cannot be read at all is refused before any merge is attempted.
`pulls/1000` merged in 2023 and its base branch is long gone, so the branch-protection route the mergeability read needs answers 404:

```
$ fm-pr-merge.sh e1 https://codeberg.org/forgejo/forgejo/pulls/1000
armed: state/e1.check.sh
error: could not read the Forgejo pull request state before merging
$ echo $?
1
```

Both refusals came after `pr=` was recorded and the merge poll was armed, exactly as a failing `gh-axi pr merge` does on the GitHub side, so a refusal still leaves the audit trail and the watch in place.

A repository whose pull requests report no passing checks therefore cannot merge through this path.
That is the intended reading of the requirement rather than an oversight, and it matches the GitLab path, where a project that runs no pipeline cannot merge either: passing checks at the head is a condition, and "there are no checks" does not satisfy it.

The remaining refusal conditions, the merge itself, and the confirmation that follows it are covered by `tests/fm-pr-merge.test.sh` against fixtures.
The merge is not exercised against any live pull request, in either direction: `forgejo-axi pr merge` has no dry run, so a live success path would mean merging someone's work to produce evidence.

## Why the head is read live and bound to the merge

The verified head is passed to `forgejo-axi pr merge --expected-head`, which re-reads the pull request before merging, refuses when the head has moved, sends that commit as the merge request's `head_commit_id`, and refuses to report a merge it cannot prove landed at that exact commit.
Without it, a push landing between the read and the merge would merge commits nothing verified.
A recorded `pr_head=` that no longer matches the live head is reported and the live head is what gets verified, because a rebase moves the head and leaves the recorded value stale.

## Why a merge method is named here and not on GitLab

GitLab's merge API applies the project's own merge method, so imposing one there would override that convention.
Forgejo's merge API takes the method in the request body and has no such fallback, so some method is always chosen.
This path therefore passes `--method squash`, the same squash default GitHub gets, rather than inheriting `forgejo-axi`'s own `merge` default, and a caller who wants another one passes `-- --method merge` or `-- --method rebase`.
`forgejo-axi pr merge` takes no `--squash`, `--merge` or `--rebase` flag, so those GitHub spellings are refused by name before anything is recorded rather than suppressing the default and failing at the CLI after the live pre-merge read has already run.
A repository that disallows the chosen method fails the merge loudly at the forge instead of landing something else.

## Known limits of this integration

A Forgejo instance served under a path prefix, such as `https://example.test/forge/owner/repo/pulls/1`, is refused rather than misparsed.
The canonical form this path accepts is exactly `https://<host>/<owner>/<repository>/pulls/<number>`, and an owner or repository name outside Forgejo's own rules is refused with it.

`forgejo-axi pr mergeability` reads commit statuses and branch protection, not Actions runs.
An instance that does not serve the Actions runs API is therefore fully supported here, because nothing in this path asks for it.
