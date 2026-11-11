#!/usr/bin/env bash
# tests/fm-watch-scan-signals.test.sh - the watcher's per-poll signal scan.
#
# These are focused units for two liveness properties of scan_signals that a
# fleet-sized poll depends on:
#   - a beat refresh paced by elapsed time across scanned files, so a long scan
#     over many multi-megabyte status logs cannot let the watcher's liveness
#     beacon age past the guard's grace, while a fast scan does not fork a
#     beacon check for every file.
#   - a single signature computation per file: scan_signals already computes the
#     reported signature to detect a change, so it hands that value to
#     fm_wake_signal_seen_current instead of forking a second
#     status_observed_signature for every file on every poll.
#
# The suite also pins the heartbeat backstop's absorbed-run behavior: an
# absorbed heartbeat must advance each task's .hb-surfaced offset past the bytes
# it just inspected, so a routine-only log is not re-folded from its last
# actionable event on every heartbeat.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-scan-signals-tests)

test_signal_seen_current_reuses_a_supplied_signature() {
  local dir state status calls out
  dir=$(make_case reuse-signature)
  state="$dir/state"
  status="$state/sample.status"
  calls="$dir/sigcalls"
  printf 'working: hi\n' > "$status"
  : > "$calls"
  out=$(CALLFILE="$calls" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_wake_signal_sig() { printf "x\n" >> "$CALLFILE"; printf "r1:stub"; }
    fm_wake_signal_seen_current "$2" "$3" "r1:supplied" || true
    printf "supplied=%s\n" "$(LC_ALL=C wc -l < "$CALLFILE" | tr -d "[:space:]")"
    fm_wake_signal_seen_current "$2" "$3" || true
    printf "omitted=%s\n" "$(LC_ALL=C wc -l < "$CALLFILE" | tr -d "[:space:]")"
  ' _ "$LIB" "$state" "$status")
  grep -qx 'supplied=0' <<<"$out" \
    || fail "a supplied signature was recomputed instead of reused: $out"
  grep -qx 'omitted=1' <<<"$out" \
    || fail "an omitted signature was not computed exactly once: $out"
  pass "signal scan: a supplied reported signature is reused, not recomputed"
}

scan_signal_counts() {  # <dir> <seconds-each-beacon-check-takes>
  local dir=$1 step=$2 state
  state="$dir/state"
  printf 'working: a\n' > "$state/one.status"
  printf 'working: b\n' > "$state/two.status"
  : > "$state/three.turn-ended"
  : > "$dir/sigcalls"
  : > "$dir/beatcalls"
  SIGCALLFILE="$dir/sigcalls" BEATCALLFILE="$dir/beatcalls" STEP="$step" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_wake_signal_sig() { printf "x\n" >> "$SIGCALLFILE"; printf "sig:%s" "${1##*/}"; }
    watch_beat() { printf "x\n" >> "$BEATCALLFILE"; SECONDS=$((SECONDS + STEP)); }
    SECONDS=100
    scan_signals >/dev/null
    printf "sigcalls=%s beatcalls=%s\n" \
      "$(LC_ALL=C wc -l < "$SIGCALLFILE" | tr -d "[:space:]")" \
      "$(LC_ALL=C wc -l < "$BEATCALLFILE" | tr -d "[:space:]")"
  ' _ "$WATCH"
}

test_scan_signals_paces_beacon_refresh_by_elapsed_time() {
  local out
  out=$(scan_signal_counts "$(make_case scan-signals-fast)" 0)
  grep -qx 'sigcalls=3 beatcalls=1' <<<"$out" \
    || fail "a fast scan should compute one signature per file and check the beacon once: $out"
  out=$(scan_signal_counts "$(make_case scan-signals-slow)" 2)
  grep -qx 'sigcalls=3 beatcalls=3' <<<"$out" \
    || fail "a slow scan should check the beacon as each second passes: $out"
  pass "signal scan: one signature per file and a time-paced beacon refresh"
}

test_absorbed_heartbeat_advances_surfaced_offset() {
  local dir state out status
  dir=$(make_case absorbed-heartbeat)
  state="$dir/state"
  status="$state/heartbeat-task.status"
  printf 'working: routine only\n' > "$status"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    heartbeat_scan_finds_actionable
    rc=$?
    mark_all_captain_relevant_surfaced
    off=$(hb_surfaced_offset heartbeat-task)
    size=$(_fm_status_file_size "$2")
    printf "rc=%s off=%s size=%s\n" "$rc" "$off" "$size"
  ' _ "$WATCH" "$status")
  size=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  grep -qx "rc=1 off=${size} size=${size}" <<<"$out" \
    || fail "an absorbed heartbeat did not advance the surfaced offset to the inspected end: $out"
  pass "heartbeat backstop: an absorbed scan advances the surfaced offset"
}

# A stale offset over a large log must not let one heartbeat fold the whole
# thing. Each pass is capped at a complete-line prefix and advances the offset
# to the exact byte it inspected, so repeated heartbeats converge on the end
# without ever stalling a poll on a multi-megabyte fold.
test_heartbeat_scan_bounds_each_fold() {
  local dir state status size out
  dir=$(make_case heartbeat-cap)
  state="$dir/state"
  status="$state/heartbeat-cap.status"
  awk 'BEGIN { for (i = 0; i < 4000; i++) printf "working: routine %d padding padding padding padding padding\n", i }' > "$status"
  size=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  out=$(FM_STATUS_HEARTBEAT_SPAN_BYTES=4096 FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    size=$2
    prev=0
    maxstep=0
    passes=0
    while [ "$passes" -lt 200 ]; do
      heartbeat_scan_finds_actionable >/dev/null
      mark_all_captain_relevant_surfaced
      off=$(hb_surfaced_offset heartbeat-cap)
      step=$((off - prev))
      [ "$step" -gt "$maxstep" ] && maxstep=$step
      prev=$off
      passes=$((passes + 1))
      [ "$off" -ge "$size" ] && break
    done
    printf "off=%s size=%s maxstep=%s passes=%s\n" "$off" "$size" "$maxstep" "$passes"
  ' _ "$WATCH" "$size")
  grep -qE "^off=${size} size=${size} maxstep=[0-9]+ passes=[0-9]+$" <<<"$out" \
    || fail "bounded heartbeat passes did not converge to the log end: $out"
  maxstep=$(sed -n 's/.*maxstep=\([0-9]*\).*/\1/p' <<<"$out")
  passes=$(sed -n 's/.*passes=\([0-9]*\).*/\1/p' <<<"$out")
  [ "$maxstep" -le 4096 ] || fail "a heartbeat fold exceeded its cap: $out"
  [ "$passes" -ge 2 ] || fail "a log larger than the cap should need more than one bounded heartbeat: $out"
  pass "heartbeat backstop: each fold is bounded and still converges"
}

# The printed reason is a prompt, not the batch. These pin its shape: a bounded
# batch summary the fleet can afford to print, while the batch identity
# (signal_batch_key) and every internal set consumer keep the full path list.
batch_reason_for() {  # <home> <state> <file> ...
  local home=$1 state=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    shift
    signal_batch_reason "$@"
  ' _ "$WATCH" "$@"
}

test_reason_names_no_path_for_a_bare_turnend_batch() {
  local dir state out
  dir=$(make_case reason-bare-turnend); state="$dir/state"
  : > "$state/one.turn-ended"
  : > "$state/two.turn-ended"
  : > "$state/three.turn-ended"
  out=$(batch_reason_for "$dir" "$state" \
    "$state/one.turn-ended" "$state/two.turn-ended" "$state/three.turn-ended")
  case "$out" in signal:*) ;; *) fail "the reason lost its signal: prefix: $out" ;; esac
  case "$out" in *"$state"*) fail "a bare turn-end reason named a path: $out" ;; esac
  [ "${#out}" -le 400 ] || fail "a bare turn-end reason exceeded the cap (${#out} bytes): $out"
  pass "a bare turn-end batch produces a path-free reason inside the cap"
}

