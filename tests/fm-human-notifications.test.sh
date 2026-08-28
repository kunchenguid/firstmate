#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031
# Portable contract and watcher delivery tests for edge-triggered human waits.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-human-notify-lib.sh
. "$ROOT/bin/fm-human-notify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-human-notifications)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"

meta() {
  local task=$1 name=$2 gen=${3:-gen-1}
  printf 'display_name=%s\nbusy_gen=%s\nkind=ship\nproject=firstmate\n' "$name" "$gen" > "$STATE/$task.meta"
}

assert_pending() {
  fm_human_notify_pending "$STATE" "$1" "$2" || fail "expected a new notification edge: $1 / $2"
}

assert_absorbed() {
  local rc=0
  fm_human_notify_pending "$STATE" "$1" "$2" || rc=$?
  [ "$rc" -eq 1 ] || fail "expected an unchanged notification to be absorbed (rc=$rc): $1 / $2"
}

meta decision-task 'CRM · Data Shape'
DECISION='needs-decision [key=shape]: choose REST or RPC'
BLOCKER='blocked [key=access]: production credential is missing'
REVIEW='done: PR https://github.com/example/repo/pull/7 checks green'
HOLD='captain-held [key=launch]: approve the launch window'
FAILURE='failed: credential check returned a new denial'
RESULT='done: implementation result is ready for review'
PAUSE='paused: waiting for the vendor release'

[ "$(fm_human_notify_class "$DECISION")" = decision ] || fail "needs-decision did not classify"
[ "$(fm_human_notify_class "$BLOCKER")" = blocker ] || fail "blocked did not classify"
[ "$(fm_human_notify_class "$REVIEW")" = review-ready ] || fail "review-ready PR did not classify"
[ "$(fm_human_notify_class "$HOLD")" = captain-hold ] || fail "captain hold did not classify"
[ "$(fm_human_notify_class "$FAILURE")" = failure ] || fail "failure did not classify"
[ "$(fm_human_notify_class "$RESULT")" = result ] || fail "terminal result did not classify"
if fm_human_notify_class "$PAUSE" >/dev/null 2>&1; then fail "external pause entered human-owned dedupe"; fi
pass "human-owned decisions, blockers, results, failures, and captain holds share one owner while external pauses stay separate"

for row in "$DECISION" "$BLOCKER" "$REVIEW" "$HOLD" "$FAILURE" "$RESULT"; do
  assert_pending decision-task "$row"
  fm_human_notify_record "$STATE" decision-task "$row" || fail "could not record notification"
  assert_absorbed decision-task "$row"
done
pass "each unchanged human-owned condition emits one edge and then stays silent"

CHANGED='needs-decision [key=shape]: choose REST, RPC, or GraphQL after the schema test'
assert_pending decision-task "$CHANGED"
fm_human_notify_record "$STATE" decision-task "$CHANGED"
assert_absorbed decision-task "$CHANGED"
pass "a changed decision question resets the edge without using elapsed time"

fm_human_notify_resolve_line "$STATE" decision-task 'resolved [key=shape]: chose RPC' || fail "resolution failed"
assert_pending decision-task "$DECISION"
fm_human_notify_record "$STATE" decision-task "$DECISION"
assert_absorbed decision-task "$DECISION"
pass "resolution clears the receipt so a genuinely reopened decision notifies"

fm_human_notify_record "$STATE" decision-task "$FAILURE"
fm_human_notify_apply_transition "$STATE" decision-task 'working: recovering the failed run'
assert_pending decision-task "$FAILURE"
fm_human_notify_record "$STATE" decision-task "$REVIEW"
fm_human_notify_apply_transition "$STATE" decision-task 'working: revising after review'
assert_pending decision-task "$REVIEW"
fm_human_notify_record "$STATE" decision-task "$REVIEW"
fm_human_notify_apply_transition "$STATE" decision-task 'blocked [key=merge]: resolve the merge conflict'
assert_pending decision-task "$REVIEW"
fm_human_notify_record "$STATE" decision-task "$REVIEW"
fm_human_notify_apply_transition "$STATE" decision-task "$PAUSE"
assert_pending decision-task "$REVIEW"
pass "recovery, rework, human waits, and external pauses reset readiness for restoration"

