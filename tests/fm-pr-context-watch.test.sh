#!/usr/bin/env bash
# The context writer, installed check, and snapshot monitor compose in one home.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-context-watch)
export FM_HOME="$TMP_ROOT/owning home"
unset FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_ROOT_OVERRIDE
mkdir -p "$FM_HOME/data" "$FM_HOME/state" "$TMP_ROOT/fakebin"
chmod 700 "$FM_HOME/state"
ln -s "$ROOT/bin" "$FM_HOME/bin"
TOOL="$ROOT/bin/fm-pr-context-watch.sh"
export FM_TEST_PR_PAYLOAD="$TMP_ROOT/pr.json"
export FM_PR_CONTEXT_GH_CMD="$TMP_ROOT/fakebin/gh-axi"
export FM_PR_CONTEXT_NOW=1000
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
URL=https://github.com/example/project/pull/12
cat > "$TMP_ROOT/context.json" <<JSON
{"pr_url":"$URL","head":"$HEAD_A","repo":"example/project","branch":"fm/change",
 "oracle":{"name":"acceptance","command":"bin/check"},"tests":[{"command":"bin/check","exit_code":0}],
 "open_review_threads":[],"deferred_items":[],"pre_push_command":"bin/check","merge_authority":"human-merge"}
JSON
cat > "$FM_TEST_PR_PAYLOAD" <<JSON
{"data":{"repository":{"pullRequest":{
 "url":"$URL","state":"OPEN","headRefOid":"$HEAD_A","headRefName":"fm/change",
 "headRepository":{"nameWithOwner":"example/project"},
 "comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"old-comment","updatedAt":"2026-09-12T01:10:00Z"}]},
 "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"old-review","state":"CHANGES_REQUESTED","submittedAt":"2026-09-12T01:10:00Z"}]},
 "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"old-thread","isResolved":false,
   "comments":{"nodes":[{"id":"before-delivery","updatedAt":"2026-09-12T11:58:59Z"}]}}]},
 "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}
}}}}
JSON
cat > "$FM_PR_CONTEXT_GH_CMD" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$1 $2 $3" = 'api POST graphql' ] || exit 1
shift 3
[ ! -f "$FM_TEST_PR_PAYLOAD.fail" ] || exit 7
if [ -n "${FM_TEST_EXPECT_HOST:-}" ]; then [ "${GH_HOST:-}" = "$FM_TEST_EXPECT_HOST" ] || exit 8; fi
filter=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) filter=$2; shift 2 ;;
    --field) shift 2 ;;
    *) exit 1 ;;
  esac
done
# Fake the remote boundary, but execute the real projection passed by the adapter.
jq -e "$filter" "$FM_TEST_PR_PAYLOAD" | jq -r 'to_entries[] | .key + ": " + (.value | tojson)'
if [ -f "$FM_TEST_PR_PAYLOAD.extra" ]; then printf 'unexpected output\n'; fi
SH
chmod +x "$FM_PR_CONTEXT_GH_CMD"
"$ROOT/bin/fm-pr-context.sh" write change < "$TMP_ROOT/context.json" >/dev/null
TZ=UTC touch -t 202609121159.00 "$FM_HOME/data/change/pr-context.md"

out=$("$TOOL" install "$FM_HOME" change 2>&1) || fail "context monitor install failed: $out"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"
fm_custom_check_snapshot_prepare "$FM_HOME/state" pr-fix-change || fail "monitor was not bound through the real installer"
out=$(cd "$TMP_ROOT" && bash "$FM_CUSTOM_CHECK_SNAPSHOT") || fail "installed monitor failed"
fm_custom_check_snapshot_cleanup
[ -z "$out" ] || fail "first poll replayed feedback strictly before delivery: $out"
jq -e '.baseline.context_hash==.context_hash and
  .baseline.delivered_at==("2026-09-12T11:59:00Z"|fromdateiso8601)' \
  "$FM_HOME/state/pr-fix-change.snapshot.json" >/dev/null || fail "delivery baseline was not recorded"
