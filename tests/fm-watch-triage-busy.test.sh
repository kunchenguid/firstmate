#!/usr/bin/env bash
# Behavior tests for watcher busy-pane age, TERM cleanup, write-deferral,
# procevent, heartbeat/afk, and exit-picker paths (bin/fm-watch.sh). Shared
# fixtures live in tests/watch-triage-helpers.sh.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-busy-tests)

# --- held downtime-marker lock must not wedge a TERM'd watcher -------------
# fm-watch-triage-r1 flake (serial-1 CI): the EXIT cleanup publishes the
# downtime marker under .watcher-down.lock through an unbounded acquire, so a
# single TERM could strand the watcher inside its own trap for as long as a
# live foreign holder kept that lock - the observed watcher only died when a
# second TERM short-circuited the trap. The bounded cleanup acquire preserves
# the single-TERM stop; on timeout the publish is skipped and the singleton
# stays behind as ordinary dead-pid evidence for the next arm to clear.

# Start a watcher, hold its .watcher-down.lock from a live foreign subshell,
# and send exactly one TERM. Without <release-ticks> the lock stays held until
# the watcher exits. With it, the watcher runs as a handling successor, whose
# poll loop never takes the marker lock, and the holder arms FIFOs as its pid
# record before the TERM. Only the TERM'd watcher's cleanup reads them, and a
# second read comes only from a retry after a completed failed acquire, so that
# read marks real contention in $dir/marker-lock-contended; the holder then
# frees the lock <release-ticks> tenths of a second later. The caller's environment
# reaches the watcher; its wait_for_exit code lands in HELD_MARKER_LOCK_RC.
term_watcher_with_held_marker_lock() {  # <dir> [release-ticks]
  local dir=$1 release_ticks=${2:-} successor=0 state fakebin out capture_file window sig pid holder i
  state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-held-marker-lock"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/heldlock.meta"
  printf 'working: implementing\n' > "$state/heldlock.status"
  sig=$(seen_sig "$state/heldlock.status"); printf '%s' "$sig" > "$state/.seen-heldlock_status"
  [ -z "$release_ticks" ] || successor=1
  FM_WATCH_HANDLING_SUCCESSOR=$successor \
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the marker-lock watcher never completed a poll: $(cat "$out")"
  fi
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1" || exit 1
    lock=$2 held=$3 release=$4 contended=$5 release_ticks=$6
    fm_lock_acquire_wait_max "$lock" 5 || exit 1
    if [ -n "$release_ticks" ]; then
      record="$(fm_lock_link_owner "$lock")/pid"
      mkfifo "$record.fifo" "$record.retry" && mv -f "$record.fifo" "$record" || exit 1
      (
        exec 3> "$record"
        mv -f "$record.retry" "$record"
        printf "%s\n" "$$" >&3
        exec 3>&-
        exec 3> "$record"
        printf "%s\n" "$$" > "$record.next" && mv -f "$record.next" "$record"
        printf "%s\n" "$$" >&3
        exec 3>&-
        : > "$contended"
      ) &
      writer=$!
      : > "$held"
      i=0
      while [ ! -e "$contended" ] && [ ! -e "$release" ] && [ "$i" -lt 600 ]; do
        sleep 0.1
        i=$((i + 1))
      done
      if [ -e "$contended" ]; then
        wait "$writer"
      else
        while kill -0 "$writer" 2>/dev/null; do
          cat "$record" > /dev/null
        done
        wait "$writer"
        rm -f "$contended"
      fi
      i=0
      while [ "$i" -lt "$release_ticks" ]; do
        sleep 0.1
        i=$((i + 1))
      done
    else
      : > "$held"
      i=0
      while [ ! -e "$release" ] && [ "$i" -lt 600 ]; do
        sleep 0.1
        i=$((i + 1))
      done
    fi
    fm_lock_release "$lock"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down.lock" "$dir/marker-lock-held" \
    "$dir/release-marker-lock" "$dir/marker-lock-contended" \
    "$release_ticks" &
  holder=$!
  i=0
  while [ ! -e "$dir/marker-lock-held" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -e "$dir/marker-lock-held" ]; then
    kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
    reap "$pid"; fail "the fixture could not take the downtime-marker lock"
  fi
  kill "$pid" 2>/dev/null || true
  wait_for_exit "$pid" 100
  HELD_MARKER_LOCK_RC=$?
  : > "$dir/release-marker-lock"
  wait "$holder" 2>/dev/null || true
  HELD_MARKER_LOCK_PID=$pid
}

# --- process-event delivery -------------------------------------------------
# A durably captured process-event result publishes an ordinary `check` wake on
# the durable queue. The watcher must deliver that queued wake proactively -
# print an actionable reason and exit into the same rewake path every other
# actionable wake uses - rather than leaving it to be found by a manual drain.

# Run the runner against a case home. FM_ROOT_OVERRIDE (exported by the shared
# wake harness to keep the drain's tangle check inert) would otherwise point the
# runner at a root with no installed adapters, and the claim root must stay
# inside the case so nothing here can observe a real home's source ownership.
pe_case() {  # <dir> <command>...
  local dir=$1
  dir=$(cd "$dir" && pwd -P) || return 1
  shift
  (unset FM_ROOT_OVERRIDE
   FM_PROCEVENT_CLAIM_ROOT="$dir/claims" FM_HOME="$dir" "$ROOT/bin/fm-procevent.sh" "$@")
}

# Capture one real process-event result into <dir>'s home, then retire the
# source so the fixture holds exactly the reported end state: one durably
# captured, unhandled, queued result and no remaining poll work.
seed_captured_procevent_result() {  # <dir>
  local dir=$1 i=0
  pe_case "$dir" register lavish delivery-src -- \
    /bin/sh -c 'printf "session:\n  file: /a.html\n  status: waiting\n"' >/dev/null || return 1
  pe_case "$dir" reconcile >/dev/null || return 1
  while [ "$i" -lt 100 ]; do
    [ -s "$dir/state/.wake-queue" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  # The runner publishes that wake BEFORE it releases its claim and exits, so a
  # retire that lands in that gap reads the exiting runner's ownership as
  # uncertain and refuses with "cannot confirm runner identity" - the pipeline
  # saw exactly that under load. Wait, bounded, for the release the publish
  # promises, so retire meets a source nothing owns instead of racing the
  # runner's last milliseconds. The bound keeps a runner that never releases a
  # real failure at retire rather than a hang here.
  i=0
  while [ "$i" -lt 100 ]; do
    [ -e "$dir/claims/delivery-src.claim" ] || break
    sleep 0.1
    i=$((i + 1))
  done
  pe_case "$dir" retire delivery-src >/dev/null || return 1
  [ -s "$dir/state/.wake-queue" ]
}

# The watcher, scoped by FM_HOME rather than FM_STATE_OVERRIDE, so the
# per-cycle reconcile it launches resolves the same home's state.
procevent_watch_bg() {  # <dir> <out>
  local dir=$1 out=$2
  dir=$(cd "$dir" && pwd -P) || return 1
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
}

# The reason line is the headline firstmate reads before the payload. Every
# procevent:* key used to surface as "process-event result captured", which
# presents a source that is collecting NOTHING as a healthy capture - the exact
# shape of the incident these wakes exist to expose. These assertions read the
# reason the watcher actually printed, so a typo in either classifying glob
# fails here instead of silently falling back to the healthy-looking headline.
surface_once() {  # <dir> <out> [limit-ticks]: run one watcher to its wake, return its status
  local dir=$1 out=$2 limit=${3:-100} pid
  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" "$limit"
}

install_marker_mv_fault() {  # <dir>
  local dir=$1
  REAL_MV=$(command -v mv)
  export REAL_MV
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
dest=${!#}
case "$dest" in
  */.seen-procevent-*)
    case "${FM_MARKER_MV_MODE:-}" in
      pause)
        printf '1\n' > "$FM_MARKER_MV_READY"
        while [ ! -e "$FM_MARKER_MV_RELEASE" ]; do sleep 0.02; done
        ;;
      kill-before) kill -KILL "$PPID"; exit 1 ;;
      kill-after) "$REAL_MV" "$@" || exit; kill -KILL "$PPID"; exit 1 ;;
      fail) exit 1 ;;
    esac
    ;;
esac
exec "$REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
}


# --- a stop request is honored mid-poll --------------------------------------
# Every stopper (the arm's signal path, the away-mode daemon, reap above) waits
# for the watcher to exit after one TERM, so TERM must end it through its EXIT
# cleanup at any point of a poll. A TERM trap body cannot promise that: bash
# defers it until the blocked command returns, and bash 5.2 can drop it outright
# when it is pending as a command substitution is parsed, which left CI watchers
# polling after reap until the job timed out. The pane capture here blocks on a
# FIFO whose writer never writes, so only a TERM honored mid-poll stops the
# watcher inside the bound; the released lock and acknowledgeable stop record
# prove its cleanup still ran.
test_term_stops_a_watcher_blocked_inside_a_poll() {
  local dir state fakebin out fifo window sig pid holder i rc
  dir=$(make_case term-blocked-poll); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; fifo="$dir/pane.fifo"; window="test:fm-blocked-capture"
  mkfifo "$fifo"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/blocked.meta"
  printf 'working: implementing\n' > "$state/blocked.status"
  sig=$(seen_sig "$state/blocked.status"); printf '%s' "$sig" > "$state/.seen-blocked_status"
  # Opening the write end waits for the capture to open the read end, and the
  # holder then keeps it open without writing, so that capture blocks mid-poll.
  ( exec 3> "$fifo"; : > "$dir/capture-blocked"; exec sleep 30 ) &
  holder=$!
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$fifo" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ ! -e "$dir/capture-blocked" ] && [ "$i" -lt 300 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -e "$dir/capture-blocked" ] || ! is_live_non_zombie "$pid"; then
    kill "$holder" 2>/dev/null || true; reap "$pid"
    fail "the watcher never blocked inside its pane capture: $(cat "$out")"
  fi
  kill "$pid" 2>/dev/null || true
  wait_for_exit "$pid" 100
  rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -ne 124 ] || fail "TERM did not stop a watcher blocked inside a poll"
  [ ! -e "$state/.watch.lock" ] || fail "a watcher stopped mid-poll kept its singleton lock, so its cleanup did not run"
  ack_stopped_cycle "$state" || fail "could not acknowledge the stop of a watcher blocked inside a poll"
  pass "TERM stops a watcher blocked inside a poll and still runs its cleanup"
}