printf '%s\n%s\n' 'blocked: temporary dependency failed' 'working: recovered and resumed' > "$STATE/nonkeyed.status"
[ -z "$(status_open_decisions "$STATE/nonkeyed.status")" ] \
  || fail "working recovery left an unkeyed blocker open"
printf '%s\n%s\n' 'blocked [key=access]: credential is required' 'working: unrelated progress resumed' > "$STATE/keyed.status"
assert_contains "$(status_open_decisions "$STATE/keyed.status")" $'access\tblocked\tcredential is required' \
  "working progress closed a keyed blocker without explicit resolution"
fm_human_notify_record "$STATE" decision-task "$BLOCKER"
fm_human_notify_apply_transition "$STATE" decision-task 'working: unrelated progress resumed'
assert_absorbed decision-task "$BLOCKER"
printf '%s\n' 'blocked: a fresh dependency failure' >> "$STATE/keyed.status"
assert_contains "$(status_open_decisions "$STATE/keyed.status")" $'default\tblocked\ta fresh dependency failure' \
  "a fresh unkeyed blocker did not reopen after recovery"
pass "working recovery closes only unkeyed blockers and later blocker edges reopen"

printf '%s\n%s\n' "$FAILURE" 'working: recovery completed' > "$STATE/decision-task.status"
printf '%s\n%s\n' "$FAILURE" 'working: recovery completed' > "$STATE/decision-task.away-unread"
fm_human_notify_record "$STATE" decision-task "$FAILURE"
(
  export FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT"
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  case "$(classify_signal "$STATE/decision-task.status" "$STATE")" in self\|*) ;; *) exit 21 ;; esac
  mark_escalated_seen signal "$STATE/decision-task.status" "$STATE"
  fm_human_notify_pending "$STATE" decision-task "$FAILURE"
) || fail "away replay restored a receipt after recovery resolved the failure"
pass "away classification and replay retain only conditions that remain open"

# Receipts are durable across a new shell process.
FM_STATE_OVERRIDE="$STATE" bash -c '
  . "$1/bin/fm-human-notify-lib.sh"
  fm_human_notify_pending "$2" decision-task "$3"
' _ "$ROOT" "$STATE" "$DECISION" && fail "restart replay re-notified an unchanged decision"
pass "restart and replay preserve one-shot silence"

meta legacy-task 'CRM · Legacy Receipt'
printf '%s' "$DECISION" > "$STATE/.hb-surfaced-legacy-task"
assert_absorbed legacy-task "$DECISION"
[ -d "$STATE/human-notifications" ] || fail "legacy receipt was not adopted"
pass "restart recovery adopts pre-owner receipts without replaying an already presented condition"

LEGACY='PR ready: legacy review result'
[ "$(fm_human_notify_class "$LEGACY")" = legacy-result ] || fail "legacy result did not enter the shared owner"
assert_pending legacy-task "$LEGACY"
fm_human_notify_record "$STATE" legacy-task "$LEGACY"
assert_absorbed legacy-task "$LEGACY"
fm_human_notify_apply_transition "$STATE" legacy-task 'working: revising the legacy result'
assert_pending legacy-task "$LEGACY"
pass "legacy outcomes use durable deduplication and reopen after resolution"

# Publication-before-record leaves only the accepted duplicate window.
CRASH='blocked [key=network]: access gateway returned a new denial'
assert_pending decision-task "$CRASH"
assert_pending decision-task "$CRASH"
fm_human_notify_record "$STATE" decision-task "$CRASH"
assert_absorbed decision-task "$CRASH"
pass "the crash window can duplicate but cannot suppress the first publication"

# Meaningful review evidence and task incarnation both reset an unchanged line.
fm_human_notify_record "$STATE" decision-task "$REVIEW"
printf 'pr=https://github.com/example/repo/pull/7\npr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >> "$STATE/decision-task.meta"
assert_pending decision-task "$REVIEW"
fm_human_notify_record "$STATE" decision-task "$REVIEW"
printf 'display_name=CRM · Data Shape\nbusy_gen=gen-2\nkind=ship\nproject=firstmate\npr=https://github.com/example/repo/pull/7\npr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$STATE/decision-task.meta"
assert_pending decision-task "$REVIEW"
pass "changed PR head evidence and a new task incarnation create new edges"

