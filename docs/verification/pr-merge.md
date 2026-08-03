# PR merge confirmation verification

Audience: maintainer verification.

This record supports the active guarantee that `bin/fm-pr-merge.sh` exits zero only when the pull request is confirmed merged at the forge.
The script header owns the exact usage, flags, and exit codes.
[`AGENTS.md`](../../AGENTS.md) owns when firstmate may merge a task PR at all.
Task chronology and delivery evidence remain outside this record.

## Why the confirmation exists

`gh-axi pr merge` reports success as soon as `gh` accepts the merge request and never re-reads the pull request afterwards.
A merge command that exits zero is therefore not evidence that the work landed.
Because firstmate's lifecycle treats a completed merge here as ground truth that the work is live, and teardown may then discard the task's branch, the merged state has to be confirmed independently.

## Observed on 2026-08-02

Verified with `gh-axi` 0.1.28 and `gh` 2.97.0 against a throwaway private repository whose base branch required a status check that never runs, so the pull request could not merge.

```
$ gh-axi pr merge 1 --repo hunterleesoik/fm-pr-merge-probe --squash --auto
merged:
  number: 1
  status: ok
  method: squash
help[1]:
  Run `gh-axi pr revert 1 -R hunterleesoik/fm-pr-merge-probe` to revert if needed
EXIT_CODE=0

$ gh pr view 1 --repo hunterleesoik/fm-pr-merge-probe --json state,mergedAt,mergeStateStatus
{"mergeStateStatus":"BLOCKED","mergedAt":null,"state":"OPEN"}
```

The command reported a completed squash merge, offered a revert, and exited zero while the pull request was still open and unmerged.
This is the false success the confirmation step exists to catch.

A merge rejected without `--auto` already fails loudly on the same fixture, so the gap is specific to a merge command that exits zero without the pull request reaching the merged state:

```
$ gh-axi pr merge 1 --repo hunterleesoik/fm-pr-merge-probe --squash
error: "X Pull request hunterleesoik/fm-pr-merge-probe#1 is not mergeable: the base branch policy prohibits the merge."
code: UNKNOWN
EXIT_CODE=1
```

## Confirmation mechanism

The confirmation reads the merged state with `gh pr view <url> --json state -q .state` and requires exactly `MERGED`.
This is the same read `bin/fm-pr-poll.sh` uses as the watcher's merge authority, so both paths agree on what merged means.
`gh` is necessarily present whenever a merge succeeded, because `gh-axi` shells out to it.
An unreadable state is treated as not merged rather than assumed landed.

`bin/fm-pr-poll.sh` does not share this gap: it prints `merged` only when that same read returns `MERGED`, and stays silent on every error.

## Regression coverage

`tests/fm-pr-merge.test.sh` covers the confirmation, including a merge command that exits zero without the pull request merging, a queued auto-merge reported as its own non-merged outcome, and a merge that lands just after the command returns.
