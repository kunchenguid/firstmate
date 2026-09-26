#!/usr/bin/env bash
# tests/fm-wake-queue.test.sh - wake-queue losslessness (the queue safety matrix):
# concurrent append/drain, bounded structural enrichment and presentation-lock
# waits, interruption safety, signal catch-up while no watcher runs, stale/check enqueue-before-suppressor
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
GUARD="$ROOT/bin/fm-guard.sh"

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

# Run one watcher leg of the foreign-stall case at fake time <now>. Each leg
# waits on what the watcher observably did, never on a wall-clock budget: a
# loaded machine can take seconds to reach the first poll, and a leg cut off
# before its stall tick silently drops the observation the next leg depends on.
# With [observation], the leg ends once the tick's whole reset is visible: the
# progress marker records exactly that "<now><TAB><row-key>" pair and the prior
# episode's stall marker is gone; otherwise the watcher runs to its own first
# wake. The poll ceiling only bounds a hang.
foreign_stall_watch_leg() {  # <dir> <leg> <now> [observation]
  local dir=$1 leg=$2 now=$3 observation=${4-} marker stall pid i=0
  marker="$dir/state/.secondmate-wake-progress-mate"
  stall="$dir/state/.secondmate-wake-stall-mate"
  printf '%s\n' "$now" > "$dir/now"
  PATH="$dir/fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$dir/watch-$leg.out" 2> "$dir/watch-$leg.err" &
  pid=$!
  if [ -n "$observation" ]; then
    while [ "$i" -lt 600 ] && is_live_non_zombie "$pid" \
      && { [ "$(cat "$marker" 2>/dev/null || true)" != "$observation" ] || [ -e "$stall" ]; }; do
      sleep 0.1
      i=$((i + 1))
    done
    # This leg tests the queue observation, not watcher shutdown/recovery.
    # TERM can leave bash waiting in a child on some runners; stop the owned
    # fixture process and clear only its watcher lifecycle state before the
    # next leg starts against the same queue and progress marker.
    ! is_live_non_zombie "$pid" || kill -KILL "$pid" 2>/dev/null || true
  fi
  wait_for_exit "$pid" 600 || true
  if [ -n "$observation" ]; then
    rm -rf -- "$dir/state/.watch.lock" "$dir/state/.watcher-down"
  fi
  if [ -n "$observation" ]; then
    [ "$(cat "$marker" 2>/dev/null || true)" = "$observation" ] \
      || fail "watcher leg $leg did not record observation '$observation': $(cat "$marker" 2>/dev/null)"
    [ ! -e "$stall" ] || fail "watcher leg $leg left the prior episode's stall marker in place"
  fi
}

test_secondmate_foreign_queue_stall_tracks_progress_and_alerts_once() {
  local dir state sub fakebin out row_before row_after stall_count real_date
  dir=$(make_case secondmate-foreign-stall)
  state="$dir/state"
  sub="$dir/secondmate"
  mkdir -p "$sub/state" "$sub/data" "$sub/bin"
  printf '# Firstmate\n' > "$sub/AGENTS.md"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$sub" > "$state/mate.meta"
  fakebin="$dir/fakebin"
  real_date=$(command -v date)
  cat > "$fakebin/date" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = +%s ]; then
  cat "\${FM_FAKE_NOW_FILE:?}"
else
  exec "$real_date" "\$@"
fi
SH
  chmod +x "$fakebin/date"

  # An already-old row starts an observation interval; its creation time alone
  # cannot produce an alert.
  printf '100\t7\tcheck\trouted\tcheck: routed row\n' > "$sub/state/.wake-queue"
  foreign_stall_watch_leg "$dir" first 1000 "$(printf '1000\t100-7')"
  [ ! -s "$state/.wake-queue" ] \
    || fail "the first observation of an old foreign row produced an age-only alert"

  # The oldest sequence advances after more than the threshold. This is healthy
  # drain progress even though the replacement row is itself very old.
  printf '100\t8\tcheck\thealthy\tcheck: healthy progress\n' > "$sub/state/.wake-queue"
  foreign_stall_watch_leg "$dir" progress 1002 "$(printf '1002\t100-8')"
  [ ! -s "$state/.wake-queue" ] \
    || fail "an advancing foreign queue produced a stall alert because its oldest row was old"

  # With no further sequence progress, the same queue must still expose the real
  # failure after the configured interval. The stall tick runs before any other
  # wake source in the poll, so this leg's first wake is the alert.
  row_before="$dir/foreign-before"
  row_after="$dir/foreign-after"
  cp "$sub/state/.wake-queue" "$row_before"
  out="$dir/watch-stalled.out"
  foreign_stall_watch_leg "$dir" stalled 1004
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=8 idle=2s' "$out" >/dev/null \
    || fail "a foreign queue with no progress did not alert: $(cat "$out")"
  stall_count=$(grep -c 'secondmate-wake-loop-mate-' "$state/.wake-queue" || true)
  [ "$stall_count" -eq 1 ] || fail "the stalled episode did not publish exactly one parent notification"
  cmp -s "$row_before" "$sub/state/.wake-queue" \
    || fail "foreign queue row changed during read-only stall detection"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "parent drain failed after the stall notification"
  ack_drain_err "$state" "$dir/drain.err" \
    || fail "parent stall notification could not be acknowledged"

  # Partial draining changes the oldest row, ends the prior no-progress episode,
  # and cannot produce an immediate notification cascade.
  printf '100\t9\tcheck\tnext\tcheck: next row\n' > "$sub/state/.wake-queue"
  foreign_stall_watch_leg "$dir" next 1010 "$(printf '1010\t100-9')"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a newly-oldest row cascaded an immediate second alert after progress"
  cp "$sub/state/.wake-queue" "$row_after"
  grep -F $'\t9\t' "$row_after" >/dev/null || fail "foreign queue progress fixture changed during observation"

  # If that new drain position then genuinely stops advancing, it is a new
  # no-progress episode and must remain visible rather than being muted forever.
  foreign_stall_watch_leg "$dir" refrozen 1012
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=9 idle=2s' "$dir/watch-refrozen.out" >/dev/null \
    || fail "a genuine later no-progress episode was hidden after earlier progress"
  stall_count=$(grep -c 'secondmate-wake-loop-mate-' "$state/.wake-queue" || true)
  [ "$stall_count" -eq 1 ] || fail "the later no-progress episode did not publish exactly one notification"
  pass "foreign secondmate queue alerts once per no-progress episode without age-only or cascade noise"
}

# Stall-tick legs wait on the watcher's own record, never on a wall-clock
# checkpoint. Under load a short checkpoint is killed before the first tick, so
# a later leg treats its own first sight as the whole episode and a negative
# assertion passes with no observation at all. Each mode stops on the artifact
# that leg's assertion depends on. The poll ceiling only bounds a hang.
#
#   progress <task> <body>     progress marker body is exactly <body>
#   tick                        one stall cycle finished
#   cleared                     paused queue observation cleared its progress marker
#   defer <task> <row-key> [hold]
#                              a cycle at least the stall threshold, or [hold]
#                              seconds when larger, after the first observation
#                              finished without alerting
#   ring <task> <row-key>      ring marker records <row-key> and that tick
#                              rewrote the progress marker
#   stall-file <task> <row-key>
#                              stall marker file records <row-key>
#   drained <task> <queue>     child queue emptied, the doorbell was submitted,
#                              and that tick rewrote the progress marker
#   alert                      the watcher exited on the stall wake
#   reject                     the watcher exited refusing the stall marker path
stall_watch_beat_epoch() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null || echo 0
  else
    stat -c %Y "$1" 2>/dev/null || echo 0
  fi
}

stall_watch_has_wake() { # <out>
  grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$1" >/dev/null 2>&1
}

stall_watch_record_met() { # <mode> <marker> <want> <progress> <progress-start> <sent>
  local mode=$1 marker=$2 want=$3 progress=$4 start=$5 sent=$6
  case "$mode" in
    progress)
      [ "$(cat "$marker" 2>/dev/null || true)" = "$want" ]
      ;;
    ring)
      [ "$(cat "$marker" 2>/dev/null || true)" = "$want" ] \
        && [ "$(cat "$progress" 2>/dev/null || true)" != "$start" ]
      ;;
    stall-file)
      [ -f "$marker" ] && [ ! -L "$marker" ] \
        && [ "$(cat "$marker" 2>/dev/null || true)" = "$want" ]
      ;;
    drained)
      [ ! -s "$marker" ] && [ -s "$sent" ] && grep -F '[ENTER]' "$sent" >/dev/null 2>&1 \
        && [ "$(cat "$progress" 2>/dev/null || true)" != "$start" ]
      ;;
    *)
      return 1
      ;;
  esac
}

secondmate_stall_watch_leg() { # <dir> <leg> <mode> [arg...]
  local dir=$1 leg=$2 mode=$3
  shift 3
  local out="$dir/watch-$leg.out" err="$dir/watch-$leg.err"
  local beat="$dir/state/.last-watcher-beat" sent="$dir/sent"
  local pid i=0 limit=600 met=0
  local marker='' want='' progress='' progress_start='' row_key='' bound=0
  local body key observed_at=0 first=0 mark=0 mtime
  case "$mode" in
    alert|reject|tick)
      ;;
    cleared)
      marker="$dir/state/.secondmate-wake-progress-mate"
      printf 'unobserved\n' > "$marker"
      ;;
    progress)
      marker="$dir/state/.secondmate-wake-progress-$1"
      want=$2
      ;;
    defer)
      marker="$dir/state/.secondmate-wake-progress-$1"
      row_key=$2
      bound=${FM_SECONDMATE_WAKE_STALL_SECS:-1}
      [ "${3:-0}" -le "$bound" ] || bound=$3
      ;;
    ring)
      marker="$dir/state/.secondmate-wake-ring-$1"
      want=$2
      progress="$dir/state/.secondmate-wake-progress-$1"
      ;;
    stall-file)
      marker="$dir/state/.secondmate-wake-stall-$1"
      want=$2
      ;;
    drained)
      marker=$2
      progress="$dir/state/.secondmate-wake-progress-$1"
      ;;
    *)
      fail "unknown stall watch mode: $mode"
      ;;
  esac
  [ -z "$progress" ] || progress_start=$(cat "$progress" 2>/dev/null || true)
  rm -f "$beat"
  # These legs pin wake-loop stall behavior only. A large cadence alone does
  # not suppress the first endpoint tick when its marker is absent; seed it so
  # every watcher launch and restart leaves the fixture endpoints untouched.
  touch "$dir/state/.secondmate-liveness-tick"
  FM_SECONDMATE_LIVENESS_SECS=99999999 "$WATCH" >"$out" 2>"$err" &
  pid=$!
  case "$mode" in
    alert)
      while [ "$i" -lt "$limit" ]; do
        if ! is_live_non_zombie "$pid"; then
          wait_for_exit "$pid" 50 || true
          if grep -F 'secondmate wake-loop stalled' "$out" >/dev/null 2>&1; then
            return 0
          fi
          FM_SECONDMATE_LIVENESS_SECS=99999999 "$WATCH" >>"$out" 2>>"$err" &
          pid=$!
        fi
        sleep 0.1
        i=$((i + 1))
      done
      wait_for_exit "$pid" 50 || true
      grep -F 'secondmate wake-loop stalled' "$out" >/dev/null \
        || fail "watcher leg $leg did not alert: $(cat "$out" 2>/dev/null) $(cat "$err" 2>/dev/null)"
      return 0
      ;;
    reject)
      wait_for_exit "$pid" "$limit" || true
      grep -F 'watcher: secondmate wake-loop observation failed' "$err" >/dev/null \
        || fail "watcher leg $leg did not refuse the stall marker path: $(cat "$out" 2>/dev/null) $(cat "$err" 2>/dev/null)"
      return 0
      ;;
  esac
  while [ "$i" -lt "$limit" ]; do
    met=0
    case "$mode" in
      tick)
        if [ -e "$beat" ]; then
          mtime=$(stall_watch_beat_epoch "$beat")
          if [ "$first" -eq 0 ]; then
            first=$mtime
          elif [ "$mtime" -gt "$first" ]; then
            met=1
          fi
        fi
        if [ "$met" -eq 0 ] && ! is_live_non_zombie "$pid" && stall_watch_has_wake "$out"; then
          met=1
        fi
        ;;
      cleared)
        [ ! -e "$marker" ] && met=1
        ;;
      defer)
        if [ "$observed_at" -eq 0 ]; then
          body=$(cat "$marker" 2>/dev/null || true)
          key=${body#*$'\t'}
          if [ -n "$key" ] && [ "$key" != "$body" ] && [ "$key" = "$row_key" ]; then
            observed_at=${body%%$'\t'*}
            case "$observed_at" in
              ''|*[!0-9]*) observed_at=0 ;;
            esac
          fi
        elif [ -e "$beat" ]; then
          mtime=$(stall_watch_beat_epoch "$beat")
          if [ "$mtime" -ge $((observed_at + bound)) ]; then
            if ! is_live_non_zombie "$pid" && stall_watch_has_wake "$out"; then
              met=1
            elif [ "$mark" -gt 0 ] && [ "$mtime" -gt "$mark" ]; then
              met=1
            else
              mark=$mtime
            fi
          fi
        fi
        if grep -F 'secondmate wake-loop stalled' "$out" >/dev/null 2>&1; then
          fail "watcher leg $leg alerted during a deferred busy turn: $(cat "$out")"
        fi
        ;;
      *)
        stall_watch_record_met "$mode" "$marker" "$want" "$progress" "$progress_start" "$sent" && met=1
        ;;
    esac
    if [ "$met" -eq 1 ]; then
      break
    fi
    if ! is_live_non_zombie "$pid"; then
      # The process has flushed. A wake after the stall tick counts; a startup
      # exit does not, so start another watcher against the same fixture.
      wait_for_exit "$pid" 50 || true
      case "$mode" in
        tick)
          stall_watch_has_wake "$out" && met=1
          ;;
        cleared)
          [ ! -e "$marker" ] && met=1
          ;;
        defer)
          if [ "$observed_at" -gt 0 ] && stall_watch_has_wake "$out" \
            && ! grep -F 'secondmate wake-loop stalled' "$out" >/dev/null 2>&1; then
            mtime=$(stall_watch_beat_epoch "$beat")
            [ "$mtime" -ge $((observed_at + bound)) ] && met=1
          fi
          ;;
        *)
          stall_watch_record_met "$mode" "$marker" "$want" "$progress" "$progress_start" "$sent" && met=1
          ;;
      esac
      if [ "$met" -eq 1 ]; then
        break
      fi
      rm -f "$beat"
      FM_SECONDMATE_LIVENESS_SECS=99999999 "$WATCH" >>"$out" 2>>"$err" &
      pid=$!
      first=0
      mark=0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  [ "$met" -eq 1 ] \
    || fail "watcher leg $leg ($mode) did not observe the stall condition: $(cat "$out" 2>/dev/null) $(cat "$err" 2>/dev/null)"
  if is_live_non_zombie "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
  wait_for_exit "$pid" "$limit" || true
}