fm_human_notify_record "$STATE" decision-task "$REVIEW"
fm_human_notify_pr_observation_record "$STATE" decision-task OPEN \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb COMPLETED SUCCESS
assert_pending decision-task "$REVIEW"
fm_human_notify_record "$STATE" decision-task "$REVIEW"
fm_human_notify_pr_observation_record "$STATE" decision-task OPEN \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb COMPLETED FAILURE
assert_absorbed decision-task "$REVIEW"
pass "durable PR observations change fingerprints without reviving red review targets"

PRIVATE_BLOCKER='blocked: cannot access /home/private/state/request-7 at https://internal.example'
SUMMARY=$(fm_human_notify_summary "$STATE" decision-task "$PRIVATE_BLOCKER")
assert_contains "$SUMMARY" 'CRM · Data Shape' "summary omitted the readable label"
assert_contains "$SUMMARY" 'blocker evidence changed' "summary omitted why it surfaced"
assert_contains "$SUMMARY" 'Action required:' "summary omitted the exact action"
case "$SUMMARY" in *'/home/'*|*'https:'*|*'request-7'*|*'blocked:'*) fail "summary leaked private status evidence: $SUMMARY" ;; esac
pass "presentation names the readable outcome, transition reason, and required action without private status evidence"

# A held condition is deliberate human waiting, while an undeclared idle worker
# remains on the stale-worker path.
(
  export FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT"
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  printf '%s\n' "$HOLD" > "$STATE/decision-task.status"
  out=$(classify_stale 'session:fm-decision-task' "$STATE")
  case "$out" in humanwait\|*) : ;; *) exit 11 ;; esac
  printf '%s\n' "$PAUSE" > "$STATE/decision-task.status"
  out=$(classify_stale 'session:fm-decision-task' "$STATE")
  case "$out" in pause\|*) : ;; *) exit 12 ;; esac
  printf '%s\n' 'working: implementation stopped without declaring a wait' > "$STATE/decision-task.status"
  out=$(classify_stale 'session:fm-decision-task' "$STATE")
  case "$out" in self\|transient\ stale*) : ;; *) exit 13 ;; esac
) || fail "human/external/undeclared stale distinction failed"
pass "human waits have no timed reminder, external pauses retain rechecks, and undeclared idle work remains inspectable"

# End-to-end: an unchanged decision signal is consumed by bash without the
# watcher exiting, printing a wake reason, or queueing a model turn.
QUIET="$TMP_ROOT/quiet"
mkdir -p "$QUIET"
printf 'display_name=CRM · Quiet Choice\nbusy_gen=quiet-1\nkind=ship\nproject=firstmate\n' > "$QUIET/q.meta"
printf '%s\n' "$DECISION" > "$QUIET/q.status"
fm_human_notify_record "$QUIET" q "$DECISION"
touch "$QUIET/.last-heartbeat" "$QUIET/.last-check"
FM_STATE_OVERRIDE="$QUIET" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP_ROOT" \
  FM_POLL=0.05 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
  "$ROOT/bin/fm-watch.sh" > "$TMP_ROOT/watch.out" 2> "$TMP_ROOT/watch.err" &
WATCH_PID=$!
sleep 0.5
kill -0 "$WATCH_PID" 2>/dev/null || fail "unchanged decision ended the watcher and would start a model turn: $(cat "$TMP_ROOT/watch.out")"
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
[ ! -s "$TMP_ROOT/watch.out" ] || fail "unchanged decision printed a delivery: $(cat "$TMP_ROOT/watch.out")"
[ ! -s "$QUIET/.wake-queue" ] || fail "unchanged decision queued a model turn"
pass "unchanged human-owned evidence is absorbed before persistent Pi or OpenCode delivery"