test_term_stops_a_watcher_whose_cleanup_marker_lock_is_held() {
  local dir state
  dir=$(make_case term-held-marker-lock); state="$dir/state"
  # A live foreign holder keeps .watcher-down.lock across the TERM, so the
  # watcher's EXIT cleanup can only finish by out-waiting its bounded acquire
  # rather than spinning on the marker lock forever.
  term_watcher_with_held_marker_lock "$dir"
  [ "$HELD_MARKER_LOCK_RC" -ne 124 ] \
    || fail "TERM did not stop a watcher whose downtime-marker lock was held"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$HELD_MARKER_LOCK_PID" ] \
    || fail "a watcher whose marker publish timed out lost its stale singleton evidence"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1" && fm_recovery_transition "$2" clear-stale-lock "$3" downtime
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" "$state/.watch.lock" \
    || fail "the retained singleton did not clear once the marker lock freed"
  [ ! -e "$state/.watch.lock" ] \
    || fail "the stale singleton survived its clear-stale-lock"
  ack_stopped_cycle "$state" \
    || fail "could not acknowledge the stop after the marker lock freed"
  pass "TERM stops a watcher whose downtime-marker lock is held, retaining stale evidence"
}

# The cleanup bound is decimal seconds: a zero spelled with leading zeros falls
# back to the 2s default instead of giving up at its first contended attempt,
# so it retries after that failed attempt, and a leading-zero value such as 08
# is an 8s bound rather than an invalid octal literal or the 2s default, so it
# still outwaits a marker lock freed 3s after the cleanup's contended retry.
test_cleanup_marker_lock_bound_is_decimal_with_zero_default() {
  local bound ticks dir state
  for bound in 00:0 08:30; do
    ticks=${bound#*:}; bound=${bound%%:*}
    dir=$(make_case "term-marker-lock-bound-$bound"); state="$dir/state"
    FM_WATCHER_CLEANUP_LOCK_BOUND=$bound term_watcher_with_held_marker_lock "$dir" "$ticks"
    [ "$HELD_MARKER_LOCK_RC" -ne 124 ] \
      || fail "TERM did not stop a watcher with cleanup lock bound $bound"
    [ -e "$dir/marker-lock-contended" ] \
      || fail "cleanup lock bound $bound never contended on the held marker lock"
    [ ! -e "$state/.watch.lock" ] \
      || fail "cleanup lock bound $bound gave up before the marker lock freed"
    ack_stopped_cycle "$state" \
      || fail "could not acknowledge the stop under cleanup lock bound $bound"
  done
  pass "the cleanup marker-lock bound is decimal and zero falls back to the default"
}

# --- busy pane duration bound: a completed-turn age gate on top of busy -----
# 2026-07 hibit-agent-focus-nonsteal-r1 incident: a busy pane (herdr "working"
# and/or the harness's rendered busy footer) is unconditional, unbounded proof
# of liveness in every existing classifier, so a genuinely hung foreground tool
# call behind a busy signature ran undetected for 25h. BUSY_TURN_MAX_SECS bounds
# how long a busy pane may run with no completed turn (state/<id>.turn-ended, or
# the task's spawn record before any turn completes); past the bound, panes
# without a declared external wait or verified captain-held transfer take the
# SAME wedge_timer_check already used for a provably-working non-busy stale.
# Escalation reuses the identical stale reason, escalation counter, and
# demand-deep-inspection marker - never an
# automatic interrupt or restart.

test_busy_pane_below_turn_age_bound_is_absorbed() {
  local dir state fakebin out capture_file window key sig pid
  dir=$(make_case busy-below-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-fresh"
  printf 'Working... (12.3s)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-fresh.meta"
  record_pi_busy "$state" busy-fresh
  printf 'working: setup complete\n' > "$state/busy-fresh.status"
  sig=$(seen_sig "$state/busy-fresh.status"); printf '%s' "$sig" > "$state/.seen-busy-fresh_status"
  key=$(watch_window_key "$window")
  touch "$state/busy-fresh.turn-ended"
  prime_turnend_seen "$state/busy-fresh.turn-ended"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=999 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a busy pane below the turn-age bound was escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a busy pane below the turn-age bound printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "a busy pane below the turn-age bound started a wedge timer"
  reap "$pid"
  pass "a busy worker below the turn-age bound remains working with no escalation"
}

test_busy_pane_stable_hash_escalates_past_turn_age_bound() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-stable-hash-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-stable"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-stable.meta"
  record_pi_busy "$state" busy-stable
  printf 'working: setup complete\n' > "$state/busy-stable.status"
  sig=$(seen_sig "$state/busy-stable.status"); printf '%s' "$sig" > "$state/.seen-busy-stable_status"
  key=$(watch_window_key "$window")
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No completed turn ever recorded for this task: age the spawn record itself.
  touch -t 200001010000 "$state/busy-stable.meta"

  # Phase A: past the bound, the stable-hash busy pane is absorbed but starts
  # the wedge timer (mirrors the existing provably-working-stale Phase A/B).
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a stable-hash busy pane past the turn-age bound escalated before the wedge threshold: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a stable-hash busy pane past the turn-age bound did not start a wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional stable-hash phase-A stop"

  # Phase B: backdate the wedge timer past the threshold; the next poll escalates.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a stable-hash busy pane did not wedge-escalate past the turn-age bound"
  grep -F "stale: $window" "$out" >/dev/null || fail "busy turn-age escalation did not print the stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "busy turn-age escalation did not flag a possible wedge"
  pass "a busy worker with a stable pane hash still escalates once its completed-turn age reaches the bound"
}

# Regression fixture for the incident's actual masking condition: Pi's rendered
# elapsed-time footer changes every poll, so the pane hash never repeats and the
# watcher always takes the "new hash" branch, never the stable-hash one above.
test_busy_pane_changing_hash_escalates_past_turn_age_bound() {
  local dir state fakebin out capture_file window key pid
  dir=$(make_case busy-changing-hash-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-ticking"
  printf 'Working... (3600.1s)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-ticking.meta"
  record_pi_busy "$state" busy-ticking
  printf 'working: setup complete\n' > "$state/busy-ticking.status"
  sig=$(seen_sig "$state/busy-ticking.status"); printf '%s' "$sig" > "$state/.seen-busy-ticking_status"
  key=$(watch_window_key "$window")
  touch -t 200001010000 "$state/busy-ticking.meta"
  # No pre-seeded .hash-<key>: with a real ticking elapsed footer, every poll
  # lands here (h != prev) - the reproduction's actual masking condition.

  # Phase A: first sight past the bound absorbs and starts the wedge timer,
  # without ever needing the "genuinely stale" hash-match path.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a changing-hash busy pane past the turn-age bound escalated before the wedge threshold: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a changing-hash busy pane past the turn-age bound did not start a wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional changing-hash phase-A stop"

  # Phase B: another tick (still a fresh, never-before-seen hash) plus a
  # backdated wedge timer escalates exactly as the stable-hash case does.
  printf 'Working... (3601.2s)' > "$capture_file"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a changing-hash busy pane did not wedge-escalate past the turn-age bound"
  grep -F "stale: $window" "$out" >/dev/null || fail "busy turn-age escalation (changing hash) did not print the stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "busy turn-age escalation (changing hash) did not flag a possible wedge"
  pass "a busy worker whose pane hash changes every poll still escalates once its completed-turn age reaches the bound"
}

test_busy_pane_turn_end_touch_resets_age() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-turn-end-resets-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-reset"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-reset.meta"
  record_pi_busy "$state" busy-reset
  printf 'working: setup complete\n' > "$state/busy-reset.status"
  sig=$(seen_sig "$state/busy-reset.status"); printf '%s' "$sig" > "$state/.seen-busy-reset_status"
  key=$(watch_window_key "$window")
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # A wedge is already mid-escalation, as if several over-age polls already ran.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '1\n' > "$state/.wedge-escalations-$key"
  # The worker's most recent turn just completed: touching turn-ended resets age.
  touch "$state/busy-reset.turn-ended"
  prime_turnend_seen "$state/busy-reset.turn-ended"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=3600 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a freshly completed turn on a busy pane was still escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a freshly completed turn on a busy pane printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "a freshly completed turn did not clear the wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a freshly completed turn did not clear the escalation counter"
  reap "$pid"
  pass "touching a busy worker's completed-turn marker resets the age and prevents an old-age escalation"
}

test_busy_pane_native_progress_resets_age() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-native-progress-resets-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-reset"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-reset.meta"
  record_pi_busy "$state" busy-reset
  printf 'working: setup complete\n' > "$state/busy-reset.status"
  sig=$(seen_sig "$state/busy-reset.status"); printf '%s' "$sig" > "$state/.seen-busy-reset_status"
  key=$(watch_window_key "$window")
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # A wedge is already mid-escalation, as if several over-age polls already ran.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '1\n' > "$state/.wedge-escalations-$key"
  # The worker has progressed without completing its long native turn.
  touch "$state/busy-reset.progress"
  touch -t 200001010000 "$state/busy-reset.meta"
  touch -t 200001010000 "$state/busy-reset.turn-ended"
  prime_turnend_seen "$state/busy-reset.turn-ended"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=3600 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a fresh native activity on a busy pane was still escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a fresh native activity on a busy pane printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "a fresh native activity did not clear the wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a fresh native activity did not clear the escalation counter"
  reap "$pid"
  pass "native progress resets busy age without a completed turn or notification"
}

test_busy_pane_repeated_escalation_reaches_demand_deep_inspection() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case busy-turn-age-demand-inspect); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-demand-inspect"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-demand.meta"
  record_pi_busy "$state" busy-demand
  printf 'working: setup complete\n' > "$state/busy-demand.status"
  sig=$(seen_sig "$state/busy-demand.status"); printf '%s' "$sig" > "$state/.seen-busy-demand_status"
  key=$(watch_window_key "$window")
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  touch -t 200001010000 "$state/busy-demand.turn-ended"
  prime_turnend_seen "$state/busy-demand.turn-ended"

  # Priming round: first sighting past the turn-age bound absorbs and starts
  # the wedge timer, mirroring the existing provably-working wedge tests.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "priming round for busy turn-age escalation was not absorbed: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional busy-wedge priming stop"

  n=1
  while [ "$n" -le 3 ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || fail "busy turn-age escalation round $n did not escalate: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "busy turn-age round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "busy turn-age round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "busy turn-age round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    ack_stopped_cycle "$state" || fail "could not acknowledge busy turn-age escalation round $n"
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "busy turn-age escalation counter did not persist across consecutive rounds"
  pass "repeated busy turn-age escalations reuse the existing escalation counter and demand deep inspection at the threshold"
}

