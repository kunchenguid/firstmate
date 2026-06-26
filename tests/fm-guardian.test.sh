#!/usr/bin/env bash
# tests/fm-guardian.test.sh - the always-on supervisor daemon's Mode B (present)
# liveness guardian: the structural fix that makes a missed watcher re-arm
# self-heal instead of silently stopping supervision. These are the deterministic
# units + real-process singleton checks behind the acceptance criteria; the full
# operator-visible lapse->restore->nudge->shutdown flow through a real daemon lives
# in fm-guardian-present-e2e.test.sh.
#
# Mapping to the spec's acceptance criteria:
#   1 (restore + exactly one nudge)  test_guardian_restores_watcher_and_nudges_once
#   2 (no double watcher)            test_guardian_restore_is_singleton_safe
#   3 (no routine-wake injection)    test_guardian_no_nudge_when_beacon_fresh,
#                                    test_guardian_lapsed_matrix
#   4 (afk unchanged)                covered by fm-afk-inject-e2e + fm-daemon units
#   5 (home isolation, no broad kill) test_no_broad_pkill_in_sources
#   6 (self-heal, clean shutdown)    fm-guardian-present-e2e + test_restore_does_not_stack
#   7 (guard banner still fires)     test_guard_banner_still_fires_with_daemon_model
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
WATCH="$ROOT/bin/fm-watch.sh"
GUARDIAN_ARM="$ROOT/bin/fm-guardian-arm.sh"

# Source the daemon's pure functions once (its main loop is BASH_SOURCE-guarded).
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-guardian-tests)

# A deterministic stub "watcher": it makes the liveness beacon fresh (like the
# real watcher's per-poll touch) and stays alive, so a guardian restore is
# observable without the real watcher's lock machinery. FM_WATCH_CMD points the
# guardian at it.
make_stub_watcher() {  # <dir>
  local dir=$1 stub="$1/stub-watcher.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
touch "${FM_STATE_OVERRIDE:?}/.last-watcher-beat"
exec sleep 30
SH
  chmod +x "$stub"
  printf '%s\n' "$stub"
}

reap_guardian_watcher() {
  if [ -n "${GUARDIAN_WATCHER_PID:-}" ]; then
    kill "$GUARDIAN_WATCHER_PID" 2>/dev/null || true
    wait "$GUARDIAN_WATCHER_PID" 2>/dev/null || true
  fi
  GUARDIAN_WATCHER_PID=""
}

