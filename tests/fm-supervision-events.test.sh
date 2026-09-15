#!/usr/bin/env bash
# tests/fm-supervision-events.test.sh - unit tests for the watcher's native
# event-wait splice (event_wait_or_sleep in bin/fm-watch.sh and
# handle_push_transition in bin/fm-push-transition-lib.sh). The watcher's source
# guard lets this file source it to load
# the functions WITHOUT acquiring the singleton lock or entering the blocking
# loop; wake/sleep and the backend dispatchers are overridden so the exemptions,
# capability memo, and fail-closed disable are asserted deterministically with no
# real herdr, watcher process, or blocking sleeps.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-supervision-events)
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"

# Source the watcher with an isolated state/home. The guard returns before the
# lock/loop, so only the functions load.
export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
# Production modules are independently linted canonical roots. Keep this test's
# ShellCheck context local while preserving its unchanged runtime source path.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"

# Overrides: capture wake reasons and neutralize real sleeps (POLL is 15s).
WAKE_LOG="$TMP/wakes"
SLEEP_LOG="$TMP/sleeps"
wake() { printf '%s\n' "$1" >> "$WAKE_LOG"; return 0; }
sleep() { printf 'SLEEP\n' >> "$SLEEP_LOG"; }

reset_state() {
  rm -f "$STATE_DIR"/*.meta "$STATE_DIR"/*.status "$STATE_DIR"/.wake-queue \
    "$STATE_DIR"/.wake-queue.seq "$STATE_DIR"/.watch-triage.log \
    "$STATE_DIR"/.herdr-escalated-* "$TMP"/panes "$TMP"/wtcalls "$TMP"/wtcalled 2>/dev/null || true
  : > "$WAKE_LOG"
  : > "$SLEEP_LOG"
  _event_cap_key=""
  _event_cap_ok=0
  _event_cap_fails=0
}

mkrec() {  # <pane_id> <status>
  fm_transition_record "$1" "wG" "" "$2" claude
}

# --- handle_push_transition: enqueue + wake for a non-paused blocked crew -----

reset_state
fm_write_meta "$STATE_DIR/tk1.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
[ -e "$STATE_DIR/.wake-queue" ] || fail "handle_push_transition should enqueue a wake for a blocked crew"
grep -q 'stale' "$STATE_DIR/.wake-queue" || fail "the enqueued wake must be a stale record: $(cat "$STATE_DIR/.wake-queue")"
grep -q 'default:wG:pQ' "$STATE_DIR/.wake-queue" || fail "the stale record must name the crew's window"
grep -q 'herdr: agent blocked' "$STATE_DIR/.wake-queue" || fail "the stale payload must name the herdr-blocked cause"
[ -s "$WAKE_LOG" ] || fail "handle_push_transition must wake the supervisor for a blocked crew"
[ -e "$STATE_DIR/.herdr-escalated-default_wG_pQ" ] || fail "handle_push_transition must commit dedupe only after enqueue"
pass "handle_push_transition: a blocked crew enqueues a stale wake naming its window and wakes the supervisor"

reset_state
fm_write_meta "$STATE_DIR/tk1.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
(
  # shellcheck disable=SC2329 # Runtime override called by the isolated production owner.
  fm_wake_append() { return 1; }
  handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
) >/dev/null 2>&1 || true
[ ! -e "$STATE_DIR/.herdr-escalated-default_wG_pQ" ] || fail "a failed durable enqueue must leave the blocked edge eligible for reconnect reconciliation"
pass "handle_push_transition: enqueue failure cannot commit the Herdr dedupe marker"

# --- handle_push_transition: absorb (no wake, no enqueue) for a declared pause -

reset_state
fm_write_meta "$STATE_DIR/tk2.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
printf 'paused: waiting on the upstream release\n' > "$STATE_DIR/tk2.status"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
if [ -e "$STATE_DIR/.wake-queue" ] && grep -q 'stale' "$STATE_DIR/.wake-queue"; then
  fail "a declared-pause crew must NOT be fast-escalated: $(cat "$STATE_DIR/.wake-queue")"
fi
[ ! -s "$WAKE_LOG" ] || fail "a declared-pause crew must not wake the supervisor from the event fast-path"
grep -q 'absorbed push' "$STATE_DIR/.watch-triage.log" 2>/dev/null || fail "the paused absorb should be logged to the triage log"
pass "handle_push_transition: a declared-pause crew is absorbed (no fast wake), left to the poll loop's long cadence"

# --- handle_push_transition: absorb for a verified captain-held transfer -------

reset_state
fm_write_meta "$STATE_DIR/tk2h.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$STATE_DIR/tk2h.status"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
if [ -e "$STATE_DIR/.wake-queue" ] && grep -q 'stale' "$STATE_DIR/.wake-queue"; then
  fail "a captain-held crew must NOT be fast-escalated: $(cat "$STATE_DIR/.wake-queue")"
fi
[ ! -s "$WAKE_LOG" ] || fail "a captain-held crew must not wake the supervisor from the event fast-path"
grep -q 'absorbed push' "$STATE_DIR/.watch-triage.log" 2>/dev/null || fail "the captain-held absorb should be logged to the triage log"
pass "handle_push_transition: a captain-held crew is absorbed (no fast wake), left to the poll loop's long cadence"

# --- event_wait_or_sleep: secondmate windows are excluded from the pane list --

reset_state
fm_write_meta "$STATE_DIR/tk3.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
fm_write_meta "$STATE_DIR/sm1.meta" "window=default:wA:pS" "backend=herdr" "kind=secondmate"
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() { shift 4; printf '%s\n' "$*" > "$TMP/panes"; return 1; }
event_wait_or_sleep
PANES=$(cat "$TMP/panes" 2>/dev/null || true)
case "$PANES" in *"default:wG:pQ"*) : ;; *) fail "the ship window must be in the event pane list, got '$PANES'" ;; esac
case "$PANES" in *"default:wA:pS"*) fail "a kind=secondmate window must be EXCLUDED from the event pane list, got '$PANES'" ;; *) : ;; esac
pass "event_wait_or_sleep: herdr windows go on the event pane list, but kind=secondmate endpoints are excluded"

reset_state
fm_write_meta "$STATE_DIR/tk3.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
CAP_CALLS=0
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { CAP_CALLS=$((CAP_CALLS + 1)); return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() {
  # Runs in the wait's own subprocess now, so record the miss for the parent to assert.
  [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" = 1 ] || printf 'unconfirmed\n' >> "$TMP/unconfirmed"
  return 1
}
rm -f "$TMP/unconfirmed"
event_wait_or_sleep
event_wait_or_sleep
[ ! -e "$TMP/unconfirmed" ] || fail "cached capability verdict was not passed to the wait"
[ "$CAP_CALLS" = 1 ] || fail "capability probe must be memoized across waits, got $CAP_CALLS calls"
pass "event_wait_or_sleep: one cached capability probe owns validation across bounded waits"

# --- event_wait_or_sleep: a tmux-only home never runs the event path ----------

reset_state
fm_write_meta "$STATE_DIR/tk4.meta" "window=fmses:fm-tk4" "kind=ship"   # no backend= -> tmux
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
fm_backend_wait_transition() { printf 'CALLED\n' > "$TMP/wtcalled"; return 1; }
event_wait_or_sleep
[ ! -e "$TMP/wtcalled" ] || fail "a tmux-only home must never invoke the event wait path"
grep -q 'SLEEP' "$SLEEP_LOG" || fail "a tmux-only home must sleep POLL exactly as before"
pass "event_wait_or_sleep: a home with no push-capable window is inert (sleeps POLL, never touches the event path)"

# --- event_wait_or_sleep: runtime failures disable the event path (fail-closed)

reset_state
fm_write_meta "$STATE_DIR/tk5.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
export EVENT_CAP_FAIL_MAX=2
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() { printf 'WT\n' >> "$TMP/wtcalls"; return 2; }
: > "$TMP/wtcalls"
event_wait_or_sleep   # fails=1
event_wait_or_sleep   # fails=2 -> disable
event_wait_or_sleep   # disabled: sleeps without calling wait_transition
WTN=$(wc -l < "$TMP/wtcalls" | tr -d '[:space:]')
[ "$WTN" = 2 ] || fail "after EVENT_CAP_FAIL_MAX connect failures the event path must be disabled for the process (expected 2 wait_transition calls, got $WTN)"
pass "event_wait_or_sleep: consecutive event-path failures disable the fast-path and revert to pure polling (fail-closed)"


# --- event_wait_or_sleep: a native edge record reaches handle_push_transition --
# The wait now runs in its own process group and hands its record back through
# a private file, so this pins that an actionable edge still arrives intact.

reset_state
fm_write_meta "$STATE_DIR/tk6.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() { printf 'EDGE-RECORD-6'; return 0; }
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
handle_push_transition() { printf '%s' "$3" > "$TMP/handled"; }
event_wait_or_sleep
[ "$(cat "$TMP/handled" 2>/dev/null || true)" = EDGE-RECORD-6 ] || fail "an actionable edge must reach handle_push_transition verbatim, got '$(cat "$TMP/handled" 2>/dev/null || true)'"
[ -z "$(ls "$STATE_DIR"/.fm-eventwait.* 2>/dev/null || true)" ] || fail "the wait's private record file must not be left behind"
pass "event_wait_or_sleep: a native edge record is handed to handle_push_transition intact and its scratch file is removed"

# --- the tap: a durable append ends the terminal wait at once -----------------
# fm_wake_tap_watcher rings the watcher with USR1; the handler below is the one
# the main entry installs. These cases install it in this shell, use a real
# sleep, and ring from a helper subprocess.

trap watcher_tap USR1
# The real sleep for the timed cases below, run the way the watcher's own
# background wait behaves: the stopped child forwards TERM to what it forked,
# so a tapped wait leaves no sleeper behind (asserted after each case). The
# sleeper's own pid is published so each case asserts on THAT process - these
# suites run on shared always-on machines, where a command-line match would see
# every unrelated sleeper on the host.
SLEEPER_PID_FILE="$TMP/sleeper.pid"
# shellcheck disable=SC2329 # Runtime override called by the sourced watcher.
sleep() {
  local s
  # Trap first, single-quoted: a tap landing between the fork and the record
  # below would otherwise kill this wait child under the default disposition
  # and orphan the sleeper it had just started.
  # shellcheck disable=SC2016 # Expanded at signal time on purpose: the pid is this call's.
  trap '[ -z "${s:-}" ] || kill "$s" 2>/dev/null; exit 143' TERM
  command sleep "$@" &
  s=$!
  printf '%s\n' "$s" > "$SLEEPER_PID_FILE"
  wait "$s"
}
ring_after() { ( command sleep "$1"; kill -USR1 "$2" ) & }
no_sleeper_left() {  # the sleeper this case started must be gone
  local s i=0
  s=$(cat "$SLEEPER_PID_FILE" 2>/dev/null || true)
  # No pid recorded means no sleeper was ever started - a tap that landed
  # before the wait forked skips the sleep entirely, which is correct. The file
  # is removed before each case, so absence is unambiguous.
  [ -n "$s" ] || return 0
  # It is a grandchild (the stopped wait child forked it), so it is reaped by
  # init a moment after that child exits.
  while [ "$i" -lt 30 ]; do
    kill -0 "$s" 2>/dev/null || return 0
    command sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# A tap that already landed mid-cycle skips the wait entirely.
reset_state
FM_WATCH_TAPPED=1
# shellcheck disable=SC2034 # Read by the sourced watcher's poll_wait.
POLL=5
started=$(date +%s)
poll_wait
[ $(( $(date +%s) - started )) -lt 3 ] || fail "an already-tapped watcher must not sleep its poll"
[ "$FM_WATCH_WAIT_STATUS" = tapped ] || fail "an already-tapped wait must report tapped, got '$FM_WATCH_WAIT_STATUS'"
pass "poll_wait: a tap that landed earlier in the cycle skips the terminal wait"

# A tap during the sleep ends it at once and leaves no child behind.
reset_state
FM_WATCH_TAPPED=0
# shellcheck disable=SC2034 # Read by the sourced watcher's poll_wait.
POLL=53
rm -f "$SLEEPER_PID_FILE"
ring_after 0.3 "$$"
started=$(date +%s)
poll_wait
wait  # the ringer
[ $(( $(date +%s) - started )) -lt 3 ] || fail "a tap during the poll sleep must end it at once"
no_sleeper_left || fail "the tapped poll sleep left its sleeper running"
[ "$FM_WATCH_WAIT_STATUS" = tapped ] || fail "a tapped sleep must report tapped, got '$FM_WATCH_WAIT_STATUS'"
[ -z "$FM_WATCH_WAIT_CHILD" ] || fail "the wait child must be cleared after a tap"
[ "$FM_WATCH_TAPPED" = 1 ] || fail "the tap flag stays set until the next cycle top resets it"
pass "poll_wait: a tap during the sleep ends the wait immediately"

# A tap during the native event wait ends it too, counts as a clean wait, and
# never hands a partial or absent record to handle_push_transition.
reset_state
FM_WATCH_TAPPED=0
# shellcheck disable=SC2034 # Read by the sourced watcher's poll_wait.
POLL=5
fm_write_meta "$STATE_DIR/tk7.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 0; }
# Blocks the way the real Herdr wait does: a forked helper it stops on TERM.
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() { sleep 54; printf 'LATE-EDGE'; return 0; }
rm -f "$TMP/handled"
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
handle_push_transition() { printf '%s' "$3" > "$TMP/handled"; }
rm -f "$SLEEPER_PID_FILE"
ring_after 0.3 "$$"
started=$(date +%s)
event_wait_or_sleep
wait  # the ringer
[ $(( $(date +%s) - started )) -lt 3 ] || fail "a tap during the native event wait must end it at once"
[ ! -e "$TMP/handled" ] || fail "a tapped event wait must not deliver a record"
[ "$_event_cap_fails" = 0 ] || fail "a tapped event wait is a clean wait, not an event-path failure (fails=$_event_cap_fails)"
[ "$_event_cap_ok" = 1 ] || fail "a tapped event wait must leave the event path enabled"
[ -z "$(ls "$STATE_DIR"/.fm-eventwait.* 2>/dev/null || true)" ] || fail "a tapped event wait must remove its scratch record file"
no_sleeper_left || fail "the tapped event wait left its helper running"
pass "event_wait_or_sleep: a tap during the native event wait ends it cleanly with the event path intact"

# The sleeper override above is a terminal-wait stand-in only. Drop it before
# the check case, so the short internal sleeps on that path cannot clobber this
# file's sleeper pid or rewrite the main shell's TERM disposition.
unset -f sleep

# A tap is only ever allowed to end the TERMINAL wait. run_check_capture blocks
# on its own `wait` for the check's process, and a trapped signal returns that
# wait early with the check still running - so a tap landing mid-check must not
# be read as "the check finished", or the watcher tears down a live check and
# surfaces its half-written output as the result. The check below prints its
# answer only at the end, so a truncated or dropped read is visible.
reset_state
FM_WATCH_TAPPED=0
CHECK_SCRIPT="$TMP/slow-check.sh"
cat > "$CHECK_SCRIPT" <<'CHK'
sleep 1
printf 'merged pr 4242\n'
CHK
ring_after 0.3 "$$"
run_check_capture "$CHECK_SCRIPT" || fail "run_check_capture must still succeed when a tap lands mid-check"
wait  # the ringer
[ "$FM_CHECK_RESULT" = "merged pr 4242" ] || fail "a tap during a check must not truncate or drop its result, got '$FM_CHECK_RESULT'"
[ "$FM_WATCH_TAPPED" = 1 ] || fail "the tap must still be recorded for this cycle's terminal wait"
pass "run_check_capture: a tap arriving mid-check leaves the check's result whole"
trap - HUP INT TERM
trap - USR1

echo "# fm-supervision-events.test.sh: all assertions passed"