test_secondmate_declared_pause_rows_do_not_feed_stall_escalation() {
  local dir state sub fakebin real_date
  dir=$(make_case secondmate-declared-pause-queue)
  state="$dir/state"
  sub="$dir/secondmate"
  mkdir -p "$sub/state"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nhome=%s\n' "$sub" > "$state/mate.meta"
  fakebin="$dir/fakebin"
  real_date=$(command -v date)
  cat > "$fakebin/date" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = +%s ]; then
  cat "\${FM_FAKE_NOW_FILE:?}"
else
  exec "$real_date" "\$@"
fi
SH
  chmod +x "$fakebin/date"
  cat > "$sub/state/.wake-queue" <<'EOF'
100	7	stale	fleet:w2:p4	stale: fleet:w2:p4 (paused 3613s, awaiting external - declared paused)
100	8	stale	fleet:w2:p3	stale: fleet:w2:p3 (paused 3615s, awaiting external - declared pause, rechecked on a long cadence not a wedge)
EOF
  printf '1000\n' > "$dir/now"
  PATH="$fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "first" cleared
  printf '5000\n' > "$dir/now"
  PATH="$fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "second" cleared
  [ ! -s "$state/.wake-queue" ] \
    || fail "declared external-wait rows fed the secondmate wake-loop escalation"
  ! grep -F 'secondmate wake-loop stalled' "$dir/watch-first.out" "$dir/watch-second.out" >/dev/null \
    || fail "a declared external wait was mislabeled as a stalled wake loop"
  pass "declared external-wait pause rows do not feed secondmate wake-loop escalation"
}

# A retired mate reprovisioned under the same task id gets a fresh home, so its
# wake-queue sequence restarts from scratch and can land on the very position the
# parent last recorded for the retired generation. Those are different rows in
# different queue generations, not the continuation of the previous generation's
# no-progress interval: inheriting that interval fires a wake-loop stall against
# a queue the mate has only just created.
test_secondmate_reprovisioned_queue_starts_a_fresh_interval() {
  local dir state sub fakebin real_date
  dir=$(make_case secondmate-reprovisioned-queue)
  state="$dir/state"
  sub="$dir/secondmate"
  mkdir -p "$sub/state"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$sub" > "$state/mate.meta"
  fakebin="$dir/fakebin"
  real_date=$(command -v date)
  cat > "$fakebin/date" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = +%s ]; then
  cat "\${FM_FAKE_NOW_FILE:?}"
else
  exec "$real_date" "\$@"
fi
SH
  chmod +x "$fakebin/date"

  # The retired generation's last observation records sequence 9.
  printf '1000\n' > "$dir/now"
  printf '100\t9\tcheck\told\tcheck: retired generation row\n' > "$sub/state/.wake-queue"
  PATH="$fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "old" progress mate "$(printf '1000\t100-9')"
  [ ! -s "$state/.wake-queue" ] || fail "the first observation of the retired generation alerted"

  # Reprovisioning under the same task id restarts the sequence on 9 again, long
  # after the recorded observation. That first sight of the new queue cannot
  # inherit the old generation's idle interval.
  printf '1010\n' > "$dir/now"
  printf '200\t9\tcheck\tregen\tcheck: reprovisioned row\n' > "$sub/state/.wake-queue"
  PATH="$fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "regen" progress mate "$(printf '1010\t200-9')"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a reprovisioned queue generation inherited the retired generation's idle interval and alerted"

  # The restarted generation still earns its own honest no-progress episode.
  printf '1012\n' > "$dir/now"
  PATH="$fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "regen-frozen" alert
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=9 idle=2s' "$dir/watch-regen-frozen.out" >/dev/null \
    || fail "a frozen reprovisioned queue generation was hidden: $(cat "$dir/watch-regen-frozen.out")"
  pass "a reprovisioned queue generation starts a fresh no-progress interval"
}

# A healthy mate drains its wake queue BETWEEN turns, not inside one, so a queue
# that has not advanced while the mate is provably mid-turn is not a stalled wake
# loop - it is the normal state of a busy mate, and the measured false alarms
# (ages 63s, 75s, 70s) all landed here. The active-turn gate must DEFER that
# escalation, not cancel it: the same frozen queue still has to surface once the
# turn ends.
test_secondmate_active_turn_defers_stall_until_the_turn_ends() {
  local dir state sub fakebin stall_count row_epoch
  dir=$(make_case secondmate-active-turn)
  state="$dir/state"
  sub="$dir/secondmate"
  mkdir -p "$sub/state"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$sub" > "$state/mate.meta"
  row_epoch=$(( $(date +%s) - 10 ))
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$row_epoch" \
    > "$sub/state/.wake-queue"
  fakebin="$dir/fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' 'firstmate:fm-mate' ;;
  capture-pane) printf 'working\n' ;;
  display-message) printf '0\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" mate >/dev/null \
    || fail "could not arm the mate's busy contract"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 \
    FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "busy" defer mate "$row_epoch-7"
  ! grep -F 'secondmate wake-loop stalled' "$dir/watch-busy.out" >/dev/null \
    || fail "a mate inside an active turn was escalated as a stalled wake loop: $(cat "$dir/watch-busy.out")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a mate inside an active turn published a durable stall notification"

  "$ROOT/bin/fm-busy-event.sh" apply "$state" mate idle --current-gen \
    --source claude-hook --event stop >/dev/null \
    || fail "could not end the mate's turn"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 \
    FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "idle" alert
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7' "$dir/watch-idle.out" >/dev/null \
    || fail "the same frozen queue stayed hidden after the turn ended: $(cat "$dir/watch-idle.out")"
  stall_count=$(grep -c 'secondmate-wake-loop-mate-' "$state/.wake-queue" || true)
  [ "$stall_count" -eq 1 ] || fail "the deferred episode did not publish exactly one notification"
  pass "an active turn defers the secondmate stall escalation without cancelling it"
}

# A mate's turns end in its own home, so this home never holds a turn-ended mark
# for it and its meta mtime records only the last launch. The active-turn gate
# once aged the mate's turn from that launch, so every mate launched more than
# BUSY_TURN_MAX_SECS ago lost the gate and a busy mate alarmed on the stall
# interval alone. The backdated meta stands in for that long-running mate. The
# busy exemption is instead bounded by how long the queue itself has been frozen,
# so a mate stuck busy forever still alarms.
#
# Scope, so this case is not read as more coverage than it is: the fixture arms
# the busy contract by hand through fm-busy-event.sh. A real --secondmate spawn
# never does - bin/fm-spawn.sh arms the contract inside its `[ "$KIND" !=
# secondmate ]` guard, so both arm calls are skipped for a mate - and with no
# record fm_busy_classify_meta answers "unknown missing" for a tmux-backed
# claude, pi, opencode, or omp mate, which is not a busy verdict. Hand-arming is
# what isolates the launch-aging defect this case pins, and the launch-aging
# defect is all it pins: on tmux the stall alarm is still reachable through that
# missing busy record, tracked upstream as issue 4268.
test_secondmate_long_lived_mate_mid_turn_is_not_a_stall() {
  local dir state sub fakebin stall_count row_epoch
  dir=$(make_case secondmate-long-lived-active-turn)
  state="$dir/state"
  sub="$dir/secondmate"
  mkdir -p "$sub/state"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$sub" > "$state/mate.meta"
  row_epoch=$(( $(date +%s) - 10 ))
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$row_epoch" \
    > "$sub/state/.wake-queue"
  fakebin="$dir/fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' 'firstmate:fm-mate' ;;
  capture-pane) printf 'working\n' ;;
  display-message) printf '0\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" mate >/dev/null \
    || fail "could not arm the mate's busy contract"
  # Backdate AFTER arming, so nothing the arm writes refreshes the launch record
  # this home would otherwise age the mate's turn from.
  touch -t 202001010000 "$state/mate.meta"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 \
    FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "busy" defer mate "$row_epoch-7" 3
  ! grep -F 'secondmate wake-loop stalled' "$dir/watch-busy.out" >/dev/null \
    || fail "a long-lived mate inside an active turn was escalated as a stalled wake loop: $(cat "$dir/watch-busy.out")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a long-lived mate inside an active turn published a durable stall notification"

  # Still busy, but the queue has now been frozen past the busy bound: a turn
  # that never ends cannot hide a frozen wake loop forever.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_SECONDMATE_WAKE_STALL_SECS=1 FM_BUSY_TURN_MAX_SECS=3 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "over" alert
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7' "$dir/watch-over.out" >/dev/null \
    || fail "a mate busy past the bound hid its frozen queue: $(cat "$dir/watch-over.out")"
  stall_count=$(grep -c 'secondmate-wake-loop-mate-' "$state/.wake-queue" || true)
  [ "$stall_count" -eq 1 ] || fail "the over-bound episode did not publish exactly one notification"
  pass "a long-lived mate mid-turn is not a stall, but a queue frozen past the busy bound still alarms"
}

# Agent liveness matches the exact window name from list-windows. Printing
# session:window makes the pane look missing, which is the leftover-row tests'
# ring-unsafe path and must keep the parent alarm. These cases print fm-mate
# and a claude foreground command so a proven-idle mate can actually be rung.
install_secondmate_alive_tmux() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) printf '%s\n' 'fm-mate' ;;
  capture-pane) exit 0 ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'claude\n' ;;
      *pane_tty*) exit 1 ;;
      *cursor_y*) printf '0\n' ;;
      *) printf '0\n' ;;
    esac
    ;;
  send-keys)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -l) shift; [ "$#" -gt 0 ] && printf '%s\n' "$1" >> "${FM_FAKE_TMUX_SENT:-/dev/null}" ;;
        Enter)
          printf '[ENTER]\n' >> "${FM_FAKE_TMUX_SENT:-/dev/null}"
          if [ -n "${FM_FAKE_CHILD_WAKE_QUEUE:-}" ]; then
            : > "$FM_FAKE_CHILD_WAKE_QUEUE"
          fi
          ;;
      esac
      shift
    done
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
}

install_secondmate_stall_date() {  # <fakebin>
  local fakebin=$1 real_date
  real_date=$(command -v date)
  cat > "$fakebin/date" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = +%s ]; then
  cat "\${FM_FAKE_NOW_FILE:?}"
else
  exec "$real_date" "\$@"
fi
SH
  chmod +x "$fakebin/date"
}

# A proven-idle, ring-safe mate with a leftover foreign row is rung so its
# own home can drain. The parent alarm stays silent when that ring actually
# empties the child's queue.
test_secondmate_proven_idle_ring_lets_the_child_drain() {
  local dir state sub fakebin inbox_body inbox_rec steer
  dir=$(make_case secondmate-proven-idle-drain)
  state="$dir/state"
  sub="$dir/secondmate"
  fakebin="$dir/fakebin"
  mkdir -p "$sub/state"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$sub" > "$state/mate.meta"
  printf '100\t7\tcheck\trouted\tcheck: routed row\n' > "$sub/state/.wake-queue"
  install_secondmate_alive_tmux "$fakebin"
  install_secondmate_stall_date "$fakebin"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" mate >/dev/null \
    || fail "could not arm the mate's busy contract"
  "$ROOT/bin/fm-busy-event.sh" apply "$state" mate idle --current-gen \
    --source claude-hook --event stop >/dev/null \
    || fail "could not mark the mate idle"

  printf '1000\n' > "$dir/now"
  PATH="$fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_SENT="$dir/sent" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "first" progress mate "$(printf '1000\t100-7')"
  [ ! -s "$state/.wake-queue" ] || fail "the first observation of a leftover row produced an alert"
  [ ! -s "$dir/sent" ] || fail "a proven-idle mate was rung before the stall interval"

  printf '1002\n' > "$dir/now"
  PATH="$fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_SENT="$dir/sent" \
    FM_FAKE_CHILD_WAKE_QUEUE="$sub/state/.wake-queue" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "ring" drained mate "$sub/state/.wake-queue"
  ! grep -F 'secondmate wake-loop stalled' "$dir/watch-ring.out" >/dev/null \
    || fail "a proven-idle mate that drained after the ring still alarmed: $(cat "$dir/watch-ring.out")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a proven-idle child-first ring published a parent stall notification"
  [ ! -s "$sub/state/.wake-queue" ] \
    || fail "the child ring did not drain the leftover foreign row"
  inbox_rec=
  for inbox_rec in "$state/mate.inbox/"*.msg; do break; done
  [ -f "$inbox_rec" ] || fail "the child-first ring did not write a drain steer record"
  sed '/^--$/q' "$inbox_rec" | grep -Fx 'delivery=fire-and-forget' >/dev/null \
    || fail "the child-first ring did not write a fire-and-forget drain steer"
  inbox_body=$(sed '1,/^--$/d' "$inbox_rec")
  [ "$(printf '%s' "$inbox_body" | "$ROOT/bin/fm-operational-input.sh" kind)" = from-firstmate ] \
    || fail "the child-first drain steer lacks the from-firstmate marker, so the mate would read it as captain intervention: $inbox_body"
  steer=$(printf '%s' "$inbox_body" | "$ROOT/bin/fm-operational-input.sh" body)
  [[ $steer =~ ^delivery=[0-9a-f]{16}\ (.*)$ ]] \
    || fail "the child-first drain steer does not carry a fire-and-forget delivery id: $steer"
  [ "${BASH_REMATCH[1]}" = "Drain pending rows in this home's wake queue, then resume idle supervision." ] \
    || fail "the child-first ring wrote the wrong drain instruction: $steer"
  grep -F '[ENTER]' "$dir/sent" >/dev/null \
    || fail "the child-first ring did not submit the doorbell: $(cat "$dir/sent" 2>/dev/null)"
  pass "a proven-idle leftover row is rung so the child home can drain without a parent alarm"
}