pass "first observation baselines comments, reviews and thread activity strictly before delivery"
jq '.data.repository.pullRequest.comments.nodes=[{id:"C1",updatedAt:"2026-09-12T12:00:00Z"}]' \
  "$FM_TEST_PR_PAYLOAD" > "$TMP_ROOT/next.json"
mv "$TMP_ROOT/next.json" "$FM_TEST_PR_PAYLOAD"
out=$("$TOOL" poll change) || fail "comment poll failed"
[ "$out" = "pr-fix: 12 $HEAD_A comment $URL event=1" ] || fail "comment did not produce the bounded wake: $out"
[ -z "$("$TOOL" poll change)" ] || fail "unchanged poll repeated a wake inside the debounce window"
pass "the real writer and trusted per-home check emit only a bounded comment wake"

first_event=$out
export FM_PR_CONTEXT_NOW=1100
jq '.data.repository.pullRequest.reviews.nodes=[{id:"R1",state:"CHANGES_REQUESTED",submittedAt:"2026-09-12T12:01:00Z"}]' \
  "$FM_TEST_PR_PAYLOAD" > "$TMP_ROOT/next.json"
mv "$TMP_ROOT/next.json" "$FM_TEST_PR_PAYLOAD"
[ -z "$("$TOOL" poll change)" ] || fail "second change escaped the debounce window"
export FM_PR_CONTEXT_NOW=1599
[ -z "$("$TOOL" poll change)" ] || fail "debounce expired early"
export FM_PR_CONTEXT_NOW=1600
event=$("$TOOL" poll change)
[ "$event" = "pr-fix: 12 $HEAD_A comment,review $URL event=2" ] || fail "pending changes were lost across polls: $event"
if "$TOOL" ack change "$first_event" >/dev/null 2>&1; then fail "old delivery acknowledged a newer event"; fi
"$TOOL" ack change "$event" || fail "exact durable delivery acknowledgement failed"
export FM_PR_CONTEXT_NOW=2200
[ -z "$("$TOOL" poll change)" ] || fail "acknowledged unchanged event was replayed"
pass "debounce retains intervening changes and only an exact generation acknowledgement consumes them"

# Exercise the actual check runner and durable queue, without a live terminal backend.
mkdir -p "$FM_HOME/config"
printf 'tmux\n' > "$FM_HOME/config/backend"
printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/fakebin/tmux"
printf '#!/bin/sh\nexit 91\n' > "$TMP_ROOT/fakebin/herdr"
chmod +x "$TMP_ROOT/fakebin/tmux" "$TMP_ROOT/fakebin/herdr"
export PATH="$TMP_ROOT/fakebin:$PATH"
export FM_PR_CONTEXT_NOW=3000
jq '.data.repository.pullRequest.comments.nodes += [{id:"C2",updatedAt:"2026-09-12T12:02:00Z"}]' \
  "$FM_TEST_PR_PAYLOAD" > "$TMP_ROOT/next.json"
mv "$TMP_ROOT/next.json" "$FM_TEST_PR_PAYLOAD"
rc=0
FM_BACKEND=tmux FM_CHECK_INTERVAL=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 15 > "$TMP_ROOT/watch.out" 2> "$TMP_ROOT/watch.err" || rc=$?
expect_code 0 "$rc" "real check runner: $(cat "$TMP_ROOT/watch.err")"
queue=$("$ROOT/bin/fm-wake-drain.sh" 2> "$TMP_ROOT/drain.err")
assert_contains "$queue" "pr-fix: 12 $HEAD_A comment $URL event=3" "monitor result was not durably queued"
export FM_PR_CONTEXT_NOW=3600
[ -z "$("$TOOL" poll change)" ] || fail "runner queued the event but did not acknowledge its exact generation"
pass "the real check runner consumes the outbox only after durable wake publication"