# --- declared pause + busy pane: the busy-turn bound must honor the declaration
# A single foreground call can keep a declared external wait semantically busy
# past the completed-turn bound, bypassing the ordinary stale-pause path.
# This fixture pins all three halves of the contract: the declared pause is
# absorbed instead of wedged (A), it is still rechecked on the long
# PAUSE_RESURFACE_SECS cadence so a forgotten wait cannot rot invisibly (B), and
# lifting the declaration on the SAME busy over-age pane restores the wedge
# escalation, proving the discriminator is the worker's own declaration and not a
# blanket silencing of the escalator (C).
test_busy_declared_pause_is_rechecked_not_wedge_escalated() {
  local dir state fakebin out capture_file window key sig pid statusf back
  dir=$(make_case busy-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-review-scout"
  statusf="$state/review-scout.status"
  printf 'Working... (7200.4s) lavish-axi poll' > "$capture_file"
  printf 'window=%s\nkind=scout\nharness=pi\n' "$window" > "$state/review-scout.meta"
  record_pi_busy "$state" review-scout
  printf 'paused: hosting the Lavish review, awaiting captain feedback\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-review-scout_status"
  key=$(watch_window_key "$window")
  # No completed turn for hours (the single blocking poll call): age the spawn
  # record itself, exactly as the never-completed-a-turn fixtures above do.
  touch -t 200001010000 "$state/review-scout.meta"
  # No pre-seeded .hash-<key>: a live harness footer ticks, so every poll lands
  # on the changed-hash branch - the review scout's real masking condition.

  # Phase A: past the bound, with the wedge threshold set as low as it goes, the
  # declared pause is absorbed on the long cadence and never starts a wedge.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "a declared pause on a busy review pane was escalated: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "a declared pause on a busy review pane printed a wake reason: $(cat "$out")"
  [ -e "$state/.paused-$key" ] || fail "the busy-turn bound did not apply the declared-pause cadence"
  [ ! -e "$state/.stale-since-$key" ] || fail "a declared pause on a busy pane started the wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a declared pause on a busy pane incremented the escalation counter"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional declared-pause phase-A stop"

  # Phase B: age the pause past the (now normal) long cadence and let the pane
  # settle on one stable hash, so the still-busy pane takes the repeat-hash
  # branch whose pause bookkeeping the bound must not wipe. It re-surfaces once
  # as a recheck, never as a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-review-scout_status"
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=240 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a declared pause past the long cadence was never rechecked"; }
  grep -F "awaiting external" "$out" >/dev/null || fail "the recheck was not labeled a declared-pause recheck: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause on a busy pane was mislabeled a possible wedge: $(cat "$out")"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the declared-pause re-surface throttle was cleared by the busy-turn bound"
  [ ! -e "$state/.stale-since-$key" ] || fail "a declared-pause recheck used the wedge timer"
  ack_stopped_cycle "$state" || fail "could not acknowledge the declared-pause recheck"

  # Phase C: the pause is lifted on the SAME busy, over-age pane. Nothing else
  # changes, so a still-absorbed pane here would mean the bound was silenced
  # rather than taught the declaration. It must wedge-escalate exactly as before.
  printf 'working: review closed, resuming the sweep\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-review-scout_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "a lifted pause escalated before the wedge threshold: $(cat "$out")"; }
  reap "$pid"
  [ -s "$state/.stale-since-$key" ] || fail "a lifted pause did not restore the busy-turn wedge timer"
  [ ! -e "$state/.paused-$key" ] || fail "a lifted pause left stale declared-pause bookkeeping behind"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional lifted-pause priming stop"

  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a lifted pause on an over-age busy pane no longer wedge-escalates"; }
  grep -F "possible wedge" "$out" >/dev/null || fail "the restored busy-turn escalation did not flag a possible wedge: $(cat "$out")"
  pass "a busy pane under a declared pause is rechecked on the long cadence, and lifting the pause restores the wedge escalation"
}

# --- declared pause + busy pane + AWAY MODE: the bound must hand off, not decorate
# Away mode is daemon-owned: the watcher reverts to one-shot and lets the daemon
# classify. The busy-turn bound used to be the one stale path that ignored that,
# running the wedge timer under afk and handing the daemon a wake already decorated
# as a possible wedge. That decoration outranks the daemon's own pause verdict, so a
# crew that declared the wait itself was wedge-escalated once per
# FM_STALE_ESCALATE_SECS for as long as the wait lasted, with the escalation count
# climbing into demand-deep-inspection on a pane nobody needed to inspect.
# Phase A pins the handoff: the plain window identity, no wedge timer, no escalation
# counter, and no normal-mode pause bookkeeping (the daemon owns that in away mode).
# Phase B re-arms on the same unchanged pane and pins the one-shot: a second wake
# here is what the climbing ladder looked like. Phase C drives the discriminator
# apart on the SAME afk, busy, over-age pane - lifting the declaration restores the
# wedge escalation, so this is the worker's declaration being honored rather than
# away mode silencing the escalator.
test_afk_busy_declared_pause_hands_off_plain_stale() {
  local dir state fakebin out capture_file window key sig pid statusf
  dir=$(make_case afk-busy-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-afk-review-scout"
  statusf="$state/afk-review-scout.status"
  printf 'Working... (7200.4s) lavish-axi poll' > "$capture_file"
  printf 'window=%s\nkind=scout\nharness=pi\n' "$window" > "$state/afk-review-scout.meta"
  record_pi_busy "$state" afk-review-scout
  printf 'paused: hosting the Lavish review, awaiting captain feedback\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-review-scout_status"
  key=$(watch_window_key "$window")
  touch -t 200001010000 "$state/afk-review-scout.meta"
  date '+%s' > "$state/.afk"

  # Phase A: past the bound, with the wedge threshold as low as it goes, the
  # declaration is handed to the daemon undecorated instead of being wedge-timed.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 150 || { reap "$pid"; fail "the away-mode busy-turn bound never handed the declared pause to the daemon"; }
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "the away-mode busy-turn bound did not hand off the plain window identity: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "away mode decorated a declared pause as a possible wedge: $(cat "$out")"
  [ ! -e "$state/.stale-since-$key" ] \
    || fail "the away-mode handoff started the wedge timer on a declared pause"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the away-mode handoff incremented the wedge escalation count on a declared pause"
  [ ! -e "$state/.paused-$key" ] \
    || fail "the away-mode handoff recorded normal-mode pause tracking instead of leaving it to the daemon"
  ack_stopped_cycle "$state" || fail "could not acknowledge the away-mode declared-pause handoff"

  # Phase B: re-arm on the same unchanged pane. The bound has already handed this
  # stale hash off, so it must stay silent rather than re-waking the daemon - a
  # second wake here is the escalation ladder the wedge timer used to climb.
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "the away-mode bound re-woke on an already-handed-off declared pause: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "the away-mode bound re-surfaced an already-handed-off declared pause: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "re-arming on an unchanged declared pause started a wedge escalation ladder"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional away-mode re-arm stop"

  # Phase C: lift the declaration on the SAME afk, busy, over-age pane. Nothing else
  # changes, so a wedge escalation here proves the declaration was the discriminator.
  printf 'working: resumed the review write-up\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-review-scout_status"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 150 || { reap "$pid"; fail "a lifted pause on an away-mode over-age busy pane no longer wedge-escalates"; }
  grep -F "possible wedge" "$out" >/dev/null \
    || fail "the restored away-mode busy-turn escalation did not flag a possible wedge: $(cat "$out")"
  pass "away mode hands a busy declared pause to the daemon as a plain stale, and lifting the declaration restores the wedge escalation"
}

# --- declared pause + busy pane + AWAY MODE + a TICKING footer: one wake per declaration
# The static-pane case above cannot tell a hash-keyed one-shot from a
# declaration-keyed one, because its capture never changes between polls. The
# incident pane's harness footer ticks on every capture, so a one-shot keyed on the
# pane hash re-fires on every poll, and the daemon, which relaunches the watcher
# after each handled wake, is woken in a loop for the whole declared wait. This
# fixture's fake tmux renders a fresh footer on EVERY capture-pane and asserts that
# divergence outright on every re-arm (.hash-<key> moves, .count-<key> never
# climbs), so the one-wake assertion across five silent re-arms cannot pass
# vacuously on a pane that happened to sit still. Round 1 also starts from an
# undeclared wedge timer and escalation count, which the handoff must clear the
# way the normal-mode absorber does, so lifting the declaration later starts the
# wedge path from a fresh timer rather than resuming a stale count.
test_afk_busy_declared_pause_ticking_pane_hands_off_once() {
  local dir state fakebin out drain_out window key sig pid statusf ticks round prev_hash cur_hash prev_ticks
  dir=$(make_case afk-busy-declared-pause-ticking); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; window="test:fm-afk-ticking-scout"
  statusf="$state/afk-ticking-scout.status"; ticks="$dir/ticks"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"
    exit 0 ;;
  capture-pane)
    n=$(( $(cat "$FM_FAKE_TMUX_TICKS" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$FM_FAKE_TMUX_TICKS"
    printf 'Working... (%d.%ds) lavish-axi poll' "$(( 7200 + n ))" "$(( n % 10 ))"
    exit 0 ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;;
    esac ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf 'window=%s\nkind=scout\nharness=pi\n' "$window" > "$state/afk-ticking-scout.meta"
  record_pi_busy "$state" afk-ticking-scout
  printf 'paused: hosting the Lavish review, awaiting captain feedback\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-ticking-scout_status"
  key=$(watch_window_key "$window")
  touch -t 200001010000 "$state/afk-ticking-scout.meta"
  date '+%s' > "$state/.afk"
  # An undeclared busy phase already ran the wedge timer and escalated twice
  # before the crew declared the wait.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '2\n' > "$state/.wedge-escalations-$key"
  date +%s > "$state/.writing-since-$key"

  # Round 1: the declaration is handed off once, undecorated, and the undeclared
  # phase's wedge bookkeeping is cleared with it.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_TICKS="$ticks" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 150 || { reap "$pid"; fail "the away-mode busy-turn bound never handed a ticking declared pause to the daemon"; }
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "the away-mode busy-turn bound did not hand off the plain window identity for a ticking pane: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "away mode decorated a ticking declared pause as a possible wedge: $(cat "$out")"
  [ ! -e "$state/.stale-since-$key" ] \
    || fail "the away-mode handoff left the undeclared phase's wedge timer in place"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the away-mode handoff left the undeclared phase's escalation count in place"
  [ ! -e "$state/.writing-since-$key" ] \
    || fail "the away-mode handoff left the undeclared phase's write-deferral chain in place"
  [ ! -e "$state/.paused-$key" ] \
    || fail "the away-mode handoff recorded normal-mode pause tracking on a ticking pane"
  ack_stopped_cycle "$state" || fail "could not acknowledge the ticking declared-pause handoff"

  # Rounds 2-6: five consecutive re-arms on the same standing declaration. Every
  # capture renders a new footer, so every poll lands on the changed-hash branch -
  # the exact shape a hash-keyed one-shot re-fires on. Each round proves the pane
  # really moved before it asserts silence, so the case cannot go vacuous.
  round=2
  while [ "$round" -le 6 ]; do
    prev_hash=$(cat "$state/.hash-$key" 2>/dev/null || true)
    prev_ticks=$(cat "$ticks" 2>/dev/null || echo 0)
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_TICKS="$ticks" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
      FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
      FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "re-arm $round on a ticking declared pause re-woke the daemon: $(cat "$out")"; }
    reap "$pid"
    cur_hash=$(cat "$state/.hash-$key" 2>/dev/null || true)
    [ "$(cat "$ticks" 2>/dev/null || echo 0)" -gt "$prev_ticks" ] \
      || fail "re-arm $round never captured the pane, so its silence proves nothing"
    [ -n "$cur_hash" ] && [ "$cur_hash" != "$prev_hash" ] \
      || fail "re-arm $round saw the same pane hash as the round before, so it cannot tell a hash-keyed one-shot from a declaration-keyed one"
    [ "$(cat "$state/.count-$key" 2>/dev/null || echo missing)" = 0 ] \
      || fail "re-arm $round settled on a stable hash instead of ticking on every poll"
    [ ! -s "$out" ] || fail "re-arm $round re-surfaced a standing declared pause on a ticking pane: $(cat "$out")"
    [ ! -e "$state/.stale-since-$key" ] \
      || fail "re-arm $round started the wedge timer on a standing declared pause"
    [ ! -e "$state/.wedge-escalations-$key" ] \
      || fail "re-arm $round climbed the wedge escalation ladder on a standing declared pause"
    ack_stopped_cycle "$state" || fail "could not acknowledge the intentional re-arm $round stop"
    round=$((round + 1))
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || true
  grep "$(printf '\tstale\t')" "$drain_out" >/dev/null \
    && fail "the silent re-arms still queued a stale row for the standing declaration: $(cat "$drain_out")"
  pass "away mode wakes the daemon once per declaration for a busy pane whose footer ticks on every capture"
}

# Behavioral proof that the production default (no FM_BUSY_TURN_MAX_SECS override
# anywhere in this env) is 3600s: a completed turn 5 minutes old must not start a
# wedge timer, while one 66 minutes old must - bracketing the default around 3600
# without waiting a literal hour.
test_busy_pane_default_turn_age_bound_is_3600s() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-default-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-default"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-default.meta"
  record_pi_busy "$state" busy-default
  printf 'working: setup complete\n' > "$state/busy-default.status"
  sig=$(seen_sig "$state/busy-default.status"); printf '%s' "$sig" > "$state/.seen-busy-default_status"
  key=$(watch_window_key "$window")
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  set_mtime $(( $(date +%s) - 300 )) "$state/busy-default.turn-ended"
  prime_turnend_seen "$state/busy-default.turn-ended"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a 5-minute-old completed turn tripped the default busy-turn-age bound: $(cat "$out")"
  fi
  [ ! -e "$state/.stale-since-$key" ] || fail "a 5-minute-old completed turn started a wedge timer under the default bound"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional five-minute-bound stop"

  set_mtime $(( $(date +%s) - 4000 )) "$state/busy-default.turn-ended"
  prime_turnend_seen "$state/busy-default.turn-ended"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a 66-minute-old completed turn escalated before the wedge threshold under the default bound: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a 66-minute-old completed turn did not start a wedge timer under the default bound (default is not 3600s)"
  reap "$pid"
  pass "the production default busy-turn-age bound is 3600s (5min under does not wedge, 66min over does)"
}

test_nonterminal_stale_repairs_missing_or_corrupt_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case nonterminal-stale-timer-repair); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet-timer"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet-timer.meta"
  printf 'working: still compiling\n' > "$state/quiet-timer.status"
  sig=$(seen_sig "$state/quiet-timer.status"); printf '%s' "$sig" > "$state/.seen-quiet-timer_status"
  key=$(watch_window_key "$window")
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with missing timer did not initialize stale-since"; }
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    fail "watcher exited while repairing a missing stale-since timer: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "missing stale-since repair enqueued a wake"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional missing-timer repair stop"

  printf 'corrupt\n' > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with corrupt timer did not repair stale-since"; }
  since=$(cat "$state/.stale-since-$key" 2>/dev/null || true)
  [ "$since" != "corrupt" ] || { reap "$pid"; fail "corrupt stale-since value was left in place"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "corrupt stale-since repair enqueued a wake"; }
  reap "$pid"
  pass "matching non-terminal stale suppressors repair missing or corrupt stale-since timers"
}

