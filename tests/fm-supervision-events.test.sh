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
FAST_REPAIR_PROGRESS_TICK_PRODUCTION=$(declare -f fast_repair_progress_tick)

# Overrides: capture wake reasons and neutralize real sleeps (POLL is 15s).
WAKE_LOG="$TMP/wakes"
SLEEP_LOG="$TMP/sleeps"
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
wake() { printf '%s\n' "$1" >> "$WAKE_LOG"; return 0; }
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
sleep() { printf 'SLEEP\n' >> "$SLEEP_LOG"; }

reset_state() {
  rm -f "$STATE_DIR"/*.meta "$STATE_DIR"/*.status "$STATE_DIR"/.wake-queue \
    "$STATE_DIR"/.wake-queue.seq "$STATE_DIR"/.watch-triage.log \
    "$STATE_DIR"/.herdr-escalated-* "$STATE_DIR"/.fast-repair-progress-wake \
    "$STATE_DIR"/.fast-repair-progress-* "$STATE_DIR"/.last-fast-repair-progress* \
    "$STATE_DIR"/.fast-repair-progress-handoff-* \
    "$STATE_DIR"/.fast-repair-progress-timer.* \
    "$TMP"/panes "$TMP"/wtcalls "$TMP"/wtcalled "$TMP"/fast-repair-transition-complete \
    "$TMP"/fast-repair-parent-returned "$TMP"/fast-repair-handoff-blocked 2>/dev/null || true
  : > "$WAKE_LOG"
  : > "$SLEEP_LOG"
  _event_cap_key=""
  _event_cap_ok=0
  _event_cap_fails=0
  # shellcheck disable=SC2034 # Reset global consumed by the sourced watcher.
  FAST_REPAIR_TIMER_MARKER=
  FAST_REPAIR_TIMER_GENERATION=0
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
  [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" = 1 ] || fail "cached capability verdict was not passed to the wait"
  return 1
}
event_wait_or_sleep
event_wait_or_sleep
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

reset_state
fm_write_meta "$STATE_DIR/tk6.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
FAST_REPAIR_ACTIVE=0
: > "$TMP/forge-called"
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
fast_repair_progress_tick() { printf 'called\n' >> "$TMP/forge-called"; }
fast_repair_progress_discover
[ "$FAST_REPAIR_ACTIVE" = 1 ] || fail "Fast Repair metadata was not discovered for its wait-time timer"
[ ! -s "$TMP/forge-called" ] || fail "Fast Repair Forge progress work ran in the main supervision loop"
pass "fast_repair_progress_discover: main supervision reads only Fast Repair metadata"

reset_state
unset -f sleep
FAST_REPAIR_ACTIVE=1
FAST_REPAIR_TIMER_PID=
FAST_REPAIR_TIMER_MARKER=
FAST_REPAIR_PROGRESS_INTERVAL=1
POLL=10
WATCHER_PID=$$
mkdir -p "$WATCH_LOCK"
printf '%s\n' "$WATCHER_PID" > "$WATCH_LOCK/pid"
touch "$STATE_DIR/.last-fast-repair-progress"
: > "$TMP/fast-repair-timer-ticks"
fast_repair_progress_tick() {
  printf 'tick\n' >> "$TMP/fast-repair-timer-ticks"
  FAST_REPAIR_ACTIVE=1
}
fast_repair_progress_timer_start
command sleep 4.5
fast_repair_progress_timer_finish
wait "$FAST_REPAIR_TIMER_PID" 2>/dev/null || true
[ "$(wc -l < "$TMP/fast-repair-timer-ticks" | tr -d '[:space:]')" -ge 2 ] \
  || fail "a long Fast Repair wait did not repeat its progress timer"
pass "fast_repair_progress_timer_start: Fast Repair repeats progress ticks during a long wait"
eval "$FAST_REPAIR_PROGRESS_TICK_PRODUCTION"

reset_state
fm_write_meta "$STATE_DIR/tk6.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
FAST_REPAIR_ACTIVE=1
FAST_REPAIR_TIMER_GENERATION=1
WATCHER_PID=${BASHPID:-$$}
mkdir -p "$WATCH_LOCK"
printf '%s\n' "$WATCHER_PID" > "$WATCH_LOCK/pid"
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
fast_repair_progress_timer_start() {
  (
    command sleep 0.05
    printf '%s\n%s\n%s\n' 1 tk6 'fast-repair tk6 broader-tests-failed' \
      > "$STATE_DIR/.fast-repair-progress-handoff-tk6-1"
  ) &
}
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
fm_backend_wait_transition() {
  command sleep 0.15
  printf 'complete\n' > "$TMP/fast-repair-transition-complete"
  return 1
}
event_wait_or_sleep
[ -e "$TMP/fast-repair-transition-complete" ] || fail "a Fast Repair timer interrupted the existing backend transition wait"
grep -q 'check: fast-repair tk6 broader-tests-failed' "$WAKE_LOG" \
  || fail "the durable Fast Repair timer result was not surfaced after the backend transition wait"
pass "event_wait_or_sleep: Fast Repair keeps its timer result durable through the full backend wait"

reset_state
fm_write_meta "$STATE_DIR/tk7.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
FAST_REPAIR_ACTIVE=1
FAST_REPAIR_TIMER_MARKER=
PARENT_PID=${BASHPID:-$$}
WATCHER_PID=$PARENT_PID
mkdir -p "$WATCH_LOCK"
printf '%s\n' "$WATCHER_PID" > "$WATCH_LOCK/pid"
trap 'fast_repair_progress_timer_wake' USR1
wake() { printf '%s\t%s\n' "${BASHPID:-$$}" "$1" >> "$WAKE_LOG"; return 0; }
fast_repair_progress_timer_start() {
  local marker closing parent=$WATCHER_PID generation
  FAST_REPAIR_TIMER_GENERATION=$((FAST_REPAIR_TIMER_GENERATION + 1))
  generation=$FAST_REPAIR_TIMER_GENERATION
  marker=$(mktemp "$STATE_DIR/.fast-repair-progress-timer.XXXXXX")
  closing="$marker.closing"
  # shellcheck disable=SC2034 # Timer cleanup in the sourced watcher reads this global.
  FAST_REPAIR_TIMER_MARKER=$marker
  (
    command sleep 0.5
    [ -e "$TMP/fast-repair-parent-returned" ] || : > "$TMP/fast-repair-handoff-blocked"
    FM_FAST_REPAIR_TIMER_PARENT="$parent" \
      FM_FAST_REPAIR_TIMER_CLOSING="$closing" \
      FM_FAST_REPAIR_TIMER_GENERATION="$generation" \
      fast_repair_progress_timer_publish tk7 'fast-repair tk7 pr-checks-failed'
    FM_FAST_REPAIR_TIMER_PARENT="$parent" \
      FM_FAST_REPAIR_TIMER_CLOSING="$closing" \
      fast_repair_progress_timer_notify
  ) &
  FAST_REPAIR_TIMER_PID=$!
}
fm_backend_events_capable() { return 0; }
fm_backend_wait_transition() {
  command sleep 0.05
  printf 'complete\n' > "$TMP/fast-repair-transition-complete"
  return 1
}
event_wait_or_sleep
: > "$TMP/fast-repair-parent-returned"
command sleep 0.6
[ -e "$TMP/fast-repair-transition-complete" ] || fail "the shutdown handoff interrupted the backend transition wait"
[ ! -e "$TMP/fast-repair-handoff-blocked" ] || fail "the timer child survived the completed wait"
[ ! -s "$WAKE_LOG" ] || fail "a shutdown handoff woke the watcher outside its safe boundary"
fast_repair_progress_timer_wake
[ ! -s "$WAKE_LOG" ] || fail "a retired timer child published after the completed wait"
pass "event_wait_or_sleep: Fast Repair retires a running timer child at wait shutdown"

reset_state
fm_write_meta "$STATE_DIR/tk8.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
PARENT_PID=${BASHPID:-$$}
WATCHER_PID=$PARENT_PID
mkdir -p "$WATCH_LOCK"
printf '%s\n' "$WATCHER_PID" > "$WATCH_LOCK/pid"
FAST_REPAIR_TIMER_GENERATION=2
: > "$STATE_DIR/current.closing"
: > "$STATE_DIR/stale.closing"
FM_FAST_REPAIR_TIMER_PARENT="$WATCHER_PID" \
FM_FAST_REPAIR_TIMER_CLOSING="$STATE_DIR/current.closing" \
FM_FAST_REPAIR_TIMER_GENERATION=2 \
  fast_repair_progress_timer_publish tk8 'fast-repair tk8 pr-checks-green'
fast_repair_progress_timer_wake
FM_FAST_REPAIR_TIMER_PARENT="$WATCHER_PID" \
FM_FAST_REPAIR_TIMER_CLOSING="$STATE_DIR/stale.closing" \
FM_FAST_REPAIR_TIMER_GENERATION=1 \
  fast_repair_progress_timer_publish tk8 'fast-repair tk8 pr-checks-failed'
fast_repair_progress_timer_wake
grep -q 'check: fast-repair tk8 pr-checks-green' "$WAKE_LOG" \
  || fail "the newest Fast Repair result was not delivered"
if grep -q 'check: fast-repair tk8 pr-checks-failed' "$WAKE_LOG"; then
  fail "an older Fast Repair timer result published after a newer result"
fi
pass "fast_repair_progress_timer_wake: stale timer results cannot publish"

reset_state
fm_write_meta "$STATE_DIR/tk12.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
OLD_WATCHER=41001
NEW_WATCHER=41002
WATCHER_PID=$OLD_WATCHER
FM_FAST_REPAIR_TIMER_PARENT="$OLD_WATCHER" \
  FM_FAST_REPAIR_TIMER_GENERATION=7 \
  fast_repair_progress_timer_publish tk12 'fast-repair tk12 broader-tests-failed'
WATCHER_PID=$NEW_WATCHER
fast_repair_progress_timer_wake
grep -q 'fast-repair:tk12' "$STATE_DIR/.wake-queue" \
  || fail "a replacement watcher did not deliver a prior watcher's Fast Repair handoff"
pass "fast_repair_progress_timer_wake: task handoffs survive watcher replacement"

reset_state
fm_write_meta "$STATE_DIR/tk13.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
FM_FAST_REPAIR_TIMER_GENERATION=8 \
  fast_repair_progress_timer_publish tk13 'fast-repair tk13 pr-checks-failed'
rm -f "$STATE_DIR/tk13.meta"
fast_repair_progress_timer_wake
[ ! -e "$STATE_DIR/.wake-queue" ] \
  || fail "a torn-down Fast Repair task surfaced a queued progress result"
[ -z "$(compgen -G "$STATE_DIR/.fast-repair-progress-handoff-tk13-8-*" || true)" ] \
  || fail "a torn-down Fast Repair handoff was not discarded after lifecycle revalidation"
pass "fast_repair_progress_timer_wake: torn-down tasks discard pending handoffs"

reset_state
fm_write_meta "$STATE_DIR/tk14.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
FAST_REPAIR_PROGRESS_INTERVAL=20
: > "$TMP/progress-checks"
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
run_check_capture() {
  printf 'check\n' >> "$TMP/progress-checks"
  # shellcheck disable=SC2034 # Result contract consumed by the sourced watcher.
  FM_CHECK_RESULT=
}
FM_FAST_REPAIR_TIMER_GENERATION=9 fast_repair_progress_tick
FM_FAST_REPAIR_TIMER_GENERATION=10 fast_repair_progress_tick
for _ in $(seq 1 50); do
  [ -s "$TMP/progress-checks" ] && break
  command sleep 0.01
done
[ "$(wc -l < "$TMP/progress-checks" | tr -d '[:space:]')" = 1 ] \
  || fail "short waits reset the Fast Repair progress cadence"
pass "fast_repair_progress_tick: short waits retain the task progress cadence"

reset_state
fm_write_meta "$STATE_DIR/tk14a.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
# shellcheck disable=SC2034 # Poll cadence consumed by the sourced watcher.
POLL=15
# shellcheck disable=SC2034 # Progress cadence consumed by the sourced watcher.
FAST_REPAIR_PROGRESS_INTERVAL=20
FAST_REPAIR_NOW=100
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
date() {
  [ "${1:-}" = +%s ] && { printf '%s\n' "$FAST_REPAIR_NOW"; return 0; }
  command date "$@"
}
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
run_check_capture() {
  printf 'check\n' >> "$TMP/default-poll-checks"
  # shellcheck disable=SC2034 # Result contract consumed by the sourced watcher.
  FM_CHECK_RESULT=
}
fast_repair_progress_schedule_missing
[ "$(cat "$STATE_DIR/.fast-repair-progress-next-due-tk14a")" = 120 ] \
  || fail "the default poll did not persist a 20-second Fast Repair due time"
FAST_REPAIR_NOW=115
FM_FAST_REPAIR_TIMER_GENERATION=10 fast_repair_progress_tick
[ ! -e "$TMP/default-poll-checks" ] \
  || fail "the first 15-second normal wait ran Fast Repair progress too early"
[ "$(fast_repair_progress_timer_delay)" = 5 ] \
  || fail "the second default-poll timer did not retain the remaining due delay"
FAST_REPAIR_NOW=120
FM_FAST_REPAIR_TIMER_GENERATION=11 fast_repair_progress_tick
for _ in $(seq 1 50); do
  [ -s "$TMP/default-poll-checks" ] && break
  command sleep 0.01
done
[ -s "$TMP/default-poll-checks" ] \
  || fail "the second default-poll wait did not run the due Fast Repair check"
fast_repair_progress_timer_tasks_finish 11
unset -f date
pass "fast_repair_progress_tick: default polls retain Fast Repair due time across waits"

reset_state
fm_write_meta "$STATE_DIR/tk9a.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
fm_write_meta "$STATE_DIR/tk9b.meta" "window=default:wG:pR" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
WATCHER_PID=${BASHPID:-$$}
FAST_REPAIR_TIMER_GENERATION=3
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
run_check_capture() {
  case "${!#}" in
    tk9a) FM_CHECK_RESULT='fast-repair tk9a pr-checks-green' ;;
    tk9b) FM_CHECK_RESULT='fast-repair tk9b broader-tests-failed' ;;
    *) fail "unexpected Fast Repair progress task: ${!#}" ;;
  esac
}
FM_FAST_REPAIR_TIMER_PARENT="$WATCHER_PID" \
  FM_FAST_REPAIR_TIMER_GENERATION=3 \
  fast_repair_progress_tick
for _ in $(seq 1 50); do
  compgen -G "$STATE_DIR/.fast-repair-progress-handoff-tk9a-3-*" >/dev/null \
    && compgen -G "$STATE_DIR/.fast-repair-progress-handoff-tk9b-3-*" >/dev/null \
    && break
  command sleep 0.01
done
fast_repair_progress_timer_wake
grep -q 'fast-repair:tk9a' "$STATE_DIR/.wake-queue" \
  || fail "the first Fast Repair task was not queued"
grep -q 'fast-repair:tk9b' "$STATE_DIR/.wake-queue" \
  || fail "a later Fast Repair task was starved by the first task"
pass "fast_repair_progress_tick: one timer generation queues every eligible task"

reset_state
fm_write_meta "$STATE_DIR/tk10.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
WATCHER_PID=${BASHPID:-$$}
FAST_REPAIR_TIMER_GENERATION=5
FM_FAST_REPAIR_TIMER_PARENT="$WATCHER_PID" \
  FM_FAST_REPAIR_TIMER_GENERATION=4 \
  fast_repair_progress_timer_publish tk10 'fast-repair tk10 pr-checks-failed'
fast_repair_progress_timer_wake
grep -q 'fast-repair:tk10' "$STATE_DIR/.wake-queue" \
  || fail "a late prior-generation handoff was not delivered"
pass "fast_repair_progress_timer_wake: late prior-generation handoffs remain deliverable"

reset_state
fm_write_meta "$STATE_DIR/tk11.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
WATCHER_PID=${BASHPID:-$$}
FAST_REPAIR_TIMER_GENERATION=6
FM_FAST_REPAIR_TIMER_PARENT="$WATCHER_PID" \
  FM_FAST_REPAIR_TIMER_GENERATION=6 \
  fast_repair_progress_timer_publish tk11 'fast-repair tk11 pr-checks-failed'
APPEND_ATTEMPTS=0
fm_wake_append() {
  APPEND_ATTEMPTS=$((APPEND_ATTEMPTS + 1))
  [ "$APPEND_ATTEMPTS" -gt 1 ] || return 1
  printf 'retry\t%s\t%s\n' "$2" "$3" >> "$STATE_DIR/.wake-queue"
}
fast_repair_progress_timer_wake
compgen -G "$STATE_DIR/.fast-repair-progress-handoff-tk11-6-*" >/dev/null \
  || fail "a failed durable append discarded its Fast Repair handoff"
fast_repair_progress_timer_wake
[ -z "$(compgen -G "$STATE_DIR/.fast-repair-progress-handoff-tk11-6-*" || true)" ] \
  || fail "a successfully queued Fast Repair handoff was not retired"
grep -q 'fast-repair:tk11' "$STATE_DIR/.wake-queue" \
  || fail "a retained Fast Repair handoff did not retry its append"
pass "fast_repair_progress_timer_wake: append failure retains the handoff for retry"

reset_state
fm_write_meta "$STATE_DIR/tk15.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
WATCHER_PID=${BASHPID:-$$}
FM_FAST_REPAIR_TIMER_GENERATION=12 \
  fast_repair_progress_timer_publish tk15 'fast-repair tk15 broader-tests-failed'
FM_FAST_REPAIR_TIMER_GENERATION=12 \
  fast_repair_progress_timer_publish tk15 'fast-repair tk15 pr-checks-failed'
handoff_count=$(compgen -G "$STATE_DIR/.fast-repair-progress-handoff-tk15-12-*" | wc -l | tr -d '[:space:]')
[ "$handoff_count" = 2 ] || fail "two Fast Repair ticks did not retain two task handoffs"
fast_repair_progress_timer_wake
grep -q 'check: fast-repair tk15 broader-tests-failed' "$WAKE_LOG" \
  || fail "the first retained Fast Repair handoff was not surfaced"
grep -q 'fast-repair tk15 pr-checks-failed' "$WAKE_LOG" \
  || fail "the later retained Fast Repair handoff was not surfaced"
pass "fast_repair_progress_timer_wake: multiple task handoffs remain distinct until drain"

reset_state
retirement_pids=()
for retirement_id in a b; do
  retirement_ready="$TMP/retirement-$retirement_id.ready"
  retirement_term="$TMP/retirement-$retirement_id.term"
  FM_RETIREMENT_READY="$retirement_ready" FM_RETIREMENT_TERM="$retirement_term" \
    bash -c 'trap '\''printf term > "$FM_RETIREMENT_TERM"; sleep 0.15; exit 0'\'' TERM; : > "$FM_RETIREMENT_READY"; while :; do :; done' &
  retirement_pid=$!
  retirement_pids+=("$retirement_pid")
  for _ in $(seq 1 50); do
    [ -e "$retirement_ready" ] && break
    command sleep 0.01
  done
  [ -e "$retirement_ready" ] || fail "a Fast Repair retirement fixture did not start"
  printf '%s\n' "$retirement_pid" > "$STATE_DIR/.fast-repair-progress-child-$retirement_id-20"
done
fast_repair_progress_timer_tasks_finish 20 &
retirement_finish_pid=$!
command sleep 0.08
[ -e "$TMP/retirement-a.term" ] && [ -e "$TMP/retirement-b.term" ] || {
  kill "$retirement_finish_pid" 2>/dev/null || true
  wait "$retirement_finish_pid" 2>/dev/null || true
  for retirement_pid in "${retirement_pids[@]}"; do
    kill -TERM "$retirement_pid" 2>/dev/null || true
    wait "$retirement_pid" 2>/dev/null || true
  done
  fail "Fast Repair timer retirement did not signal every task before its bounded reap"
}
wait "$retirement_finish_pid" || fail "Fast Repair timer retirement did not finish"
for retirement_pid in "${retirement_pids[@]}"; do
  wait "$retirement_pid" 2>/dev/null || true
done
for retirement_id in a b; do
  [ ! -e "$STATE_DIR/.fast-repair-progress-child-$retirement_id-20" ] \
    || fail "Fast Repair timer retirement retained a child marker"
done
pass "fast_repair_progress_timer_tasks_finish: task retirement signals children concurrently"

reset_state
reservation_fakebin="$TMP/reservation-fakebin"
reservation_started="$TMP/reservation-started"
reservation_check="$TMP/reservation-check-ran"
mkdir -p "$reservation_fakebin"
cat > "$reservation_fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  *.starting.XXXXXX) ;;
  *.fast-repair-progress-child-*.XXXXXX)
    : > "$FM_RESERVATION_STARTED"
    sleep 0.2
    ;;
esac
exec "$FM_REAL_MKTEMP" "$@"
SH
chmod +x "$reservation_fakebin/mktemp"
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
run_check_capture() {
  : > "$reservation_check"
  # shellcheck disable=SC2034 # Result contract consumed by the sourced watcher.
  FM_CHECK_RESULT=
}
FM_RESERVATION_STARTED="$reservation_started" FM_REAL_MKTEMP="$(command -v mktemp)" \
  FM_FAST_REPAIR_TIMER_CLOSING="$STATE_DIR/reservation.closing" \
  PATH="$reservation_fakebin:$PATH" fast_repair_progress_task_start tk-reservation 21 &
reservation_starter=$!
for _ in $(seq 1 50); do
  [ -e "$reservation_started" ] && break
  command sleep 0.01
done
[ -e "$reservation_started" ] || fail "the Fast Repair task did not enter the pre-registration window"
: > "$STATE_DIR/reservation.closing"
fast_repair_progress_timer_tasks_finish 21
wait "$reservation_starter" || fail "the Fast Repair task starter did not finish"
for _ in $(seq 1 50); do
  [ ! -e "$STATE_DIR/.fast-repair-progress-child-tk-reservation-21" ] \
    && [ ! -e "$STATE_DIR/.fast-repair-progress-child-tk-reservation-21.ready" ] \
    && break
  command sleep 0.01
done
[ ! -e "$STATE_DIR/.fast-repair-progress-child-tk-reservation-21" ] \
  && [ ! -e "$STATE_DIR/.fast-repair-progress-child-tk-reservation-21.ready" ] \
  || fail "wait shutdown retained a pre-registration Fast Repair child"
[ ! -e "$reservation_check" ] || fail "a pre-registration Fast Repair child ran after shutdown"
pass "fast_repair_progress_timer_tasks_finish: reservations retire pre-registration children"

ordinary_check_state="$TMP/ordinary-check-state"
ordinary_check="$TMP/ordinary-check.sh"
ordinary_check_pid="$TMP/ordinary-check.pid"
ordinary_check_out="$TMP/ordinary-check.out"
mkdir -p "$ordinary_check_state"
cat > "$ordinary_check" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_ORDINARY_CHECK_PID"
trap '' TERM
while :; do sleep 1; done
SH
chmod +x "$ordinary_check"
if ! FM_STATE_OVERRIDE="$ordinary_check_state" FM_ORDINARY_CHECK_PID="$ordinary_check_pid" \
  bash -c '
    set -u
    . "$1"
    run_check_capture "$2" &
    runner=$!
    i=0
    while [ ! -s "$3" ] && [ "$i" -lt 50 ]; do sleep 0.01; i=$((i + 1)); done
    [ -s "$3" ] || exit 1
    check_pid=$(cat "$3")
    pgid=$(ps -o pgid= -p "$check_pid" 2>/dev/null | tr -d "[:space:]")
    case "$pgid" in ""|*[!0-9]*) exit 1 ;; esac
    trap "kill -KILL -- -$pgid 2>/dev/null || true; wait \"$runner\" 2>/dev/null || true" EXIT
    kill -TERM "$runner"
    wait "$runner"
    runner_status=$?
    [ "$runner_status" -eq 1 ] || exit 1
    kill -0 "$check_pid" 2>/dev/null
  ' _ "$ROOT/bin/fm-watch.sh" "$ordinary_check" "$ordinary_check_pid" > "$ordinary_check_out" 2>&1; then
  fail "an ordinary check signal stopped its active check group: $(cat "$ordinary_check_out")"
fi
pass "ordinary checks keep their original signal behavior"

fast_check_state="$TMP/fast-check-state"
fast_check="$TMP/fast-check.sh"
fast_check_pid="$TMP/fast-check.pid"
fast_check_out="$TMP/fast-check.out"
mkdir -p "$fast_check_state"
cat > "$fast_check" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_FAST_CHECK_PID"
trap '' TERM
while :; do sleep 1; done
SH
chmod +x "$fast_check"
if ! FM_STATE_OVERRIDE="$fast_check_state" FM_FAST_CHECK_PID="$fast_check_pid" \
  bash -c '
    set -u
    . "$1"
    check=$2
    WATCHER_PID=$$
    mkdir -p "$WATCH_LOCK"
    printf "%s\n" "$WATCHER_PID" > "$WATCH_LOCK/pid"
    FAST_REPAIR_ACTIVE=1
    POLL=10
    FAST_REPAIR_PROGRESS_INTERVAL=1
    fast_repair_progress_tick() { run_check_capture --stop-active-check-on-signal "$check"; }
    fast_repair_progress_timer_start
    trap "fast_repair_progress_timer_finish || true" EXIT
    i=0
    while [ ! -s "$3" ] && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
    [ -s "$3" ] || exit 1
    fast_repair_progress_timer_finish
    check_pid=$(cat "$3")
    ! kill -0 "$check_pid" 2>/dev/null
  ' _ "$ROOT/bin/fm-watch.sh" "$fast_check" "$fast_check_pid" > "$fast_check_out" 2>&1; then
  fail "Fast Repair timer retirement left its active check group alive: $(cat "$fast_check_out")"
fi
pass "Fast Repair timer retirement stops its active check group"

normal_home="$TMP/normal-usr1-home"
normal_state="$normal_home/state"
normal_data="$normal_home/data"
normal_out="$TMP/normal-usr1.out"
mkdir -p "$normal_state" "$normal_data"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$normal_home" FM_STATE_OVERRIDE="$normal_state" \
  FM_DATA_OVERRIDE="$normal_data" FM_POLL=60 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$normal_out" 2>&1 &
normal_pid=$!
normal_ready=0
for _ in $(seq 1 50); do
  if [ -s "$normal_state/.watch.lock/pid" ]; then
    normal_ready=1
    break
  fi
  kill -0 "$normal_pid" 2>/dev/null || break
  command sleep 0.02
done
if [ "$normal_ready" -ne 1 ]; then
  kill "$normal_pid" 2>/dev/null || true
  wait "$normal_pid" 2>/dev/null || true
  fail "an ordinary watcher did not start for the USR1 regression: $(cat "$normal_out")"
fi
kill -USR1 "$normal_pid" || fail "could not signal the ordinary watcher with USR1"
wait "$normal_pid"
normal_status=$?
[ "$normal_status" -eq 138 ] \
  || fail "an ordinary watcher changed its USR1 termination status: $normal_status"
pass "ordinary watcher keeps default USR1 termination behavior"

echo "# fm-supervision-events.test.sh: all assertions passed"
