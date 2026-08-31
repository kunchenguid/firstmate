#!/usr/bin/env bash
# tests/fm-wake-queue.test.sh - wake-queue losslessness (the queue safety matrix):
# concurrent append/drain, bounded structural enrichment, interruption safety,
# signal catch-up while no watcher runs, stale/check enqueue-before-suppressor
# ordering, atomic double-drain, duplicate collapse, and liveness assertion.
# Nothing is lost and nothing is double-consumed. General watcher/lock liveness
# lives in fm-watcher-lock.test.sh; daemon classification/injection in
# fm-daemon.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
GRANT="$ROOT/bin/fm-wake-grant.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-tests)


test_concurrent_append_and_drain() {
  local dir state out1 out2 pids i pid count unique malformed sequence generation
  dir=$(make_case concurrent)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    append_wake "$state" signal "status-$i" "signal: $state/status-$i.status" &
    pids="$pids $!"
    i=$((i + 1))
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pids="$pids $!"
  for pid in $pids; do
    wait "$pid" || fail "concurrent append/drain subprocess failed"
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" 2> "$dir/drain-two.err" || fail "final drain failed"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out2")
  [ "$count" -eq 40 ] || fail "expected final replay of 40 durable records, got $count"
  malformed=$(awk -F '\t' 'NF && NF != 5 { bad++ } END { print bad + 0 }' "$out2")
  [ "$malformed" -eq 0 ] || fail "drained records had malformed fields"
  unique=$(awk -F '\t' 'NF == 5 { keys[$4] = 1 } END { for (k in keys) count++; print count + 0 }' "$out2")
  [ "$unique" -eq 40 ] || fail "expected 40 unique keys, got $unique"
  [ -s "$state/.wake-queue" ] || fail "concurrent drain consumed records before handling acknowledgement"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/drain-two.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/drain-two.err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "final replay omitted its acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "concurrent records could not be acknowledged"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged concurrent records remained queued"
  pass "concurrent append plus drain preserves durable records through acknowledgement"
}

test_signal_catchup_without_running_watcher() {
  local dir state fakebin out drain_out drain_err status_file sequence generation
  dir=$(make_case signal)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  drain_err="$dir/drain.err"
  status_file="$state/task.status"
  # The durable-queue catch-up contract applies to ACTIONABLE wakes (the always-on
  # watcher can absorb no-verb working: notes when the crew is provably working).
  # Use a captain-relevant verb so the wake is surfaced and the catch-up path is
  # tested.
  printf 'blocked: first\n' > "$status_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for first signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print first signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" || fail "drain after first signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "first signal was not queued"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$drain_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$drain_err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "first signal handling acknowledgement failed"

  printf 'done: second\n' >> "$status_file"
  : > "$out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for second signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "signal written with no watcher was not caught"
  pass "signal written while no watcher runs is caught on next run"
}

test_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash
  dir=$(make_case stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-stale"
  printf 'idle prompt' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stale.meta"
  # A stale pane sitting on a captain-relevant status is actionable when the crew
  # is not provably working, so give the window one and prime the .seen-* marker
  # to its current signature so the per-poll signal scan does not pre-empt the
  # stale wake with a signal wake.
  printf 'done: ready in branch fm/stale\n' > "$state/stale.status"
  prime_status_seen "$state" "$state/stale.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for stale pane"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not written"
  pass "stale wake is queued before suppressor state is advanced"
}

# Absorb-only-when-provably-working adds a new actionable wake: a non-terminal stale
# whose crew is NOT provably working is surfaced immediately. That new path must keep
# the queue-safety invariant - enqueue the stale wake BEFORE advancing the .stale-*
# suppressor - so a watcher killed between the two never swallows the surfaced finish.
test_not_working_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash
  dir=$(make_case stale-stopped)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (no captain-relevant verb); prime .seen-* so the per-poll
  # signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  prime_status_seen "$state" "$state/stopped.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # NOT provably working: no running pipeline, idle pane. (make_case installed the
  # fake fm-crew-state.sh the watcher reads via FM_CREW_STATE_BIN.)
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not surface a not-provably-working stale"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after the immediate stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced after the enqueue"
  unset FM_FAKE_CREW_STATE
  pass "a not-provably-working stale wake is queued before its suppressor is advanced"
}

test_check_output_is_queued() {
  local dir state fakebin out drain_out check_file
  dir=$(make_case check)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/1\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register queue custom check"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for check output"
  grep -F "check: $check_file: merged: https://example.test/pr/1" "$out" >/dev/null || fail "watcher did not print check wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after check wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/1' >/dev/null || fail "check wake was not queued"
  [ -e "$state/.last-check" ] || fail "check cadence marker was not written after queue append"
  pass "registered custom check output is queued before cadence suppression"
}

test_atomic_double_drain() {
  local dir state out1 out2 count1 count2 sequence generation leftover
  dir=$(make_case double-drain)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat append failed"
  append_wake "$state" signal task "signal: $state/task.status" || fail "signal append failed"
  append_wake "$state" stale 's:fm-task' 'stale: s:fm-task' || fail "stale append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" 2> "$dir/drain-one.err" &
  pid1=$!
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" 2> "$dir/drain-two.err" &
  pid2=$!
  wait "$pid1" || fail "first drain failed"
  wait "$pid2" || fail "second drain failed"
  count1=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out1")
  count2=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out2")
  [ "$count1" -eq 3 ] && [ "$count2" -eq 3 ] \
    || fail "unacknowledged concurrent drains did not replay all three records"
  cmp -s "$out1" "$out2" || fail "concurrent pre-ack replays were not deterministic"
  [ -s "$state/.wake-queue" ] || fail "concurrent drains consumed records before acknowledgement"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/drain-two.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/drain-two.err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "concurrent replay omitted its acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "concurrent replay acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledgement did not consume replayed records"
  leftover=$(FM_STATE_OVERRIDE="$state" "$DRAIN" | awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }')
  [ "$leftover" -eq 0 ] || fail "acknowledged records replayed again"
  pass "concurrent drains replay until one post-handling acknowledgement consumes records"
}