# --- quiet pane, worktree still being written: deferred, never wedge-escalated -
# The live 2026-08-14 case: one crew produced eight consecutive possible-wedge
# escalations in an afternoon, three of them demanding deep inspection, while it
# was demonstrably writing source, then tests, then documentation. The detector's
# two inputs (pane quietness, run step) cannot see that, so the pane looks frozen.
# Both halves of the contract are asserted on the SAME fixture, because the whole
# point is that only the worktree evidence differs: writing defers, silent
# escalates on the unchanged schedule.
# Every wait below is the file's standard one (wait_poll_cycle for an absorbing
# watcher, a 100-tick wait_for_exit for an escalating one), because the poll these
# tests assert on is the ONE poll that spawns the bounded worktree walk: on a
# loaded runner it outlives a fixed liveness budget, and a round reaped before it
# finished reports a lost deferral instead of the deferral under test.
test_wedge_escalation_deferred_while_worktree_is_written() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid wt back
  dir=$(make_case wedge-worktree-writes); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-writing"; wt="$dir/wt"
  mkdir -p "$wt/src"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/writing.meta"
  printf 'working: implementing\n' > "$state/writing.status"
  sig=$(seen_sig "$state/writing.status"); printf '%s' "$sig" > "$state/.seen-writing_status"
  key=$(watch_window_key "$window")
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Already-classified hash with an idle window that opened 500s ago, so the very
  # first stale poll lands straight on the at-threshold wedge branch (this repeat
  # path never re-reads crew state, so the worktree evidence is the only input
  # that can change the outcome).
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"

  # Phase A: the crew wrote a file after the idle window opened. Deferred.
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher wedge-escalated a quiet pane whose worktree was being written: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a written-worktree deferral printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a written-worktree deferral enqueued a wake"; }
  [ -e "$state/.writing-since-$key" ] || { reap "$pid"; fail "the write-deferral chain marker was not recorded"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "a deferral advanced the wedge escalation counter"; }
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || echo 0)" -gt "$back" ] \
    || { reap "$pid"; fail "a deferral did not restart the idle timer, so the next window cannot re-probe"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: same fixture, same quiet pane, but nothing written during this idle
  # window (the crew really is stalled). The unchanged schedule must still fire.
  set_mtime "$(( $(date +%s) - 900 ))" "$wt/src/main.c"
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a stalled crew that wrote nothing did not wedge-escalate on the existing schedule"
  grep -F "stale: $window" "$out" >/dev/null || fail "the stalled-crew escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "the stalled-crew escalation did not flag a possible wedge"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] || fail "the stalled-crew escalation was not counted"
  [ ! -e "$state/.stale-since-$key" ] || fail "the idle timer was not cleared after a real escalation"
  [ ! -e "$state/.writing-since-$key" ] || fail "the write-deferral chain outlived a real escalation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the stalled-crew escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the stalled-crew escalation was not queued"
  pass "a quiet pane writing its own worktree is deferred, while one writing nothing still wedge-escalates on the unchanged schedule"
}

# A deferral is not silence. A worktree can churn without real progress (a
# rewritten log, a build touching the same file), so the whole deferral chain ages
# and re-surfaces once per PAUSE_RESURFACE_SECS - the same bounded cadence a
# declared pause uses - labeled as a recheck rather than a wedge.
test_write_deferral_resurfaces_on_the_bounded_cadence() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid wt back
  dir=$(make_case wedge-worktree-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-churn"; wt="$dir/wt"
  mkdir -p "$wt/src"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/churn.meta"
  printf 'working: implementing\n' > "$state/churn.status"
  sig=$(seen_sig "$state/churn.status"); printf '%s' "$sig" > "$state/.seen-churn_status"
  key=$(watch_window_key "$window")
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  # This pane has been deferring on write evidence for 500s already.
  : > "$state/.writing-since-$key"
  set_mtime "$back" "$state/.writing-since-$key"
  printf 'churn\n' > "$wt/src/main.c"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a long-running write deferral never re-surfaced on the bounded cadence"
  grep -F "stale: $window" "$out" >/dev/null || fail "the write-deferral recheck did not print a stale wake"
  grep -F "writing its worktree" "$out" >/dev/null || fail "the write-deferral recheck was not labeled as such"
  grep -F "possible wedge" "$out" >/dev/null && fail "a write-deferral recheck was mislabeled a possible wedge"
  [ -e "$state/.writing-resurfaced-$key" ] || fail "the write-deferral re-surface throttle marker was not recorded"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a write-deferral recheck advanced the wedge escalation counter"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the write-deferral recheck failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the write-deferral recheck was not queued"
  pass "a write deferral re-surfaces once on the bounded pause cadence, so a churning worktree cannot stay invisible"
}