# Busy and unknown panes are never typed into. Busy still defers inside the
# active-turn bound. Unknown keeps the parent alarm. Empty inbox is not idle
# proof, so the unknown fixture starts with no instruction records.
test_secondmate_busy_and_unknown_panes_are_not_rung() {
  local dir state sub fakebin
  dir=$(make_case secondmate-busy-unknown-no-ring)
  state="$dir/state"
  sub="$dir/secondmate"
  fakebin="$dir/fakebin"
  mkdir -p "$sub/state"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$sub" > "$state/mate.meta"
  printf '100\t7\tcheck\trouted\tcheck: routed row\n' > "$sub/state/.wake-queue"
  install_secondmate_alive_tmux "$fakebin"
  install_secondmate_stall_date "$fakebin"

  "$ROOT/bin/fm-busy-event.sh" arm "$state" mate >/dev/null \
    || fail "could not arm the mate's busy contract"
  printf '1000\n' > "$dir/now"
  PATH="$fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_SENT="$dir/sent-busy" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "busy-first" progress mate "$(printf '1000\t100-7')"
  printf '1002\n' > "$dir/now"
  PATH="$fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_SENT="$dir/sent-busy" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "busy" tick
  ! grep -F 'secondmate wake-loop stalled' "$dir/watch-busy.out" >/dev/null \
    || fail "a busy mate was escalated as a stalled wake loop: $(cat "$dir/watch-busy.out")"
  [ ! -s "$state/.wake-queue" ] || fail "a busy mate published a durable stall notification"
  [ ! -e "$dir/sent-busy" ] || fail "a busy mate was rung"
  [ ! -e "$state/mate.inbox" ] || fail "a busy mate received a drain steer"

  rm -f "$state/.secondmate-wake-progress-mate" "$state/.secondmate-wake-stall-mate" \
    "$state/.secondmate-wake-ring-mate"
  rm -rf "$state/.secondmate-wake-stall-receipts" "$state/mate.busy-state" "$state/mate.busy-gen"
  : > "$dir/sent-unknown"
  printf '1000\n' > "$dir/now"
  PATH="$fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_SENT="$dir/sent-unknown" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "unknown-first" progress mate "$(printf '1000\t100-7')"
  printf '1002\n' > "$dir/now"
  PATH="$fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_SENT="$dir/sent-unknown" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "unknown" alert
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7 idle=2s' "$dir/watch-unknown.out" >/dev/null \
    || fail "an unknown pane did not keep the parent alarm: $(cat "$dir/watch-unknown.out")"
  [ ! -s "$dir/sent-unknown" ] || fail "an unknown pane was rung: $(cat "$dir/sent-unknown")"
  [ ! -e "$state/mate.inbox" ] || fail "an unknown pane received a drain steer"
  pass "busy panes defer without a ring and unknown panes keep the parent alarm"
}

# After a proven-idle ring, the same leftover row is a genuine stall if the
# child home does not drain it. The second stall interval must still surface.
test_secondmate_genuine_stall_after_idle_ring_still_alarms() {
  local dir state sub fakebin row_before stall_count
  dir=$(make_case secondmate-genuine-stall-after-ring)
  state="$dir/state"
  sub="$dir/secondmate"
  fakebin="$dir/fakebin"
  mkdir -p "$sub/state"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$sub" > "$state/mate.meta"
  printf '100\t7\tcheck\trouted\tcheck: routed row\n' > "$sub/state/.wake-queue"
  row_before="$dir/foreign-before"
  cp "$sub/state/.wake-queue" "$row_before"
  install_secondmate_alive_tmux "$fakebin"
  install_secondmate_stall_date "$fakebin"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" mate >/dev/null \
    || fail "could not arm the mate's busy contract"
  "$ROOT/bin/fm-busy-event.sh" apply "$state" mate idle --current-gen \
    --source claude-hook --event stop >/dev/null \
    || fail "could not mark the mate idle"

  printf '1000\n' > "$dir/now"
  PATH="$fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_SENT="$dir/sent" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "first" progress mate "$(printf '1000\t100-7')"

  printf '1002\n' > "$dir/now"
  PATH="$fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_SENT="$dir/sent" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "ring" ring mate 100-7
  ! grep -F 'secondmate wake-loop stalled' "$dir/watch-ring.out" >/dev/null \
    || fail "the first proven-idle ring published a parent alarm: $(cat "$dir/watch-ring.out")"
  [ ! -s "$state/.wake-queue" ] || fail "the first proven-idle ring published a durable stall"
  grep -F '[ENTER]' "$dir/sent" >/dev/null \
    || fail "the genuine-stall fixture never rang the child"
  [ "$(cat "$state/.secondmate-wake-ring-mate" 2>/dev/null || true)" = "100-7" ] \
    || fail "the successful ring did not record the frozen row"
  cmp -s "$row_before" "$sub/state/.wake-queue" \
    || fail "the unread ring rewrote the foreign queue"

  printf '1004\n' > "$dir/now"
  PATH="$fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_SENT="$dir/sent" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "stall" alert
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7 idle=2s' "$dir/watch-stall.out" >/dev/null \
    || fail "a leftover row that survived the idle ring stayed hidden: $(cat "$dir/watch-stall.out")"
  stall_count=$(grep -c 'secondmate-wake-loop-mate-' "$state/.wake-queue" || true)
  [ "$stall_count" -eq 1 ] || fail "the genuine stall after a ring did not publish exactly one notification"
  cmp -s "$row_before" "$sub/state/.wake-queue" \
    || fail "the parent alarm path rewrote the foreign queue"
  pass "a leftover row that survives a proven-idle ring still surfaces as a genuine stall"
}