# Rewriting evidence on the same head also advances the delivery baseline.
export FM_PR_CONTEXT_NOW=3700
jq '.data.repository.pullRequest.comments.nodes += [{id:"before-rewrite",updatedAt:"2026-09-12T12:03:00Z"}]' \
  "$FM_TEST_PR_PAYLOAD" > "$TMP_ROOT/next.json"
mv "$TMP_ROOT/next.json" "$FM_TEST_PR_PAYLOAD"
event=$("$TOOL" poll change)
assert_contains "$event" " comment $URL event=" "pre-rewrite feedback was not observed"
# Leave that outbox unacknowledged: replacement evidence covers this old activity.
jq '.tests += [{command:"bin/check",exit_code:0}]' "$TMP_ROOT/context.json" > "$TMP_ROOT/rewrite.json"
"$ROOT/bin/fm-pr-context.sh" write change < "$TMP_ROOT/rewrite.json" >/dev/null
TZ=UTC touch -t 202609121204.00 "$FM_HOME/data/change/pr-context.md"
jq '.data.repository.pullRequest.reviews.nodes += [{id:"late-old-review",state:"CHANGES_REQUESTED",submittedAt:"2026-09-12T12:03:59Z"}]' \
  "$FM_TEST_PR_PAYLOAD" > "$TMP_ROOT/next.json"
mv "$TMP_ROOT/next.json" "$FM_TEST_PR_PAYLOAD"
export FM_PR_CONTEXT_NOW=3800
[ -z "$("$TOOL" poll change)" ] || fail "context rewrite replayed old feedback"
jq -e '.baseline.context_hash==.context_hash and
  .baseline.delivered_at==("2026-09-12T12:04:00Z"|fromdateiso8601) and (.pending|length)==0' \
  "$FM_HOME/state/pr-fix-change.snapshot.json" >/dev/null || fail "rewrite retained the old baseline or outbox"
jq '.data.repository.pullRequest.comments.nodes += [{id:"after-rewrite",updatedAt:"2026-09-12T12:05:00Z"}]' \
  "$FM_TEST_PR_PAYLOAD" > "$TMP_ROOT/next.json"
mv "$TMP_ROOT/next.json" "$FM_TEST_PR_PAYLOAD"
export FM_PR_CONTEXT_NOW=4300
event=$("$TOOL" poll change)
assert_contains "$event" " comment $URL event=" "rewrite swallowed newer feedback"
"$TOOL" ack change "$event"
pass "changed context hashes absorb old pending/history but retain post-delivery activity on the same head"

# A remote-open task may release compute only after the context monitor is ready.
copy="$TMP_ROOT/project copy"
fm_git_init_commit "$copy"
git -C "$copy" checkout -qb fm/change
fm_git_add_origin "$copy" "$TMP_ROOT/remote.git"
git -C "$copy" fetch -q origin
copy_head=$(git -C "$copy" rev-parse HEAD)
jq --arg head "$copy_head" '.head=$head' "$TMP_ROOT/context.json" > "$TMP_ROOT/current-context.json"
"$ROOT/bin/fm-pr-context.sh" write change < "$TMP_ROOT/current-context.json" >/dev/null
jq --arg head "$copy_head" '.data.repository.pullRequest.headRefOid=$head' \
  "$FM_TEST_PR_PAYLOAD" > "$TMP_ROOT/next.json"