test_drain_dedupes_obvious_duplicates() {
  local dir state out count
  dir=$(make_case dedupe)
  state="$dir/state"
  out="$dir/drain.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "first heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status" || fail "first signal append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "second heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status $state/task.turn-ended" || fail "second signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "dedupe drain failed"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 2 ] || fail "expected 2 deduped records, got $count"
  grep "$(printf '\theartbeat\theartbeat\theartbeat')" "$out" >/dev/null || fail "heartbeat was not preserved"
  grep "$(printf '\tsignal\ttask.status\t')" "$out" | grep -F "$state/task.turn-ended" >/dev/null || fail "latest signal payload was not preserved"
  pass "drain collapses obvious duplicate heartbeat and signal records"
}

# The drain runs at the top of every wake-handling turn, so it also asserts
# watcher liveness via fm-guard.sh: a lapsed re-arm chain then surfaces even on a
# plain drain-and-handle turn that runs no other supervision script. It must warn
# when work is in flight with no live watcher, and stay silent right after a
# normal fire from a live watcher with a fresh beacon, so it never false-alarms.
test_secondmate_foreign_queue_stall_is_one_shot_and_read_only() {
  local dir state sub fakebin out row_before row_after stall_count
  dir=$(make_case secondmate-foreign-stall)
  state="$dir/state"
  sub="$dir/secondmate"
  mkdir -p "$sub/state" "$sub/data" "$sub/bin"
  printf '# Firstmate\n' > "$sub/AGENTS.md"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$sub" > "$state/mate.meta"
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$(( $(date +%s) - 10 ))" > "$sub/state/.wake-queue"
  row_before="$dir/foreign-before"
  row_after="$dir/foreign-after"
  cp "$sub/state/.wake-queue" "$row_before"
  fakebin="$dir/fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' "${FM_FAKE_TMUX_WINDOW:-}" ;;
  capture-pane) cat "${FM_FAKE_TMUX_CAPTURE:-/dev/null}" ;;
  display-message) printf '0\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  out="$dir/watch.out"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 3 > "$out" 2> "$dir/watch.err" || true
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7' "$out" >/dev/null \
    || fail "an aged foreign row did not wake the parent checkpoint: $(cat "$out"); err=$(cat "$dir/watch.err"); meta=$(cat "$state/mate.meta"); foreign=$(cat "$sub/state/.wake-queue")"
  [ -s "$state/.wake-queue" ] || fail "the parent notification was not durable"
  stall_count=$(grep -c 'secondmate-wake-loop-mate-' "$state/.wake-queue" || true)
  [ "$stall_count" -eq 1 ] || fail "the first parent checkpoint did not publish exactly one stall notification"

  cmp -s "$row_before" "$sub/state/.wake-queue" \
    || fail "foreign queue row changed during read-only stall detection"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "parent drain failed after the stall notification"
  ack_drain_err "$state" "$dir/drain.err" \
    || fail "parent stall notification could not be acknowledged"

  sleep 1
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$dir/watch-second.out" 2> "$dir/watch-second.err" || true
  [ ! -s "$state/.wake-queue" ] || {
    stall_count=$(grep -c 'secondmate-wake-loop-mate-' "$state/.wake-queue" || true)
    [ "$stall_count" -eq 0 ] || fail "repeated checkpoint re-published the same stall notification"
  }
  cp "$sub/state/.wake-queue" "$row_after"
  cmp -s "$row_before" "$row_after" || fail "foreign queue changed after idempotent re-check"

  : > "$sub/state/.wake-queue"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$dir/watch-empty.out" 2> "$dir/watch-empty.err" || true
  ! grep -F 'secondmate wake-loop stalled' "$dir/watch-empty.out" >/dev/null \
    || fail "an empty foreign queue produced a stall notification"

  printf '%s\t8\tcheck\thealthy\tcheck: healthy row\n' "$(date +%s)" > "$sub/state/.wake-queue"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
    FM_SECONDMATE_WAKE_STALL_SECS=60 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$dir/watch-healthy.out" 2> "$dir/watch-healthy.err" || true
  ! grep -F 'secondmate wake-loop stalled' "$dir/watch-healthy.out" >/dev/null \
    || fail "a healthy foreign queue produced a stall notification"
  pass "foreign secondmate queue stalls notify once, remain byte-stable, and stay quiet when empty or healthy"
}

test_secondmate_stall_marker_rejects_symlink() {
  local dir state sub fakebin marker outside expected
  dir=$(make_case secondmate-stall-marker-symlink)
  state="$dir/state"
  sub="$dir/secondmate"
  mkdir -p "$sub/state"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nhome=%s\n' "$sub" > "$state/mate.meta"
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$(( $(date +%s) - 10 ))" > "$sub/state/.wake-queue"
  outside="$dir/outside"
  expected='must remain unchanged'
  printf '%s\n' "$expected" > "$outside"
  marker="$state/.secondmate-wake-stall-mate"
  ln -s "$outside" "$marker"
  fakebin="$dir/fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' 'firstmate:fm-mate' ;;
  capture-pane) : ;;
  display-message) printf '0\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 \
    FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 \
    > "$dir/watch.out" 2> "$dir/watch.err" || true
  [ "$(cat "$outside")" = "$expected" ] || fail "stall marker write followed an unsafe symlink"
  [ -L "$marker" ] || fail "stall marker write replaced rather than rejected an unsafe path"
  [ ! -s "$state/.wake-queue" ] || fail "unsafe stall marker path still published a parent notification"
  pass "secondmate stall markers reject symlinks without touching their targets"
}

test_acknowledged_stall_publication_survives_pre_marker_crash() {
  local dir state sub fakebin out epoch row_before
  dir=$(make_case secondmate-stall-crash)
  state="$dir/state"
  sub="$dir/secondmate"
  mkdir -p "$sub/state" "$sub/data"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$sub" > "$state/mate.meta"
  epoch=$(( $(date +%s) - 10 ))
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$epoch" > "$sub/state/.wake-queue"
  row_before="$dir/foreign-before"
  cp "$sub/state/.wake-queue" "$row_before"
  append_wake "$state" check "secondmate-wake-loop-mate-$epoch-7" \
    "check: secondmate wake-loop stalled: mate=mate row=7 age=10s" \
    || fail "could not seed the pre-marker crash publication"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "pre-marker crash publication could not be drained"
  ack_drain_err "$state" "$dir/drain.err" \
    || fail "pre-marker crash publication could not be acknowledged"

  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$out" 2> "$dir/watch.err" || true
  ! grep -F 'secondmate wake-loop stalled' "$out" >/dev/null \
    || fail "an acknowledged publication was duplicated after the pre-marker crash state"
  [ ! -s "$state/.wake-queue" ] \
    || fail "the replacement watcher re-published an acknowledged stall notification"
  cmp -s "$row_before" "$sub/state/.wake-queue" \
    || fail "pre-marker crash recovery changed the foreign queue row"
  pass "stall publication acknowledgement closes the pre-marker crash window"
}