test_secondmate_stall_marker_rejects_symlink() {
  local dir state sub fakebin marker outside expected epoch
  dir=$(make_case secondmate-stall-marker-symlink)
  state="$dir/state"
  sub="$dir/secondmate"
  mkdir -p "$sub/state"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nhome=%s\n' "$sub" > "$state/mate.meta"
  epoch=$(( $(date +%s) - 10 ))
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$epoch" > "$sub/state/.wake-queue"
  outside="$dir/outside"
  expected='must remain unchanged'
  printf '%s\n' "$expected" > "$outside"
  marker="$state/.secondmate-wake-stall-mate"
  printf '%s\t%s-7\n' "$(( $(date +%s) - 2 ))" "$epoch" > "$state/.secondmate-wake-progress-mate"
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
    secondmate_stall_watch_leg "$dir" "once" reject
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
  printf '%s\t%s-7\n' "$(( $(date +%s) - 2 ))" "$epoch" > "$state/.secondmate-wake-progress-mate"
  append_wake "$state" check "secondmate-wake-loop-mate-$epoch-7" \
    "check: secondmate wake-loop stalled: mate=mate row=7 idle=2s" \
    || fail "could not seed the pre-marker crash publication"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "pre-marker crash publication could not be drained"
  ack_drain_err "$state" "$dir/drain.err" \
    || fail "pre-marker crash publication could not be acknowledged"

  fakebin="$dir/fakebin"
  out="$dir/watch-once.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    secondmate_stall_watch_leg "$dir" "once" stall-file mate "$epoch-7"
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
  printf '%s\t%s-9\n' "$(( $(date +%s) - 2 ))" "$epoch" > "$state/.secondmate-wake-progress-ios-ui"
  append_wake "$state" check "secondmate-wake-loop-ios-ui-$epoch-9" \
    "check: secondmate wake-loop stalled: mate=ios-ui row=9 idle=2s" \
    || fail "could not seed the ios-ui stall publication"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "ios-ui stall publication could not be drained"
  ack_drain_err "$state" "$dir/drain.err" \
    || fail "ios-ui stall publication could not be acknowledged"

  fakebin="$dir/fakebin"
  round=1
  while [ "$round" -le 2 ]; do
    printf 'seed\n' > "$state/.secondmate-wake-progress-ios"
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='' \
      FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
      FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      secondmate_stall_watch_leg "$dir" "$round" tick
    [ ! -e "$state/.secondmate-wake-progress-ios" ] \
      || fail "empty ios queue was not observed on round $round"
    [ -f "$state/.secondmate-wake-stall-ios-ui" ] && [ ! -L "$state/.secondmate-wake-stall-ios-ui" ] \
      || fail "ios-ui stall marker was not recorded on round $round"
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

# The drain runs at the top of every wake-handling turn, so it also asserts
# watcher liveness via fm-guard.sh: a lapsed re-arm chain then surfaces even on a
# plain drain-and-handle turn that runs no other supervision script. It must warn
# when work is in flight with no live watcher, and stay silent right after a
# normal fire from a live watcher with a fresh beacon, so it never false-alarms.
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

# The away posture lets a branch grant name a check-kind row, so the branch
# ack must close the same publish-before-receipt crash window the main ack
# does: consuming a secondmate-wake-loop row commits its stall receipt under
# exactly the granted sequences, keeping a later stall tick from re-alerting a
# consumed notification.
test_branch_ack_commits_secondmate_stall_receipts() {
  local dir state epoch sequence generation receipt
  dir=$(make_case secondmate-branch-stall)
  state="$dir/state"
  epoch=$(( $(date +%s) - 10 ))
  append_wake "$state" check "secondmate-wake-loop-mate-$epoch-7" \
    "check: secondmate wake-loop stalled: mate=mate row=7 idle=2s" \
    || fail "could not seed the stall publication"
  append_wake "$state" check "secondmate-wake-loop-mate-$epoch-9" \
    "check: secondmate wake-loop stalled: mate=mate row=9 idle=3s" \
    || fail "could not seed the ungranted stall publication"

  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" branch-stall \
    || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish branch-stall 1 \
    || fail "branch grant publication failed"

  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$dir/branch.out" 2> "$dir/branch.err" \
    || fail "branch drain failed: $(cat "$dir/branch.err")"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/branch.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/branch.err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "branch drain omitted its acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" \
    --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "branch acknowledgement failed"

  receipt="$state/.secondmate-wake-stall-receipts/mate/$epoch-7"
  [ "$(cat "$receipt" 2>/dev/null || true)" = "$epoch-7" ] \
    || fail "branch acknowledgement did not commit the consumed stall row's receipt"
  receipt="$state/.secondmate-wake-stall-receipts/mate/$epoch-9"
  [ ! -e "$receipt" ] \
    || fail "branch acknowledgement committed a stall receipt for a row outside its grant"
  pass "a branch-actor acknowledgement commits secondmate stall receipts for exactly its granted rows"
}

# The pending-warning condition and what a drain can actually present must name
# the same rows. A row reserved by a live branch grant is invisible to a main
# drain by design, so counting it as "queued for main" told main to run a drain
# that could only print nothing - no row, no acknowledgement command - on every
# guarded command, for as long as the branch held the grant.
test_main_is_never_told_to_drain_rows_only_the_branch_owns() {
  local dir state out err sequence generation
  dir=$(make_case main-not-told-to-drain-branch-rows)
  state="$dir/state"
  printf 'window=test:fm-x\nkind=ship\n' > "$state/x.meta"

  append_wake "$state" stale "fleet:w2:p3" "stale: fleet:w2:p3 (paused, awaiting external)" \
    || fail "stale append failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" held-by-branch || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish held-by-branch 1 || fail "branch grant publication failed"

  out="$dir/main-drain.out"
  err="$dir/main-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "main drain failed: $(cat "$err")"
  ! grep -Fq "$(printf '\tstale\tfleet:w2:p3\t')" "$out" || fail "main drain presented a branch-granted row"
  grep -Fq 'WAKE ROWS HELD BY SUPERVISION BRANCH' "$out" \
    || fail "main drain went silent instead of naming who holds the queued rows"
  ! grep -Fq 'WAKE_ACK_REQUIRED' "$err" || fail "main drain offered an acknowledgement for a row it never presented"
  ! grep -Fq 'queued wakes pending' "$err" \
    || fail "main was told to drain rows only the branch can present"
  FM_STATE_OVERRIDE="$state" "$GUARD" 2> "$dir/guard-held.err" || fail "guard failed while the branch held the rows"
  ! grep -Fq 'queued wakes pending' "$dir/guard-held.err" \
    || fail "guard counted branch-held rows as pending for main"
  grep -Fq 'wake rows held by the live supervision branch' "$dir/guard-held.err" \
    || fail "guard went silent about a non-empty queue instead of naming the branch as its holder"
  grep -Fq 'do not drain them from here' "$dir/guard-held.err" \
    || fail "the held advisory did not say the rows must not be drained from here"
  grep -Fq "$(printf '\tstale\tfleet:w2:p3\t')" "$state/.wake-queue" \
    || fail "the branch-held row must stay durable for its own owner"

  # Disconfirming half: the same row, same kind, same stopped endpoint, with the
  # grant released. Nothing about the row makes it unpresentable - only the
  # live grant did - so main now presents it with an executable acknowledgement.
  FM_STATE_OVERRIDE="$state" "$GRANT" release held-by-branch || fail "branch grant release failed"
  out="$dir/main-drain-after.out"
  err="$dir/main-drain-after.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "main drain failed after release: $(cat "$err")"
  grep -Fq "$(printf '\tstale\tfleet:w2:p3\t')" "$out" || fail "main drain omitted the released row"
  ! grep -Fq 'WAKE ROWS HELD BY SUPERVISION BRANCH' "$out" \
    || fail "main drain reported a hold that no longer exists"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "the released row was presented without an acknowledgement command"
  grep -Fq 'queued wakes pending' "$err" || fail "guard stopped warning about a row main can actually drain"
  ! grep -Fq 'wake rows held by the live supervision branch' "$err" \
    || fail "guard kept advising about a hold that was already released"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "acknowledgement of the released row failed"
  [ ! -s "$state/.wake-queue" ] || fail "the acknowledged row stayed queued"

  pass "a branch-held row raises no queued-wake warning for main, and the same row is presented and acknowledged once the grant clears"
}

# The pending-warning condition must also survive a queue nobody could read: a
# queue that exists but cannot be counted is not evidence that it was drained.
# The per-actor count runs awk over the queue, and awk implementations differ on
# whether a failed input open aborts before the END rule; one that reaches END
# reports a 0 count for a queue that was never proved empty.
test_uncountable_queue_still_raises_the_pending_alarm() {
  local dir state awkbin real_awk
  dir=$(make_case uncountable-queue)
  state="$dir/state"
  awkbin="$dir/awkbin"
  mkdir -p "$awkbin"
  printf 'window=test:fm-x\nkind=ship\n' > "$state/x.meta"

  # An awk that still runs its END rule after failing to open its input: it
  # prints a 0 count and exits non-zero. Every other invocation is the real awk.
  real_awk=$(command -v awk) || fail "no awk on PATH"
  cat > "$awkbin/awk" <<SH
#!/usr/bin/env bash
set -u
for _arg in "\$@"; do _last=\$_arg; done
if [ -n "\${_last:-}" ] && [ -e "\$_last" ] && [ ! -r "\$_last" ]; then
  printf '0\\n'
  exit 2
fi
exec "$real_awk" "\$@"
SH
  chmod +x "$awkbin/awk"

  append_wake "$state" stale "fleet:w2:p3" "stale: fleet:w2:p3 (paused, awaiting external)" \
    || fail "stale append failed"
  chmod 000 "$state/.wake-queue" || fail "could not make the queue unreadable"
  PATH="$awkbin:$PATH" FM_STATE_OVERRIDE="$state" "$GUARD" 2> "$dir/unreadable.err" \
    || fail "guard failed on an unreadable queue"
  grep -Fq 'queued wakes pending' "$dir/unreadable.err" \
    || fail "a queue that could not be counted silenced the queued-wake alarm"
  chmod 600 "$state/.wake-queue" || fail "could not restore the queue"

  # Disconfirming half: the same fake awk over a queue that is readable and
  # provably empty stays silent, so the warning above came from the failed count
  # and not from the fake awk itself.
  : > "$state/.wake-queue"
  PATH="$awkbin:$PATH" FM_STATE_OVERRIDE="$state" "$GUARD" 2> "$dir/empty.err" \
    || fail "guard failed on an empty queue"
  ! grep -Fq 'queued wakes pending' "$dir/empty.err" \
    || fail "a provably empty queue raised the queued-wake alarm"

  pass "a queue that cannot be counted keeps the queued-wake alarm up"
}

# A row that lost its structure can never be claimed, presented, or named by an
# --ack-through cutoff, while it still counts as queued: without retirement it
# wedges the queue permanently and keeps waking supervision.
test_unconsumable_rows_are_retired_instead_of_wedging_the_queue() {
  local dir state out err sequence generation
  dir=$(make_case unconsumable-row-retirement)
  state="$dir/state"
  printf 'window=test:fm-x\nkind=ship\n' > "$state/x.meta"

  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"
  printf '1788792074\t574\tstale\tfleet:w2:p3\n' >> "$state/.wake-queue"
  printf '1788792075\tnot-a-sequence\tstale\tfleet:w2:p4\tstale: fleet:w2:p4\n' >> "$state/.wake-queue"

  # A branch actor never repairs the queue: it may only touch its own grant.
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" retire-scope || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish retire-scope 1 || fail "branch grant publication failed"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$dir/branch.out" 2> "$dir/branch.err" \
    || fail "branch drain failed: $(cat "$dir/branch.err")"
  ! grep -Fq 'retired' "$dir/branch.err" || fail "a branch drain retired rows outside its grant"
  [ "$(awk 'END { print NR }' "$state/.wake-queue")" -eq 3 ] \
    || fail "a branch drain changed rows it was never granted"
  FM_STATE_OVERRIDE="$state" "$GRANT" release retire-scope || fail "branch grant release failed"

  FM_STATE_OVERRIDE="$state" "$GUARD" 2> "$dir/guard-before.err" || fail "guard failed with unusable rows queued"
  grep -Fq 'queued wakes pending' "$dir/guard-before.err" \
    || fail "guard stayed silent about rows main still has to clear"
  ! grep -Fq 'wake rows held by the live supervision branch' "$dir/guard-before.err" \
    || fail "guard advised a branch hold for rows no grant covers"

  out="$dir/main.out"
  err="$dir/main.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "main drain failed: $(cat "$err")"
  grep -Fq 'retired 2 unusable queue row(s)' "$err" || fail "main drain did not report the rows it retired"
  grep -Fq "$(printf '1788792074\t574\tstale\tfleet:w2:p3')" "$err" \
    || fail "the retired row's content was discarded instead of reported"
  grep -Fq "$(printf '1788792075\tnot-a-sequence\tstale\tfleet:w2:p4\tstale: fleet:w2:p4')" "$err" \
    || fail "the second retired row's content was discarded instead of reported"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$out" || fail "retirement dropped a usable row"
  [ "$(awk 'END { print NR }' "$state/.wake-queue")" -eq 1 ] || fail "unusable rows survived the drain"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "the usable row was presented without an acknowledgement command"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "the queue stayed wedged after acknowledgement"
  FM_STATE_OVERRIDE="$state" "$GUARD" 2> "$dir/guard-after.err" || fail "guard failed after the queue drained"
  ! grep -Fq 'queued wakes pending' "$dir/guard-after.err" || fail "guard kept warning about an empty queue"

  pass "structurally unusable rows are retired by main alone, leaving every remaining row presentable and acknowledgeable"
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

# A wake that lands between main's drain and its acknowledgement was never
# presented to main and sits above the printed cutoff, so the acknowledgement
# must leave it unowned: an away-session grant can still take it, and main's
# next drain still presents it. Claiming it for main instead handed every later
# away wake back to main until main drained again.
test_main_ack_leaves_a_row_that_arrived_after_its_drain_unclaimed() {
  local dir state sequence generation rc
  dir=$(make_case main-ack-leaves-late-row)
  state="$dir/state"

  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "first signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/main.out" 2> "$dir/main.err" \
    || fail "main presentation failed"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/main.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/main.err")
  [ "$sequence" = 1 ] || fail "main was not asked to acknowledge exactly its presented row: $(cat "$dir/main.err")"

  append_wake "$state" signal "task-b.status" "signal: task-b" || fail "late signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    > "$dir/ack.out" 2> "$dir/ack.err" || fail "main acknowledgement failed: $(cat "$dir/ack.err")"
  grep -Fq "$(printf '\tsignal\ttask-b.status\t')" "$state/.wake-queue" \
    || fail "main's acknowledgement consumed a row it was never shown"

  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" late-row || fail "branch owner activation failed"
  rc=0
  FM_STATE_OVERRIDE="$state" "$GRANT" publish late-row 2 || rc=$?
  [ "$rc" -eq 0 ] || fail "an away-session grant could not take a row main never saw: rc=$rc"
  FM_STATE_OVERRIDE="$state" "$GRANT" release late-row || fail "branch grant release failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" deactivate "$$" late-row || fail "branch owner deactivation failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/main2.out" 2> "$dir/main2.err" \
    || fail "main's next drain failed"
  grep -Fq "$(printf '\tsignal\ttask-b.status\t')" "$dir/main2.out" \
    || fail "main's next drain did not present the late row: $(cat "$dir/main2.out" "$dir/main2.err")"

  pass "main's acknowledgement leaves a row that arrived after its drain for whichever actor takes it next"
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
    acked:*) ;;
    *) fail "an acknowledgement that consumed its own rows left the episode open" ;;
  esac

  # The rows above the cutoff stay queued and resurface on the next drain.
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

# An acknowledgement for an EARLIER wake while the current one is still
# presented consumes nothing. That must be said plainly, with the exact command
# for the current wake, because "re-run the drain" re-presents the same row and
# invites the same stale acknowledgement again (the refused-ack loop).
stale_ack_remedy() {  # <stderr-file> -> "<seq>\t<generation>"
  local seq generation
  seq=$(sed -n 's/^wake drain: nothing was acknowledged through [0-9][0-9]*.*run bin\/fm-wake-drain.sh --ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]* after handling it$/\1/p' "$1")
  generation=$(sed -n 's/^wake drain: nothing was acknowledged through [0-9][0-9]*.*run bin\/fm-wake-drain.sh --ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\) after handling it$/\1/p' "$1")
  [ -n "$seq" ] && [ -n "$generation" ] || return 1
  printf '%s\t%s\n' "$seq" "$generation"
}

test_stale_ack_that_consumes_nothing_names_the_current_wake() {
  local dir state first_seq first_gen second_seq second_gen remedy rc
  dir=$(make_case stale-ack-current-wake)
  state="$dir/state"

  append_wake "$state" check first 'check: first wake' || fail "first append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first.out" 2> "$dir/first.err" || fail "first drain failed"
  first_seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$dir/first.err")
  first_gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/first.err")
  [ -n "$first_seq" ] && [ -n "$first_gen" ] || fail "first drain printed no acknowledgement command"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$first_seq" --recovery-generation "$first_gen" \
    || fail "first acknowledgement failed"

  append_wake "$state" check second 'check: second wake' || fail "second append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/second.out" 2> "$dir/second.err" || fail "second drain failed"
  second_seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$dir/second.err")
  second_gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/second.err")
  [ "$second_seq" -gt "$first_seq" ] || fail "second drain did not present a newer row"

  # The stale acknowledgement: the previous wake's command, re-run from memory.
  rc=0
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$first_seq" --recovery-generation "$first_gen" \
    > "$dir/stale.out" 2> "$dir/stale.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "a stale acknowledgement failed instead of degrading safely: $(cat "$dir/stale.err")"
  grep -F "nothing was acknowledged through $first_seq" "$dir/stale.err" >/dev/null \
    || fail "a no-op acknowledgement was not reported as acknowledging nothing: $(cat "$dir/stale.err")"
  grep -F "the current wake is row $second_seq" "$dir/stale.err" >/dev/null \
    || fail "a no-op acknowledgement did not name the current wake: $(cat "$dir/stale.err")"
  ! grep -F 're-run' "$dir/stale.err" >/dev/null \
    || fail "a no-op acknowledgement told the caller to drain again instead of naming the exact command: $(cat "$dir/stale.err")"
  remedy=$(stale_ack_remedy "$dir/stale.err") \
    || fail "a no-op acknowledgement did not print the exact current command: $(cat "$dir/stale.err")"
  [ "${remedy%%$'\t'*}" = "$second_seq" ] && [ "${remedy##*$'\t'}" = "$second_gen" ] \
    || fail "the printed remedy differs from the drain's own WAKE_ACK_REQUIRED command: $remedy vs $second_seq/$second_gen"
  grep "$(printf '\tcheck\tsecond\t')" "$state/.wake-queue" >/dev/null \
    || fail "a stale acknowledgement consumed the current wake"

  # Following the printed command, verbatim, closes the wake and the episode.
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "${remedy%%$'\t'*}" --recovery-generation "${remedy##*$'\t'}" \
    2> "$dir/remedy.err" || fail "the printed remedy failed: $(cat "$dir/remedy.err")"
  [ ! -s "$state/.wake-queue" ] || fail "the printed remedy left the current wake queued"
  ! grep -F 'nothing was acknowledged' "$dir/remedy.err" >/dev/null \
    || fail "a real acknowledgement was reported as acknowledging nothing: $(cat "$dir/remedy.err")"
  case "$(cat "$state/.watcher-down")" in
    acked:*) ;;
    *) fail "the printed remedy did not retire the recovery episode" ;;
  esac
  pass "wake drain: an acknowledgement that consumes nothing says so and names the exact command for the current wake"
}