# The worktree recorded for a secondmate is a provisioned firstmate home, and that
# home runs its OWN supervision inside itself: its watcher beacon, pane hashes and
# heartbeats keep state/ churning whether or not the mate produced anything. Reading
# that as crew progress would quietly relax the kind-agnostic busy-turn backstop from
# the escalation cadence to the hourly recheck for work that produced nothing, so the
# probe must report no evidence and the unchanged schedule must still fire.
test_secondmate_home_supervision_churn_is_not_write_evidence() {
  local dir state fakebin out drain_out capture_file window key sig pid home back
  dir=$(make_case secondmate-home-churn); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-mate"; home="$dir/mate-home"
  mkdir -p "$home/state"
  printf 'sm-mate\n' > "$home/.fm-secondmate-home"
  printf 'Working... (12.3s)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\nworktree=%s\n' "$window" "$home" > "$state/mate.meta"
  record_pi_busy "$state" mate
  # An ordinary crew recording a provisioned mate home is the route that actually
  # reaches the probe: a kind=secondmate window of its own is triaged only under a
  # declared pause, and a declared pause takes the bounded recheck cadence instead of
  # the wedge timer. The home marker alone is what excludes the walk, so the exclusion
  # is what this asserts. A busy pane is bounded by its completed-turn age; no turn
  # ever completed here, so the spawn record itself is aged past the bound that routes
  # it into the wedge timer.
  printf 'working: implementing\n' > "$state/mate.status"
  sig=$(seen_sig "$state/mate.status"); printf '%s' "$sig" > "$state/.seen-mate_status"
  key=$(watch_window_key "$window")
  set_mtime "$(( $(date +%s) - 4000 ))" "$state/mate.meta"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  # The only thing written since the idle window opened is the mate home's own
  # supervision bookkeeping.
  printf 'beat\n' > "$home/state/.last-watcher-beat"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_BUSY_TURN_MAX_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a mate home's own supervision churn deferred an escalation it must not defer"
  grep -F "stale: $window" "$out" >/dev/null || fail "the mate-home escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "the mate-home escalation did not flag a possible wedge"
  [ ! -e "$state/.writing-since-$key" ] || fail "a mate's provisioned home was probed as if it were a code tree"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] || fail "the mate escalation was not counted"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the mate escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the mate escalation was not queued"
  pass "a secondmate's own home supervision churn is not crew write evidence, so a pane recording that home keeps the unchanged escalation schedule"
}

# A write deferral is a bounded chain, not a permanent one: its .writing-since
# marker ages the whole chain so a churning worktree still re-surfaces once per
# PAUSE_RESURFACE_SECS. That only holds while the chain belongs to the CURRENT quiet
# stretch, so every path that restarts the idle-window timer must drop it too. The
# reachable case is a pane that deferred on write evidence and later has its timer
# repaired: a long-finished chain would make the first deferral of the new window
# re-surface immediately instead of after a fresh window.
test_timer_repair_drops_a_finished_write_deferral_chain() {
  local dir state fakebin out capture_file window key pane_hash sig pid wt back
  dir=$(make_case wedge-write-chain-timer-repair); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-chain-repair"; wt="$dir/wt"
  mkdir -p "$wt/src"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/chain-repair.meta"
  printf 'working: implementing\n' > "$state/chain-repair.status"
  sig=$(seen_sig "$state/chain-repair.status"); printf '%s' "$sig" > "$state/.seen-chain-repair_status"
  key=$(watch_window_key "$window")
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  # A deferral chain left over from an earlier quiet stretch, already well past the
  # bounded re-surface window.
  back=$(( $(date +%s) - 5000 ))
  : > "$state/.writing-since-$key"
  set_mtime "$back" "$state/.writing-since-$key"
  # The idle-window timer is corrupt, so this poll repairs it and opens a NEW quiet
  # window without probing the worktree at all.
  printf 'corrupt\n' > "$state/.stale-since-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  # Watcher startup performs bounded recovery scans before its first stale poll;
  # give this positive marker assertion the same loaded-runner budget as the
  # suite's other startup-sensitive waits instead of failing after only 3s.
  wait_numeric_file "$state/.stale-since-$key" 100 \
    || { reap "$pid"; fail "the corrupt idle-window timer was not repaired"; }
  [ ! -e "$state/.writing-since-$key" ] \
    || { reap "$pid"; fail "an idle-window timer repair kept a finished write-deferral chain"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "the idle-window timer repair enqueued a wake"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional timer-repair watcher stop"

  # The new quiet window now crosses the escalation threshold while the crew writes
  # its worktree. That deferral must get a FRESH re-surface window rather than
  # inheriting the finished chain's age.
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"
    fail "the first deferral of a new quiet window re-surfaced at once, so it inherited a finished chain: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a fresh write deferral printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a fresh write deferral enqueued a wake"; }
  [ -e "$state/.writing-since-$key" ] || { reap "$pid"; fail "the new deferral recorded no chain marker"; }
  [ ! -e "$state/.writing-resurfaced-$key" ] \
    || { reap "$pid"; fail "a fresh write deferral spent its bounded re-surface on the first poll"; }
  reap "$pid"
  pass "an idle-window timer repair drops a finished write-deferral chain, so the next deferral gets a fresh re-surface window"
}

# The same chain must not outlive either first-sight path through a captain-relevant
# status line, because both also open a new idle window: the provably-working absorb
# and the plain surface.
test_terminal_first_sight_drops_a_finished_write_deferral_chain() {
  local dir state fakebin out capture_file window key pane_hash sig pid wt back
  dir=$(make_case wedge-write-chain-first-sight); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-chain-firstsight"; wt="$dir/wt"
  mkdir -p "$wt/src"
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/chain-first.meta"
  printf 'done: implementation complete, ready to validate\n' > "$state/chain-first.status"
  sig=$(seen_sig "$state/chain-first.status"); printf '%s' "$sig" > "$state/.seen-chain-first_status"
  key=$(watch_window_key "$window")
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  back=$(( $(date +%s) - 5000 ))
  : > "$state/.writing-since-$key"
  set_mtime "$back" "$state/.writing-since-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # First sight of this hash, absorbed because the active run outranks the stale
  # captain-relevant line. The absorb opens a new idle window, so the finished chain
  # must go with it.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the overridden terminal status was not absorbed on first sight: $(cat "$out")"
  fi
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] \
    || { reap "$pid"; fail "the first-sight absorb did not advance the stale suppressor"; }
  [ ! -e "$state/.writing-since-$key" ] \
    || { reap "$pid"; fail "the provably-working first-sight absorb kept a finished write-deferral chain"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional first-sight absorb stop"

  # Same pane, first sight again, but nothing overrides the status line now, so it
  # surfaces. That path drops the idle-window timer, so it must drop the chain too.
  rm -f "$state/.stale-$key" "$state/.stale-since-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.writing-since-$key"
  set_mtime "$back" "$state/.writing-since-$key"
  FM_FAKE_CREW_STATE='state: unknown · source: none · no run, no busy pane'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a first-sight captain-relevant status was not surfaced"
  grep -F "stale: $window" "$out" >/dev/null || fail "the first-sight surface did not print a stale wake"
  [ ! -e "$state/.writing-since-$key" ] \
    || fail "the first-sight surface kept a finished write-deferral chain"
  unset FM_FAKE_CREW_STATE
  pass "both first-sight paths through a captain-relevant status drop a finished write-deferral chain with the idle window"
}

# --- triage debug log stays size capped -------------------------------------

test_triage_log_size_cap_accepts_spaced_wc_counts() {
  local dir state fakebin out status_file pid lines i
  dir=$(make_case triage-log-spaced-wc); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  i=1
  while [ "$i" -le 3000 ]; do
    printf 'old line %04d\n' "$i" >> "$state/.watch-triage.log"
    i=$((i + 1))
  done
  cat > "$fakebin/wc" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "-c" ]; then
  printf '   999999\n'
  exit 0
fi
exit 127
SH
  chmod +x "$fakebin/wc"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # Provably working so the no-verb signal is absorbed (which is what writes the
  # triage log line under test).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_TRIAGE_LOG_MAX_BYTES=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a benign signal while testing log capping: $(cat "$out")"
  fi
  i=0
  while [ "$i" -lt 30 ]; do
    lines=$(awk 'END { print NR + 0 }' "$state/.watch-triage.log")
    [ "$lines" -le 2000 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$lines" -le 2000 ] || { reap "$pid"; fail "triage log was not capped when wc emitted a spaced byte count (lines=$lines)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "benign signal enqueued a wake while testing log capping"; }
  reap "$pid"
  pass "triage log capping handles wc byte counts with leading spaces"
}

