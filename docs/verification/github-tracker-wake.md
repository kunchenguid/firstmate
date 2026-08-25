# GitHub tracker wake verification

Audience: maintainer verification.

This record holds the empirical facts behind `bin/fm-tracker-notify.sh`.
The script's own header owns its mechanics, and `bin/fm-tracker.sh --help` owns the command surface.

Verified on 2026-08-25 on macOS 26.3 (Darwin 25.3.0) with `gh` 2.92.0, against github.com, on a token carrying scopes `gist, read:org, repo, workflow`.

## One endpoint covers every repository, and states its own cadence

`GET /notifications` is a single endpoint spanning every repository, issue and thread the account can see, so no issue is ever polled individually.
It returns an `ETag` and declares its own polling floor:

```sh
$ gh api -i /notifications | grep -iE '^(HTTP/|Etag|X-Poll-Interval|X-Accepted-Oauth-Scopes)'
HTTP/2.0 200 OK
Etag: "d60a42e19badc17feb376948c52dc1d9824977e41dcad51c682108262d3d244f"
X-Accepted-Oauth-Scopes: notifications, repo
X-Poll-Interval: 60
```

The `repo` scope alone is sufficient to read the inbox; the separate `notifications` scope is not required for listing.

## A conditional re-request costs nothing

A re-request carrying `If-None-Match` returns 304 and consumes zero core rate limit.
Measured either side of the same request:

```sh
$ gh api /rate_limit --jq '.resources.core | "remaining=\(.remaining)  limit=\(.limit)"'
remaining=4966  limit=5000

$ gh api -i -H "If-None-Match: $ETAG" /notifications | grep -iE '^(HTTP/|X-Poll-Interval)'
HTTP/2.0 304 Not Modified
X-Poll-Interval: 60

$ gh api /rate_limit --jq '.resources.core | "remaining=\(.remaining)  limit=\(.limit)"'
remaining=4966  limit=5000
```

`gh` exits non-zero on a 304, so the poll reads the status line as the authority and ignores the exit code.

The same holds for the per-repository issue-comment feed the poll uses as its second source:

```sh
$ gh api -i "/repos/<owner>/<repo>/issues/comments?sort=updated&direction=desc&per_page=5" \
    | grep -iE '^(HTTP/|Etag)'
HTTP/2.0 200 OK
Etag: W/"d6e5d7f0b945fcf0088782a15f5635c5b1b3330d4c89d04b20d2f54a246982a9"

# rate limit 4999 before, conditional request, 4999 after
$ gh api -i -H "If-None-Match: $ETAG" "/repos/<owner>/<repo>/issues/comments?..." | head -1
HTTP/2.0 304 Not Modified
```

That endpoint carries no `X-Poll-Interval`; only `/notifications` states a cadence.

## The inbox does not carry the account's own actions

This is the constraint that shapes the design, and it is why the poll has a second source.

A comment left by the same account that opened the issue produces no notification at all.
Measured on a repository whose issues that account had opened, immediately after posting a comment to one of them:

```sh
$ gh api -X POST "/repos/<owner>/<repo>/issues/144/comments" -f body='...' --jq .id
5406338983

$ gh api "/notifications?all=true&per_page=20" --jq 'length'
0
```

Zero threads, including with `all=true`, which returns read threads as well.

In the current fleet the captain and firstmate authenticate as the same GitHub account, so a captain's answer falls entirely into this case.
The notifications inbox alone would therefore never fire, which is why `bin/fm-tracker-notify.sh` also polls each watched repository's issue-comment feed.
With both sources armed, the same comment does wake firstmate:

```sh
$ state/live.check.sh
issue comment: <owner>/<repo>#144

$ state/live.check.sh      # nothing new
$
```

A quiet poll across both sources consumes no rate limit:

```sh
$ gh api /rate_limit --jq '.resources.core.remaining'
4969
$ state/live.check.sh      # silent
$ gh api /rate_limit --jq '.resources.core.remaining'
4969
```

If the fleet later separates the captain's account from firstmate's, the notifications source begins carrying these events on its own and the per-repository source becomes redundant rather than load-bearing.
Neither source needs removing for that to happen.

## Watcher cadence versus the server's cadence

`bin/fm-watch.sh` sweeps checks every `FM_CHECK_INTERVAL` seconds, default 300, and allows `FM_CHECK_TIMEOUT` seconds per check, default 30.
GitHub's stated floor is 60 seconds, so the default watcher cadence already satisfies it with room to spare; the two do not conflict at their defaults.

They can conflict if a home lowers `FM_CHECK_INTERVAL` below 60.
The poll therefore records the interval the server returned and refuses to re-request the inbox before it elapses, so the server's number wins regardless of local configuration.
The per-repository source is bounded instead by the watch list cap (10 repositories) and by an internal request budget that stops issuing requests before `FM_CHECK_TIMEOUT` would fire.

## The blocking-edge fact the tracker depends on

A markdown task-list reference in an issue body becomes a queryable `trackedIssues` edge; prose does not.
Measured against six hand-written issues, of which only two carried task lists:

```sh
$ gh api graphql -F owner=<owner> -F repo=<repo> -F query=@q.graphql \
    --jq '.data.repository.issues.nodes[] | {n:.number, blockers:[.trackedIssues.nodes[]|{number,state}]}'
{"blockers":[],"n":142}
{"blockers":[],"n":144}
{"blockers":[{"number":143,"state":"CLOSED"}],"n":145}
{"blockers":[{"number":144,"state":"OPEN"}],"n":146}
{"blockers":[],"n":147}
```

Issue 147's body reads `**Blocked by:** nothing - this is the frontier.` and produces no edge, as expected.
Had it named a real issue in that prose, the frontier query would have reported it READY while it was blocked.
That is the defect `fm-tracker.sh add` refuses and `fm-tracker.sh validate` reports.

GitHub ticks the task-list checkbox itself when a blocker closes, so the rendered body and the queried graph cannot drift:

```sh
# before answering #149
## Blocked by
- [ ] #149
# after answering #149, with no rewrite by firstmate
## Blocked by
- [x] #149
```

The `parent` field and `addSubIssue` mutation both work on this token with no preview header.