mv "$TMP_ROOT/next.json" "$FM_TEST_PR_PAYLOAD"
if "$TOOL" ready change "$URL" "$copy_head" "$copy" >/dev/null 2>&1; then fail "stale context snapshot authorized retirement"; fi
export FM_PR_CONTEXT_NOW=4500
[ -z "$("$TOOL" poll change)" ] || fail "head recorded by the writer was misclassified as external"
"$TOOL" ready change "$URL" "$copy_head" "$copy" || fail "fresh monitored context did not authorize ordinary retirement"
cat > "$FM_HOME/state/change.meta" <<META
kind=ship
pr=$URL
pr_head=$copy_head
worktree=$copy
META
printf 'done: PR %s\n' "$URL" > "$FM_HOME/state/change.status"
cat > "$TMP_ROOT/fakebin/gh" <<'SH'
#!/bin/sh
printf 'OPEN\n'
SH
cat > "$TMP_ROOT/fakebin/teardown" <<'SH'
#!/usr/bin/env bash
[ "$#" -eq 1 ] && [ "$1" = change ] && [ "$FM_TEARDOWN_GUARD_DONE" = 1 ] || exit 91
[ "$(cat "$FM_HOME/data/change/debrief.md")" = 'delivery evidence' ] || exit 92
printf '%s\n' "$*" >> "$FM_HOME/retired"
rm "$FM_HOME/state/change.meta" "$FM_HOME/state/change.status"
SH
printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/fakebin/slack"
chmod +x "$TMP_ROOT/fakebin/gh" "$TMP_ROOT/fakebin/teardown" "$TMP_ROOT/fakebin/slack"
FM_TEARDOWN_BIN="$TMP_ROOT/fakebin/teardown" "$ROOT/bin/fm-auto-retire.sh" > "$TMP_ROOT/missing-debrief.out"
assert_grep 'debrief-missing' "$TMP_ROOT/missing-debrief.out" "open-PR handoff bypassed the debrief guard"
[ ! -e "$FM_HOME/retired" ] || fail "missing debrief retired the task"
[ -f "$FM_HOME/state/change.meta" ] || fail "missing debrief discarded task metadata"
mkdir -p "$copy/data/change"
: > "$copy/data/change/debrief.md"
FM_TEARDOWN_BIN="$TMP_ROOT/fakebin/teardown" "$ROOT/bin/fm-auto-retire.sh" > "$TMP_ROOT/empty-debrief.out"
assert_grep 'debrief-missing' "$TMP_ROOT/empty-debrief.out" "empty debrief bypassed the guard"
[ ! -e "$FM_HOME/retired" ] || fail "empty debrief retired the task"
printf 'delivery evidence\n' > "$copy/data/change/debrief.md"
pass "missing and empty debriefs retain the open task and permit a later retry"
FM_TEARDOWN_BIN="$TMP_ROOT/fakebin/teardown" FM_SLACK_POST_BIN="$TMP_ROOT/fakebin/slack" \
  "$ROOT/bin/fm-auto-retire.sh" > "$TMP_ROOT/retire.out"
[ -f "$FM_HOME/retired" ] || fail "open monitored task was not passed to ordinary teardown"
cmp -s "$copy/data/change/debrief.md" "$FM_HOME/data/change/debrief.md" || fail "debrief was not preserved"
[ ! -e "$FM_HOME/state/change.auto-retire" ] || fail "successful handoff retained its transient retry marker"
[ -f "$FM_HOME/data/change/pr-context.md" ] || fail "retirement removed the durable context"
fm_custom_check_registered "$FM_HOME/state" pr-fix-change || fail "retirement removed the independent monitor"
"$ROOT/bin/fm-pr-context.sh" validate change --json | jq -e '.merge_authority=="human-merge"' >/dev/null \
  || fail "retirement promoted merge authority"
pass "a monitored open PR releases its original task without forcing teardown or removing its context/check"

# Missing source fields are unavailability, never a healthy no-checks PR.
cp "$FM_TEST_PR_PAYLOAD" "$TMP_ROOT/good-pr.json"
export FM_PR_CONTEXT_NOW=5000
jq 'del(.data.repository.pullRequest.commits)' "$TMP_ROOT/good-pr.json" > "$FM_TEST_PR_PAYLOAD"
event=$("$TOOL" poll change)
assert_contains "$event" " unavailable $URL event=" "missing commit evidence became a healthy snapshot"
if "$TOOL" ready change "$URL" "$copy_head" "$copy" >/dev/null 2>&1; then fail "failed read authorized retirement"; fi
"$TOOL" ack change "$event"
cp "$TMP_ROOT/good-pr.json" "$FM_TEST_PR_PAYLOAD"
[ -z "$("$TOOL" poll change)" ] || fail "recovery fabricated review changes"
pass "incomplete forge evidence announces unavailability and withholds retirement until recovery"

