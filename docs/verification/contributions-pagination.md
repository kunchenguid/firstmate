# Contribution observation pagination verification

Repeatable evidence that published-contribution observation works on the `gh` a machine actually has, including builds with no `api --slurp` flag.
Current behavior and the data contract are owned by the header of [`../../bin/fm-contributions.sh`](../../bin/fm-contributions.sh); this page records evidence only.

Date: 2026-09-30.
Host: Linux, GNU bash 5.2.
Comparison base: `main` at `c35b9a69`.

## Why the guarantee is needed

`gh api --slurp` does not exist in every supported `gh`: it was added in gh 2.48.0 (2024-04-17, cli/cli#8620).
Stock Ubuntu noble ships `gh version 2.45.0 (2025-07-18 Ubuntu 2.45.0-1ubuntu0.3)`, which rejects the flag outright with `unknown flag: --slurp` and exit status 1.
Firstmate must observe contributions on the `gh` the machine has rather than on a version floor it cannot enforce.

## Affected operation and user-visible failure

`observe()` in `bin/fm-contributions.sh` performs seven paginated reads across its pull-request and issue paths: issue comments, pull-request reviews, pull-request inline comments, commit check-runs, commit statuses, and the issue timeline.
Every one of those previously passed `--paginate --slurp`, so on a `gh` without the flag every read failed, `observe()` returned non-zero for every URL, and `poll` reported only `contributions: observation unavailable for <url>`.
This was not an edge case bound to merged pull requests or deleted branches: it affected every observed URL, open or merged, pull request or issue.
The user-visible consequence is that no contribution is ever observed, so maintainer comments, reviews, and `ready-for-pr` transitions never become pending signals, and coverage can never be proven clear.

## Reproduction with the incompatible behavior simulated

The host `gh` is `gh version 2.102.0 (2026-09-30)`, which does support `--slurp`, so the original failure no longer reproduces from the host tool alone.
A stub earlier on `PATH` that rejects the flag exactly as 2.45.0 did reproduces it deterministically and shows the working shape beside it.

```console
$ gh --version | head -1
gh version 2.102.0 (2026-09-30)
$ cat stub/gh
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = --slurp ] || continue; printf 'unknown flag: --slurp\n' >&2; exit 1; done
printf '[{"id":1}]\n'
$ PATH=stub:$PATH gh api 'repos/o/r/issues/1/comments?per_page=100' --paginate --slurp; echo "rc=$?"
unknown flag: --slurp
rc=1
$ PATH=stub:$PATH gh api 'repos/o/r/issues/1/comments?per_page=100' --paginate | jq -c -s '., (type), (all(.[]; type=="array"))'
[[{"id":1}]]
"array"
true
```

`tests/fm-contributions.test.sh` carries the same simulation as a permanent regression guard rather than leaving it to a manual stub: its shared `gh` fixture rejects `--slurp` with `unknown flag: --slurp` on stderr and exit status 1, and serves `--paginate` as the raw page stream.
`tests/fm-pr-check-security.test.sh` carries the same fixture shape, so the registered-check path is covered by the same guard.

## Chosen fix

`forge_pages` performs each paginated read with `--paginate` alone and folds that read's page stream locally with `jq -s`.
No `gh` pagination flag beyond `--paginate` is required, and the call sites keep the array-of-pages shape every downstream projection already expected, so the existing guard `type == "array" and all(.[]; type == "array")` and the `add` flattening are unchanged.
Both page-stream shapes `gh` produces fold correctly: array endpoints return their pages merged into a single array, and object endpoints such as check-runs return one object per page.

These reads run concurrently as background jobs joined by `wait_forges`, so each fold names its scratch file after its own destination.
One shared scratch path would let five concurrent reads overwrite each other's pages, producing observations assembled from the wrong endpoint's data with no read failure to signal it.

A read that returns no page at all is treated as a failed read rather than an empty result, and it marks the wave unavailable exactly as `forge` does, so a sibling read reaching the budget deadline cannot downgrade it to merely unmeasured.
Without that, an empty stream would fold to `[]`, pass the shape guard vacuously, and record a maintainer comment that exists upstream as a proven absence.

## Regression evidence

```console
$ bash tests/fm-contributions.test.sh | grep -c '^ok'
47
$ bash tests/fm-contributions.test.sh >/dev/null; echo "rc=$?"
rc=0
$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint.sh: local changed-file mode; ShellCheck source following disabled
fm-lint-workflows.sh: actionlint 1.7.12 (pinned 1.7.12)
fm-lint-workflows.sh: 3 workflow files valid
```

`test_observes_without_slurp` drives a full poll against the no-`--slurp` fixture, asserts no recorded `gh` invocation contains `--slurp`, and asserts the observation is usable rather than merely non-empty.
It serves comments, reviews, inline comments, and check-runs as two single-page documents each with distinct content, so a fold that kept only the first page loses the second, and a fold sharing one scratch file across the concurrent reads assembles the wrong stream's pages.
The assertion pins both event tokens per stream, both review ids, and both check-run lane names.
`test_empty_page_stream_is_a_failed_read` pins the fail-closed half: a successful read returning no page keeps error evidence instead of recording a proven-empty observation.

Three mutations confirm the suite fails for the right reasons rather than passing vacuously.
Replacing the per-destination scratch path with one shared path fails many assertions across the suite, because the concurrent reads then corrupt each other.
Removing the empty-stream guard fails exactly `test_empty_page_stream_is_a_failed_read` and nothing else.
Restoring `--paginate --slurp` on the comment reads fails 23 assertions.

## Limitations

The stub reproduction above models one flag rejection; it is not a substitute for running against a real 2.45.0 binary, which this host no longer has.
Multi-page folding is proven against fixture page streams rather than a live forge corpus large enough to paginate, because a live multi-page read depends on repository state no test can guarantee.
The empty-page-stream guard is defensive: no reachable input was found that makes `gh` exit 0 with empty output on these endpoints, since a timeout returns 124 and an HTTP error returns non-zero.
The scratch-isolation guard is a deterministic content check rather than a scheduler-level race detector, so it proves each read folds its own pages but cannot enumerate every interleaving.

## Why the removed capability-gap special case is not part of this fix

An earlier draft of this change named the missing `gh` capability directly, in a dedicated diagnostic with its own episode state, suppression key, and control flow, so that a `--slurp` rejection would be reported as a named capability gap rather than a bare failed read.
Review of that draft found three independent ways that machinery could silently starve contribution observation instead of merely mislabeling it.
A repeating wake carried no episode suppression, so the same named gap could be re-diagnosed and re-logged on every poll rather than settling once.
An episode could also be cleared by a successful read on the same URL that never exercised the missing capability at all, hiding a real, still-present gap behind unrelated success.
A URL with a diagnosed gap could pin the front of the observation queue and consume the poll budget ahead of URLs whose reads could still succeed, so one unreadable URL could starve every other URL's turn.
The mechanism was removed rather than patched a fourth time, because each fix would address only one starvation path without proving no others remained.
Under the fix in this change, a read that fails because this `gh` cannot perform it is an ordinary failed read: the error is recorded on that URL's own record, `checked_at` is advanced, and the loop continues, so the queue rotates and no URL can starve another.
The observer reports `contributions: observation unavailable for <url>` for such a failure, exactly as it did before this change.
Re-adding capability naming, episode state, or any ordering machinery is deliberately out of scope for this fix.