test_procevent_captured_result_surfaces_proactively() {
  local dir state out drain_out pid beacon_age
  dir=$(make_case procevent-delivery); state="$dir/state"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  seed_captured_procevent_result "$dir" || fail "the fixture captured no process-event result"
  grep -F "procevent lavish delivery-src 1" "$state/.wake-queue" >/dev/null \
    || fail "the captured result was never published to the durable queue"

  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "a healthy watcher never surfaced a durably captured process-event result: $(cat "$out")"
  grep -F "check:" "$out" >/dev/null \
    || fail "the process-event wake was not reported as an actionable check: $(cat "$out")"
  grep -F "procevent:delivery-src:1" "$out" >/dev/null \
    || fail "the actionable reason did not name the queued result: $(cat "$out")"
  beacon_age=$(FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_path_age "$2"' _ "$ROOT" "$state/.last-watcher-beat")
  [ "$beacon_age" -lt 60 ] || fail "the surfacing watcher was not a healthy one (beacon age ${beacon_age}s)"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the process-event wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "procevent lavish delivery-src 1" >/dev/null \
    || fail "the process-event result was not queued for the drain that follows the wake"
  pass "a captured process-event result wakes a healthy watcher proactively, with no manual drain"
}

test_procevent_unacknowledged_result_redrains_until_handled() {
  local dir state out replay_out replay_err pid before after sequence generation
  dir=$(make_case procevent-redrain); state="$dir/state"
  out="$dir/watch.out"; replay_out="$dir/replay.out"; replay_err="$dir/replay.err"
  seed_captured_procevent_result "$dir" || fail "the fixture captured no process-event result"

  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "the first proactive wake never happened: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain after the first process-event wake failed"

  # An interrupted handler leaves the captured result durable. The successor
  # must re-surface it through recovery, then its drain must print the same row.
  : > "$out"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "an unacknowledged process-event result was not re-surfaced on re-arm: $(cat "$out")"
  grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || fail "the successor did not report recovery for the unacknowledged result: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$replay_out" 2> "$replay_err" \
    || fail "the successor could not re-drain the unacknowledged process-event result"
  grep "$(printf '\tcheck\t')" "$replay_out" | grep -F 'procevent lavish delivery-src 1' >/dev/null \
    || fail "the successor drain did not re-print the durable process-event row"

  pe_case "$dir" handled delivery-src 1 >/dev/null || fail "could not acknowledge the captured result"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$replay_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$replay_err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "the replay drain omitted its post-handling acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "completed process-event handling could not acknowledge the replay"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged process-event replay remained durable"

  before=$(awk 'END { print NR + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  : > "$out"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    fail "a handled process-event result woke the watcher: $(cat "$out")"
  fi
  reap "$pid"
  after=$(awk 'END { print NR + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$after" = "$before" ] || fail "a handled result was announced again ($before -> $after queued records)"
  pass "an unacknowledged process-event result re-drains until handling is acknowledged"
}

test_procevent_marker_keys_are_injective() {
  local dir state out pid marker_count
  dir=$(make_case procevent-marker-identity); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:a.b:1" "check: procevent fixture a.b 1"
  append_wake "$state" check "procevent:a_b:1" "check: procevent fixture a_b 1"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "colliding-looking process-event keys were not surfaced"
  grep -F "procevent:a.b:1" "$out" >/dev/null || fail "the dotted queue key was suppressed"
  grep -F "procevent:a_b:1" "$out" >/dev/null || fail "the underscored queue key was suppressed"
  marker_count=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | awk 'END { print NR + 0 }')
  [ "$marker_count" = 2 ] || fail "distinct queue keys produced $marker_count seen markers"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "marker identity fixture drain failed"
  pass "complete process-event queue keys map to distinct seen markers"
}

test_procevent_headlines_classify_queue_keys() {
  local dir state out
  dir=$(make_case procevent-headline-captured); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:cap-src:1" "check: procevent lavish cap-src 1"
  surface_once "$dir" "$out" || fail "a captured-result key was not surfaced: $(cat "$out")"
  grep -F "check: process-event result captured: procevent:cap-src:1" "$out" >/dev/null \
    || fail "a captured result did not surface under its own headline: $(cat "$out")"
  ! grep -F "source stranded" "$out" >/dev/null \
    || fail "a captured result was headlined as a strand: $(cat "$out")"
  ! grep -F "failed to start" "$out" >/dev/null \
    || fail "a captured result was headlined as a failed start: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "captured headline fixture drain failed"

  dir=$(make_case procevent-headline-stranded); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:str-src:stranded:tok-1" "check: process-event source str-src is registered but nothing can arm it"
  surface_once "$dir" "$out" || fail "a stranded key was not surfaced: $(cat "$out")"
  grep -F "check: process-event source stranded: procevent:str-src:stranded:tok-1" "$out" >/dev/null \
    || fail "a stranded source did not surface under its own headline: $(cat "$out")"
  ! grep -F "result captured" "$out" >/dev/null \
    || fail "a stranded source was headlined as a captured result: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "stranded headline fixture drain failed"

  dir=$(make_case procevent-headline-joined); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:cap2-src:1" "check: procevent lavish cap2-src 1"
  append_wake "$state" check "procevent:str2-src:stranded:tok-2" "check: process-event source str2-src is registered but nothing can arm it"
  surface_once "$dir" "$out" || fail "a mixed cycle was not surfaced: $(cat "$out")"
  grep -F "check: process-event result captured: procevent:cap2-src:1; process-event source stranded: procevent:str2-src:stranded:tok-2" "$out" >/dev/null \
    || fail "a cycle with a capture and a strand did not carry both headlines joined: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "joined headline fixture drain failed"
  pass "process-event queue keys surface under their own headlines"
}

# Delivery, not queue rows, is what proves a launch-failure episode reaches
# firstmate. The watcher remembers every procevent key it has surfaced for
# good, so reconcile keys each episode with a fresh suffix beyond the
# registration identity: this test would fail if a second episode reused the
# first one's key, because the watcher would keep polling and never wake.
test_procevent_launch_failed_episodes_are_each_delivered() {
  local dir state out status
  dir=$(make_case procevent-launch-failed-episodes); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:lf-src:launch-failed:1-2-100-7" \
    "check: process-event source lf-src is registered but its launch did not prove it took the claim"
  surface_once "$dir" "$out" || fail "a launch-failed key was not surfaced: $(cat "$out")"
  grep -F "check: process-event source failed to start: procevent:lf-src:launch-failed:1-2-100-7" "$out" >/dev/null \
    || fail "a failed launch did not surface under its own headline: $(cat "$out")"
  ! grep -F "result captured" "$out" >/dev/null \
    || fail "a failed launch was headlined as a captured result: $(cat "$out")"
  ack_stopped_cycle "$state" >/dev/null || fail "launch-failed fixture could not be handled and acknowledged"

  # The same key again is what a registration-identity-only key would produce
  # for the next episode: already surfaced, so the process-event surface never
  # delivers it under its headline again. A fresh watcher still recovers the
  # unacknowledged queue row through the generic `check: rearm-resurface`
  # path (the contract test_procevent_unacknowledged_result_redrains_until_handled
  # proves), so what this asserts is the headline, not silence.
  append_wake "$state" check "procevent:lf-src:launch-failed:1-2-100-7" \
    "check: process-event source lf-src is registered but its launch did not prove it took the claim"
  : > "$out"
  status=0
  surface_once "$dir" "$out" 30 || status=$?
  case "$status" in
    124) ;;
    0)
      # The one wake this tolerates is the recovery path named above, by its
      # exact reason line. A wake for any other reason would mean either that
      # the ordinary surface delivered the repeated key after all, or that
      # something unrelated fired inside the window - and both are failures of
      # exactly what this test guards, so neither may pass as "recovery".
      grep -F 'check: rearm-resurface' "$out" >/dev/null \
        || fail "an already-surfaced launch-failed key woke the watcher, and the reason was not the one tolerated recovery path (expected the exact line 'check: rearm-resurface'; if that path was reworded, update this expectation, do not restore the strict silence check): $(cat "$out")"
      ;;
    *) fail "the watcher failed on an already-surfaced launch-failed key (status $status): $(cat "$out")" ;;
  esac
  ! grep -F "failed to start: procevent:lf-src:launch-failed:1-2-100-7" "$out" >/dev/null \
    || fail "an already-surfaced launch-failed key was delivered again under its headline: $(cat "$out")"
  ack_stopped_cycle "$state" >/dev/null || fail "repeated-key fixture could not be handled and acknowledged"

  # A later episode of the same registration carries the same identity under a
  # fresh suffix, and that one must be delivered.
  append_wake "$state" check "procevent:lf-src:launch-failed:1-2-160-9" \
    "check: process-event source lf-src is registered but its launch did not prove it took the claim"
  : > "$out"
  surface_once "$dir" "$out" || fail "a second launch-failure episode was not surfaced: $(cat "$out")"
  grep -F "check: process-event source failed to start: procevent:lf-src:launch-failed:1-2-160-9" "$out" >/dev/null \
    || fail "a second launch-failure episode did not surface under its own headline: $(cat "$out")"
  ack_stopped_cycle "$state" >/dev/null || fail "second episode fixture could not be handled and acknowledged"
  pass "every launch-failure episode is delivered under the failed-to-start headline"
}

test_procevent_surface_serializes_with_drain() {
  local dir state out drain_out ready release pid drain_pid
  dir=$(make_case procevent-drain-race); state="$dir/state"; out="$dir/watch.out"
  drain_out="$dir/drain.out"; ready="$dir/marker-ready"; release="$dir/marker-release"
  append_wake "$state" check "procevent:drain-race:1" "check: procevent fixture drain-race 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=pause FM_MARKER_MV_READY="$ready" FM_MARKER_MV_RELEASE="$release" \
    procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_numeric_file "$ready" 100 || fail "the watcher never reached its marker commit boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" &
  drain_pid=$!
  wait_live "$drain_pid" 10 || fail "a concurrent drain split the surfacing transition"
  [ -s "$state/.wake-queue" ] || fail "the concurrent drain consumed the record before marker commit"
  touch "$release"
  wait "$pid" || fail "the paused watcher did not finish surfacing"
  wait "$drain_pid" || fail "the concurrent drain failed after surfacing committed"
  grep -F "procevent:drain-race:1" "$drain_out" >/dev/null \
    || fail "the serialized drain lost the process-event record"
  pass "queue revalidation, proactive output, and marker commit serialize with drain"
}

test_procevent_surface_crash_boundaries() {
  local dir state out fifo pid reader marker exit_status replay_err sequence generation
  dir=$(make_case procevent-output-fail); state="$dir/state"; out="$dir/watch.out"; fifo="$dir/output.fifo"
  append_wake "$state" check "procevent:output-fail:1" "check: procevent fixture output-fail 1"
  mkfifo "$fifo"
  sh -c ': < "$1"' _ "$fifo" & reader=$!
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$fifo" &
  pid=$!
  wait "$reader" || true
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived a failed actionable output write"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "failed output committed a suppression marker"
  [ -s "$state/.wake-queue" ] || fail "failed output consumed the durable queue record"
  procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100 || fail "the record was not replayable after output failure"
  grep -F "procevent:output-fail:1" "$out" >/dev/null || fail "output failure lost proactive replay"

  dir=$(make_case procevent-before-marker); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:before-marker:1" "check: procevent fixture before-marker 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=kill-before procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived the injected pre-marker crash"
  grep -F "procevent:before-marker:1" "$out" >/dev/null || fail "the pre-marker crash happened before output"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "a pre-marker crash committed suppression"
  procevent_watch_bg "$dir" "$out.replay"; pid=$!
  wait_for_exit "$pid" 100 || fail "a pre-marker crash was not replayable"

  dir=$(make_case procevent-after-marker); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:after-marker:1" "check: procevent fixture after-marker 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=kill-after procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived the injected post-marker crash"
  grep -F "procevent:after-marker:1" "$out" >/dev/null || fail "the post-marker crash lost actionable output"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -n "$marker" ] || fail "the post-marker crash did not reach marker commit"
  : > "$out.replay"
  procevent_watch_bg "$dir" "$out.replay"; pid=$!
  wait_for_exit "$pid" 100 \
    || fail "an unacknowledged delivered record was not re-surfaced on re-arm: $(cat "$out.replay")"
  grep -F 'check: rearm-resurface' "$out.replay" >/dev/null \
    || fail "the successor did not recover the delivered-but-unacknowledged record: $(cat "$out.replay")"
  replay_err="$out.replay.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out.replay.drain" 2> "$replay_err" \
    || fail "post-marker successor drain failed"
  grep "$(printf '\tcheck\t')" "$out.replay.drain" | grep -F 'procevent fixture after-marker 1' >/dev/null \
    || fail "post-marker successor did not re-drain the durable record"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$replay_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$replay_err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "post-marker replay omitted its post-handling acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "post-marker replay acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "post-marker acknowledgement left the durable record queued"
  pass "surfacing failures replay until post-handling acknowledgement"
}