test_branch_stale_ack_that_consumes_nothing_names_its_granted_wake() {
  local dir state first_seq first_gen second_seq second_gen remedy
  dir=$(make_case branch-stale-ack-current-wake)
  state="$dir/state"
  append_wake "$state" signal "task-a.status" "signal: task-a first" || fail "first signal append failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" branch-stale || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish branch-stale 1 || fail "first grant publication failed"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$dir/first.out" 2> "$dir/first.err" \
    || fail "first branch drain failed: $(cat "$dir/first.err")"
  first_seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$dir/first.err")
  first_gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/first.err")
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "$first_seq" --recovery-generation "$first_gen" \
    || fail "first branch acknowledgement failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" release branch-stale || fail "first grant release failed"

  # The next prompt: a stale escalation for another pane, granted on its own.
  append_wake "$state" stale "fm-window-b" "stale: fm-window-b (idle 378s, possible wedge)" || fail "stale append failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish branch-stale 2 || fail "second grant publication failed"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$dir/second.out" 2> "$dir/second.err" \
    || fail "second branch drain failed: $(cat "$dir/second.err")"
  second_seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$dir/second.err")
  second_gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/second.err")
  [ "$second_seq" -eq 2 ] || fail "second branch drain did not present the granted stale row: $(cat "$dir/second.out")"

  # The refused-ack loop's first step: the PREVIOUS wake's command.
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "$first_seq" --recovery-generation "$first_gen" \
    > "$dir/stale.out" 2> "$dir/stale.err" || fail "a stale branch acknowledgement failed instead of degrading safely: $(cat "$dir/stale.err")"
  grep -F "nothing was acknowledged through $first_seq" "$dir/stale.err" >/dev/null \
    || fail "the branch's no-op acknowledgement was not reported as acknowledging nothing: $(cat "$dir/stale.err")"
  remedy=$(stale_ack_remedy "$dir/stale.err") \
    || fail "the branch's no-op acknowledgement did not print the exact current command: $(cat "$dir/stale.err")"
  [ "${remedy%%$'\t'*}" = "$second_seq" ] && [ "${remedy##*$'\t'}" = "$second_gen" ] \
    || fail "the branch remedy differs from its drain's WAKE_ACK_REQUIRED command: $remedy vs $second_seq/$second_gen"
  grep "$(printf '\tstale\tfm-window-b\t')" "$state/.wake-queue" >/dev/null \
    || fail "a stale branch acknowledgement consumed the granted wake"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "${remedy%%$'\t'*}" --recovery-generation "${remedy##*$'\t'}" \
    || fail "the branch's printed remedy failed"
  [ ! -s "$state/.wake-queue" ] || fail "the branch's printed remedy left its wake queued"
  FM_STATE_OVERRIDE="$state" "$GRANT" deactivate "$$" branch-stale || fail "branch owner deactivation failed"
  pass "wake drain: a branch acknowledgement that consumes nothing names the exact command for its granted wake"
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
# functions: a file this home already knows (seen marker or OPEN DECISIONS
# fold) plus the home's own bookkeeping close stays
# announced (no wake), while ANY unannounced byte - a pending foreign line, a
# missing cursor, a later different note - reads as wake-worthy.
test_self_announced_append_guards() {
  local dir state status folded rc=0
  dir=$(make_case self-announced-append)
  state="$dir/state"
  status="$state/t.status"
  folded="$state/folded.status"

  run_wake_lib() {
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"; shift; "$@"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$@"
  }

  # FIRST status change: a fresh file with no marker is unannounced (wakes).
  printf 'working: first line\n' > "$status"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    && fail "a never-announced status file read as already announced"

  # A close over those never-announced bytes must not swallow them.
  run_wake_lib fm_wake_status_append_self_announced "$state" "$status" \
    'resolved [key=k0]: answered: too early' || rc=$?
  [ "$rc" -eq 1 ] || fail "a close over never-announced bytes did not fail toward waking (rc=$rc)"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    && fail "a close over never-announced bytes swallowed the pending wake"

  # Prime the marker to current (the watcher just surfaced/absorbed everything).
  prime_status_seen "$state" "$status" || fail "could not prime the seen marker"

  # A self-announced bookkeeping close on a fully announced file is suppressed.
  run_wake_lib fm_wake_status_append_self_announced "$state" "$status" \
    'resolved [key=k1]: answered: closed by this home' \
    || fail "self-announced append on an announced file was not suppressed (rc=$?)"
  sed -E 's/ \[at=[0-9]+\]//' "$status" | grep -Fq 'resolved [key=k1]: answered: closed by this home' \
    || fail "the suppressed close was not appended"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    || fail "the self-announced close left unannounced bytes behind"

  # A later DIFFERENT note from any other writer still wakes.
  printf 'needs-decision [key=k2]: a new decision\n' >> "$status"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    && fail "a later different note on the same task read as already announced"

  # With that foreign line pending, a bookkeeping close must NOT advance the
  # marker over it: the close appends but the file stays wake-worthy.
  rc=0
  run_wake_lib fm_wake_status_append_self_announced "$state" "$status" \
    'resolved [key=k1]: answered: second close' || rc=$?
  [ "$rc" -eq 1 ] || fail "a close over pending foreign bytes did not fail toward waking (rc=$rc)"
  sed -E 's/ \[at=[0-9]+\]//' "$status" | grep -Fq 'resolved [key=k1]: answered: second close' \
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

  # Issue 4767: a drain that folded OPEN DECISIONS has already presented those
  # bytes to this home even when the watcher has not written a matching seen
  # marker. The bookkeeping close must stay quiet; a later worker line must not.
  printf 'needs-decision [key=k3]: pick one\n' > "$folded"
  run_wake_lib fm_wake_signal_seen_current "$state" "$folded" \
    && fail "an unfolded file without a seen marker read as announced"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    status_open_decisions_incremental "$2" >/dev/null
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$folded" \
    || fail "could not fold the open decision"
  run_wake_lib fm_wake_status_append_self_announced "$state" "$folded" \
    'resolved [key=k3]: answered: folded close' \
    || fail "a close after an OPEN DECISIONS fold was not self-announced (rc=$?)"
  run_wake_lib fm_wake_signal_seen_current "$state" "$folded" \
    || fail "the folded close left unannounced bytes behind"
  printf 'blocked: worker still needs help\n' >> "$folded"
  run_wake_lib fm_wake_signal_seen_current "$state" "$folded" \
    && fail "a later worker line after a folded close was swallowed"

  pass "self-announced appends suppress only their own bytes and fail toward waking"
}

# Two distinct --resolve-key closes after an OPEN DECISIONS fold record their
# own byte ranges, so the watcher's span classification never reports the
# answers. The fold alone does not mark the worker's decisions seen, because
# any actor's drain folds: a folded decision this home has not answered still
# classifies as a new signal. Once the watcher has classified the worker's
# decisions and nothing beyond them, only the owned-append ledger can vouch
# for the two answers sitting past that offset, and a later worker line past
# the recorded ranges still wakes.
test_separate_self_announced_answers_after_fold_are_owned() {
  local dir state status rc events pre_answer ident
  dir=$(make_case multi-answer-owned)
  state="$dir/state"
  status="$state/t.status"

  run_wake_lib() {
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"; shift; "$@"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$@"
  }

  {
    printf 'needs-decision [key=k1]: pick REST or RPC\n'
    printf 'needs-decision [key=k2]: pick us-east or eu-west\n'
    printf 'needs-decision [key=k3]: pick a database\n'
  } > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>"$dir/fold.err" \
    || fail "the OPEN DECISIONS fold drain failed"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    && fail "a fold alone marked unclassified worker decisions as seen"

  pre_answer=$(wc -c < "$status" | tr -d '[:space:]')
  rc=0
  run_wake_lib fm_wake_status_append_self_announced "$state" "$status" \
    'resolved [key=k1]: answered: REST' || rc=$?
  [ "$rc" -eq 1 ] || fail "the first answer over unclassified decisions did not fail toward waking (rc=$rc)"
  rc=0
  run_wake_lib fm_wake_status_append_self_announced "$state" "$status" \
    'resolved [key=k2]: answered: eu-west' || rc=$?
  [ "$rc" -eq 1 ] || fail "the second answer over unclassified decisions did not fail toward waking (rc=$rc)"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    && fail "unclassified worker decisions were hidden behind this home's answers"

  events=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; status_span_first_actionable "$2" 0' _ "$ROOT/bin/fm-classify-lib.sh" "$status") \
    || fail "the unanswered folded decision was not classified as actionable"
  [ "$events" = 'needs-decision [key=k3]: pick a database' ] \
    || fail "the span classification reported more than the unanswered decision: $events"

  ident=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"; _fm_open_decisions_file_ident "$2"
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$status") \
    || fail "could not read the status identity"
  run_wake_lib fm_wake_status_seen_commit "$state" "$status" "$pre_answer" "$ident" \
    || fail "could not record the watcher classifying the worker's decisions"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    || fail "the owned answers past the classified offset were left to re-wake this home"

  printf 'blocked [key=creds]: need staging credentials\n' >> "$status"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    && fail "a later worker line after two owned answers was swallowed"

  pass "separate self-announced answers after a fold stay owned; worker decisions and later lines still wake"
}

# The owned ledger only vouches for growth it recorded. A signature change
# with no growth past the classified offset, such as the log turning
# unreadable, must still read as unreported, before and after owned growth.
test_unreadable_status_is_not_owned() {
  local dir state status
  dir=$(make_case owned-unreadable)
  state="$dir/state"
  status="$state/t.status"

  run_wake_lib() {
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"; shift; "$@"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$@"
  }

  if [ "$(id -u)" -eq 0 ]; then
    pass "unreadable status check skipped: root reads mode-000 files"
    return 0
  fi
  printf 'needs-decision [key=k1]: pick one\n' > "$status"
  run_wake_lib fm_wake_status_mark_current "$state" "$status" \
    || fail "could not prime the announced baseline"
  chmod 000 "$status"
  if run_wake_lib fm_wake_signal_seen_current "$state" "$status"; then
    chmod 600 "$status"
    fail "an unreadable fully classified status read as already seen"
  fi
  chmod 600 "$status"

  run_wake_lib fm_wake_status_mark_current "$state" "$status" \
    || fail "could not re-prime the announced baseline"
  run_wake_lib fm_wake_status_append_self_announced "$state" "$status" \
    'resolved [key=k1]: answered: one' \
    || fail "the owned close was not self-announced"
  printf 'needs-decision [key=k2]: pick two\n' >> "$status"
  run_wake_lib fm_wake_status_mark_current "$state" "$status" \
    || fail "could not record the watcher classifying the worker line"
  run_wake_lib fm_wake_status_append_self_announced "$state" "$status" \
    'resolved [key=k2]: answered: two' \
    || fail "the second owned close was not self-announced"
  chmod 000 "$status"
  if run_wake_lib fm_wake_signal_seen_current "$state" "$status"; then
    chmod 600 "$status"
    fail "an unreadable status after owned growth read as already seen"
  fi
  chmod 600 "$status"
  pass "an unreadable status still reads as unreported, with or without owned growth"
}

test_folded_worker_resolved_is_not_owned_lag() {
  local dir state status rc
  dir=$(make_case folded-worker-resolved)
  state="$dir/state"
  status="$state/t.status"

  run_wake_lib() {
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"; shift; "$@"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$@"
  }

  {
    printf 'needs-decision [key=budget]: approve spend?\n'
    printf 'needs-decision [key=vendor]: vendor A or B?\n'
    printf 'resolved [key=vendor]: picked vendor B myself, cheaper\n'
  } > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>"$dir/fold.err" \
    || fail "the OPEN DECISIONS fold drain failed"

  rc=0
  run_wake_lib fm_wake_status_append_self_announced "$state" "$status" \
    'resolved [key=budget]: answered: approved' || rc=$?
  [ "$rc" -eq 1 ] || fail "a close over a folded worker resolved did not fail toward waking (rc=$rc)"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    && fail "a worker resolved in the folded span was treated as already owned"

  pass "a worker resolved in fold lag still wakes after this home's close"
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

test_subshell_lock_ownership_without_bashpid() {
  local dir state rc
  dir=$(make_case subshell-lock-ownership)
  state="$dir/state"
  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    unset BASHPID
    . "$1"
    lock="$2/.fixture.lock"
    fm_lock_acquire_wait "$lock" || exit 10
    ( fm_lock_release "$lock" )
    [ "$(cat "$lock/pid")" = "$$" ] || exit 11
    ( fm_lock_try_acquire "$lock" && exit 12; exit 0 ) || exit 12
    fm_lock_release "$lock"
    (
      fm_lock_acquire_wait "$lock" || exit 13
      [ "$(cat "$lock/pid")" != "$$" ] || exit 14
      fm_lock_try_acquire "$lock" || exit 15
      fm_lock_set_role "$lock" terminal-check || exit 16
      fm_lock_release "$lock"
      [ ! -e "$lock" ] && [ ! -L "$lock" ] || exit 17
    ) || exit $?
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" || rc=$?
  [ "$rc" -eq 0 ] || fail "subshell lock ownership without BASHPID failed (rc=$rc)"
  pass "without BASHPID a subshell cannot release or reclaim its parent lock and owns its own hold"
}

# A bounded waiter acquires in a helper process, but the caller must own the
# lock once contention clears so it can safely hold and release the critical
# section itself.
test_bounded_lock_handoff_after_contention() {
  local dir state lock holder_pid waiter_pid i recorded_pid real_sleep sleep_log
  dir=$(make_case bounded-lock-handoff)
  state="$dir/state"
  lock="$state/.fixture.lock"
  sleep_log="$dir/waiter-sleeps"
  real_sleep=$(command -v sleep) || fail "sleep is unavailable for the handoff fixture"
  cat > "$dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HANDOFF_SLEEP_LOG"
exec "$FM_HANDOFF_REAL_SLEEP" "$@"
SH
  chmod +x "$dir/fakebin/sleep"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" || exit 10
    printf "ready\n" > "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$dir/holder.ready" "$dir/release-holder" &
  holder_pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/holder.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/holder.ready" ] \
    || { kill "$holder_pid" 2>/dev/null || true; fail "handoff fixture holder never acquired its lock"; }

  PATH="$dir/fakebin:$PATH" FM_HANDOFF_SLEEP_LOG="$sleep_log" FM_HANDOFF_REAL_SLEEP="$real_sleep" \
    FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait_bounded "$2" 5 || exit 11
    current=${BASHPID:-$$}
    printf "%s\n" "$current" > "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    [ "$(cat "$2/pid" 2>/dev/null || true)" = "$current" ] || exit 12
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$dir/waiter.ready" "$dir/release-waiter" &
  waiter_pid=$!
  i=0
  while [ "$i" -lt 100 ] && ! grep -Fx '0.1' "$sleep_log" >/dev/null 2>&1; do
    sleep 0.05
    i=$((i + 1))
  done
  grep -Fx '0.1' "$sleep_log" >/dev/null 2>&1 \
    || { kill "$holder_pid" "$waiter_pid" 2>/dev/null || true; fail "bounded helper never entered its contended wait"; }
  [ ! -e "$dir/waiter.ready" ] \
    || { kill "$holder_pid" "$waiter_pid" 2>/dev/null || true; fail "bounded waiter bypassed a live holder"; }

  : > "$dir/release-holder"
  wait "$holder_pid" || { kill "$waiter_pid" 2>/dev/null || true; fail "fixture holder did not release cleanly"; }
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/waiter.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/waiter.ready" ] \
    || { kill "$waiter_pid" 2>/dev/null || true; fail "bounded waiter did not acquire after contention cleared"; }
  recorded_pid=$(cat "$dir/waiter.ready")
  [ "$recorded_pid" = "$waiter_pid" ] && [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$waiter_pid" ] \
    || { kill "$waiter_pid" 2>/dev/null || true; fail "bounded acquire did not hand lock ownership to its caller"; }

  : > "$dir/release-waiter"
  wait "$waiter_pid" || fail "caller could not release its handed-off lock"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || fail "handed-off lock remained after caller release"
  pass "bounded acquire hands ownership to the waiting caller after contention"
}

# A live-but-stuck presentation lock must not strand the executable drain. The
# presentation remains retriable on the next pass, while the separate queue
# mutation lock keeps its blocking all-or-nothing acknowledgement contract.
test_live_presentation_holder_is_deadlined_without_weakening_ack() {
  local dir state status queue_out queue_err first_out first_err second_out second_err replay_out replay_err
  local queue_holder presentation_holder ack_holder i start elapsed rc advisory_count
  dir=$(make_case presentation-lock-deadline)
  state="$dir/state"
  status="$state/task.status"
  queue_out="$dir/queue.out"
  queue_err="$dir/queue.err"
  first_out="$dir/first.out"
  first_err="$dir/first.err"
  second_out="$dir/second.out"
  second_err="$dir/second.err"
  replay_out="$dir/replay.out"
  replay_err="$dir/replay.err"

  printf 'needs-decision [key=fixture]: presentation remains retriable\n' > "$status"
  append_wake "$state" signal task.status "signal: $status" \
    || fail "could not seed the presentation-deadline wake"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    printf "ready\n" > "$3"
    exec sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.wake-queue.lock" "$dir/queue.ready" &
  queue_holder=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/queue.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/queue.ready" ] \
    || { kill "$queue_holder" 2>/dev/null || true; fail "queue holder never acquired its lock"; }

  start=$(date +%s)
  FM_STATE_OVERRIDE="$state" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 \
    "$DRAIN" > "$queue_out" 2> "$queue_err" \
    || { kill "$queue_holder" 2>/dev/null || true; fail "bounded queue presentation drain failed"; }
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -le 4 ] \
    || { kill "$queue_holder" 2>/dev/null || true; fail "queue lock delayed the drain for ${elapsed}s"; }
  advisory_count=$(grep -Fc \
    "WAKE DRAIN SKIPPED: queue lock remains held by live pid $queue_holder" \
    "$queue_out" || true)
  [ "$advisory_count" -eq 1 ] \
    || { kill "$queue_holder" 2>/dev/null || true; fail "queue deadline did not emit exactly one holder advisory"; }
  [ ! -s "$queue_err" ] \
    || { kill "$queue_holder" 2>/dev/null || true; fail "queue deadline leaked helper-process diagnostics"; }
  if grep "$(printf '\tsignal\t')" "$queue_out" >/dev/null \
    || grep -F 'WAKE_ACK_REQUIRED:' "$queue_err" >/dev/null; then
    kill "$queue_holder" 2>/dev/null || true
    fail "contended queue lock allowed a partial drain"
  fi
  grep "$(printf '\tsignal\t')" "$state/.wake-queue" >/dev/null \
    || { kill "$queue_holder" 2>/dev/null || true; fail "contended queue lock changed the durable wake"; }

  kill "$queue_holder" 2>/dev/null || true
  wait "$queue_holder" 2>/dev/null || true

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    printf "ready\n" > "$3"
    exec sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.status-presentation-lock" "$dir/presentation.ready" &
  presentation_holder=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/presentation.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/presentation.ready" ] \
    || { kill "$presentation_holder" 2>/dev/null || true; fail "presentation holder never acquired its lock"; }

  start=$(date +%s)
  FM_STATE_OVERRIDE="$state" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 \
    "$DRAIN" > "$first_out" 2> "$first_err" \
    || { kill "$presentation_holder" 2>/dev/null || true; fail "bounded presentation drain failed"; }
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -le 4 ] \
    || { kill "$presentation_holder" 2>/dev/null || true; fail "presentation lock delayed the drain for ${elapsed}s"; }
  advisory_count=$(grep -Fc \
    "STATUS PRESENTATION SKIPPED: lock remains held by live pid $presentation_holder" \
    "$first_out" || true)
  [ "$advisory_count" -eq 1 ] \
    || { kill "$presentation_holder" 2>/dev/null || true; fail "presentation deadline did not emit exactly one holder advisory"; }
  if grep -v '^WAKE_ACK_REQUIRED:' "$first_err" | grep . >/dev/null; then
    kill "$presentation_holder" 2>/dev/null || true
    fail "presentation deadline leaked helper-process diagnostics"
  fi
  grep "$(printf '\tsignal\t')" "$first_out" >/dev/null \
    || { kill "$presentation_holder" 2>/dev/null || true; fail "bounded presentation dropped the durable wake row"; }
  if grep -F 'task.status: needs-decision [key=fixture]' "$first_out" >/dev/null; then
    kill "$presentation_holder" 2>/dev/null || true
    fail "contended presentation emitted status content without its cursor lock"
  fi

  kill "$presentation_holder" 2>/dev/null || true
  wait "$presentation_holder" 2>/dev/null || true
  FM_STATE_OVERRIDE="$state" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 \
    "$DRAIN" > "$second_out" 2> "$second_err" || fail "presentation retry failed"
  grep -F 'task.status: needs-decision [key=fixture]: presentation remains retriable' "$second_out" >/dev/null \
    || fail "the next presentation pass did not surface the skipped status"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    printf "ready\n" > "$3"
    exec sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.wake-queue.lock" "$dir/ack.ready" &
  ack_holder=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/ack.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/ack.ready" ] \
    || { kill "$ack_holder" 2>/dev/null || true; fail "acknowledgement holder never acquired the queue lock"; }

  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    shift
    fm_run_timed 1 "$@"
  ' _ "$ROOT/bin/fm-timeout-lib.sh" "$DRAIN" \
    --ack-through "$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$second_err")" \
    --recovery-generation "$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$second_err")" \
    > "$dir/ack-held.out" 2> "$dir/ack-held.err" || rc=$?
  [ "$rc" -eq 124 ] \
    || { kill "$ack_holder" 2>/dev/null || true; fail "held acknowledgement lock did not retain blocking semantics (rc=$rc)"; }

  kill "$ack_holder" 2>/dev/null || true
  wait "$ack_holder" 2>/dev/null || true
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$replay_out" 2> "$replay_err" \
    || fail "drain after the interrupted acknowledgement failed"
  grep "$(printf '\tsignal\t')" "$replay_out" >/dev/null \
    || fail "the held acknowledgement lock allowed a partial consume"
  ack_drain_err "$state" "$replay_err" \
    || fail "the intact wake could not be acknowledged after contention cleared"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged presentation fixture remained queued"
  pass "presentation lock waits are bounded and retriable without weakening acknowledgement atomicity"
}

test_malformed_presentation_lock_reports_acquire_failure() {
  local dir state status out err
  dir=$(make_case malformed-presentation-lock)
  state="$dir/state"
  status="$state/task.status"
  out="$dir/drain.out"
  err="$dir/drain.err"

  printf 'needs-decision [key=fixture]: malformed lock remains retriable\n' > "$status"
  append_wake "$state" signal task.status "signal: $status" \
    || fail "could not seed the malformed-lock wake"
  : > "$state/.status-presentation-lock"

  FM_STATE_OVERRIDE="$state" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 \
    "$DRAIN" > "$out" 2> "$err" || fail "malformed-lock drain failed"
  grep -F 'wake drain: status presentation lock could not be acquired safely' "$err" >/dev/null \
    || fail "malformed presentation lock did not report an acquire failure"
  if grep -F 'STATUS PRESENTATION SKIPPED: lock remains held by live pid' "$out" >/dev/null; then
    fail "malformed presentation lock was reported as live-holder contention"
  fi
  grep "$(printf '\tsignal\t')" "$out" >/dev/null \
    || fail "malformed presentation lock dropped the durable wake row"
  pass "malformed presentation locks report acquire failure instead of contention"
}

# The owned-append ledger is wake-only: it must never withhold a captain-facing
# turn-ended annotation. An in-flight watcher classification that commits after
# this home's own close regresses the classified offset behind the owned bytes -
# exactly the state the wake scan treats as already owned - so the wake stays
# suppressed while the historical annotation must still present the line.
test_owned_growth_still_annotates_turn_ended() {
  local dir state out err status pre_close ident
  dir=$(make_case owned-historical)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  status="$state/scout.status"

  run_wake_lib() {
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"; shift; "$@"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$@"
  }

  printf 'needs-decision [key=budget]: approve spend?\n' > "$status"
  prime_status_seen "$state" "$status" || fail "could not prime the scout seen marker"
  pre_close=$(wc -c < "$status" | tr -d '[:space:]')
  run_wake_lib fm_wake_status_append_self_announced "$state" "$status" \
    'resolved [key=budget]: answered: approved' \
    || fail "the answerer close was not self-announced"
  ident=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"; _fm_open_decisions_file_ident "$2"
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$status") \
    || fail "could not read the status identity"
  run_wake_lib fm_wake_status_seen_commit "$state" "$status" "$pre_close" "$ident" \
    || fail "could not replay the stale watcher classification"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    || fail "owned-only growth did not suppress the wake"

  : > "$state/scout.turn-ended"
  append_wake "$state" signal scout.turn-ended "signal: $state/scout.turn-ended" \
    || fail "turn-ended wake append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "drain failed"
  sed -E 's/ \[at=[0-9]+\]//' "$out" | grep -F 'scout.status: resolved [key=budget]: answered: approved' >/dev/null \
    || fail "owned growth hid this home's own close from the turn-ended annotation: $(cat "$out")"
  pass "owned growth suppresses the wake without hiding the turn-ended annotation"
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

test_wake_queue_prune_task() {
  local dir state queue
  dir=$(make_case prune)
  state="$dir/state"
  queue="$state/.wake-queue"

  append_wake "$state" stale "test:window-a" "stale: test:window-a"
  append_wake "$state" signal "task-a.status" "signal: $state/task-a.status"
  append_wake "$state" signal "task-a.turn-ended" "signal: $state/task-a.turn-ended"
  append_wake "$state" check "$state/task-a.check.sh" "check: $state/task-a.check.sh: merged: https://example.test/pr/1"
  append_wake "$state" stale "test:window-b" "stale: test:window-b"
  append_wake "$state" signal "task-b.status" "signal: $state/task-b.status"
  append_wake "$state" check "$state/task-b.check.sh" "check: $state/task-b.check.sh: merged: https://example.test/pr/2"

  FM_STATE_OVERRIDE="$state" bash -c '. "$0/bin/fm-wake-lib.sh"; fm_wake_queue_prune_task "$1" "$2" "$3"' "$ROOT" "$state" "task-a" "test:window-a" \
    || fail "fm_wake_queue_prune_task returned non-zero"

  grep -F 'test:window-a' "$queue" >/dev/null && fail "prune left stale wake for task-a"
  grep -F 'task-a.status' "$queue" >/dev/null && fail "prune left status wake for task-a"
  grep -F 'task-a.turn-ended' "$queue" >/dev/null && fail "prune left turn-ended wake for task-a"
  grep -F 'task-a.check.sh' "$queue" >/dev/null && fail "prune left check wake for task-a"
  grep -F 'test:window-b' "$queue" >/dev/null || fail "prune removed stale wake for task-b"
  grep -F 'task-b.status' "$queue" >/dev/null || fail "prune removed status wake for task-b"
  grep -F 'task-b.check.sh' "$queue" >/dev/null || fail "prune removed check wake for task-b"

  pass "fm_wake_queue_prune_task: prunes wakes for target task without touching other tasks"
}

# --- secondmate endpoint liveness tick ---------------------------------------
# bin/fm-watch.sh's secondmate_liveness_tick drives the shared
# bin/fm-secondmate-liveness-lib.sh probe+relaunch machinery during ordinary
# supervision: only a positively dead or missing recorded endpoint relaunches
# (through the same guarded fm-spawn.sh --secondmate path the session-start
# sweep uses), every relaunch emits exactly one `check` wake plus a durable
# ledger line, inconclusive verdicts are triage-only, an unreachable remote
# route is preserved, and the attempt bound parks a mate that keeps dying.

# make_secondmate_liveness_case <name>: a watcher case dir carrying one local
# secondmate whose tmux fixture answers the backend's agent-state probe AND the
# guarded spawn's window lifecycle (kill-window, a window id from new-window).
# FM_FAKE_TMUX_CURRENT_COMMAND selects the pane's foreground command per leg;
# FM_FAKE_WINDOW_GONE=1 makes the session inventory omit fm-sm1 (missing);
# after a logged new-window the probe reads alive, matching a real respawn.
make_secondmate_liveness_case() {
  local name=$1 dir fakebin home
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  # The mate home must sit OUTSIDE the watcher's FM_HOME: fm-spawn.sh refuses
  # a secondmate home nested inside the active home that would supervise it.
  home="$TMP_ROOT/$name-mate"
  mkdir -p "$dir/state" "$dir/config" "$dir/data" "$fakebin" \
    "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  # A secondmate home is a git checkout: the AI-trailer strip hook refuses a
  # launch whose worktree is not git.
  git init -q -b main "$home"
  printf 'sm1\n' > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  printf 'codex\n' > "$dir/config/crew-harness"
  printf 'window=firstmate:fm-sm1\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$home" > "$dir/state/sm1.meta"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_TMUX_CALL_LOG:-/dev/null}
probe=${FM_TMUX_CALL_LOG:-/dev/null}.probe
cmd=${FM_FAKE_TMUX_CURRENT_COMMAND:-zsh}
[ ! -f "$probe.spawned" ] || cmd=claude
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) printf '%s\n' "$cmd"; exit 0 ;;
        *cursor_y*) printf '0\n'; exit 0 ;;
      esac
    done
    exit 0 ;;
  list-windows)
    if [ "${FM_FAKE_WINDOW_GONE:-0}" = 1 ] || { [ -f "$probe.killed" ] && [ ! -f "$probe.spawned" ]; }; then
      printf 'main\n'
    else
      printf 'main\nfm-sm1\n'
    fi
    exit 0 ;;
  capture-pane) [ -z "${FM_FAKE_TMUX_CAPTURE:-}" ] || cat "$FM_FAKE_TMUX_CAPTURE"; exit 0 ;;
  new-window)
    printf '%s\n' "$*" >> "$log"
    [ "${FM_TEST_FAIL_NEW_WINDOW:-0}" = 1 ] && exit 1
    : > "$probe.spawned"
    printf '@1\n'
    exit 0 ;;
  kill-window)
    printf '%s\n' "$*" >> "$log"
    : > "$probe.killed"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  make_fake_crew_state "$fakebin" >/dev/null
  printf '%s\n' "$dir"
}