test_empty_prefix_mate_preserves_other_mate_receipt() {
  local dir state empty stalled fakebin epoch row_before round
  dir=$(make_case secondmate-prefix-receipt)
  state="$dir/state"
  empty="$dir/ios"
  stalled="$dir/ios-ui"
  mkdir -p "$empty/state" "$stalled/state"
  printf 'ios\n' > "$empty/.fm-secondmate-home"
  printf 'ios-ui\n' > "$stalled/.fm-secondmate-home"
  printf 'window=firstmate:fm-ios\nkind=secondmate\nhome=%s\n' "$empty" > "$state/ios.meta"
  printf 'window=firstmate:fm-ios-ui\nkind=secondmate\nhome=%s\n' "$stalled" > "$state/ios-ui.meta"
  : > "$empty/state/.wake-queue"
  epoch=$(( $(date +%s) - 10 ))
  printf '%s\t9\tcheck\trouted\tcheck: routed row\n' "$epoch" > "$stalled/state/.wake-queue"
  row_before="$dir/foreign-before"
  cp "$stalled/state/.wake-queue" "$row_before"
  append_wake "$state" check "secondmate-wake-loop-ios-ui-$epoch-9" \
    "check: secondmate wake-loop stalled: mate=ios-ui row=9 age=10s" \
    || fail "could not seed the ios-ui stall publication"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "ios-ui stall publication could not be drained"
  ack_drain_err "$state" "$dir/drain.err" \
    || fail "ios-ui stall publication could not be acknowledged"

  fakebin="$dir/fakebin"
  round=1
  while [ "$round" -le 2 ]; do
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='' \
      FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
      FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 \
      > "$dir/watch-$round.out" 2> "$dir/watch-$round.err" || true
    ! grep -F 'secondmate wake-loop stalled' "$dir/watch-$round.out" >/dev/null \
      || fail "empty ios queue erased ios-ui idempotency on checkpoint $round"
    round=$((round + 1))
  done
  [ ! -s "$state/.wake-queue" ] \
    || fail "overlapping mate ids re-published the acknowledged ios-ui stall"
  cmp -s "$row_before" "$stalled/state/.wake-queue" \
    || fail "overlapping mate receipt checks changed the foreign row"
  pass "empty prefix mate cleanup preserves another mate's stall receipt"
}

test_drain_asserts_watcher_liveness() {
  local dir state err identity
  dir=$(make_case drain-liveness)
  state="$dir/state"
  err="$dir/drain.err"
  printf 'window=test:fm-x\nkind=ship\n' > "$state/x.meta"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || fail "drain failed while asserting liveness"
  grep -F 'WATCHER DOWN' "$err" >/dev/null || fail "drain did not surface the watcher-down banner with work in flight and no live watcher"
  : > "$err"
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$$") \
    || fail "could not identify the live watcher fixture"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$DRAIN" >/dev/null 2> "$err" \
    || fail "drain failed with a live watcher and fresh beacon"
  if grep -F 'WATCHER DOWN' "$err" >/dev/null; then
    fail "drain false-alarmed with a live watcher and fresh beacon"
  fi
  pass "drain asserts watcher liveness: warns on a lapse, stays silent for a live watcher with a fresh beacon"
}

test_structural_signal_enrichment_preserves_raw_rows() {
  local dir state out expected actual annotation_count outside perl_bin
  dir=$(make_case enrichment)
  state="$dir/state"
  out="$dir/drain.out"
  expected="$dir/expected.out"
  actual="$dir/actual.out"
  outside="$dir/outside-secret"
  printf 'working: first\n\ndone: latest event\n' > "$state/task.status"
  printf 'working: old turn-end context\n' > "$state/turn-only.status"
  printf 'must-not-be-read\n' > "$outside"
  ln -s "$outside" "$state/escape.status"
  perl_bin=$(command -v perl) || fail "perl is required for safe status reads"
  cat > "$dir/fakebin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -MFcntl=:DEFAULT ]; then
  for arg in "$@"; do
    if [ "$arg" = "${FM_WAKE_ENRICH_SWAP_PATH:-}" ]; then
      rm -f "$arg"
      ln -s "$FM_WAKE_ENRICH_SWAP_TARGET" "$arg"
      break
    fi
  done
fi
exec "$FM_WAKE_ENRICH_REAL_PERL" "$@"
SH
  chmod +x "$dir/fakebin/perl"

  append_wake "$state" signal task.status "signal: $outside" || fail "direct status wake append failed"
  append_wake "$state" signal task.turn-ended "signal: $outside" || fail "coalesced turn-end wake append failed"
  append_wake "$state" signal turn-only.turn-ended "signal: $outside" || fail "bare turn-end wake append failed"
  append_wake "$state" signal escape.status "signal: $outside" || fail "symlink status wake append failed"
  append_wake "$state" signal arbitrary-key "signal: $outside" || fail "non-status signal wake append failed"
  append_wake "$state" check task.check.sh "check: complete payload" || fail "check wake append failed"
  append_wake "$state" stale test:fm-task "stale: test:fm-task" || fail "stale wake append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat wake append failed"

  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_print_deduped "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state/.wake-queue" > "$expected"
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WAKE_ENRICH_SWAP_PATH="$state/task.status" \
    FM_WAKE_ENRICH_SWAP_TARGET="$outside" FM_WAKE_ENRICH_REAL_PERL="$perl_bin" "$DRAIN" > "$out" \
    || fail "structural enrichment drain failed"
  awk -F '\t' 'NF == 5 { print }' "$out" > "$actual"
  cmp -s "$expected" "$actual" || fail "enrichment changed or reordered an authoritative raw row"

  annotation_count=$(grep -c '^wake annotation:' "$out" || true)
  [ "$annotation_count" -eq 1 ] || fail "expected only the unreadable-race-safe status annotation, got $annotation_count"
  if grep -E '^wake annotation:.*: task\.status:' "$out" >/dev/null; then
    fail "replaced status file produced an annotation"
  fi
  grep -F 'latest wake-EVENT observed at drain, not current state; historical / not necessarily the triggering event: turn-only.status:' "$out" >/dev/null \
    || fail "bare turn-end mapping did not carry the historical warning"
  if grep -F 'must-not-be-read' "$out" >/dev/null; then
    fail "drain trusted a payload path or followed an out-of-state status symlink"
  fi
  pass "structural signal enrichment is separate, deduped, home-local, and tier-zero for other wakes"
}