"$ROOT/bin/fm-pr-context.sh" write duplicate < "$TMP_ROOT/current-context.json" >/dev/null
if "$TOOL" install "$FM_HOME" duplicate >/dev/null 2>&1; then fail "two contexts acquired the same PR"; fi
[ ! -e "$FM_HOME/state/pr-fix-duplicate.check.sh" ] || fail "rejected duplicate left an executable check"
rm "$FM_HOME/data/duplicate/pr-context.md"
pass "duplicate context ownership is refused before installing another check"

for filter in \
  '.data.repository.pullRequest.comments.pageInfo.hasNextPage=true' \
  '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup={}' \
  '.data.repository.pullRequest.comments.nodes=[{id:"C",updatedAt:"not-a-date"}]' \
  '.data.repository.pullRequest.reviews.nodes=[{id:"R",state:"COMMENTED",submittedAt:"not-a-date"}]' \
  '.data.repository.pullRequest.comments.nodes=[{id:null,updatedAt:"now"}]' \
  '.data.repository.pullRequest.comments.nodes=[{id:"same",updatedAt:"now"},{id:"same",updatedAt:"now"}]' \
  '.data.repository.pullRequest.reviews.nodes=[{id:"R",state:"invalid",submittedAt:null}]' \
  '.data.repository.pullRequest.reviewThreads.nodes=[{id:"T",isResolved:"true",comments:{nodes:[]}}]' \
  '.data.repository.pullRequest.headRepository.nameWithOwner="unrelated/repo"' \
  '.errors=[{message:"partial response"}]'; do
  export FM_PR_CONTEXT_NOW=$((FM_PR_CONTEXT_NOW + 600))
  jq "$filter" "$TMP_ROOT/good-pr.json" > "$FM_TEST_PR_PAYLOAD"
  event=$("$TOOL" poll change)
  assert_contains "$event" " unavailable $URL event=" "malformed response was accepted: $filter"
  "$TOOL" ack change "$event"
  cp "$TMP_ROOT/good-pr.json" "$FM_TEST_PR_PAYLOAD"
  [ -z "$("$TOOL" poll change)" ] || fail "recovery changed the prior good snapshot"
done
pass "pagination, malformed identities, partial errors, and repository mismatches never become healthy evidence"
for fault in fail extra; do
  export FM_PR_CONTEXT_NOW=$((FM_PR_CONTEXT_NOW + 600))
  touch "$FM_TEST_PR_PAYLOAD.$fault"
  event=$("$TOOL" poll change)
  assert_contains "$event" " unavailable $URL event=" "API/wire failure was accepted: $fault"
  "$TOOL" ack change "$event"
  rm "$FM_TEST_PR_PAYLOAD.$fault"
  [ -z "$("$TOOL" poll change)" ] || fail "recovery fabricated changes after $fault"
done
pass "API failures and unexpected wire output retain the last good evidence"

export FM_PR_CONTEXT_NOW=$((FM_PR_CONTEXT_NOW + 600))
jq '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.state="FAILURE"' \
  "$TMP_ROOT/good-pr.json" > "$FM_TEST_PR_PAYLOAD"
event=$("$TOOL" poll change)
assert_contains "$event" " ci-red $URL event=" "CI failure did not wake"
"$TOOL" ack change "$event"
if "$TOOL" ready change "$URL" "$copy_head" "$copy" >/dev/null 2>&1; then fail "red CI authorized retirement"; fi
jq '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.state="PENDING"' \
  "$TMP_ROOT/good-pr.json" > "$FM_TEST_PR_PAYLOAD"
[ -z "$("$TOOL" poll change)" ] || fail "pending CI fabricated a failure"
if "$TOOL" ready change "$URL" "$copy_head" "$copy" >/dev/null 2>&1; then fail "pending CI authorized retirement"; fi
cp "$TMP_ROOT/good-pr.json" "$FM_TEST_PR_PAYLOAD"
[ -z "$("$TOOL" poll change)" ] || fail "green CI fabricated work"
"$TOOL" ready change "$URL" "$copy_head" "$copy" || fail "green recovery stayed ineligible"
pass "red CI wakes and red/pending CI withhold retirement without changing merge policy"

