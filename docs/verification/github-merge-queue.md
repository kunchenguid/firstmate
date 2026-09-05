# GitHub merge-queue merge verification

Audience: maintainer verification.

This record supports the current guarantee that a GitHub merge-queue enqueue is not a landing.
`bin/fm-pr-merge.sh` can omit a merge strategy so the forge chooses the method and then names the live outcome of that merge call, `bin/fm-pr-poll.sh` stays silent until the pull request is merged, and `bin/fm-teardown.sh` refuses while the pull request is still open.
The merge-method flags themselves are owned by the `bin/fm-pr-merge.sh` header.

No public pull request was in a merge queue at collection time, so queue membership was read from live GraphQL schema enums plus GitHub's documented CLI enqueue behavior, and the poll-relevant `state` field was read from a live open pull request.

## Environment

Recorded 2026-08-24 on GNU bash 5.2.37(1)-release (x86_64-pc-linux-gnu).

```
$ gh --version
gh version 2.46.0 (2025-01-13 Debian 2.46.0-3)
https://github.com/cli/cli/releases/tag/v2.46.0

$ gh-axi --version
0.1.33
```

## Pull request state is not the queue entry state

Live GraphQL introspection of `PullRequestState` has only three values.
`QUEUED` and `AWAITING_CHECKS` are not pull request states.

```
$ gh api graphql -f query='query { __type(name: "PullRequestState") { enumValues { name description } } }'
{"data":{"__type":{"enumValues":[{"name":"OPEN","description":"A pull request that is still open."},{"name":"CLOSED","description":"A pull request that has been closed without being merged."},{"name":"MERGED","description":"A pull request that has been closed by being merged."}]}}}
```

Live introspection of `MergeQueueEntryState` is the queue-entry machine the brief named.

```
$ gh api graphql -f query='query { __type(name: "MergeQueueEntryState") { enumValues { name description } } }'
{"data":{"__type":{"enumValues":[{"name":"QUEUED","description":"The entry is currently queued."},{"name":"AWAITING_CHECKS","description":"The entry is currently waiting for checks to pass."},{"name":"MERGEABLE","description":"The entry is currently mergeable."},{"name":"UNMERGEABLE","description":"The entry is currently unmergeable."},{"name":"LOCKED","description":"The entry is currently locked."}]}}}
```

The merge poll and the teardown landed-work check both read `gh pr view --json state`.
That CLI, at this `gh` version, does not expose `isInMergeQueue` or `mergeQueueEntry`.

```
$ gh pr view https://github.com/microsoft/TypeScript/pull/63931 --json isInMergeQueue
Unknown JSON field: "isInMergeQueue"
```

On a live open pull request, the poll-relevant fields stay `OPEN` with a null merge time, which is the same `state` a queued pull request keeps until it lands.

```
$ gh pr view https://github.com/microsoft/TypeScript/pull/63931 --json state,mergedAt,mergeStateStatus,url
{"mergeStateStatus":"BLOCKED","mergedAt":null,"state":"OPEN","url":"https://github.com/microsoft/TypeScript/pull/63931"}

$ gh api graphql -f query='query { repository(owner:"microsoft", name:"TypeScript") { pullRequest(number:63931) { url state merged mergedAt mergeStateStatus isInMergeQueue mergeQueueEntry { state position } } } }'
{"data":{"repository":{"pullRequest":{"url":"https://github.com/microsoft/TypeScript/pull/63931","state":"OPEN","merged":false,"mergedAt":null,"mergeStateStatus":"BLOCKED","isInMergeQueue":false,"mergeQueueEntry":null}}}}
```

## Enqueue is not a merge

`gh pr merge --help` on this CLI version states that a merge-queue target needs no strategy, enables auto-merge when checks have not passed, and adds the pull request to the queue when they have.

```
When targeting a branch that requires a merge queue, no merge strategy is required.
If required checks have not yet passed, auto-merge will be enabled.
If required checks have passed, the pull request will be added to the merge queue.
```

Passing an explicit strategy is what GitHub rejects on those branches, with the refusal `The merge strategy for <branch> is set by the merge queue`.

`gh-axi` 0.1.33 accepts `--method` only as `merge`, `squash`, or `rebase`, so `--method=queue` must be consumed by `bin/fm-pr-merge.sh` and not forwarded.

Because the merge call succeeds either way and the forge CLI labels the enqueue a merge, the same live outcome read that follows every GitHub merge names whether the pull request is merged or in the merge queue.
That read is queue-aware when `gh` is present (`isInMergeQueue`) and degrades to the gh-axi view otherwise.

```
$ gh pr view 63931 --repo microsoft/TypeScript --json state -q .state
OPEN

$ gh pr view 63927 --repo microsoft/TypeScript --json state -q .state
MERGED
```

An outcome that is neither merged nor queued is refused.
An unreadable outcome is refused and keeps the merge poll armed.
Landing is still confirmed by the merge poll and teardown, which accept `MERGED` alone.

## GitLab is unchanged

`--no-method`, `--method=queue`, and `--method queue` are firstmate-level tokens that no `glab` flag defines, and GitLab already applies the project's own merge method.
They are refused by name on GitLab before any state is recorded, rather than forwarded to `glab` after the merge is armed, and a merge method the caller spells for `glab` itself still forwards untouched.

## Portable regressions

```sh
bin/fm-test-run.sh tests/fm-pr-merge.test.sh
bin/fm-test-run.sh tests/fm-pr-check-security.test.sh
bin/fm-test-run.sh tests/fm-teardown.test.sh
```

The merge tests prove `--method=queue`, `--method queue`, and `--no-method` invoke `gh-axi pr merge` with no strategy flag, that a queue-governed base is refused with a forge-decides retry rather than an explicit strategy the queue would reject, that the printed retry is itself accepted when run, that a caller whose own arguments already are that retry is told no different retry exists instead of being handed their own command back, on every rules outcome that would otherwise name it and whether the merge command succeeded or failed, that combining one of those tokens with an explicit GitHub strategy is refused before the forge is called, that the same live outcome read names a queued pull request as queued and a merged one as merged, that an unreadable state refuses rather than claiming a merge, and that those tokens are refused on GitLab before any state is recorded while a real GitLab merge method still forwards.
The poll contract stays silent for `OPEN`, `CLOSED`, an empty state, and a malformed one, and emits `merged` only for `MERGED`.
Teardown refuses an open pull request whose commits are not otherwise landed.
