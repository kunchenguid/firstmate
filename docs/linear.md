# Linear mirror

firstmate can mirror `data/backlog.md` into Linear as a browsable view, link each task's pull request to its mirrored issue, and refresh that view in place.

`data/backlog.md` stays authoritative for execution.
Linear is a view: reordering or reprioritising there does not reach the backlog.
That split is the captain's decision of 2026-08-02.

**Linear is never a gate.**
Every code path here degrades quietly.
If Linear is unconfigured, unreachable, unauthenticated, or slow, firstmate's
lifecycle continues untouched and the operator is told what did not happen.
Nothing in this feature can prevent a PR from being checked, reported, or merged.

## Configuration

[`configuration.md`](configuration.md#linear-mirror-env) owns the opt-in, supported settings, and defaults.
The key is sent as the bare `Authorization` header value expected by Linear personal API keys; OAuth access tokens use the `Bearer` scheme.

## The join

Nothing about firstmate's branch naming is load-bearing here, and it cannot be:
Linear's own branch convention is `<user>/<issue-key>-<slug>`, and firstmate's
branches are `fm/<task-id>`, which can never match.

The join is the **first line of the Linear issue description**, written by the
original mirror as a markdown code span:

```
`firstmate: <task-id>`
```

It is queryable from Linear directly, so the mapping is recoverable with no local
file. Matching is exact on that first line after backticks and whitespace are
stripped: an issue that merely mentions a task id further down its description is
not a join, and the id `004` never matches `004-engine-surface-testers`.

## How Linear links a pull request

Verified against Linear's own GitHub documentation, <https://linear.app/docs/github>,
fetched 2026-08-02. The supported ways to link a PR to an issue are:

1. The branch name, using Linear's generated convention.
2. The issue ID in the **PR title**.
3. A magic word plus the issue ID in the **PR description**.

Also verified on that page, and load-bearing for this design:

- "To link a PR that is already open, modify the PR title or description to link
  an issue." So editing the body of an already-open PR is a supported linking
  path, not a workaround.
- "Magic words in PR comments won't create links." A comment would not have
  worked, so the reference must go in the body.
- The **closing** magic words are `close, closes, closed, closing, fix, fixes,
  fixed, fixing, resolve, resolves, resolved, resolving, complete, completes,
  completed, completing, implement, implements, implemented, implementing,
  linear issue`.
- The **non-closing** magic words are `ref, refs, references, part of, related
  to, relates to, contributes to, toward, towards`. A non-closing word still
  links, but does not apply the "On PR or commit merge" status when the PR merges.

firstmate writes a **non-closing** word, `Part of <IDENT>`, by default.
A closing word would make GitHub a second writer of the issue's status on merge,
competing with `fm-linear-refresh.sh`, which owns the Done transition because the
backlog is authoritative. Set `LINEAR_MAGIC_WORD=Fixes` to opt into Linear's
merge automation instead.

## Linking a PR: `bin/fm-linear-pr-link.sh`

`bin/fm-pr-check.sh` calls it last and non-fatally, the moment a task's PR is
reported, so a slow or broken Linear can neither delay arming the merge poll nor
fail the check.

It looks up the mirrored issue for the task id and appends to the PR body:

```
<!-- firstmate:linear -->
Part of PSY-42
```

- **Strictly additive.** The existing body is copied byte-for-byte and the block
  appended after it; the result is then checked to still start with the original
  bytes before it is pushed. The validation pipeline's evidence record in the PR
  body is never rewritten, truncated, or reordered. If that check ever fails,
  nothing is pushed.
- **Idempotent.** A body already carrying the marker comment, or the identifier
  anywhere in it, is left alone. Running the PR check twice links exactly once.
- **A missing issue is the normal case.** Only queued items were ever mirrored,
  so most in-flight work has no issue. That is reported, not treated as an error.

After valid arguments are supplied, every operational outcome prints one `linear: ...` line and exits 0.

## Refreshing in place: `bin/fm-linear-refresh.sh`

```sh
bin/fm-linear-refresh.sh --dry-run      # show the plan, change nothing
bin/fm-linear-refresh.sh                # apply it
```

Reconciled on the `firstmate: <task-id>` join, for every id:

| Situation | Action |
| --- | --- |
| In the backlog and in Linear | **Update that issue** - never create a second one |
| In the backlog only | Create it |
| In Linear only | **Report it as retired**, and change nothing |

Deleting or archiving the captain's issues is never this tool's decision, so a
retired id is output, not an action.

Completed work moves to the team's Done status and carries its PR as a Linear
link attachment (or its scout report path in the description), so the board can
answer "what has been built and confirmed" - which `data/backlog.md` cannot,
because it prunes Done to the configured recent few. That is also why
`data/done-archive.md` is read by default alongside the backlog: the pruned Done
entries live there.

What refresh **never** writes: priority, labels, project, cycle, estimate,
assignee, or the status of anything that is not newly done. Those are the
captain's, and reprioritising in Linear must survive a refresh.

An issue whose title and description already match the backlog is left untouched
and counted as `unchanged`, so a converged refresh is a genuine no-op.

Exit codes: `0` refreshed (or inert because Linear is not configured), `2` usage
or unresolvable team, `3` Linear unreachable, `4` some operations failed. Nothing
here is on a PR's path.

## Verification

Hermetic behavior tests: `tests/fm-linear.test.sh`. They stub the network with a
fakebin `curl` answering per GraphQL operation, and pin the degradation contract,
the additive and idempotent body edit, the exact first-line join, and the
in-place reconciliation.

Live verification against the real Linear API and the non-gating PR-check path is recorded in [`linear-verification.md`](linear-verification.md).