export FM_PR_CONTEXT_NOW=$((FM_PR_CONTEXT_NOW + 600))
head_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
jq --arg head "$head_b" '.data.repository.pullRequest.headRefOid=$head' "$TMP_ROOT/good-pr.json" > "$FM_TEST_PR_PAYLOAD"
event=$("$TOOL" poll change)
assert_contains "$event" "pr-fix: 12 $head_b head-moved $URL event=" "external head movement was missed"
"$TOOL" ack change "$event"
if "$TOOL" ready change "$URL" "$copy_head" "$copy" >/dev/null 2>&1; then fail "foreign head authorized stale-copy retirement"; fi
cp "$TMP_ROOT/good-pr.json" "$FM_TEST_PR_PAYLOAD"
[ -z "$("$TOOL" poll change)" ] || fail "the context head was treated as external"
pass "external head movement is distinguished from the head recorded in the context"

jq '.data.repository.pullRequest.comments.nodes |= reverse' "$TMP_ROOT/good-pr.json" > "$FM_TEST_PR_PAYLOAD"
[ -z "$("$TOOL" poll change)" ] || fail "equivalent collection ordering produced a wake"
export FM_PR_CONTEXT_NOW=$((FM_PR_CONTEXT_NOW + 601))
if "$TOOL" ready change "$URL" "$copy_head" "$copy" >/dev/null 2>&1; then fail "expired observation authorized retirement"; fi
"$TOOL" poll change >/dev/null
git -C "$copy" checkout -qb wrong-branch
if "$TOOL" ready change "$URL" "$copy_head" "$copy" >/dev/null 2>&1; then fail "wrong local branch authorized retirement"; fi
git -C "$copy" checkout -q fm/change
if "$TOOL" ready change "$URL" "$head_b" "$copy" >/dev/null 2>&1; then fail "wrong metadata head authorized retirement"; fi
pass "collection order is irrelevant while snapshot freshness and local identity remain mandatory"

snapshot="$FM_HOME/state/pr-fix-change.snapshot.json"
cp "$snapshot" "$TMP_ROOT/snapshot.backup"
printf 'broken\n' > "$snapshot"
if "$TOOL" poll change >/dev/null 2>&1; then fail "corrupt snapshot was accepted"; fi
[ "$(cat "$snapshot")" = broken ] || fail "corrupt snapshot was silently overwritten"
cp "$TMP_ROOT/snapshot.backup" "$snapshot"
mv "$snapshot" "$TMP_ROOT/snapshot.target"
ln -s "$TMP_ROOT/snapshot.target" "$snapshot"
if "$TOOL" poll change >/dev/null 2>&1; then fail "linked snapshot was accepted"; fi
cmp -s "$TMP_ROOT/snapshot.target" "$TMP_ROOT/snapshot.backup" || fail "linked target was modified"
rm "$snapshot"
mv "$TMP_ROOT/snapshot.target" "$snapshot"
cp "$FM_HOME/state/pr-fix-change.check.sh" "$TMP_ROOT/check.backup"
printf '# changed\n' >> "$FM_HOME/state/pr-fix-change.check.sh"
if "$TOOL" ready change "$URL" "$copy_head" "$copy" >/dev/null 2>&1; then fail "modified check authorized retirement"; fi
cp "$TMP_ROOT/check.backup" "$FM_HOME/state/pr-fix-change.check.sh"
rm "$FM_HOME/state/pr-fix-change.check-trust"
"$TOOL" install "$FM_HOME" change >/dev/null || fail "interrupted registration could not converge"
fm_custom_check_registered "$FM_HOME/state" pr-fix-change || fail "registration repair did not bind exact bytes"
pass "corrupt/linked evidence and modified checks refuse; canonical interrupted installation converges"