REOPEN="$TMP_ROOT/reopen"
mkdir -p "$REOPEN"
printf 'display_name=CRM · Recovery\nbusy_gen=reopen-1\nkind=ship\nproject=firstmate\n' > "$REOPEN/r.meta"
printf '%s\n' "$FAILURE" > "$REOPEN/r.status"
fm_human_notify_record "$REOPEN" r "$FAILURE"
printf '%s\n%s\n%s\n' "$FAILURE" 'working: recovered the prior attempt' "$FAILURE" > "$REOPEN/r.status"
touch "$REOPEN/.last-heartbeat" "$REOPEN/.last-check"
FM_STATE_OVERRIDE="$REOPEN" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP_ROOT" \
  FM_POLL=0.05 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
  "$ROOT/bin/fm-watch.sh" > "$TMP_ROOT/reopen.out" 2> "$TMP_ROOT/reopen.err" &
WATCH_PID=$!
for _ in $(seq 1 100); do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$WATCH_PID" 2>/dev/null; then
  kill "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  fail "coalesced recovery and reopened failure remained suppressed"
fi
wait "$WATCH_PID" 2>/dev/null || true
[ -s "$REOPEN/.wake-queue" ] || fail "reopened failure did not publish a durable wake"
assert_contains "$(cat "$TMP_ROOT/reopen.out")" 'new failure evidence surfaced' \
  "reopened failure did not surface after its lifecycle clear"
pass "coalesced resolution and reopening is actionable before receipt recording"

DEDUP="$TMP_ROOT/range-dedup"
mkdir -p "$DEDUP"
printf 'display_name=CRM · Duplicate Choice\nbusy_gen=dedup-1\nkind=ship\nproject=firstmate\n' > "$DEDUP/d.meta"
printf '%s\n%s\n' "$DECISION" "$DECISION" > "$DEDUP/d.status"
touch "$DEDUP/.last-heartbeat" "$DEDUP/.last-check"
FM_STATE_OVERRIDE="$DEDUP" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP_ROOT" \
  FM_POLL=0.05 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
  "$ROOT/bin/fm-watch.sh" > "$TMP_ROOT/dedup.out" 2> "$TMP_ROOT/dedup.err" &
WATCH_PID=$!
for _ in $(seq 1 100); do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$WATCH_PID" 2>/dev/null; then
  kill "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  fail "duplicate decision range did not produce its actionable wake"