# run_liveness_leg <dir> <tag> [NAME=VALUE...]: one watcher invocation under the
# case's fake toolchain; extra env assignments precede the command for env(1).
# The watcher exits 0 on its first wake, so a leg that should wake ends via
# wait_for_exit and a leg that should stay quiet is polled then killed. The
# pid lands in LIVENESS_PID - capturing it through $(...) would orphan the
# watcher and break wait_for_exit's ownership check.
run_liveness_leg() {
  local dir=$1 tag=$2
  shift 2
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    TMUX='' FM_BACKEND=tmux \
    FM_TMUX_CALL_LOG="$dir/tmux.log" FM_SECONDMATE_LIVENESS_SECS=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$@" "$WATCH" > "$dir/watch-$tag.out" 2> "$dir/watch-$tag.err" &
  LIVENESS_PID=$!
}

# kill_liveness_leg <pid>: end a leg that must have stayed quiet.
kill_liveness_leg() {
  kill -TERM "$1" 2>/dev/null || true
  wait_for_exit "$1" 50 >/dev/null || true
}

# drain_liveness_wakes <dir>: replay the case's durable queue through the real
# drain and post the acknowledgement it names - the same handling boundary a
# firstmate applies to a surfaced wake. A leg after an unacked wake would exit
# on check: rearm-resurface instead of exercising the tick it is testing.
drain_liveness_wakes() {
  local dir=$1 state="$1/state" seq gen
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" > /dev/null 2> "$dir/drain.err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\).*$/\1/p' "$dir/drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\).*$/\1/p' "$dir/drain.err")
  [ -n "$seq" ] && [ -n "$gen" ] || return 0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" \
    > /dev/null 2>&1 || true
}