test_enrichment_preserves_all_unread_lines_and_status_file_failures() {
  local dir state out i raw_count expected
  dir=$(make_case complete-enrichment)
  state="$dir/state"
  out="$dir/drain.out"
  awk 'BEGIN { printf "done: "; for (i = 0; i < 20000; i++) printf "x"; printf "\n" }' > "$state/huge.status"
  append_wake "$state" signal huge.status "signal: huge" || fail "huge status wake append failed"
  i=1
  while [ "$i" -le 8 ]; do
    awk -v n="$i" 'BEGIN { printf "working-%d: ", n; for (j = 0; j < 3000; j++) printf "y"; printf "\n" }' > "$state/many-$i.status"
    append_wake "$state" signal "many-$i.status" "signal: many-$i" || fail "many-status wake append failed"
    i=$((i + 1))
  done
  : > "$state/empty.status"
  append_wake "$state" signal empty.status "signal: empty" || fail "empty status wake append failed"
  append_wake "$state" signal missing.status "signal: missing" || fail "missing status wake append failed"
  mkdir "$state/malformed.status"
  append_wake "$state" signal malformed.status "signal: malformed" || fail "malformed status wake append failed"
  printf 'done: unreadable\n' > "$state/unreadable.status"
  chmod 000 "$state/unreadable.status"
  append_wake "$state" signal unreadable.status "signal: unreadable" || fail "unreadable status wake append failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "complete enrichment drain failed"
  raw_count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out")
  [ "$raw_count" -eq 13 ] || fail "missing, unreadable, malformed, empty, or oversized status input hid a raw row"

  expected="wake annotation: latest wake-EVENT observed at drain, not current state: huge.status: $(cat "$state/huge.status")"
  grep -Fx "$expected" "$out" >/dev/null \
    || fail "the oversized unread status line was truncated or omitted"
  i=1
  while [ "$i" -le 8 ]; do
    expected="wake annotation: latest wake-EVENT observed at drain, not current state: many-$i.status: $(cat "$state/many-$i.status")"
    grep -Fx "$expected" "$out" >/dev/null \
      || fail "readable status many-$i was truncated or omitted"
    i=$((i + 1))
  done
  if grep -E '^wake annotation:.*(truncated|omitted)' "$out" >/dev/null; then
    fail "complete unread annotation output still reported dropped content"
  fi
  if grep -E ': (empty|missing|malformed|unreadable)\.status:' "$out" >/dev/null; then
    fail "missing, unreadable, malformed, or empty status file produced an annotation"
  fi
  pass "every readable unread status line is annotated in full while invalid status files preserve their raw wakes"
}

wait_for_file_text() {  # <file> <fixed-text>
  local file=$1 expected=$2 i=0
  while [ "$i" -lt 100 ]; do
    grep -F "$expected" "$file" >/dev/null 2>&1 && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_slow_annotation_does_not_block_append_and_deleted_file_fails_open() {
  local dir state out1 out2 pid
  dir=$(make_case slow-annotation)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  printf 'done: disappears before bounded read\n' > "$state/slow.status"
  append_wake "$state" signal slow.status "signal: slow" || fail "slow status wake append failed"

  FM_STATE_OVERRIDE="$state" FM_WAKE_ENRICH_TEST_DELAY=3 "$DRAIN" > "$out1" &
  pid=$!
  wait_for_file_text "$out1" "$(printf '\tsignal\tslow.status\t')" \
    || { kill "$pid" 2>/dev/null || true; fail "slow drain did not commit its raw row"; }
  printf 'done: appended while first drain annotates\n' > "$state/next.status"
  append_wake "$state" signal next.status "signal: next" || fail "append blocked or failed during annotation"
  kill -0 "$pid" 2>/dev/null || fail "slow annotation finished before the concurrent append proved lock independence"
  rm -f "$state/slow.status"
  wait "$pid" || fail "deleted status file made the committed drain fail"
  grep -F "$(printf '\tsignal\tslow.status\t')" "$out1" >/dev/null || fail "deleted status file hid the committed raw row"
  if grep -F ': slow.status:' "$out1" >/dev/null; then
    fail "status deleted during annotation still produced an annotation"
  fi
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" || fail "follow-up drain after concurrent append failed"
  grep -F "$(printf '\tsignal\tnext.status\t')" "$out2" >/dev/null || fail "concurrent append was not left for the next drain"
  pass "slow annotation releases the append lock and a deleted status file fails open"
}

# Per-actor consume (docs/watcher-continuity.md "Per-actor acknowledgement").
# Drives a MIXED queue snapshot - an unacked main-only check row alongside two
# task-local rows the Pi supervision branch was granted - directly against
# the real bin/fm-wake-drain.sh, independent of the Pi SDK. This is the core
# safety property: a scoped actor's ack must never remove a row outside its
# own eligible snapshot, no matter that row's sequence number relative to
# what the actor presents or acks itself. Do not regress it.
test_branch_actor_scoped_ack_never_swallows_a_main_owned_row() {
  local dir state out err sequence generation count
  dir=$(make_case actor-scope)
  state="$dir/state"

  append_wake "$state" check "some-poll.check.sh" "check: some-poll.check.sh: merged" \
    || fail "main-only append failed"
  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"
  append_wake "$state" stale "fm-window" "stale: fm-window" || fail "stale append failed"

  # The extension's own job (fm-branch-dispatch.ts) is granting exactly the
  # two task-local rows; this test drives the bash consume contract those
  # sequence numbers gate, independent of the Pi SDK.
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" actor-scope || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish actor-scope 2 3 || fail "branch grant publication failed"

  out="$dir/branch-drain.out"
  err="$dir/branch-drain.err"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$out" 2> "$err" \
    || fail "branch-scoped drain failed: $(cat "$err")"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$out" || fail "branch drain omitted its eligible signal row"
  grep -Fq "$(printf '\tstale\tfm-window\t')" "$out" || fail "branch drain omitted its eligible stale row"
  grep -Fq "$(printf '\tcheck\tsome-poll.check.sh\t')" "$out" && fail "branch drain presented the main-owned row"

  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "branch drain omitted its acknowledgement boundary"
  [ "$sequence" -eq 3 ] || fail "branch ack cutoff must be the max ELIGIBLE seq (3), got $sequence"

  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "branch-scoped ack failed"

  # The core no-swallow property: the main-only row - seq 1, BELOW the
  # branch's own ack cutoff of 3 - must still be there.
  grep -Fq "$(printf '\tcheck\tsome-poll.check.sh\t')" "$state/.wake-queue" \
    || fail "branch's scoped ack swallowed a main-owned row below its own cutoff"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$state/.wake-queue" \
    && fail "branch's own eligible signal row was not consumed"
  grep -Fq "$(printf '\tstale\tfm-window\t')" "$state/.wake-queue" \
    && fail "branch's own eligible stale row was not consumed"

  # Main's own later, ordinary (unscoped) drain sees exactly what remains.
  out="$dir/main-drain.out"
  err="$dir/main-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "main drain failed: $(cat "$err")"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 1 ] || fail "main's later drain should see exactly the one remaining main-owned row: $(cat "$out")"
  grep -Fq "$(printf '\tcheck\tsome-poll.check.sh\t')" "$out" || fail "main's later drain lost the main-owned row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "main's drain omitted its acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "main's ack failed"
  [ ! -s "$state/.wake-queue" ] || fail "the main-owned row survived main's own ack"

  pass "a branch-actor scoped ack never swallows an unacked main-owned row, and main's later drain sees exactly what remains"
}

test_main_drain_excludes_rows_already_granted_to_branch() {
  local dir state out err sequence generation
  dir=$(make_case main-excludes-branch-grant)
  state="$dir/state"

  append_wake "$state" check "some-poll.check.sh" "check: some-poll.check.sh: merged" \
    || fail "main-only append failed"
  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" main-excludes || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish main-excludes 2 || fail "branch grant publication failed"

  out="$dir/main-drain.out"
  err="$dir/main-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "main drain failed: $(cat "$err")"
  grep -Fq "$(printf '\tcheck\tsome-poll.check.sh\t')" "$out" || fail "main drain omitted its main-owned row"
  ! grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$out" || fail "main drain presented a branch-granted row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ "$sequence" = 1 ] && [ -n "$generation" ] || fail "main acknowledgement did not bind only its presented row"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "main acknowledgement failed"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$state/.wake-queue" \
    || fail "main acknowledgement consumed the branch-granted row"

  out="$dir/branch-drain.out"
  err="$dir/branch-drain.err"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$out" 2> "$err" \
    || fail "branch drain failed: $(cat "$err")"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$out" || fail "branch lost its granted row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "branch acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "branch acknowledgement left its handled row queued"
  [ ! -e "$state/.branch-eligible-rows" ] || fail "branch acknowledgement retained its completed grant"

  pass "main drain and acknowledgement exclude an active branch grant"
}