# --- guardian_lapsed: the detection contract (criterion 3 boundary) ----------
test_guardian_lapsed_matrix() {
  local dir state
  dir=$(make_supercase guardian-lapsed)
  state="$dir/state"

  # No work in flight -> never a lapse, even with no beacon at all.
  rm -f "$state"/*.meta 2>/dev/null || true
  rm -f "$state/.last-watcher-beat"
  if FM_GUARD_GRACE=2 guardian_lapsed "$state"; then
    fail "guardian_lapsed true with no work in flight"
  fi

  # Work in flight + fresh beacon -> NOT a lapse (a live watcher is beating).
  printf 'project=x\n' > "$state/task.meta"
  touch "$state/.last-watcher-beat"
  if FM_GUARD_GRACE=300 guardian_lapsed "$state"; then
    fail "guardian_lapsed true while the beacon is fresh (routine, not a lapse)"
  fi

  # Work in flight + missing beacon -> lapse.
  rm -f "$state/.last-watcher-beat"
  FM_GUARD_GRACE=300 guardian_lapsed "$state" || fail "missing beacon with work in flight is not a lapse"

  # Work in flight + stale beacon -> lapse.
  touch -t 200001010000 "$state/.last-watcher-beat"
  FM_GUARD_GRACE=300 guardian_lapsed "$state" || fail "stale beacon with work in flight is not a lapse"

  pass "guardian_lapsed: lapse only when work is in flight AND the beacon is missing/stale"
}

# --- guardian_nudge_due: exactly-one-nudge cooldown (criterion 1) ------------
test_guardian_nudge_due_cooldown() {
  local dir state
  dir=$(make_supercase guardian-cooldown)
  state="$dir/state"
  # The cooldown keys off the marker's MTIME (via _file_age), not its content.
  rm -f "$state/.guardian-last-nudge"
  FM_GUARD_GRACE=300 guardian_nudge_due "$state" || fail "first nudge should be due (no marker)"
  touch "$state/.guardian-last-nudge"                       # mtime = now -> within cooldown
  if FM_GUARD_GRACE=300 guardian_nudge_due "$state"; then
    fail "a fresh nudge marker should suppress a second nudge (cooldown)"
  fi
  touch -t 200001010000 "$state/.guardian-last-nudge"       # mtime far in the past -> aged out
  FM_GUARD_GRACE=300 guardian_nudge_due "$state" || fail "an aged nudge marker should allow a new nudge"
  pass "guardian_nudge_due: one nudge per cooldown window, re-armed after it elapses"
}

# --- criterion 3: a fresh beacon (routine) produces NO injection -------------
test_guardian_no_nudge_when_beacon_fresh() {
  local dir state sent
  dir=$(make_supercase guardian-fresh-noop)
  state="$dir/state"
  sent="$dir/sent.log"; : > "$sent"
  printf 'project=x\n' > "$state/task.meta"
  touch "$state/.last-watcher-beat"          # a live watcher is beating
  rm -f "$state/.guardian-last-nudge"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 \
    guardian_step "$state"
  [ ! -s "$sent" ] || fail "guardian injected on a routine tick (fresh beacon) - criterion 3 violated"
  [ ! -e "$state/.guardian-last-nudge" ] || fail "guardian recorded a nudge with a fresh beacon"
  [ -z "${GUARDIAN_WATCHER_PID:-}" ] || fail "guardian forked a watcher with a fresh beacon"
  pass "guardian: a fresh beacon is a no-op - no watcher fork, no nudge (criterion 3)"
}

test_guardian_no_action_without_work() {
  local dir state sent
  dir=$(make_supercase guardian-nowork)
  state="$dir/state"
  sent="$dir/sent.log"; : > "$sent"
  rm -f "$state"/*.meta 2>/dev/null || true
  rm -f "$state/.last-watcher-beat"          # no beacon, but also no work
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=2 \
    guardian_step "$state"
  [ ! -s "$sent" ] || fail "guardian injected with no work in flight"
  [ -z "${GUARDIAN_WATCHER_PID:-}" ] || fail "guardian forked a watcher with no work in flight"
  pass "guardian: no work in flight is a no-op even with a missing beacon"
}

# --- criterion 1: lapse -> restore liveness + exactly ONE nudge --------------
test_guardian_restores_watcher_and_nudges_once() {
  local dir state sent stub i
  dir=$(make_supercase guardian-restore)
  state="$dir/state"
  sent="$dir/sent.log"; : > "$sent"
  : > "$dir/pane.txt"
  stub=$(make_stub_watcher "$dir")
  printf 'project=x\n' > "$state/task.meta"   # work in flight
  rm -f "$state/.last-watcher-beat"           # watcher killed: lapse
  rm -f "$state/.guardian-last-nudge"
  GUARDIAN_WATCHER_PID=""

  # First guardian tick on a detected lapse: restore the watcher + nudge once.
  # Small grace so the missing beacon is an immediate lapse; a long nudge cooldown
  # so "exactly one nudge" is a property of the logic, not of test timing.
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_STATE_OVERRIDE="$state" FM_WATCH_CMD="$stub" \
    FM_WATCH_ERR="$dir/watch.err" FM_GUARD_GRACE=2 FM_GUARDIAN_NUDGE_COOLDOWN=9999 \
    FM_INJECT_CONFIRM_SLEEP=0.05 guardian_step "$state"

  # The beacon goes fresh again (liveness restored) within a beat.
  i=0
  while [ "$i" -lt 50 ] && [ ! -e "$state/.last-watcher-beat" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$state/.last-watcher-beat" ] || { reap_guardian_watcher; fail "guardian did not restore the watcher beacon"; }
  if [ -z "${GUARDIAN_WATCHER_PID:-}" ] || ! kill -0 "$GUARDIAN_WATCHER_PID" 2>/dev/null; then
    reap_guardian_watcher
    fail "guardian did not keep a restored watcher alive"
  fi

  # Exactly one nudge was submitted, and it is the liveness-lapse nudge.
  [ "$(grep -c 'supervision liveness lapsed' "$sent")" -eq 1 ] \
    || { reap_guardian_watcher; fail "expected exactly one liveness nudge, got $(grep -c 'supervision liveness lapsed' "$sent")"; }
  [ "$(grep -c '\[ENTER\]' "$sent")" -eq 1 ] \
    || { reap_guardian_watcher; fail "nudge was not submitted exactly once"; }

  # A second tick within the cooldown must NOT nudge again (exactly one). The
  # restored stub keeps the beacon fresh, so this is also a no-lapse no-op.
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_STATE_OVERRIDE="$state" FM_WATCH_CMD="$stub" \
    FM_WATCH_ERR="$dir/watch.err" FM_GUARD_GRACE=2 FM_GUARDIAN_NUDGE_COOLDOWN=9999 \
    FM_INJECT_CONFIRM_SLEEP=0.05 guardian_step "$state"
  [ "$(grep -c 'supervision liveness lapsed' "$sent")" -eq 1 ] \
    || { reap_guardian_watcher; fail "guardian re-nudged within the cooldown (criterion 1: exactly one)"; }

  reap_guardian_watcher
  pass "guardian: a detected lapse restores the watcher and nudges firstmate exactly once (criterion 1)"
}

# The nudge must carry the sentinel marker so a PRESENT firstmate tells it from a
# captain message, and inject_nudge must NOT be afk-gated (it fires while present).
test_inject_nudge_marked_and_not_afk_gated() {
  local dir state sent nudge_line
  dir=$(make_supercase guardian-nudge-marker)
  state="$dir/state"
  sent="$dir/sent.log"; : > "$sent"
  : > "$dir/pane.txt"
  # afk deliberately NOT set (present). inject_msg would defer here; inject_nudge must not.
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_INJECT_CONFIRM_SLEEP=0.05 \
    inject_nudge "supervision liveness lapsed - draining the wake-queue and resuming" "$state" \
    || fail "inject_nudge did not deliver while afk was off (it must not be presence-gated)"
  grep -F 'supervision liveness lapsed' "$sent" >/dev/null || fail "nudge text was not submitted"
  # The submitted line starts with the sentinel marker byte (0x1f). Pure-bash
  # first-char check against FM_INJECT_MARK (no `od`, which a PATH shim can shadow).
  nudge_line=$(grep -F 'supervision liveness lapsed' "$sent" | head -1)
  [ "${nudge_line:0:1}" = "$FM_INJECT_MARK" ] || fail "nudge is not sentinel-marked (first char not 0x1f)"
  # Contrast: inject_msg (Mode A) stays presence-gated and defers while afk is off.
  : > "$sent"
  if PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" inject_msg "an escalation" "$state"; then
    fail "inject_msg delivered while afk inactive (it must stay presence-gated)"
  fi
  [ ! -s "$sent" ] || fail "inject_msg injected while afk inactive"
  pass "inject_nudge is sentinel-marked and fires while present; inject_msg stays afk-gated"
}

# --- criterion 2: the guardian restore can never double-arm the watcher ------
test_guardian_restore_is_singleton_safe() {
  local dir state i a_pid
  dir=$(make_case guardian-singleton)   # make_case gives a list/capture tmux shim
  state="$dir/state"

  # "firstmate's" watcher: a real fm-watch.sh holding the singleton + beating.
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >/dev/null 2>&1 &
  a_pid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$a_pid" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$a_pid" ] \
    || { kill "$a_pid" 2>/dev/null; fail "seed watcher did not take the singleton lock"; }

  # The guardian forks a watcher via the singleton-safe path: it must stand down
  # rather than become a second live watcher.
  GUARDIAN_WATCHER_PID=""
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_CMD="$WATCH" \
    FM_WATCH_ERR="$dir/watch.err" guardian_restore_watcher
  local b_pid=$GUARDIAN_WATCHER_PID
  [ -n "$b_pid" ] || { kill "$a_pid" 2>/dev/null; fail "guardian did not fork a watcher"; }
  wait_for_exit "$b_pid" 60 || true   # the redundant fork exits ("already running")

  is_live_non_zombie "$a_pid" || { kill "$a_pid" "$b_pid" 2>/dev/null; fail "the original watcher died - guardian fork stole the singleton"; }
  is_live_non_zombie "$b_pid" && { kill "$a_pid" "$b_pid" 2>/dev/null; fail "two live watchers after a guardian restore (double-arm) - criterion 2 violated"; }
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$a_pid" ] \
    || { kill "$a_pid" "$b_pid" 2>/dev/null; fail "guardian fork disturbed the live watcher's lock"; }

  kill "$a_pid" "$b_pid" 2>/dev/null || true
  wait "$a_pid" 2>/dev/null || true
  GUARDIAN_WATCHER_PID=""
  pass "guardian restore is singleton-safe: a redundant fork stands down, exactly one watcher survives (criterion 2)"
}

# guardian_restore_watcher must not stack forks: while one forked watcher is still
# alive, a second call is a no-op (no crash-spin of watcher processes; criterion 6).
test_restore_does_not_stack() {
  local dir stub first second
  dir=$(make_supercase guardian-nostack)
  stub=$(make_stub_watcher "$dir")
  GUARDIAN_WATCHER_PID=""
  FM_STATE_OVERRIDE="$dir/state" FM_WATCH_CMD="$stub" FM_WATCH_ERR="$dir/watch.err" \
    guardian_restore_watcher
  first=$GUARDIAN_WATCHER_PID
  [ -n "$first" ] || fail "first restore did not fork a watcher"
  FM_STATE_OVERRIDE="$dir/state" FM_WATCH_CMD="$stub" FM_WATCH_ERR="$dir/watch.err" \
    guardian_restore_watcher
  second=$GUARDIAN_WATCHER_PID
  [ "$first" = "$second" ] || { kill "$first" "$second" 2>/dev/null; fail "restore stacked a second watcher fork while one was alive"; }
  reap_guardian_watcher
  pass "guardian_restore_watcher does not stack forks while one is alive (criterion 6)"
}

# --- criterion 5: home isolation - never a broad pkill -----------------------
test_no_broad_pkill_in_sources() {
  local f
  for f in "$DAEMON" "$GUARDIAN_ARM"; do
    # Strip comments first: a "Never a broad pkill" caution is fine; an actual
    # pkill invocation is not (it would match sibling/secondmate homes).
    if sed 's/#.*//' "$f" | grep -nE 'pkill' >/dev/null 2>&1; then
      fail "pkill invocation found in $(basename "$f") - would match sibling/secondmate homes (criterion 5)"
    fi
  done
  # The daemon's takeover stops only a pid the lock proves is THIS home's watcher.
  grep -F 'daemon_watch_lock_is_genuine' "$DAEMON" >/dev/null \
    || fail "daemon takeover lost its identity-checked, home-scoped stop"
  pass "no pkill invocation in the daemon or guardian-arm; takeover is home-scoped + identity-checked (criterion 5)"
}