test_secondmate_liveness_tick_relaunches_dead_endpoint_once() {
  local dir state pid out ledger
  dir=$(make_secondmate_liveness_case liveness-dead)
  state="$dir/state"

  run_liveness_leg "$dir" dead FM_FAKE_TMUX_CURRENT_COMMAND=zsh; pid=$LIVENESS_PID
  wait_for_exit "$pid" 300 || fail "the watcher did not exit on its auto-relaunch wake"
  out="$dir/watch-dead.out"
  grep -F 'check: secondmate sm1 auto-relaunched after confirmed agent absence on existing endpoint (backend=tmux)' "$out" >/dev/null \
    || fail "a confirmed-dead secondmate was not auto-relaunched: $(cat "$out" "$dir/watch-dead.err")"
  [ "$(grep -c 'check: secondmate sm1 auto-relaunched' "$out")" -eq 1 ] \
    || fail "an auto-relaunch did not produce exactly one captain-facing line: $(cat "$out")"
  assert_contains "$(cat "$dir/tmux.log")" "kill-window" \
    "the confirmed-dead endpoint must be killed before relaunch"
  assert_contains "$(cat "$dir/tmux.log")" "new-window" \
    "the dead secondmate was not relaunched"
  ledger="$state/.secondmate-relaunch-sm1"
  [ -f "$ledger" ] || fail "the durable relaunch ledger was not written"
  [ "$(awk -F '\t' '$2 == "attempt"' "$ledger" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "the ledger did not record exactly one attempt: $(cat "$ledger")"
  [ "$(awk -F '\t' '$2 == "relaunched"' "$ledger" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "the ledger did not record the relaunched outcome: $(cat "$ledger")"
  [ "$(grep -c 'secondmate-relaunch-sm1-' "$state/.wake-queue")" -eq 1 ] \
    || fail "the durable auto-relaunch wake row was not queued exactly once: $(cat "$state/.wake-queue")"
  [ -e "$state/.secondmate-liveness-tick" ] \
    || fail "the liveness cadence marker was not stamped"

  # A restarted watcher sees the relaunched endpoint alive and stays quiet -
  # the durable row remains for the drain and no second notification fires.
  drain_liveness_wakes "$dir"
  rm -f "$state/.secondmate-liveness-tick"
  run_liveness_leg "$dir" dead-idle FM_FAKE_TMUX_CURRENT_COMMAND=zsh; pid=$LIVENESS_PID
  sleep 4
  is_live_non_zombie "$pid" \
    || fail "the watcher exited against an alive relaunched secondmate: $(cat "$dir/watch-dead-idle.out" "$dir/watch-dead-idle.err")"
  kill_liveness_leg "$pid"
  [ "$(grep -c 'secondmate-relaunch-sm1' "$state/.wake-queue" 2>/dev/null || true)" -eq 0 ] \
    || fail "a live post-relaunch probe produced a second wake: $(cat "$state/.wake-queue")"
  pass "watch liveness: a dead secondmate is relaunched once, ledgered, and quiet afterwards"
}

test_secondmate_liveness_tick_relaunches_missing_endpoint() {
  local dir state pid out
  dir=$(make_secondmate_liveness_case liveness-missing)
  state="$dir/state"

  run_liveness_leg "$dir" missing FM_FAKE_WINDOW_GONE=1; pid=$LIVENESS_PID
  wait_for_exit "$pid" 300 || fail "the watcher did not exit on its auto-relaunch wake"
  out="$dir/watch-missing.out"
  grep -F 'check: secondmate sm1 auto-relaunched after recorded endpoint confidently missing (backend=tmux)' "$out" >/dev/null \
    || fail "a missing secondmate endpoint was not auto-relaunched: $(cat "$out" "$dir/watch-missing.err")"
  assert_contains "$(cat "$dir/tmux.log")" "new-window" \
    "the missing secondmate endpoint was not relaunched"
  assert_not_contains "$(cat "$dir/tmux.log")" "kill-window" \
    "an absent window must not take the destructive pre-kill path"
  pass "watch liveness: a missing secondmate endpoint is relaunched without a pre-kill"
}

test_secondmate_liveness_tick_relaunches_every_dead_mate_before_waking() {
  local dir state pid out home id
  dir=$(make_secondmate_liveness_case liveness-several)
  state="$dir/state"
  home="$TMP_ROOT/liveness-several-mate2"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  git init -q -b main "$home"
  printf 'sm2\n' > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  printf 'window=firstmate:fm-sm2\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$home" > "$state/sm2.meta"

  run_liveness_leg "$dir" several FM_FAKE_WINDOW_GONE=1; pid=$LIVENESS_PID
  wait_for_exit "$pid" 300 || fail "the watcher did not exit on its auto-relaunch wake"
  out="$dir/watch-several.out"
  [ "$(grep -c 'check: secondmate sm[12] auto-relaunched' "$out")" -eq 1 ] \
    || fail "one liveness tick did not wake exactly once: $(cat "$out" "$dir/watch-several.err")"
  [ "$(grep -c 'new-window' "$dir/tmux.log")" -eq 2 ] \
    || fail "the tick did not relaunch every dead mate before waking: $(cat "$dir/tmux.log")"
  for id in sm1 sm2; do
    [ "$(awk -F '\t' '$2 == "relaunched"' "$state/.secondmate-relaunch-$id" 2>/dev/null | wc -l | tr -d ' ')" -eq 1 ] \
      || fail "$id's relaunch was not ledgered: $(cat "$state/.secondmate-relaunch-$id" 2>/dev/null)"
    [ "$(grep -c "secondmate-relaunch-$id-" "$state/.wake-queue")" -eq 1 ] \
      || fail "$id's relaunch did not queue its own check row: $(cat "$state/.wake-queue")"
  done
  pass "watch liveness: one tick relaunches every dead mate, queues a row each, and wakes once"
}

test_secondmate_liveness_tick_leaves_alive_and_inconclusive_untouched() {
  local dir state pid
  dir=$(make_secondmate_liveness_case liveness-quiet)
  state="$dir/state"

  # A live endpoint probes every cadence and never acts.
  run_liveness_leg "$dir" alive FM_FAKE_TMUX_CURRENT_COMMAND=claude; pid=$LIVENESS_PID
  sleep 4
  is_live_non_zombie "$pid" \
    || fail "the watcher exited against an alive secondmate: $(cat "$dir/watch-alive.out" "$dir/watch-alive.err")"
  kill_liveness_leg "$pid"
  [ ! -s "$dir/tmux.log" ] || fail "an alive secondmate was touched: $(cat "$dir/tmux.log")"
  [ ! -s "$state/.wake-queue" ] || fail "an alive secondmate queued a wake: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.secondmate-relaunch-sm1" ] || fail "an alive secondmate was ledgered"
  [ -e "$state/.secondmate-liveness-tick" ] || fail "the liveness tick did not stamp its cadence marker"

  # An ambiguous existing process is evidence of nothing; it is triage-only
  # and never a relaunch. Drain the killed leg's downtime marker first so the
  # next watcher does not resurface instead of exercising the tick.
  drain_liveness_wakes "$dir"
  run_liveness_leg "$dir" ambiguous FM_FAKE_TMUX_CURRENT_COMMAND=node; pid=$LIVENESS_PID
  sleep 4
  is_live_non_zombie "$pid" \
    || fail "the watcher exited against an ambiguous secondmate endpoint: $(cat "$dir/watch-ambiguous.out" "$dir/watch-ambiguous.err")"
  kill_liveness_leg "$pid"
  [ ! -s "$dir/tmux.log" ] || fail "an ambiguous endpoint was killed or relaunched: $(cat "$dir/tmux.log")"
  [ ! -s "$state/.wake-queue" ] || fail "an ambiguous endpoint queued a wake: $(cat "$state/.wake-queue")"
  grep -F 'secondmate sm1 liveness: existing endpoint has ambiguous agent process (backend=tmux)' \
    "$state/.watch-triage.log" >/dev/null \
    || fail "the ambiguous probe did not land in the triage log: $(cat "$state/.watch-triage.log" 2>/dev/null)"
  pass "watch liveness: alive and ambiguous endpoints are probed, logged, and never touched"
}

test_secondmate_liveness_tick_cadence_gates_the_probe() {
  local dir state pid
  dir=$(make_secondmate_liveness_case liveness-cadence)
  state="$dir/state"

  # A fresh cadence marker holds the probe even over a dead endpoint.
  touch "$state/.secondmate-liveness-tick"
  run_liveness_leg "$dir" gated FM_SECONDMATE_LIVENESS_SECS=99999999 FM_FAKE_TMUX_CURRENT_COMMAND=zsh; pid=$LIVENESS_PID
  sleep 4
  is_live_non_zombie "$pid" \
    || fail "the watcher woke inside the liveness cadence: $(cat "$dir/watch-gated.out" "$dir/watch-gated.err")"
  kill_liveness_leg "$pid"
  [ ! -s "$dir/tmux.log" ] || fail "a gated tick probed the endpoint: $(cat "$dir/tmux.log")"
  [ ! -s "$state/.wake-queue" ] || fail "a gated tick queued a wake"
  [ ! -e "$state/.secondmate-relaunch-sm1" ] || fail "a gated tick ledgered an attempt"

  # Once the cadence lapses the same dead endpoint is recovered on the next poll.
  drain_liveness_wakes "$dir"
  rm -f "$state/.secondmate-liveness-tick"
  run_liveness_leg "$dir" ungated FM_FAKE_TMUX_CURRENT_COMMAND=zsh; pid=$LIVENESS_PID
  wait_for_exit "$pid" 300 || fail "the lapsed-cadence watcher did not auto-relaunch"
  grep -F 'check: secondmate sm1 auto-relaunched' "$dir/watch-ungated.out" >/dev/null \
    || fail "the lapsed cadence did not recover the dead secondmate: $(cat "$dir/watch-ungated.out")"
  pass "watch liveness: the cadence marker gates probing and survives across legs"
}

test_secondmate_liveness_tick_attempt_bound_parks_then_rearm_on_alive() {
  local dir state pid ledger now
  dir=$(make_secondmate_liveness_case liveness-bound)
  state="$dir/state"
  ledger="$state/.secondmate-relaunch-sm1"

  # Three ledgered attempts inside the window meet the default bound; the next
  # dead probe parks the mate behind the bound marker and escalates once.
  now=$(date +%s)
  printf '%s\tattempt\n%s\tattempt\n%s\tattempt\n' "$now" "$now" "$now" > "$ledger"
  run_liveness_leg "$dir" bound FM_FAKE_TMUX_CURRENT_COMMAND=zsh; pid=$LIVENESS_PID
  wait_for_exit "$pid" 300 || fail "the watcher did not exit on its bound wake"
  grep -F 'check: secondmate sm1 auto-relaunch paused after 3 attempts in 3600s' "$dir/watch-bound.out" >/dev/null \
    || fail "a mate past its relaunch bound was not escalated once: $(cat "$dir/watch-bound.out" "$dir/watch-bound.err")"
  [ -e "$state/.secondmate-relaunch-bound-sm1" ] || fail "the bound marker was not written"
  [ ! -s "$dir/tmux.log" ] || fail "a parked mate was relaunched anyway: $(cat "$dir/tmux.log")"
  [ "$(awk -F '\t' '$2 == "attempt"' "$ledger" | wc -l | tr -d ' ')" -eq 3 ] \
    || fail "a parked probe ledgered another attempt: $(cat "$ledger")"
  [ "$(grep -c 'secondmate-relaunch-bound-sm1' "$state/.wake-queue")" -eq 1 ] \
    || fail "the bound wake was not queued exactly once"

  # While the marker stands, further dead probes are silent - no repeat wake.
  drain_liveness_wakes "$dir"
  rm -f "$state/.secondmate-liveness-tick"
  run_liveness_leg "$dir" parked FM_FAKE_TMUX_CURRENT_COMMAND=zsh; pid=$LIVENESS_PID
  sleep 4
  is_live_non_zombie "$pid" \
    || fail "the watcher re-escalated a parked mate: $(cat "$dir/watch-parked.out" "$dir/watch-parked.err")"
  kill_liveness_leg "$pid"
  [ "$(grep -c 'secondmate-relaunch' "$state/.wake-queue" 2>/dev/null || true)" -eq 0 ] \
    || fail "a parked mate produced a second wake: $(cat "$state/.wake-queue")"
  [ ! -s "$dir/tmux.log" ] || fail "a parked mate was relaunched: $(cat "$dir/tmux.log")"

  # A live probe rearms the guarantee: the marker clears and the mate can be
  # auto-relaunched again on a later death.
  drain_liveness_wakes "$dir"
  rm -f "$state/.secondmate-liveness-tick"
  run_liveness_leg "$dir" rearm FM_FAKE_TMUX_CURRENT_COMMAND=claude; pid=$LIVENESS_PID
  sleep 4
  is_live_non_zombie "$pid" \
    || fail "the watcher exited against a live rearmed mate: $(cat "$dir/watch-rearm.out" "$dir/watch-rearm.err")"
  kill_liveness_leg "$pid"
  [ ! -e "$state/.secondmate-relaunch-bound-sm1" ] \
    || fail "a live probe did not clear the bound marker"
  [ "$(awk -F '\t' '$2 == "rearmed"' "$ledger" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "the live rearm was not ledgered exactly once: $(cat "$ledger")"
  drain_liveness_wakes "$dir"
  rm -f "$state/.secondmate-liveness-tick"
  # The three seeded attempts still sit inside the window, yet the rearm
  # restores the full default budget: the next death relaunches, not re-parks.
  run_liveness_leg "$dir" rearmed-dead FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_WINDOW_GONE=1; pid=$LIVENESS_PID
  wait_for_exit "$pid" 300 || fail "a rearmed mate was not auto-relaunched on its next death"
  grep -F 'check: secondmate sm1 auto-relaunched' "$dir/watch-rearmed-dead.out" >/dev/null \
    || fail "the rearmed mate's relaunch did not wake: $(cat "$dir/watch-rearmed-dead.out" "$dir/watch-rearmed-dead.err")"
  [ ! -e "$state/.secondmate-relaunch-bound-sm1" ] \
    || fail "a rearmed mate was re-parked on its pre-rearm attempts"
  [ "$(awk -F '\t' '$2 == "attempt"' "$ledger" | wc -l | tr -d ' ')" -eq 4 ] \
    || fail "the ledger did not keep its pre-rearm history plus the new attempt: $(cat "$ledger")"
  pass "watch liveness: the attempt bound parks a flapping mate once and a live probe rearms a full budget"
}

test_secondmate_liveness_tick_relaunch_failure_reports_once() {
  local dir state pid ledger
  dir=$(make_secondmate_liveness_case liveness-failure)
  state="$dir/state"
  ledger="$state/.secondmate-relaunch-sm1"

  run_liveness_leg "$dir" failed FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_TEST_FAIL_NEW_WINDOW=1; pid=$LIVENESS_PID
  wait_for_exit "$pid" 300 || fail "the watcher did not exit on its relaunch-failure wake"
  grep -F 'check: secondmate sm1 auto-relaunch failed after confirmed agent absence on existing endpoint:' \
    "$dir/watch-failed.out" >/dev/null \
    || fail "a failed auto-relaunch did not wake with its cause: $(cat "$dir/watch-failed.out" "$dir/watch-failed.err")"
  [ "$(awk -F '\t' '$2 == "attempt"' "$ledger" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "the ledger did not record the failed attempt: $(cat "$ledger" 2>/dev/null)"
  [ "$(awk -F '\t' '$2 == "failed"' "$ledger" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "the ledger did not record the failed outcome: $(cat "$ledger")"
  [ "$(grep -c 'secondmate-relaunch-failed-sm1-' "$state/.wake-queue")" -eq 1 ] \
    || fail "the failure wake was not queued exactly once: $(cat "$state/.wake-queue")"
  pass "watch liveness: a failed auto-relaunch wakes once with its cause and is ledgered"
}

test_secondmate_liveness_tick_fails_closed_on_ledger_errors() {
  local dir state pid ledger mode rc
  if [ "$(id -u)" -eq 0 ]; then
    pass "watch liveness: ledger permission errors skipped (root ignores file modes)"
    return 0
  fi
  for mode in 444 000; do
    dir=$(make_secondmate_liveness_case "liveness-ledger-$mode")
    state="$dir/state"
    ledger="$state/.secondmate-relaunch-sm1"
    : > "$ledger"
    chmod "$mode" "$ledger"
    run_liveness_leg "$dir" ledger FM_FAKE_TMUX_CURRENT_COMMAND=zsh; pid=$LIVENESS_PID
    rc=0
    wait_for_exit "$pid" 300 || rc=$?
    chmod 644 "$ledger"
    [ "$rc" -eq 1 ] || fail "a mode-$mode relaunch ledger did not fail the watcher (rc=$rc): $(cat "$dir/watch-ledger.out" "$dir/watch-ledger.err")"
    grep -F 'secondmate liveness check failed' "$dir/watch-ledger.err" >/dev/null \
      || fail "a mode-$mode ledger failure was not reported: $(cat "$dir/watch-ledger.err")"
    [ ! -s "$dir/tmux.log" ] \
      || fail "a mode-$mode relaunch ledger still killed or spawned: $(cat "$dir/tmux.log")"
    [ ! -s "$ledger" ] || fail "a mode-$mode ledger gained rows: $(cat "$ledger")"
    ! grep -F 'secondmate-relaunch' "$state/.wake-queue" >/dev/null 2>&1 \
      || fail "a mode-$mode ledger failure queued a relaunch wake: $(cat "$state/.wake-queue")"
  done
  pass "watch liveness: an unwritable or unreadable relaunch ledger refuses to kill or spawn"
}

test_secondmate_liveness_tick_error_keeps_scanning_and_wakes() {
  local dir state pid out home rc
  if [ "$(id -u)" -eq 0 ]; then
    pass "watch liveness: mid-tick ledger error skipped (root ignores file modes)"
    return 0
  fi
  dir=$(make_secondmate_liveness_case liveness-mid-error)
  state="$dir/state"
  home="$TMP_ROOT/liveness-mid-error-mate2"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  git init -q -b main "$home"
  printf 'sm2\n' > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  printf 'window=firstmate:fm-sm2\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$home" > "$state/sm2.meta"
  : > "$state/.secondmate-relaunch-sm1"
  chmod 000 "$state/.secondmate-relaunch-sm1"

  # sm1 errors first; the tick must still recover sm2 and surface its wake.
  run_liveness_leg "$dir" mid-error FM_FAKE_WINDOW_GONE=1; pid=$LIVENESS_PID
  rc=0
  wait_for_exit "$pid" 300 || rc=$?
  chmod 644 "$state/.secondmate-relaunch-sm1"
  out="$dir/watch-mid-error.out"
  [ "$rc" -eq 0 ] || fail "a per-mate ledger error discarded the tick's pending wake (rc=$rc): $(cat "$out" "$dir/watch-mid-error.err")"
  grep -F 'check: secondmate sm2 auto-relaunched' "$out" >/dev/null \
    || fail "a mate after the ledger error was not recovered and surfaced: $(cat "$out" "$dir/watch-mid-error.err")"
  grep -F 'watcher: secondmate sm1 liveness: relaunch ledger is unreadable' "$dir/watch-mid-error.err" >/dev/null \
    || fail "the per-mate ledger error was not reported: $(cat "$dir/watch-mid-error.err")"
  [ "$(grep -c 'new-window' "$dir/tmux.log")" -eq 1 ] \
    || fail "exactly the healthy mate should have been relaunched: $(cat "$dir/tmux.log")"
  [ ! -s "$state/.secondmate-relaunch-sm1" ] \
    || fail "the errored mate gained ledger rows: $(cat "$state/.secondmate-relaunch-sm1")"
  [ "$(grep -c 'secondmate-relaunch-sm2-' "$state/.wake-queue")" -eq 1 ] \
    || fail "the healthy mate's relaunch row was not queued: $(cat "$state/.wake-queue")"
  pass "watch liveness: a per-mate error keeps scanning, recovers later mates, and still wakes"
}

test_secondmate_liveness_tick_unqueued_outcome_is_an_error_not_a_wake() {
  local dir state pid rc
  if [ "$(id -u)" -eq 0 ]; then
    pass "watch liveness: unqueued-outcome check skipped (root ignores file modes)"
    return 0
  fi
  dir=$(make_secondmate_liveness_case liveness-unqueued)
  state="$dir/state"
  : > "$state/.wake-queue"
  chmod 444 "$state/.wake-queue"
  run_liveness_leg "$dir" unqueued FM_FAKE_WINDOW_GONE=1; pid=$LIVENESS_PID
  rc=0
  wait_for_exit "$pid" 300 || rc=$?
  chmod 644 "$state/.wake-queue"
  [ "$rc" -eq 1 ] \
    || fail "an outcome whose check row was never queued did not fail the watcher (rc=$rc): $(cat "$dir/watch-unqueued.out" "$dir/watch-unqueued.err")"
  ! grep -F 'check: secondmate sm1 auto-relaunched' "$dir/watch-unqueued.out" >/dev/null \
    || fail "an unqueued outcome was printed as a delivered wake: $(cat "$dir/watch-unqueued.out")"
  grep -F 'watcher: secondmate sm1 liveness: check wake row could not be queued' "$dir/watch-unqueued.err" >/dev/null \
    || fail "the unqueued outcome was not reported as an error: $(cat "$dir/watch-unqueued.err")"
  pass "watch liveness: an outcome that could not be queued surfaces as an error, not a wake"
}

test_secondmate_liveness_tick_skips_mate_whose_lock_is_held() {
  local dir state pid holder
  dir=$(make_secondmate_liveness_case liveness-locked)
  state="$dir/state"

  # A concurrent liveness episode (e.g. the session-start sweep) holds the
  # per-mate lock; this tick must skip the mate entirely rather than probe a
  # moving target.
  ( STATE="$state" bash -c '. "$1" && fm_lock_acquire_wait "$2" && sleep 30' \
      _ "$ROOT/bin/fm-wake-lib.sh" "$state/.secondmate-liveness-sm1.lock" ) &
  holder=$!
  local i=0
  while [ ! -d "$state/.secondmate-liveness-sm1.lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -d "$state/.secondmate-liveness-sm1.lock" ] || fail "the fixture never acquired the liveness lock"

  run_liveness_leg "$dir" locked FM_FAKE_TMUX_CURRENT_COMMAND=zsh; pid=$LIVENESS_PID
  sleep 4
  is_live_non_zombie "$pid" \
    || fail "the watcher exited against a locked secondmate: $(cat "$dir/watch-locked.out" "$dir/watch-locked.err")"
  kill_liveness_leg "$pid"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ ! -s "$dir/tmux.log" ] || fail "a locked mate was probed or relaunched: $(cat "$dir/tmux.log")"
  [ ! -s "$state/.wake-queue" ] || fail "a locked mate queued a wake"
  pass "watch liveness: a mate mid-episode under the shared liveness lock is skipped entirely"
}

test_secondmate_liveness_tick_preserves_unreachable_remote() {
  local dir state
  dir=$(make_secondmate_liveness_case liveness-remote-down)
  state="$dir/state"
  rm -f "$state/sm1.meta"
  cat > "$state/rsm1.meta" <<EOF
window=remote:rsm1
kind=secondmate
harness=claude
remote_host=lab-host
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:w1:p1
home=/remote/rsm1-home
EOF
  cat > "$dir/data/secondmates.md" <<EOF
- rsm1 - Remote mate (host: lab-host; root: /remote/root; home: /remote/rsm1-home; scope: remote work; projects: alpha; added 2026-01-01)
EOF
  cp "$state/rsm1.meta" "$dir/rsm1.meta.before"
  cat > "$dir/fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_SSH_LOG:?}"
exit 255
SH
  chmod +x "$dir/fakebin/ssh"
  : > "$dir/ssh.log"

  run_liveness_leg "$dir" unreachable FM_SSH_BIN="$dir/fakebin/ssh" FM_FAKE_SSH_LOG="$dir/ssh.log"; pid=$LIVENESS_PID
  sleep 4
  is_live_non_zombie "$pid" \
    || fail "the watcher exited against an unreachable remote secondmate: $(cat "$dir/watch-unreachable.out" "$dir/watch-unreachable.err")"
  kill_liveness_leg "$pid"
  [ -s "$dir/ssh.log" ] || fail "the remote endpoint was never probed"
  cmp -s "$dir/rsm1.meta.before" "$state/rsm1.meta" \
    || fail "an unreachable remote probe changed the route metadata"
  assert_grep '- rsm1 ' "$dir/data/secondmates.md" "an unreachable probe changed the registry route"
  [ ! -s "$state/.wake-queue" ] || fail "an unreachable remote probe queued a wake"
  [ ! -e "$state/.secondmate-relaunch-rsm1" ] \
    || fail "an unreachable remote probe ledgered a relaunch attempt"
  [ ! -s "$dir/tmux.log" ] || fail "an unreachable remote probe touched a local endpoint"
  pass "watch liveness: an unreachable remote secondmate is probed, preserved, and never failed over"
}

test_self_held_lock_reclaims_instead_of_deadlocking
test_subshell_lock_ownership_without_bashpid
test_bounded_lock_handoff_after_contention
test_live_presentation_holder_is_deadlined_without_weakening_ack
test_malformed_presentation_lock_reports_acquire_failure
test_secondmate_foreign_queue_stall_tracks_progress_and_alerts_once
test_secondmate_declared_pause_rows_do_not_feed_stall_escalation
test_secondmate_reprovisioned_queue_starts_a_fresh_interval
test_secondmate_active_turn_defers_stall_until_the_turn_ends
test_secondmate_long_lived_mate_mid_turn_is_not_a_stall
test_secondmate_proven_idle_ring_lets_the_child_drain
test_secondmate_busy_and_unknown_panes_are_not_rung
test_secondmate_genuine_stall_after_idle_ring_still_alarms
test_secondmate_stall_marker_rejects_symlink
test_acknowledged_stall_publication_survives_pre_marker_crash
test_empty_prefix_mate_preserves_other_mate_receipt
test_self_announced_append_guards
test_separate_self_announced_answers_after_fold_are_owned
test_unreadable_status_is_not_owned
test_folded_worker_resolved_is_not_owned_lag
test_owned_growth_still_annotates_turn_ended
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
test_branch_ack_commits_secondmate_stall_receipts
test_main_is_never_told_to_drain_rows_only_the_branch_owns
test_uncountable_queue_still_raises_the_pending_alarm
test_unconsumable_rows_are_retired_instead_of_wedging_the_queue
test_branch_grant_refuses_rows_already_claimed_by_main
test_main_ack_leaves_a_row_that_arrived_after_its_drain_unclaimed
test_actor_filter_precedes_same_key_deduplication
test_main_reclaims_a_grant_whose_branch_owner_exited
test_branch_actor_without_eligible_snapshot_refuses
test_wake_publish_requires_atomic_recovery_evidence
test_legacy_generationless_wake_is_adopted
test_stale_recovery_generation_cannot_touch_a_newer_episode
test_stale_ack_that_consumes_nothing_names_the_current_wake
test_branch_stale_ack_that_consumes_nothing_names_its_granted_wake
test_recovery_ack_failure_is_reported
test_interruption_before_and_after_raw_commit
test_wake_queue_prune_task
test_secondmate_liveness_tick_relaunches_dead_endpoint_once
test_secondmate_liveness_tick_relaunches_missing_endpoint
test_secondmate_liveness_tick_relaunches_every_dead_mate_before_waking
test_secondmate_liveness_tick_leaves_alive_and_inconclusive_untouched
test_secondmate_liveness_tick_cadence_gates_the_probe
test_secondmate_liveness_tick_attempt_bound_parks_then_rearm_on_alive
test_secondmate_liveness_tick_relaunch_failure_reports_once
test_secondmate_liveness_tick_fails_closed_on_ledger_errors
test_secondmate_liveness_tick_error_keeps_scanning_and_wakes
test_secondmate_liveness_tick_unqueued_outcome_is_an_error_not_a_wake
test_secondmate_liveness_tick_skips_mate_whose_lock_is_held
test_secondmate_liveness_tick_preserves_unreachable_remote