test_branch_grant_refuses_rows_already_claimed_by_main() {
  local dir state rc
  dir=$(make_case branch-refuses-main-claim)
  state="$dir/state"

  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/main.out" 2> "$dir/main.err" \
    || fail "main presentation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" branch-refuses || fail "branch owner activation failed"
  rc=0
  FM_STATE_OVERRIDE="$state" "$GRANT" publish branch-refuses 1 || rc=$?
  [ "$rc" -eq 3 ] || fail "branch grant did not report the existing main ownership: rc=$rc"
  [ ! -e "$state/.branch-eligible-rows" ] || fail "refused branch grant published an ownership snapshot"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$dir/main.out" \
    || fail "the main owner did not present its claimed row"

  pass "branch grant cannot take a row already claimed by main"
}

test_actor_filter_precedes_same_key_deduplication() {
  local dir state main_sequence main_generation branch_sequence branch_generation
  dir=$(make_case actor-dedup-order)
  state="$dir/state"

  append_wake "$state" signal "task-a.status" "signal: branch version" || fail "branch row append failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" actor-dedup || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish actor-dedup 1 || fail "branch grant publication failed"
  append_wake "$state" signal "task-a.status" "signal: main version" || fail "main row append failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/main.out" 2> "$dir/main.err" || fail "main drain failed"
  [ "$(awk -F '\t' '$3 == "signal" { print $2 }' "$dir/main.out")" = 2 ] \
    || fail "main did not present its same-key claimed row"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$dir/branch.out" 2> "$dir/branch.err" \
    || fail "branch drain failed"
  [ "$(awk -F '\t' '$3 == "signal" { print $2 }' "$dir/branch.out")" = 1 ] \
    || fail "global deduplication hid the branch's older same-key row"

  main_sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/main.err")
  main_generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/main.err")
  branch_sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/branch.err")
  branch_generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/branch.err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$main_sequence" --recovery-generation "$main_generation" \
    || fail "main same-key acknowledgement failed"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "$branch_sequence" --recovery-generation "$branch_generation" \
    || fail "branch same-key acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "same-key actor rows remained stranded"

  pass "actor ownership filtering precedes same-key deduplication"
}

test_main_reclaims_a_grant_whose_branch_owner_exited() {
  local dir state owner sequence generation
  dir=$(make_case stale-branch-owner)
  state="$dir/state"

  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"
  sleep 30 &
  owner=$!
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$owner" stale-owner || {
    kill "$owner" 2>/dev/null || true
    fail "branch owner activation failed"
  }
  FM_STATE_OVERRIDE="$state" "$GRANT" publish stale-owner 1 || {
    kill "$owner" 2>/dev/null || true
    fail "branch grant publication failed"
  }
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/main.out" 2> "$dir/main.err" || fail "main reclaim drain failed"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$dir/main.out" \
    || fail "main did not reclaim the dead branch owner's row"
  [ ! -e "$state/.branch-eligible-rows" ] && [ ! -e "$state/.branch-eligible-owner" ] \
    || fail "dead branch ownership evidence survived reclaim"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/main.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/main.err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "reclaimed row acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "reclaimed branch row remained queued"

  pass "main reclaims rows granted to an exited branch owner"
}

# A branch-actor drain or ack without a snapshot is a wiring bug, never
# "nothing eligible": it must refuse loudly rather than silently draining or
# acking nothing.
test_branch_actor_without_eligible_snapshot_refuses() {
  local dir state
  dir=$(make_case actor-no-snapshot)
  state="$dir/state"
  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "append failed"
  if FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" >/dev/null 2>"$dir/err"; then
    fail "a branch-actor drain with no eligible-row snapshot must refuse, not silently drain"
  fi
  grep -q "no branch-eligible row snapshot" "$dir/err" || fail "the refusal did not name the missing snapshot: $(cat "$dir/err")"
  [ -s "$state/.wake-queue" ] || fail "the refused drain must leave the queue untouched"
  pass "a branch-actor drain with no eligible-row snapshot refuses loudly instead of draining nothing"
}