fi
wait "$WATCH_PID" 2>/dev/null || true
DEDUP_REASON=$(cat "$TMP_ROOT/dedup.out")
[ "$(printf '%s' "$DEDUP_REASON" | grep -Fo 'decision evidence changed' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "one unread range rendered an identical decision more than once: $DEDUP_REASON"
pass "one unread range renders each notification fingerprint once"

CURRENT="$TMP_ROOT/currentness"
mkdir -p "$CURRENT"
printf 'display_name=CRM · Current State\nbusy_gen=current-1\nkind=ship\nproject=firstmate\n' > "$CURRENT/c.meta"
printf '%s\n%s\n' "$FAILURE" 'working: recovery completed' > "$CURRENT/c.status"
(
  export FM_STATE_OVERRIDE="$CURRENT" FM_ROOT_OVERRIDE="$ROOT"
  # shellcheck source=bin/fm-watch.sh
  . "$ROOT/bin/fm-watch.sh"
  ! status_human_condition_is_current "$CURRENT/c.status" "$FAILURE"
) || fail "a resolved historical failure remained current"

printf '%s\n' "$REVIEW" > "$CURRENT/c.status"
CURRENT_HEAD=$(printf 'c%.0s' {1..40})
for observation in 'CLOSED COMPLETED SUCCESS' 'MERGED COMPLETED SUCCESS' 'OPEN COMPLETED FAILURE'; do
  read -r obs_state obs_checks obs_conclusion <<< "$observation"
  fm_human_notify_pr_observation_record "$CURRENT" c "$obs_state" \
    "$CURRENT_HEAD" "$obs_checks" "$obs_conclusion"
  (
    export FM_STATE_OVERRIDE="$CURRENT" FM_ROOT_OVERRIDE="$ROOT"
    # shellcheck source=bin/fm-watch.sh
    . "$ROOT/bin/fm-watch.sh"
    ! status_human_condition_is_current "$CURRENT/c.status" "$REVIEW"
  ) || fail "a closed, merged, or red review target resurfaced as review-ready: $observation"
  review_rc=0
  fm_human_notify_pending "$CURRENT" c "$REVIEW" || review_rc=$?
  [ "$review_rc" -eq 1 ] \
    || fail "shared pending boundary accepted a closed, merged, or red review target: $observation"
done
fm_human_notify_pr_observation_record "$CURRENT" c OPEN \
  "$CURRENT_HEAD" COMPLETED SUCCESS
(
  export FM_STATE_OVERRIDE="$CURRENT" FM_ROOT_OVERRIDE="$ROOT"
  # shellcheck source=bin/fm-watch.sh
  . "$ROOT/bin/fm-watch.sh"
  status_human_condition_is_current "$CURRENT/c.status" "$REVIEW"
) || fail "an open green review target was not current"
fm_human_notify_pending "$CURRENT" c "$REVIEW" \
  || fail "shared pending boundary rejected an open green review target"
pass "all watcher paths share durable PR currentness gating"

fm_human_notify_record "$CURRENT" c "$REVIEW" || fail "could not seed delivered green readiness"
GREEN_OBSERVATION=$(cat "$CURRENT/c.pr-observation")
for transition in 'CLOSED COMPLETED SUCCESS' 'OPEN COMPLETED FAILURE'; do
  read -r obs_state obs_checks obs_conclusion <<< "$transition"
  (
    export FM_STATE_OVERRIDE="$CURRENT" FM_ROOT_OVERRIDE="$ROOT"
    # shellcheck source=bin/fm-watch.sh
    . "$ROOT/bin/fm-watch.sh"
    pr_observation_handle c "$obs_state" "$CURRENT_HEAD" "$obs_checks" "$obs_conclusion"
    [ "$PR_OBSERVATION_COMMIT" -eq 1 ] && [ "$PR_OBSERVATION_CLEAR_REVIEW" -eq 1 ]
  ) || fail "PR transition was not prepared for publication: $transition"
  [ "$(cat "$CURRENT/c.pr-observation")" = "$GREEN_OBSERVATION" ] \
    || fail "PR transition committed observation before durable publication: $transition"
  if fm_human_notify_pending "$CURRENT" c "$REVIEW"; then
    fail "PR transition cleared readiness before durable publication: $transition"
  fi
done
pass "red and closed PR transitions defer state changes until publication"

SYMLINK_STATE="$TMP_ROOT/symlink-state"
SYMLINK_TARGET="$TMP_ROOT/symlink-target"
mkdir -p "$SYMLINK_STATE" "$SYMLINK_TARGET"
printf 'display_name=CRM · Symlink Safety\nbusy_gen=link-1\nkind=ship\nproject=firstmate\n' > "$SYMLINK_STATE/link.meta"
fm_human_notify_record "$SYMLINK_STATE" link "$DECISION" || fail "could not seed symlink safety receipt"
mv "$SYMLINK_STATE/human-notifications" "$SYMLINK_TARGET/receipts"
ln -s "$SYMLINK_TARGET/receipts" "$SYMLINK_STATE/human-notifications"
receipt_count=$(find "$SYMLINK_TARGET/receipts" -type f | wc -l | tr -d ' ')
if fm_human_notify_clear_task "$SYMLINK_STATE" link; then
  fail "task cleanup accepted a symlinked receipt directory"
fi
[ "$(find "$SYMLINK_TARGET/receipts" -type f | wc -l | tr -d ' ')" -eq "$receipt_count" ] \
  || fail "task cleanup removed a receipt through a directory symlink"
if fm_human_notify_apply_transition "$SYMLINK_STATE" link 'resolved [key=shape]: chose RPC'; then
  fail "transition cleanup accepted a symlinked receipt directory"
fi
[ "$(find "$SYMLINK_TARGET/receipts" -type f | wc -l | tr -d ' ')" -eq "$receipt_count" ] \
  || fail "transition cleanup removed a receipt through a directory symlink"
pass "receipt removals refuse symlinked directories without touching their targets"