# --- criterion 7: the pull-based guard banner still fires on a real lapse -----
# Defense in depth: even with the daemon model, fm-guard.sh must still alarm on a
# stale beacon with work in flight, so a human touching the fleet sees it.
test_guard_banner_still_fires_with_daemon_model() {
  local dir state err
  dir=$(make_case guardian-guard-banner)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  # No beacon -> watcher down. Non-git FM_ROOT keeps the tangle guard inert.
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 \
    "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard exited non-zero"
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null \
    || fail "guard banner did not fire on a stale beacon with work in flight (criterion 7)"
  pass "fm-guard.sh still fires its stale-beacon banner under the daemon model (criterion 7)"
}

# --- guardian-arm is singleton-safe (no-op when a live daemon already runs) ---
test_guardian_arm_no_ops_when_daemon_alive() {
  local dir state out
  dir=$(make_case guardian-arm-noop)
  state="$dir/state"
  # A live "daemon": any live pid recorded in the pidfile.
  sleep 30 &
  local fake=$!
  printf '%s\n' "$fake" > "$state/.supervise-daemon.pid"
  out=$(FM_STATE_OVERRIDE="$state" FM_HOME="$dir" "$GUARDIAN_ARM" 2>&1) || fail "guardian-arm exited non-zero with a live daemon"
  grep -F "already running pid=$fake" <<<"$out" >/dev/null || fail "guardian-arm did not no-op for a live daemon: $out"
  kill "$fake" 2>/dev/null || true
  wait "$fake" 2>/dev/null || true
  pass "guardian-arm no-ops when a live daemon already holds this home"
}

test_guardian_lapsed_matrix
test_guardian_nudge_due_cooldown
test_guardian_no_nudge_when_beacon_fresh
test_guardian_no_action_without_work
test_guardian_restores_watcher_and_nudges_once
test_inject_nudge_marked_and_not_afk_gated
test_guardian_restore_is_singleton_safe
test_restore_does_not_stack
test_no_broad_pkill_in_sources
test_guard_banner_still_fires_with_daemon_model
test_guardian_arm_no_ops_when_daemon_alive