test_wake_publish_requires_atomic_recovery_evidence() {
  local dir state fakebin real_mv rc out
  dir=$(make_case wake-publish-recovery-evidence)
  state="$dir/state"
  fakebin="$dir/fakebin"
  real_mv=$(command -v mv) || fail "could not locate mv for recovery publication fixture"
  printf 'pending:handling:existing\n' > "$state/.watcher-down"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "${FM_TEST_PUBLISH_MARKER:-}" ]; then
  exit 1
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"

  set +e
  PATH="$fakebin:$PATH" FM_TEST_REAL_MV="$real_mv" FM_TEST_PUBLISH_MARKER="$state/.watcher-down" \
    append_wake "$state" signal task.status "signal: publish failure"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "recovery publication failure allowed wake append to succeed"
  [ "$(cat "$state/.watcher-down")" = 'pending:handling:existing' ] \
    || fail "failed atomic publication erased existing recovery evidence"
  [ ! -s "$state/.wake-queue" ] \
    || fail "wake became durable before its recovery evidence"

  PATH="$fakebin:$PATH" FM_TEST_REAL_MV="$real_mv" \
    append_wake "$state" signal task.status "signal: recovered retry" \
    || fail "wake retry did not publish durable recovery evidence"
  out="$dir/drain.out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "wake retry did not drain"
  grep -F "signal: recovered retry" "$out" >/dev/null \
    || fail "retried wake was not recovered by the durable drain"
  pass "wake append publishes atomic recovery evidence before durable rows"
}

test_legacy_generationless_wake_is_adopted() {
  local dir state row sequence generation
  dir=$(make_case legacy-generationless-wake)
  state="$dir/state"
  row=$(printf '1700000000\t7\tcheck\tlegacy-process-event\tcheck: legacy process-event')
  printf '%s\n' "$row" > "$state/.wake-queue"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first.out" 2> "$dir/first.err" \
    || fail "generation-less legacy wake could not be adopted"
  grep -F "$row" "$dir/first.out" >/dev/null \
    || fail "adopted legacy wake was not presented"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/first.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/first.err")
  [ "$sequence" = 7 ] && [ -n "$generation" ] \
    || fail "legacy wake adoption omitted its generation-bound acknowledgement"
  [ "$(cat "$state/.watcher-down" 2>/dev/null || true)" = "pending:handling:$generation" ] \
    || fail "legacy wake was not adopted into durable handling recovery"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/replay.out" 2> "$dir/replay.err" \
    || fail "unacknowledged adopted wake could not be re-drained"
  grep -F "$row" "$dir/replay.out" >/dev/null \
    || fail "unacknowledged adopted wake was lost"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" \
    || fail "adopted legacy wake could not be acknowledged"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged legacy wake remained queued"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/after-ack.out" 2> "$dir/after-ack.err" \
    || fail "post-acknowledgement legacy drain failed"
  ! grep -F "$row" "$dir/after-ack.out" >/dev/null \
    || fail "acknowledged legacy wake was consumed more than once"
  pass "wake drain: generation-less legacy wakes are adopted and acknowledged"
}

# Pin the recovery acknowledgement contract from docs/watcher-continuity.md at
# the queue-library boundary.
test_stale_recovery_generation_cannot_touch_a_newer_episode() {
  local dir state first_err replay_err sequence generation handling_marker
  local newer_marker newer_sequence newer_generation rc
  dir=$(make_case stale-recovery-generation)
  state="$dir/state"

  append_wake "$state" check first 'check: first generation' \
    || fail "first generation wake append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first.out" 2> "$dir/first.err" \
    || fail "first generation drain failed"
  first_err="$dir/first.err"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$first_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$first_err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "first drain did not emit a generation-bound acknowledgement"

  append_wake "$state" check second 'check: same episode' \
    || fail "first same-episode wake append failed"
  append_wake "$state" check third 'check: same episode again' \
    || fail "second same-episode wake append failed"
  handling_marker=$(cat "$state/.watcher-down")
  [ "${handling_marker##*:}" = "$generation" ] \
    || fail "repeated publications replaced the outstanding recovery generation"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" > "$dir/handled-ack.out" 2> "$dir/handled-ack.err" \
    || fail "a publication during handling invalidated the printed acknowledgement"
  ! grep "$(printf '\tcheck\tfirst\t')" "$state/.wake-queue" >/dev/null \
    || fail "the handled row was not consumed"
  grep "$(printf '\tcheck\tsecond\t')" "$state/.wake-queue" >/dev/null \
    || fail "a row above the acknowledged sequence was consumed"
  grep "$(printf '\tcheck\tthird\t')" "$state/.wake-queue" >/dev/null \
    || fail "the second row above the acknowledged sequence was consumed"
  case "$(cat "$state/.watcher-down")" in
    pending:*) ;;
    *) fail "an episode with rows still queued was retired" ;;
  esac

  # Retire that episode, then let a genuinely newer one open.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/replay.out" 2> "$dir/replay.err" \
    || fail "remaining wake could not be re-drained"
  replay_err="$dir/replay.err"
  grep "$(printf '\tcheck\tsecond\t')" "$dir/replay.out" >/dev/null \
    || fail "remaining wake did not re-surface"
  grep "$(printf '\tcheck\tthird\t')" "$dir/replay.out" >/dev/null \
    || fail "second remaining wake did not re-surface"
  newer_sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$replay_err")
  newer_generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$replay_err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$newer_sequence" \
    --recovery-generation "$newer_generation" \
    || fail "the handled episode could not be acknowledged"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledgement left durable wakes queued"

  append_wake "$state" check fourth 'check: newer recovery generation' \
    || fail "newer generation wake append failed"
  newer_marker=$(cat "$state/.watcher-down")
  [ "${newer_marker##*:}" != "$generation" ] \
    || fail "a retired episode did not open a new recovery generation"

  rc=0
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" > "$dir/stale-ack.out" 2> "$dir/stale-ack.err" || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a stale acknowledgement failed instead of degrading safely: $(cat "$dir/stale-ack.err")"
  if ! grep -F 'WAKE_ACK_REQUIRED' "$dir/stale-ack.err" >/dev/null \
    || ! grep -F 're-run' "$dir/stale-ack.err" >/dev/null; then
    fail "a stale acknowledgement did not name its own remedy: $(cat "$dir/stale-ack.err")"
  fi
  [ "$(cat "$state/.watcher-down")" = "$newer_marker" ] \
    || fail "a stale acknowledgement retired the newer recovery episode"
  grep "$(printf '\tcheck\tfourth\t')" "$state/.wake-queue" >/dev/null \
    || fail "a stale acknowledgement consumed the newer durable wake"
  pass "wake drain: a stale acknowledgement cannot retire or consume a newer recovery episode"
}

