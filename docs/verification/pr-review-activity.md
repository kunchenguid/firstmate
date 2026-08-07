# PR review-activity watch verification

Empirical record for the review-activity half of the per-task PR poll, alongside the merge half recorded in [`docs/gitlab-merge-watch.md`](../gitlab-merge-watch.md).
Every command below was run on 2026-08-07 and its output is reproduced exactly.
Each fact here would fail silently into a permanent "no review activity" if it were assumed instead of run, which is why it is recorded rather than reasoned about.

Refresh this record by rerunning the commands below after a `gh` upgrade.
The behavior they support is enforced continuously by `tests/fm-pr-review-activity.test.sh`, which runs against a stubbed `gh` and so cannot notice a real field going away.

## Versions

```
$ gh --version | head -1
gh version 2.92.0 (2026-04-28)
```

## The evidence pull requests

All evidence below reads public pull requests in <https://github.com/cli/cli>, so a reader can rerun each command without a credential beyond an authenticated `gh`.
They are ordinary upstream pull requests rather than a fixture, so their counts move over time; the shapes and relationships are what this record establishes, and those are stable.

## The fields the poll reads exist, and carry the instants it uses

`gh pr view` exposes reviews and issue comments as selectable JSON fields.
A review carries `submittedAt` and an issue comment carries `createdAt`:

```
$ gh pr view https://github.com/cli/cli/pull/14079 --json reviews -q '.reviews[0]|keys|join(", ")'
author, authorAssociation, body, commit, id, includesCreatedEdit, reactionGroups, state, submittedAt

$ gh pr view https://github.com/cli/cli/pull/14097 --json comments -q '.comments[0]|keys|join(", ")'
author, authorAssociation, body, createdAt, id, includesCreatedEdit, isMinimized, minimizedReason, reactionGroups, url, viewerDidAuthor
```

There is no field-level projection on the wire: `--json reviews` fetches whole review bodies and `-q` filters them locally.
The poll accepts that cost because it runs on the watcher's slow cadence and under `FM_CHECK_TIMEOUT`, and a read that exceeds the bound reports nothing rather than a wake.

Read those two key lists against each other: `viewerDidAuthor` is present on a comment and absent from a review.
That asymmetry is the whole reason the exclusion below covers comments only.
Excluding a self-authored review would need an author-login comparison, which would put a string the pull request's authors control into the decision, so it is not done and a review stays counted whoever submitted it.

## Why counting reviews covers inline review comments too

The poll reads `reviews` and `comments` and never the inline review-comment endpoint.
That is sound because GitHub creates a review row for every inline comment, including a reply posted into an existing review thread.
Pull request 14079 has eight inline comments across six distinct reviews, three of which are thread replies (`in_reply_to_id` set):

```
$ gh api repos/cli/cli/pulls/14079/comments -q '.[]|"pull_request_review_id=\(.pull_request_review_id) in_reply_to_id=\(.in_reply_to_id // "none")"'
pull_request_review_id=4865420005 in_reply_to_id=none
pull_request_review_id=4865420005 in_reply_to_id=none
pull_request_review_id=4865473130 in_reply_to_id=3721379248
pull_request_review_id=4865827266 in_reply_to_id=none
pull_request_review_id=4865827266 in_reply_to_id=none
pull_request_review_id=4865896961 in_reply_to_id=3721690695
pull_request_review_id=4865899530 in_reply_to_id=3721379181
pull_request_review_id=4865902117 in_reply_to_id=3721690747
```

Every one of those six review ids is a row in the reviews list, so no inline comment is invisible to a count of reviews:

```
$ gh api repos/cli/cli/pulls/14079/reviews -q '.[]|"id=\(.id) state=\(.state)"'
id=4865420005 state=COMMENTED
id=4865473130 state=COMMENTED
id=4865827266 state=COMMENTED
id=4865896961 state=COMMENTED
id=4865899530 state=COMMENTED
id=4865902117 state=COMMENTED
```

## The projection the poll actually reports

`bin/fm-pr-poll.sh` reduces those two fields to review count, issue-comment count, and the newest instant across both, counting only the comments firstmate did not write itself:

```
$ gh pr view https://github.com/cli/cli/pull/14079 --json reviews,comments \
    -q '(.comments // []|map(select(.viewerDidAuthor != true))) as $c|[(.reviews|length|tostring),($c|length|tostring),(([(.reviews[]?.submittedAt),($c[]?.createdAt)]|map(select(. != null and . != ""))|max) // "")]|join(" ")'
6 0 2026-08-05T15:12:33Z
```

The count and the instant are reported together on purpose.
The instant alone would miss two comments landing in the same second, and the count alone would miss activity that replaces rather than adds.

No string the pull request's authors control ever reaches the reported line: only the two counts and the one instant, each validated against a fixed pattern before it is printed.
Firstmate reads the pull request itself for the content.

## The self-authored exclusion, observed firing

The exclusion cannot be demonstrated on `cli/cli`, because `viewerDidAuthor` is defined against whoever is authenticated and this record's viewer has commented on nothing there.
The run below therefore reads one of our own pull requests, whose URL is redacted because it lives in a private repository; rerun it against any pull request you have commented on.
Its comments are one from someone else and one newer one from the viewer:

```
$ gh pr view "$PR" --json comments -q '.comments[]|"viewerDidAuthor=\(.viewerDidAuthor) createdAt=\(.createdAt)"'
viewerDidAuthor=false createdAt=2026-08-04T22:59:15Z
viewerDidAuthor=true createdAt=2026-08-05T00:01:32Z
```

Without the exclusion, the viewer's own comment is both counted and the newest thing on the pull request, so it sets the reported instant, and firstmate wakes to be told about itself:

```
$ gh pr view "$PR" --json reviews,comments \
    -q '[(.reviews|length|tostring),(.comments|length|tostring),(([(.reviews[]?.submittedAt),(.comments[]?.createdAt)]|map(select(. != null and . != ""))|max) // "")]|join(" ")'
8 2 2026-08-05T00:01:32Z
```

With it, the count drops and the instant falls back to the newest thing someone else actually did, here the last of the eight reviews:

```
$ gh pr view "$PR" --json reviews,comments \
    -q '(.comments // []|map(select(.viewerDidAuthor != true))) as $c|[(.reviews|length|tostring),($c|length|tostring),(([(.reviews[]?.submittedAt),($c[]?.createdAt)]|map(select(. != null and . != ""))|max) // "")]|join(" ")'
8 1 2026-08-04T23:42:03Z
```

Both halves move together, which is the point: excluding a comment from the count while letting it still set the instant would change the reported line and wake firstmate anyway.
The comparison is `!= true` rather than `== false`, so a `viewerDidAuthor` that stops being reported counts the comment instead of silently suppressing it - a field that disappears must cost an extra wake, never a missed one.

## Why the counts move but the wake does not repeat

The poll reports this projection on every sweep rather than a terminal event, because a check is invoked with no task identity and must never write task state.
`bin/fm-watch.sh` treats every non-empty check output as actionable, so the suppression of an unchanged repeat is owned by the per-task cursor in `bin/fm-pr-lib.sh` and proved by `tests/fm-pr-review-activity.test.sh`.

## Why GitLab reports merge state only

`glab mr view` has no field selector, exactly as recorded for the merge watch in [`docs/gitlab-merge-watch.md`](../gitlab-merge-watch.md).
Reading review activity from it would need a JSON processor, and `jq` is not one of firstmate's common tools.
A GitLab merge request therefore keeps the merge signal it already had and reports no review activity, the same asymmetry that already leaves a GitLab task without a recorded `pr_head`.