export FM_PR_CONTEXT_NOW=$((FM_PR_CONTEXT_NOW + 600))
event=$(GH_HOST=unrelated.example FM_TEST_EXPECT_HOST=github.com "$TOOL" poll change)
[ -z "$event" ] || fail "ambient forge host redirected the context lookup: $event"
pass "the context lookup stays on GitHub despite an unrelated ambient host"
if "$TOOL" retire "$FM_HOME" change >/dev/null 2>&1; then fail "an open PR monitor was retired"; fi
jq '.data.repository.pullRequest.state="MERGED"' "$TMP_ROOT/good-pr.json" > "$FM_TEST_PR_PAYLOAD"
event=$("$TOOL" poll change)
assert_contains "$event" " merged $URL event=" "merge disappeared after original task retirement"
"$TOOL" ack change "$event"
export FM_PR_CONTEXT_NOW=$((FM_PR_CONTEXT_NOW + 600))
[ -z "$("$TOOL" poll change)" ] || fail "acknowledged terminal state was re-announced"
"$TOOL" retire "$FM_HOME" change >/dev/null || fail "terminal monitor could not retire"
"$TOOL" retire "$FM_HOME" change >/dev/null || fail "repeated terminal retirement did not converge"
[ ! -e "$FM_HOME/state/pr-fix-change.check.sh" ] || fail "terminal check survived retirement"
[ -f "$FM_HOME/data/change/pr-context.md" ] || fail "monitor retirement discarded context evidence"
pass "terminal PR state remains observable without the original task and its check retires without deleting evidence"

closed_url=https://github.com/example/project/pull/13
jq --arg url "$closed_url" '.pr_url=$url' "$TMP_ROOT/current-context.json" > "$TMP_ROOT/closed-context.json"
"$ROOT/bin/fm-pr-context.sh" write closed < "$TMP_ROOT/closed-context.json" >/dev/null
"$TOOL" install "$FM_HOME" closed >/dev/null
jq --arg url "$closed_url" '.data.repository.pullRequest.url=$url | .data.repository.pullRequest.state="CLOSED"' \
  "$TMP_ROOT/good-pr.json" > "$FM_TEST_PR_PAYLOAD"
event=$("$TOOL" poll closed)
assert_contains "$event" " closed $closed_url event=" "closed PR did not produce a terminal event"
if "$TOOL" retire "$FM_HOME" closed >/dev/null 2>&1; then fail "unqueued terminal event was discarded"; fi
"$TOOL" ack closed "$event"
"$TOOL" retire "$FM_HOME" closed >/dev/null || fail "acknowledged closed PR stayed registered"
pass "closed PRs retain their terminal outbox until durable delivery acknowledgement"

fresh_url=https://github.com/example/project/pull/14
jq --arg url "$fresh_url" '.pr_url=$url' "$TMP_ROOT/current-context.json" > "$TMP_ROOT/fresh-context.json"
"$ROOT/bin/fm-pr-context.sh" write fresh < "$TMP_ROOT/fresh-context.json" >/dev/null
TZ=UTC touch -t 202609121204.00 "$FM_HOME/data/fresh/pr-context.md"
jq --arg url "$fresh_url" '.data.repository.pullRequest.url=$url |
  .data.repository.pullRequest.comments.nodes=[
    {id:"old",updatedAt:"2026-09-12T01:10:00Z"},{id:"new",updatedAt:"2026-09-12T12:05:00Z"}] |
  .data.repository.pullRequest.reviews.nodes=[{id:"old-review",state:"COMMENTED",submittedAt:"2026-09-12T12:03:59Z"}]' \
  "$TMP_ROOT/good-pr.json" > "$FM_TEST_PR_PAYLOAD"
"$TOOL" install "$FM_HOME" fresh >/dev/null
event=$("$TOOL" poll fresh)
[ "$event" = "pr-fix: 14 $copy_head comment $fresh_url event=1" ] || fail "initial baseline swallowed new feedback: $event"
jq -e '(.observed.comments|length)==2' "$FM_HOME/state/pr-fix-fresh.snapshot.json" >/dev/null \
  || fail "baselining discarded observed history"