test_recovery_ack_failure_is_reported() {
  local dir state fakebin real_mv rc generation
  dir=$(make_case recovery-ack-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  real_mv=$(command -v mv) || fail "could not locate mv for recovery acknowledgement fixture"
  printf 'pending:handling:fixture\n' > "$state/.watcher-down"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/initial.out" 2> "$dir/initial.err" \
    || fail "initial recovery drain failed"
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through 0 --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/initial.err")
  [ -n "$generation" ] || fail "initial recovery drain omitted its generation"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "${FM_TEST_ACK_MARKER:-}" ]; then
  exit 1
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"

  set +e
  PATH="$fakebin:$PATH" FM_TEST_REAL_MV="$real_mv" FM_TEST_ACK_MARKER="$state/.watcher-down" \
    FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through 0 --recovery-generation "$generation" \
      > "$dir/drain.out" 2> "$dir/drain.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "recovery acknowledgement failure was reported as success"
  grep -F 'recovery episode could not be retired safely' "$dir/drain.err" >/dev/null \
    || fail "recovery acknowledgement failure had no explicit diagnostic"
  grep -F 'WAKE_ACK_REQUIRED' "$dir/drain.err" >/dev/null \
    || fail "recovery acknowledgement failure did not name its own remedy"
  [ "$(cat "$state/.watcher-down")" = "pending:handling:$generation" ] \
    || fail "failed acknowledgement corrupted the pending recovery marker"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through 0 --recovery-generation "$generation" \
    > "$dir/retry.out" 2> "$dir/retry.err" \
    || fail "recovery acknowledgement did not succeed on retry"
  [ "$(cat "$state/.watcher-down")" = "acked:handling:$generation" ] \
    || fail "successful retry did not acknowledge pending recovery state"
  pass "wake drain: recovery acknowledgement failures are explicit and retryable"
}

test_interruption_before_and_after_raw_commit() {
  local dir state before_out after_out replay_out empty_out pid rc count i sequence generation
  dir=$(make_case interruption)
  state="$dir/state"
  before_out="$dir/before.out"
  after_out="$dir/after.out"
  replay_out="$dir/replay.out"
  empty_out="$dir/empty.out"
  printf 'done: interruption fixture\n' > "$state/task.status"
  append_wake "$state" signal task.status "signal: task" || fail "pre-commit interruption wake append failed"

  FM_STATE_OVERRIDE="$state" FM_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT=5 "$DRAIN" > "$before_out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$state/.wake-queue.lock" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$state/.wake-queue.lock" ] || { kill "$pid" 2>/dev/null || true; fail "pre-commit drain never entered its serialized read boundary"; }
  kill -TERM "$pid" 2>/dev/null || fail "could not interrupt drain before raw commitment"
  set +e
  wait "$pid"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "pre-commit interruption unexpectedly succeeded"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$replay_out" 2> "$dir/replay.err" || fail "restored pre-commit wake did not drain"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$replay_out")
  [ "$count" -eq 1 ] || fail "pre-commit interruption lost or duplicated the durable row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/replay.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/replay.err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "pre-commit replay acknowledgement failed"

  append_wake "$state" signal task.status "signal: task after commit" || fail "post-commit interruption wake append failed"
  FM_STATE_OVERRIDE="$state" FM_WAKE_ENRICH_TEST_DELAY=5 "$DRAIN" > "$after_out" &
  pid=$!
  wait_for_file_text "$after_out" "$(printf '\tsignal\ttask.status\t')" \
    || { kill "$pid" 2>/dev/null || true; fail "post-commit drain did not print its raw row"; }
  [ -s "$state/.wake-queue" ] \
    || { kill "$pid" 2>/dev/null || true; fail "post-commit drain consumed its raw row before handling acknowledgement"; }
  kill -TERM "$pid" 2>/dev/null || fail "could not interrupt drain after raw presentation"
  set +e
  wait "$pid"
  set -e
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$empty_out" 2> "$dir/after-replay.err" \
    || fail "drain after post-presentation interruption failed"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$empty_out")
  [ "$count" -eq 1 ] || fail "interrupted handling did not replay its durable row exactly once"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/after-replay.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/after-replay.err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "post-interruption replay acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged interrupted wake remained durable"
  pass "interruptions preserve durable rows until post-handling acknowledgement"
}

# The guarded self-announced status append (fm_wake_status_append_self_announced)
# and the seen-signature gate it shares with the watcher's signal scan. Both
# directions of the dedup contract are pinned through the real library
# functions: a fully announced file plus the home's own bookkeeping close stays
# announced (no wake), while ANY unannounced byte - a pending foreign line, a
# missing marker, a later different note - reads as wake-worthy.
test_self_announced_append_guards() {
  local dir state status
  dir=$(make_case self-announced-append)
  state="$dir/state"
  status="$state/t.status"

  run_wake_lib() {
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"; shift; "$@"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$@"
  }

  # FIRST status change: a fresh file with no marker is unannounced (wakes).
  printf 'working: first line\n' > "$status"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    && fail "a never-announced status file read as already announced"

  # Prime the marker to current (the watcher just surfaced/absorbed everything).
  prime_status_seen "$state" "$status" || fail "could not prime the seen marker"

  # A self-announced bookkeeping close on a fully announced file is suppressed.
  run_wake_lib fm_wake_status_append_self_announced "$state" "$status" \
    'resolved [key=k1]: answered: closed by this home' \
    || fail "self-announced append on an announced file was not suppressed (rc=$?)"
  grep -Fq 'resolved [key=k1]: answered: closed by this home' "$status" \
    || fail "the suppressed close was not appended"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    || fail "the self-announced close left unannounced bytes behind"

  # A later DIFFERENT note from any other writer still wakes.
  printf 'needs-decision [key=k2]: a new decision\n' >> "$status"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    && fail "a later different note on the same task read as already announced"

  # With that foreign line pending, a bookkeeping close must NOT advance the
  # marker over it: the close appends but the file stays wake-worthy.
  local rc=0
  run_wake_lib fm_wake_status_append_self_announced "$state" "$status" \
    'resolved [key=k1]: answered: second close' || rc=$?
  [ "$rc" -eq 1 ] || fail "a close over pending foreign bytes did not fail toward waking (rc=$rc)"
  grep -Fq 'resolved [key=k1]: answered: second close' "$status" \
    || fail "the fail-toward-waking close was not appended"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    && fail "a close over pending foreign bytes swallowed the pending wake"

  # UTF-8 close on an announced file: byte accounting must hold for multibyte.
  prime_status_seen "$state" "$status" || fail "could not re-prime the seen marker"
  run_wake_lib fm_wake_status_append_self_announced "$state" "$status" \
    "$(printf 'resolved [key=k2]: answered: caf\xc3\xa9 rentr\xc3\xa9e')" \
    || fail "a multibyte self-announced close was not suppressed (rc=$?)"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    || fail "multibyte byte accounting broke the self-announce guard"

  pass "self-announced appends suppress only their own bytes and fail toward waking"
}

