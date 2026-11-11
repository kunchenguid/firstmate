#!/usr/bin/env bash
# tests/fm-watch-signal-batch.test.sh - one coalesced signal wake per changed-file
# batch, not one per file.
#
# The watcher used to enqueue one row per changed state file, each repeating the
# whole "signal:$files" list, so a busy fleet cost a hundred rows per drain. These
# tests pin the batch shape: N changed files produce one ordinary row (plus one
# decision row when the batch contains a decision-owned file), the printed reason
# is the compact summary while the batch's full path list goes to the private
# batch-path record keyed by the same batch identity, and every file's .seen-*
# marker still advances.
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
  reason="signal: 3 files (3 status, 0 turn-end): $state/a.status +2 more"
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
  record=$(awk -F '\t' -v k="$key" '$1 == k { print $2 }' "$state/.signal-batch-paths")
  for f in a b c; do
    case "$record" in *"$state/$f.status"*) ;; *) fail "the batch-path record dropped $f.status: $record" ;; esac
  done
  pass "a changed-file batch enqueues one ordinary row with its compact reason and records the full list privately"
}

test_batch_with_a_decision_file_enqueues_one_ordinary_and_one_decision_row() {
  local dir state reason count ordinary decision
  dir=$(make_case batch-decision-row); state="$dir/state"
  printf 'blocked: a\n' > "$state/a.status"
  printf 'needs-decision: pick one\n' > "$state/b.status"
  reason="signal:$state/a.status $state/b.status"
  # The decision row carries the batch's full path list, not the printed reason,
  # because the Pi branch dispatcher resolves the decision task from that row.
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
  [ "${decision#*$'\t'}" = "needs-decision: $state/a.status $state/b.status" ] \
    || fail "the decision row payload is not byte-identical to the pre-change value: $decision"
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
  case "$payload" in
    "signal: 3 files (3 status, 0 turn-end): "*) ;;
    *) fail "the batch payload is not the compact summary: $payload" ;;
  esac
  key=$(signal_rows "$state" | cut -f4)
  record=$(awk -F '\t' -v k="$key" '$1 == k { print $2 }' "$state/.signal-batch-paths")
  for f in a b c; do
    case "$record" in *"$state/$f.status"*) ;; *) fail "the batch-path record dropped $f.status: $record" ;; esac
  done
  for f in a b c; do
    [ -s "$state/.seen-${f}_status" ] \
      || fail "the batch did not advance $f.status's .seen-* marker"
  done
  pass "a real watcher poll coalesces N changed files into one signal row"
}

test_batch_path_record_tracks_queue_lifetime() {
  local dir state records i
  dir=$(make_case batch-record-lifetime); state="$dir/state"
  for i in $(seq 1 40); do
    printf '1\t%s\tsignal\tsignal-batch-%s\tsignal: %s/a.status\n' "$i" "$i" "$state" \
      >> "$state/.wake-queue"
  done
  for i in $(seq 1 40); do
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      signal_record_batch_paths "signal-batch-$2" "$3"
    ' _ "$WATCH" "$i" "$state/a.status" || fail "batch-path record write failed for batch $i"
  done
  records=$(wc -l < "$state/.signal-batch-paths" | tr -d '[:space:]')
  [ "$records" -eq 40 ] \
    || fail "the batch-path record dropped queued batches: $records records"
  grep -F "signal-batch-1"$'\t' "$state/.signal-batch-paths" >/dev/null \
    || fail "the oldest queued batch lost its private path record"
  if ! awk -F '\t' '$4 == "signal-batch-40"' "$state/.wake-queue" > "$state/.wake-queue.next"; then
    fail "could not filter the wake queue"
  fi
  if ! mv "$state/.wake-queue.next" "$state/.wake-queue"; then
    fail "could not consume the older queued batches"
  fi
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    signal_record_batch_paths "signal-batch-40" "$2"
  ' _ "$WATCH" "$state/a.status" || fail "batch-path record write failed after consuming rows"
  records=$(wc -l < "$state/.signal-batch-paths" | tr -d '[:space:]')
  [ "$records" -eq 1 ] \
    || fail "consumed batches kept their records: $records records"
  grep -F "signal-batch-40"$'\t' "$state/.signal-batch-paths" >/dev/null \
    || fail "the still-queued batch lost its private path record"
  pass "the private batch-path record follows the wake queue's lifetime"
}

test_batch_enqueues_one_ordinary_row
test_batch_with_a_decision_file_enqueues_one_ordinary_and_one_decision_row
test_watcher_coalesces_a_real_changed_file_batch
test_batch_path_record_tracks_queue_lifetime