test_procevent_marker_failure_exits_and_replays() {
  local dir state out pid marker output_count
  dir=$(make_case procevent-marker-failure); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:marker-failure:1" "check: procevent fixture marker-failure 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=fail procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "marker failure did not end the actionable watcher cycle successfully"
  output_count=$(grep -Fc "procevent:marker-failure:1" "$out" || true)
  [ "$output_count" = 1 ] || fail "marker failure printed the actionable reason $output_count times"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "marker failure committed suppression"
  [ ! -e "$state/.wake-queue.lock" ] && [ ! -L "$state/.wake-queue.lock" ] \
    || fail "marker failure left the queue lock held"
  procevent_watch_bg "$dir" "$out.replay"
  pid=$!
  wait_for_exit "$pid" 100 || fail "marker failure did not leave the durable record replayable"
  grep -F "procevent:marker-failure:1" "$out.replay" >/dev/null \
    || fail "marker failure lost the later proactive replay"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "marker-failure fixture drain failed"
  pass "marker failure exits through the shared wake owner, releases its lock, and replays later"
}

# --- heartbeat: no-change absorbed, backstop surfaces a missed status --------

test_heartbeat_no_change_absorbed() {
  local dir state fakebin out pid i sig
  dir=$(make_case heartbeat-absorb); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  printf 'working: routine heartbeat history\n' > "$state/routine.status"
  sig=$(seen_sig "$state/routine.status"); printf '%s' "$sig" > "$state/.seen-routine_status"
  # A quiet fleet with a fast heartbeat cadence.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a no-change heartbeat (should absorb): $(cat "$out")"
  fi
  # The heartbeat fires on the first poll whose .last-heartbeat has aged past
  # FM_HEARTBEAT, which need not be the first completed cycle, so wait for the
  # absorbed heartbeat itself rather than assuming one cycle produced it.
  i=0
  while [ "$i" -lt 200 ]; do
    [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ ! -s "$out" ] || fail "no-change heartbeat printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "no-change heartbeat enqueued a durable wake record"
  [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] || fail "heartbeat backoff streak did not advance while absorbing"
  [ "$(status_presentation_marker_offset "$state/.hb-surfaced-routine" "$state/routine.status")" = \
    "$(size_of "$state/routine.status")" ] \
    || fail "routine heartbeat classification did not commit its captured endpoint"
  reap "$pid"
  pass "a heartbeat with no captain-relevant change is absorbed and backs off the cadence"
}

test_heartbeat_backstop_surfaces_a_masked_status() {
  local dir state fakebin out sig pid
  dir=$(make_case heartbeat-masked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  # Same miss as below, but the captain-relevant event is followed by a routine
  # append, so its last line reads benign. The backstop must still catch it.
  printf 'working: setup\nneeds-decision: pick A or B\nworking: tidying the branch\n' \
    > "$state/miss.status"
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"
  printf '3\n' > "$state/.heartbeat-streak"
  touch "$state/.last-heartbeat"
  set_mtime "$(( $(date +%s) - 30 ))" "$state/.last-heartbeat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "heartbeat backstop missed a decision hidden behind a later working: line"
  [ "$(cat "$state/.heartbeat-streak")" = 0 ] || fail "actionable backstop did not reset idle heartbeat backoff"
  awk -F '\t' '$3 == "heartbeat" && $4 == "heartbeat" { found=1 } END { exit !found }' \
    "$state/.wake-queue" || fail "actionable backstop did not preserve the heartbeat wake"
  grep -Fx heartbeat "$out" >/dev/null || fail "backstop did not preserve its heartbeat wake reason"
  [ "$(status_presentation_marker_offset "$state/.hb-surfaced-miss" "$state/miss.status")" = \
    "$(size_of "$state/miss.status")" ] \
    || fail "backstop did not record the masked status as surfaced through its end"
  pass "the heartbeat backstop surfaces a captain event hidden behind a later routine append"
}

test_heartbeat_backstop_surfaces_unsurfaced_status() {
  local dir state fakebin out drain_out sig pid
  dir=$(make_case heartbeat-backstop); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # A captain-relevant status whose .seen-* signature ALREADY matches (so the
  # per-poll signal scan stays quiet) but which was never surfaced (no
  # .hb-surfaced-* marker). This stands in for a per-wake-path miss; the heartbeat
  # fleet-scan backstop must catch it and wake firstmate.
  printf 'done: PR https://example.test/pr/5\n' > "$state/miss.status"
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"
  printf '3\n' > "$state/.heartbeat-streak"
  touch "$state/.last-heartbeat"
  set_mtime "$(( $(date +%s) - 30 ))" "$state/.last-heartbeat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "heartbeat backstop did not surface an unsurfaced captain-relevant status"
  [ "$(cat "$state/.heartbeat-streak")" = 0 ] || fail "actionable backstop did not reset idle heartbeat backoff"
  awk -F '\t' '$3 == "heartbeat" && $4 == "heartbeat" { found=1 } END { exit !found }' \
    "$state/.wake-queue" || fail "actionable backstop did not preserve the heartbeat wake"
  grep -Fx heartbeat "$out" >/dev/null || fail "backstop did not preserve its heartbeat wake reason"
  [ "$(status_presentation_marker_offset "$state/.hb-surfaced-miss" "$state/miss.status")" = \
    "$(size_of "$state/miss.status")" ] \
    || fail "backstop did not record the status as surfaced through its end (would re-fire next heartbeat)"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the backstop heartbeat failed"
  grep "$(printf '\theartbeat\theartbeat\t')" "$drain_out" >/dev/null || fail "backstop heartbeat was not drained"
  pass "heartbeat backstop fail-safe surfaces a captain-relevant status the per-wake path missed"
}

test_afk_heartbeat_preserves_idle_accounting() {
  local dir state fakebin out pid
  dir=$(make_case afk-heartbeat); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  date '+%s' > "$state/.afk"
  printf '3\n' > "$state/.heartbeat-streak"
  touch "$state/.last-heartbeat"
  set_mtime "$(( $(date +%s) - 30 ))" "$state/.last-heartbeat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "away-mode heartbeat did not hand off to daemon triage"
  [ "$(cat "$state/.heartbeat-streak")" = 4 ] || fail "away-mode heartbeat did not preserve idle backoff accounting"
  awk -F '\t' '$3 == "heartbeat" && $4 == "heartbeat" { found=1 } END { exit !found }' \
    "$state/.wake-queue" || fail "away-mode heartbeat did not enqueue a heartbeat wake"
  grep -Fx heartbeat "$out" >/dev/null || fail "away-mode heartbeat lost its transport wake reason"
  pass "away-mode heartbeat keeps daemon triage and idle backoff accounting"
}

# --- beacon stays fresh while absorbing -------------------------------------

test_beacon_stays_fresh_while_absorbing() {
  local dir state fakebin out status_file pid m1 m2 now
  dir=$(make_case beacon-fresh); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: a\n' > "$status_file"
  # Provably working so the working: notes are absorbed (the path that must keep the
  # beacon fresh).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  # Wait on the beacon itself rather than a fixed liveness budget: the watcher's
  # bounded startup can outlast a short wait, and reading an absent beacon would
  # report a missing beacon that simply had not been written yet.
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "watcher exited while absorbing the first benign signal"; }
  m1=$(file_mtime "$state/.last-watcher-beat")
  # A second benign signal keeps it absorbing; the beacon must keep advancing.
  printf 'working: b\n' >> "$status_file"
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "watcher exited while absorbing a second benign signal"; }
  m2=$(file_mtime "$state/.last-watcher-beat")
  now=$(date +%s)
  if [ -z "$m1" ] || [ -z "$m2" ]; then
    reap "$pid"
    fail "watcher beacon missing while absorbing"
  fi
  [ "$m2" -ge "$m1" ] || { reap "$pid"; fail "beacon mtime regressed while absorbing"; }
  [ "$(( now - m2 ))" -lt 10 ] || { reap "$pid"; fail "beacon went stale while absorbing (age $(( now - m2 ))s)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "absorbing benign signals enqueued a wake"; }
  reap "$pid"
  pass "the liveness beacon stays fresh while the watcher absorbs benign wakes (fm-guard never false-alarms)"
}

# --- afk coherence: the daemon owns triage; the watcher does not double-triage ---

test_afk_signal_records_heartbeat_endpoint() {
  local dir state fakebin out status_file pid
  dir=$(make_case afk-heartbeat-endpoint); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; status_file="$state/task.status"
  printf 'needs-decision: choose release target\nworking: preparing both targets\n' > "$status_file"
  date '+%s' > "$state/.afk"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "afk watcher did not hand the actionable signal to the daemon"
  [ "$(status_presentation_marker_offset "$state/.hb-surfaced-task" "$status_file")" = \
    "$(size_of "$status_file")" ] \
    || fail "afk signal did not record the endpoint handed to the daemon"
  unset FM_FAKE_CREW_STATE
  pass "an afk signal records its captured heartbeat endpoint"
}

test_afk_present_reverts_watcher_to_one_shot() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case afk-coherence); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: routine note\n' > "$status_file"
  date '+%s' > "$state/.afk"   # away mode: the supervise-daemon owns triage
  # Set a PROVABLY-WORKING verdict: if afk failed to bypass the provably-working
  # check, this no-verb signal would be absorbed (not surfaced). The test asserting
  # a surface therefore also proves afk reverts to one-shot and skips the costly read.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "with .afk present the watcher did not exit one-shot for a benign signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "afk-mode watcher did not surface the signal for the daemon"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the afk-mode signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "afk-mode benign signal was not queued for the daemon to classify"
  pass "with .afk present the watcher reverts to one-shot so the daemon owns triage (no double-triage)"
}