# A trap that fires inside a lock's critical section abandons the holding
# frame, and the exit path then re-acquires the same lock (a TERM inside a
# recovery-marker section is the reproduced case: the watcher's reap wedged
# forever spinning against its own pid). The same-process re-acquire must
# reclaim the abandoned hold, while a SUBSHELL still waits on its parent's
# live hold exactly as before.
test_self_held_lock_reclaims_instead_of_deadlocking() {
  local dir state rc
  dir=$(make_case self-held-lock)
  state="$dir/state"
  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    lock="$2/.fixture.lock"
    fm_lock_acquire_wait "$lock" || exit 10
    fm_lock_try_acquire "$lock" || exit 11
    fm_lock_release "$lock"
    [ ! -e "$lock" ] && [ ! -L "$lock" ] || exit 12
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" || rc=$?
  [ "$rc" -eq 0 ] || fail "self-held lock was not reclaimed cleanly (rc=$rc)"
  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    lock="$2/.fixture2.lock"
    fm_lock_acquire_wait "$lock" || exit 10
    ( fm_lock_try_acquire "$lock" && exit 13; exit 0 ) || exit 13
    fm_lock_release "$lock"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" || rc=$?
  [ "$rc" -eq 0 ] || fail "a subshell reclaimed its parent's live hold (rc=$rc)"
  pass "an abandoned same-process lock hold is reclaimed; a parent's live hold is not"
}

# Drain-time historical annotation staleness: a turn-ended-only wake row must
# not present an already-announced status line as a new update, while a status
# file with unannounced bytes keeps its annotation and a direct status row is
# always annotated. Driven through the real drain executable.
test_historical_annotation_skips_announced_status() {
  local dir state out err
  dir=$(make_case historical-annotation)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"

  printf 'working: long scout still going\n' > "$state/scout.status"
  prime_status_seen "$state" "$state/scout.status" \
    || fail "could not prime the scout seen marker"
  : > "$state/scout.turn-ended"
  append_wake "$state" signal scout.turn-ended "signal: $state/scout.turn-ended" \
    || fail "turn-ended wake append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "drain failed"
  if grep -F 'scout.status: working: long scout still going' "$out" >/dev/null; then
    fail "a fully announced status line was replayed as a historical annotation"
  fi
  grep -F 'scout.turn-ended' "$out" >/dev/null \
    || fail "suppressing the stale annotation dropped the turn-ended wake row itself"
  ack_drain_err "$state" "$err" || fail "could not acknowledge the first drain"

  # Unannounced status bytes: the historical annotation is genuinely new
  # information and must stay.
  printf 'working: fresh unannounced progress\n' >> "$state/scout.status"
  : > "$state/scout.turn-ended"
  append_wake "$state" signal scout.turn-ended "signal: $state/scout.turn-ended" \
    || fail "second turn-ended wake append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "second drain failed"
  grep -F 'historical / not necessarily the triggering event: scout.status: working: fresh unannounced progress' "$out" >/dev/null \
    || fail "an unannounced status line lost its historical annotation"
  ack_drain_err "$state" "$err" || fail "could not acknowledge the second drain"

  # A direct status row is the announcement itself and is always annotated,
  # even when the seen marker already covers the file.
  printf 'done: scout finished\n' >> "$state/scout.status"
  prime_status_seen "$state" "$state/scout.status" \
    || fail "could not prime the marker for the direct-row leg"
  append_wake "$state" signal scout.status "signal: $state/scout.status" \
    || fail "direct status wake append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "third drain failed"
  grep -F 'scout.status: done: scout finished' "$out" >/dev/null \
    || fail "a direct status row lost its annotation"
  pass "historical annotations replay nothing already announced and keep everything new"
}

test_self_held_lock_reclaims_instead_of_deadlocking
test_secondmate_foreign_queue_stall_is_one_shot_and_read_only
test_secondmate_stall_marker_rejects_symlink
test_acknowledged_stall_publication_survives_pre_marker_crash
test_empty_prefix_mate_preserves_other_mate_receipt
test_self_announced_append_guards
test_historical_annotation_skips_announced_status
test_concurrent_append_and_drain
test_signal_catchup_without_running_watcher
test_stale_enqueue_before_suppressor
test_not_working_stale_enqueue_before_suppressor
test_check_output_is_queued
test_atomic_double_drain
test_drain_dedupes_obvious_duplicates
test_drain_asserts_watcher_liveness
test_structural_signal_enrichment_preserves_raw_rows
test_enrichment_preserves_all_unread_lines_and_status_file_failures
test_slow_annotation_does_not_block_append_and_deleted_file_fails_open
test_branch_actor_scoped_ack_never_swallows_a_main_owned_row
test_main_drain_excludes_rows_already_granted_to_branch
test_branch_grant_refuses_rows_already_claimed_by_main
test_actor_filter_precedes_same_key_deduplication
test_main_reclaims_a_grant_whose_branch_owner_exited
test_branch_actor_without_eligible_snapshot_refuses
test_wake_publish_requires_atomic_recovery_evidence
test_legacy_generationless_wake_is_adopted
test_stale_recovery_generation_cannot_touch_a_newer_episode
test_recovery_ack_failure_is_reported
test_interruption_before_and_after_raw_commit
