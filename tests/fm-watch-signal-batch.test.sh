#!/usr/bin/env bash
# tests/fm-watch-signal-batch.test.sh - one coalesced signal wake per changed-file
# batch, not one per file.
#
# The watcher used to enqueue one row per changed state file, each repeating the
# whole "signal:$files" list, so a busy fleet cost a hundred rows per drain. These
# tests pin the batch shape: N changed files produce one ordinary row (plus one
# decision row when the batch contains a decision-owned file), the reason line
# stays byte-identical, and every file's .seen-* marker still advances.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-signal-batch-tests)

watch_bg() {  # <state> <fakebin> <out>
  local state=$1 fakebin=$2 out=$3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
}

signal_rows() {  # <state>
  awk -F '\t' '$3 == "signal" { print }' "$1/.wake-queue" 2>/dev/null
}

test_batch_enqueues_one_ordinary_row() {
  local dir state reason count key payload
  dir=$(make_case batch-one-row); state="$dir/state"
  printf 'blocked: a\n' > "$state/a.status"
  printf 'blocked: b\n' > "$state/b.status"
  printf 'blocked: c\n' > "$state/c.status"
  reason="signal:$state/a.status $state/b.status $state/c.status"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    signal_enqueue_batch "$2" "" "$3" "$4" "$5"
  ' _ "$WATCH" "$reason" "$state/a.status" "$state/b.status" "$state/c.status" \
    || fail "batch enqueue failed"
  count=$(signal_rows "$state" | wc -l | tr -d '[:space:]')
  [ "$count" -eq 1 ] || fail "3 changed files produced $count signal rows, not 1: $(cat "$state/.wake-queue")"
  key=$(signal_rows "$state" | cut -f4)
  case "$key" in signal-batch-*) ;; *) fail "batch row key is not a stable batch identity: $key" ;; esac
  payload=$(signal_rows "$state" | cut -f5)
  [ "$payload" = "$reason" ] || fail "batch row payload changed shape: $payload"
  pass "a changed-file batch enqueues one ordinary row with the byte-identical reason"
}

test_batch_with_a_decision_file_enqueues_one_ordinary_and_one_decision_row() {
  local dir state reason count ordinary decision
  dir=$(make_case batch-decision-row); state="$dir/state"
  printf 'blocked: a\n' > "$state/a.status"
  printf 'needs-decision: pick one\n' > "$state/b.status"
  reason="signal:$state/a.status $state/b.status"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    signal_enqueue_batch "$2" "$3" "$4" "$5"
  ' _ "$WATCH" "$reason" "$state/b.status" "$state/a.status" "$state/b.status" \
    || fail "decision batch enqueue failed"
  count=$(signal_rows "$state" | wc -l | tr -d '[:space:]')
  [ "$count" -eq 2 ] || fail "a decision batch produced $count signal rows, not 2: $(cat "$state/.wake-queue")"
  ordinary=$(signal_rows "$state" | awk -F '\t' '$5 ~ /^signal:/ { print $4 "\t" $5 }')
  decision=$(signal_rows "$state" | awk -F '\t' '$5 ~ /^needs-decision:/ { print $4 "\t" $5 }')
  [ -n "$ordinary" ] || fail "a decision batch lost its ordinary row: $(cat "$state/.wake-queue")"
  [ -n "$decision" ] || fail "a decision batch lost its decision row: $(cat "$state/.wake-queue")"
  [ "${decision%%$'\t'*}" = "b.status" ] \
    || fail "the decision row is not keyed by the decision file's status name: $decision"
  [ "${decision#*$'\t'}" = "needs-decision:$state/a.status $state/b.status" ] \
    || fail "the decision row payload changed shape: $decision"
  [ "${ordinary#*$'\t'}" = "$reason" ] \
    || fail "the ordinary row payload changed shape: $ordinary"
  pass "a decision batch enqueues one ordinary row plus one decision row, not one per file"
}

test_watcher_coalesces_a_real_changed_file_batch() {
  local dir state fakebin out count payload pid f
  dir=$(make_case watcher-batch); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'blocked: a\n' > "$state/a.status"
  printf 'blocked: b\n' > "$state/b.status"
  printf 'blocked: c\n' > "$state/c.status"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for the changed-file batch"
  count=$(signal_rows "$state" | wc -l | tr -d '[:space:]')
  [ "$count" -eq 1 ] || fail "the watcher enqueued $count signal rows for 3 changed files: $(cat "$state/.wake-queue")"
  payload=$(signal_rows "$state" | cut -f5)
  for f in a b c; do
    case "$payload" in *"$state/$f.status"*) ;; *) fail "the batch payload dropped $f.status: $payload" ;; esac
  done
  for f in a b c; do
    [ -s "$state/.seen-${f}_status" ] \
      || fail "the batch did not advance $f.status's .seen-* marker"
  done
  pass "a real watcher poll coalesces N changed files into one signal row"
}

test_batch_enqueues_one_ordinary_row
test_batch_with_a_decision_file_enqueues_one_ordinary_and_one_decision_row
test_watcher_coalesces_a_real_changed_file_batch