# A paused pane can first appear as a changed hash. In AFK mode that initial path
# must still hand off the plain window identity to the daemon, rather than running
# the normal-mode pause re-surface and decorating the stale identity.
test_afk_paused_changed_pane_hands_off_plain_stale() {
  local dir state fakebin out drain_out capture_file statusf window key sig pid back
  dir=$(make_case afk-paused-changed-pane); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-afk-held"
  printf 'idle, awaiting upstream\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/afk-held.meta"
  statusf="$state/afk-held.status"
  printf 'paused: awaiting the upstream tool release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-held_status"
  date '+%s' > "$state/.afk"
  key=$(watch_window_key "$window")

  # Deliberately do not seed .hash-*: this is the changed-pane path that used to
  # call handle_paused_stale before AFK's one-shot daemon handoff.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream tool release' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "AFK paused changed pane did not hand off a stale wake"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "AFK paused stale did not preserve its plain window identity: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null && fail "AFK watcher decorated a stale identity instead of handing it to the daemon"
  [ ! -e "$state/.paused-$key" ] || fail "AFK watcher recorded normal-mode pause tracking instead of handing off"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after AFK paused stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "stale: $window" >/dev/null \
    || fail "AFK paused stale was not queued with the plain window identity"
  pass "AFK changed paused panes hand off plain stale identities for daemon-owned pause triage"
}

# The recorded Claude background-task exit picker. The footer is the last
# non-blank row, which is what fm_composer_blocking_dialog requires.
write_exit_picker() {  # <file>
  printf '%s\n' \
    'Background work is running' \
    'The following will stop when you exit:' \
    'shell · sleep 300' \
    '❯ 1. Exit and stop tasks' \
    '  2. Move to background and exit' \
    '  3. Stay' \
    'Enter to confirm · Esc to cancel' > "$1"
}

# The same words quoted above a normal composer. That is not a live picker.
write_quoted_exit_picker() {  # <file>
  printf '%s\n' \
    'Background work is running' \
    '❯ 1. Exit and stop tasks' \
    'Enter to confirm · Esc to cancel' \
    '╭──────────────╮' \
    '│ > next steer │' \
    '╰──────────────╯' > "$1"
}

prime_picker_window() {  # <state> <id> <window> <kind> <capture> <status-line>
  local state=$1 id=$2 window=$3 kind=$4 capture=$5 status_line=$6 key statusf
  statusf="$state/$id.status"
  printf 'window=%s\nkind=%s\nbackend=tmux\n' "$window" "$kind" > "$state/$id.meta"
  printf '%s\n' "$status_line" > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-${id}_status"
  key=$(watch_window_key "$window")
  printf '%s' "$(hash_text "$(cat "$capture")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$key"
}

test_exit_picker_stale_names_the_dialog() {
  local dir state fakebin out capture_file window key pid count_file
  dir=$(make_case exit-picker-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; count_file="$dir/captures"
  window="test:fm-picker"
  write_exit_picker "$capture_file"
  key=$(prime_picker_window "$state" picker "$window" ship "$capture_file" 'working: parked between turns')
  printf '0\n' > "$count_file"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CAPTURE_COUNT_FILE="$count_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a pane parked on the exit picker: $(cat "$out")"
  grep -F "stale: $window" "$out" >/dev/null || fail "the picker wake was not a stale wake: $(cat "$out")"
  grep -F 'blocked-on-prompt: Claude background-task exit picker' "$out" >/dev/null \
    || fail "the picker wake did not name the dialog: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null && fail "the first picker stale was labeled a wedge: $(cat "$out")"
  [ "$(cat "$count_file")" -eq 1 ] || fail "the picker poll captured the pane $(cat "$count_file") times"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$(hash_text "$(cat "$capture_file")")" ] \
    || fail "the picker stale did not record the pane hash"
  unset FM_FAKE_CREW_STATE
  pass "a pane on the exit picker is a named stale, from the one capture the poll already takes"
}

test_exit_picker_wedge_keeps_climbing() {
  local dir state fakebin out capture_file window key pid n
  dir=$(make_case exit-picker-wedge); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-picker-wedge"
  write_exit_picker "$capture_file"
  key=$(prime_picker_window "$state" picker "$window" ship "$capture_file" 'working: parked between turns')
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a working pane on the picker exited instead of keeping the wedge timer: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a working pane on the picker woke before the wedge timer: $(cat "$out")"
  [ -s "$state/.stale-since-$key" ] || fail "the picker did not start the wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the picker absorb"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_WEDGE_DEMAND_INSPECT_COUNT=3 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "the first picker wedge did not escalate: $(cat "$out")"
  grep -F 'possible wedge, escalation 1' "$out" >/dev/null || fail "the first picker wedge lost its count: $(cat "$out")"
  grep -F 'blocked-on-prompt: Claude background-task exit picker' "$out" >/dev/null \
    || fail "the first picker wedge dropped the dialog name: $(cat "$out")"
  grep -F 'demand-deep-inspection' "$out" >/dev/null && fail "escalation 1 demanded inspection: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge picker escalation 1"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '2\n' > "$state/.wedge-escalations-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_WEDGE_DEMAND_INSPECT_COUNT=3 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "the third picker wedge did not escalate: $(cat "$out")"
  grep -F 'possible wedge, escalation 3' "$out" >/dev/null || fail "the ladder did not reach escalation 3: $(cat "$out")"
  grep -F 'demand-deep-inspection: same pane has wedge-escalated 3 times in a row - do not re-absorb on the run-step/pane state alone, blocked-on-prompt: Claude background-task exit picker' \
    "$out" >/dev/null || fail "the dialog name was not after demand-deep-inspection: $(cat "$out")"
  n=$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)
  [ "$n" -eq 3 ] || fail "the escalation count was $n, not 3"
  unset FM_FAKE_CREW_STATE
  pass "a pane on the exit picker keeps the wedge ladder, and the name follows demand-deep-inspection"
}

test_quoted_exit_picker_stays_ordinary_stale() {
  local dir state fakebin out capture_file window pid
  dir=$(make_case quoted-exit-picker); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-quoted"
  write_quoted_exit_picker "$capture_file"
  prime_picker_window "$state" quoted "$window" ship "$capture_file" 'working: parked between turns' >/dev/null
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a quoted picker did not take the ordinary stale path: $(cat "$out")"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "a quoted picker was not an ordinary stale: $(cat "$out")"
  grep -F 'blocked-on-prompt' "$out" >/dev/null && fail "a quoted picker was named as a dialog: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "picker text quoted above a composer stays an ordinary stale"
}

test_secondmate_exit_picker_stays_quiet() {
  local dir state fakebin out capture_file window pid count_file
  dir=$(make_case secondmate-exit-picker); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; count_file="$dir/captures"
  window="test:fm-picker-mate"
  write_exit_picker "$capture_file"
  prime_picker_window "$state" mate "$window" secondmate "$capture_file" 'working: the parent supervises this secondmate' >/dev/null
  printf '0\n' > "$count_file"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CAPTURE_COUNT_FILE="$count_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a second mate on the exit picker woke: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a second mate on the exit picker printed a wake: $(cat "$out")"; }
  [ "$(cat "$count_file")" -eq 0 ] \
    || { reap "$pid"; fail "a second mate on the exit picker was captured $(cat "$count_file") times"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a second mate on the exit picker stays quiet, and the poll does not capture the pane"
}

# The away daemon saved this name while the picker was up. Once the pane leaves
# it, the same capture the stale path already takes has to drop the name, or
# the persistence line would still say the dialog is open.
test_closed_exit_picker_drops_saved_dialog_name() {
  local dir state fakebin out capture_file window pid
  dir=$(make_case exit-picker-closed); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-picker-closed"
  printf 'idle at the prompt\n' > "$capture_file"
  prime_picker_window "$state" closer "$window" ship "$capture_file" 'working: parked between turns' >/dev/null
  printf '%s' 'Claude background-task exit picker' > "$state/.subsuper-dialog-closer"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a closed picker did not take the ordinary stale path: $(cat "$out")"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "a closed picker was not an ordinary stale: $(cat "$out")"
  grep -F 'blocked-on-prompt' "$out" >/dev/null && fail "a closed picker was still named as a dialog: $(cat "$out")"
  [ ! -e "$state/.subsuper-dialog-closer" ] || fail "a closed picker left the saved dialog name"
  unset FM_FAKE_CREW_STATE
  pass "a closed picker drops the saved dialog name, and the stale stays ordinary"
}

fm_test_run \
  test_term_stops_a_watcher_blocked_inside_a_poll \
  test_term_stops_a_watcher_whose_cleanup_marker_lock_is_held \
  test_cleanup_marker_lock_bound_is_decimal_with_zero_default \
  test_busy_pane_below_turn_age_bound_is_absorbed \
  test_busy_pane_stable_hash_escalates_past_turn_age_bound \
  test_busy_pane_changing_hash_escalates_past_turn_age_bound \
  test_busy_pane_turn_end_touch_resets_age \
  test_busy_pane_native_progress_resets_age \
  test_busy_pane_repeated_escalation_reaches_demand_deep_inspection \
  test_busy_pane_default_turn_age_bound_is_3600s \
  test_busy_declared_pause_is_rechecked_not_wedge_escalated \
  test_afk_busy_declared_pause_hands_off_plain_stale \
  test_afk_busy_declared_pause_ticking_pane_hands_off_once \
  test_nonterminal_stale_repairs_missing_or_corrupt_timer \
  test_wedge_escalation_deferred_while_worktree_is_written \
  test_write_deferral_resurfaces_on_the_bounded_cadence \
  test_secondmate_home_supervision_churn_is_not_write_evidence \
  test_timer_repair_drops_a_finished_write_deferral_chain \
  test_terminal_first_sight_drops_a_finished_write_deferral_chain \
  test_triage_log_size_cap_accepts_spaced_wc_counts \
  test_procevent_captured_result_surfaces_proactively \
  test_procevent_unacknowledged_result_redrains_until_handled \
  test_procevent_marker_keys_are_injective \
  test_procevent_headlines_classify_queue_keys \
  test_procevent_launch_failed_episodes_are_each_delivered \
  test_procevent_surface_serializes_with_drain \
  test_procevent_surface_crash_boundaries \
  test_procevent_marker_failure_exits_and_replays \
  test_heartbeat_no_change_absorbed \
  test_heartbeat_backstop_surfaces_unsurfaced_status \
  test_heartbeat_backstop_surfaces_a_masked_status \
  test_afk_heartbeat_preserves_idle_accounting \
  test_beacon_stays_fresh_while_absorbing \
  test_afk_signal_records_heartbeat_endpoint \
  test_afk_present_reverts_watcher_to_one_shot \
  test_afk_paused_changed_pane_hands_off_plain_stale \
  test_exit_picker_stale_names_the_dialog \
  test_exit_picker_wedge_keeps_climbing \
  test_quoted_exit_picker_stays_ordinary_stale \
  test_secondmate_exit_picker_stays_quiet \
  test_closed_exit_picker_drops_saved_dialog_name