pass "first observation retains history while excluding strictly older activity"
"$TOOL" ack fresh "$event"
export FM_PR_CONTEXT_NOW=$((FM_PR_CONTEXT_NOW + 600))
jq '.data.repository.pullRequest.reviewThreads.nodes[0].isResolved=true |
  .data.repository.pullRequest.reviews.nodes[0].state="DISMISSED"' \
  "$FM_TEST_PR_PAYLOAD" > "$TMP_ROOT/next.json"
mv "$TMP_ROOT/next.json" "$FM_TEST_PR_PAYLOAD"
event=$("$TOOL" poll fresh)
assert_contains "$event" " comment,review $fresh_url event=" "baseline hid subsequently observed state changes"
pass "newly observed thread/review state changes remain actionable even on old feedback"
"$TOOL" ack fresh "$event"
[ -z "$("$TOOL" poll fresh)" ] || fail "unchanged state transition replayed its wake"
"$TOOL" inspect fresh | jq -e '
  any(.feedback.threads[]; .id=="old-thread") and any(.feedback.reviews[]; .id=="old-review")' >/dev/null \
  || fail "unchanged polling erased actionable state-change identities before repair intake"
pass "actionable state-change identities survive acknowledgement and unchanged polls"

# Feedback arrives after delivery but shares its forge timestamp's whole second.
same_url=https://github.com/example/project/pull/15
jq --arg url "$same_url" '.pr_url=$url' "$TMP_ROOT/current-context.json" > "$TMP_ROOT/same-context.json"
"$ROOT/bin/fm-pr-context.sh" write same-second < "$TMP_ROOT/same-context.json" >/dev/null
TZ=UTC touch -t 202609121205.00 "$FM_HOME/data/same-second/pr-context.md"
jq --arg url "$same_url" '.data.repository.pullRequest.url=$url |
  .data.repository.pullRequest.comments.nodes=[
    {id:"historical-comment",updatedAt:"2026-09-12T12:04:59Z"},
    {id:"same-comment",updatedAt:"2026-09-12T12:05:00Z"}] |
  .data.repository.pullRequest.reviews.nodes=[
    {id:"same-review",state:"CHANGES_REQUESTED",submittedAt:"2026-09-12T12:05:00Z"}] |
  .data.repository.pullRequest.reviewThreads.nodes=[{id:"same-thread",isResolved:false,
    comments:{nodes:[{id:"same-thread-comment",updatedAt:"2026-09-12T12:05:00Z"}]}}]' \
  "$TMP_ROOT/good-pr.json" > "$FM_TEST_PR_PAYLOAD"
"$TOOL" install "$FM_HOME" same-second >/dev/null
event=$("$TOOL" poll same-second)
assert_contains "$event" " comment,review $same_url event=" "same-second post-delivery feedback was swallowed"
[ -z "$("$TOOL" poll same-second)" ] || fail "same-second feedback bypassed debounce"
export FM_PR_CONTEXT_NOW=$((FM_PR_CONTEXT_NOW + 600))
event=$("$TOOL" poll same-second)
assert_contains "$event" " comment,review $same_url event=" "unchanged polling lost unacknowledged same-second feedback"
"$TOOL" ack same-second "$event"
export FM_PR_CONTEXT_NOW=$((FM_PR_CONTEXT_NOW + 600))
[ -z "$("$TOOL" poll same-second)" ] || fail "acknowledged same-second feedback replayed"
"$TOOL" inspect same-second | jq -e '
  [.feedback.comments[].id]==["same-comment"] and
  [.feedback.reviews[].id]==["same-review"] and
  [.feedback.threads[].id]==["same-thread"]' >/dev/null \
  || fail "same-second feedback was erased or historical feedback became actionable"
pass "same-second post-delivery feedback survives first observation and unchanged polls without replaying earlier history"