test_reason_still_names_a_changed_status_path() {
  local dir state out
  dir=$(make_case reason-status-path); state="$dir/state"
  printf 'blocked: a\n' > "$state/a.status"
  : > "$state/b.turn-ended"
  out=$(batch_reason_for "$dir" "$state" "$state/a.status" "$state/b.turn-ended")
  case "$out" in *"$state/a.status"*) ;; *) fail "a changed status path was dropped from the reason: $out" ;; esac
  case "$out" in *"$state/b.turn-ended"*) fail "a turn-ended marker reached the reason: $out" ;; esac
  pass "a changed status path is still named, and no turn-ended path is"
}

test_identical_file_sets_keep_one_batch_key() {
  local dir state first second reversed
  dir=$(make_case reason-batch-key); state="$dir/state"
  printf 'working: a\n' > "$state/a.status"
  printf 'working: b\n' > "$state/b.status"
  first=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    signal_batch_key "$2" "$3"
  ' _ "$WATCH" "$state/a.status" "$state/b.status")
  second=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    signal_batch_key "$2" "$3"
  ' _ "$WATCH" "$state/a.status" "$state/b.status")
  reversed=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    signal_batch_key "$2" "$3"
  ' _ "$WATCH" "$state/b.status" "$state/a.status")
  [ -n "$first" ] || fail "an identical file set produced no batch key"
  [ "$first" = "$second" ] || fail "two identical file sets produced different batch keys: $first vs $second"
  [ "$first" = "$reversed" ] || fail "file order changed the batch key: $first vs $reversed"
  pass "identical file sets keep one batch identity"
}

test_reason_truncates_a_large_batch_with_a_more_suffix() {
  local dir state out f i args=()
  dir=$(make_case reason-truncated); state="$dir/state"
  for i in 1 2 3 4 5 6 7 8; do
    printf 'working: %s\n' "$i" > "$state/s$i.status"
  done
  for i in $(seq 1 60); do
    : > "$state/t$i.turn-ended"
  done
  for f in "$state"/*.status "$state"/*.turn-ended; do args+=("$f"); done
  out=$(batch_reason_for "$dir" "$state" "${args[@]}")
  case "$out" in *'+'*' more'*) ;; *) fail "a large batch did not truncate with a +N more suffix: $out" ;; esac
  case "$out" in *".turn-ended"*) fail "a large batch leaked a turn-ended path into the reason: $out" ;; esac
  [ "${#out}" -le 400 ] || fail "a large batch grew the reason past the cap (${#out} bytes): $out"
  pass "a large batch truncates with +N more instead of growing the reason"
}


test_signal_seen_current_reuses_a_supplied_signature
test_scan_signals_paces_beacon_refresh_by_elapsed_time
test_absorbed_heartbeat_advances_surfaced_offset
test_heartbeat_scan_bounds_each_fold
test_reason_names_no_path_for_a_bare_turnend_batch
test_reason_still_names_a_changed_status_path
test_identical_file_sets_keep_one_batch_key
test_reason_truncates_a_large_batch_with_a_more_suffix
