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
    "$STATE_DIR"/watched-panes \
    "$STATE_DIR"/.wake-queue.seq "$STATE_DIR"/.watch-triage.log \
    "$STATE_DIR"/.herdr-escalated-* "$TMP"/panes "$TMP"/wtcalls "$TMP"/wtcalled 2>/dev/null || true
  : > "$WAKE_LOG"
  : > "$SLEEP_LOG"
  _event_cap_key=""
  _event_cap_ok=0
  _event_cap_fails=0
  FM_WATCHED_PANES=
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
rm -f "$STATE_DIR"/.rex-escalated-* 2>/dev/null || true
fm_write_meta "$STATE_DIR/tk1.meta" "window=0a1b-c2:3d4e-f5" "backend=rex" "kind=ship"
handle_push_transition rex 0a1b-c2 "$(fm_transition_record 3d4e-f5 "" "" blocked claude-code "permission: Allow Bash: rm -rf build")"
grep -q 'stale	0a1b-c2:3d4e-f5' "$STATE_DIR/.wake-queue" || fail "a rex push must name the task's recorded window: $(cat "$STATE_DIR/.wake-queue")"
grep -q 'rex: agent blocked (permission: Allow Bash: rm -rf build) - waiting on human' "$STATE_DIR/.wake-queue" \
  || fail "the stale payload must name rex and carry the blocked kind and message: $(cat "$STATE_DIR/.wake-queue")"
[ -e "$STATE_DIR/.rex-escalated-0a1b-c2_3d4e-f5" ] || fail "the rex dedupe marker must be committed after enqueue"
pass "handle_push_transition: a rex blocked edge's wake names the backend and carries Rex's blocked kind and message"

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

# --- event_wait_or_sleep: a T3 task never takes herdr's fast path away -------

reset_state
fm_write_meta "$STATE_DIR/api-fix.meta" "window=fm-api-fix" "backend=t3code" "t3_thread_id=mcp:thread-api" "kind=ship"
fm_write_meta "$STATE_DIR/web-ui.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() { printf '%s %s\n' "$1" "$*" > "$TMP/panes"; return 1; }
event_wait_or_sleep
PANES=$(cat "$TMP/panes" 2>/dev/null || true)
case "$PANES" in "herdr "*"default:wG:pQ"*) : ;; *) fail "a mixed home must keep herdr's push wait even when a T3 task sorts first, got '$PANES'" ;; esac
rm -f "$STATE_DIR/web-ui.meta" "$TMP/panes"
_event_cap_key=""
event_wait_or_sleep
PANES=$(cat "$TMP/panes" 2>/dev/null || true)
case "$PANES" in "t3code "*) : ;; *) fail "a T3-only home must use T3's bounded wait, got '$PANES'" ;; esac
pass "event_wait_or_sleep: herdr keeps the push wait in a mixed home; T3's wait runs only without another push backend"

reset_state
fm_write_meta "$STATE_DIR/tk3.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
CAP_CALLS=0
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { CAP_CALLS=$((CAP_CALLS + 1)); return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() {
  # The wait runs in its own process, so record what it saw for the assertion.
  printf '%s\n' "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" >> "$TMP/wtcalls"
  return 1
}
: > "$TMP/wtcalls"
event_wait_or_sleep
event_wait_or_sleep
[ "$CAP_CALLS" = 1 ] || fail "capability probe must be memoized across waits, got $CAP_CALLS calls"
[ "$(cat "$TMP/wtcalls")" = $'1\n1' ] || fail "cached capability verdict was not passed to each wait, got: $(cat "$TMP/wtcalls")"
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

# --- operator watches: explicit backend, task precedence, refresh and polling --
reset_state
fm_backend_source herdr || fail "load Herdr backend"
# shellcheck disable=SC2329 # Runtime fixture for the explicit identity boundary.
fm_backend_herdr_resolve_watched_pane() {
  case "$3" in
    design) printf '%s:%s' "$1" "$(cat "$TMP/current-pane")" ;;
    ship) printf '%s:wG:pQ' "$1" ;;
    mate) printf '%s:wA:pS' "$1" ;;
    missing) return 1 ;;
  esac
}
# shellcheck disable=SC2329 # Runtime fixture for level reconciliation.
fm_backend_herdr_agent_status_raw() { cat "$TMP/agent-status"; }
# shellcheck disable=SC2329 # Runtime fixture for one multiplexed wait.
fm_backend_wait_transition() { printf '%s\n' "$*" >> "$TMP/watch-calls"; return 1; }
# shellcheck disable=SC2329 # Runtime capability fixture.
fm_backend_events_capable() { return 0; }
printf 'wD:p1' > "$TMP/current-pane"
printf working > "$TMP/agent-status"
printf 'default\tops\tdesign\tDesign review\t1\ndefault\tops\tship\tShip alias\t1\ndefault\tops\tmate\tMate alias\t1\ndefault\tops\tmissing\tMissing\t0\nother\tops\tdesign\tOther design\t0\n' > "$STATE_DIR/watched-panes"
fm_write_meta "$STATE_DIR/ship.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
fm_write_meta "$STATE_DIR/mate.meta" "window=default:wA:pS" "backend=herdr" "kind=secondmate"
: > "$TMP/watch-calls"
event_wait_or_sleep
CALL=$(cat "$TMP/watch-calls")
assert_contains "$CALL" 'default:wD:p1' "metadata-free watch missing from wait"
assert_not_contains "$CALL" 'default:wA:pS' "secondmate alias must remain excluded"
assert_not_contains "$CALL" 'other:wD:p1' "another session must stay on polling path"
[ "$(printf '%s\n' "$CALL" | tr ' ' '\n' | grep -cx default:wG:pQ)" = 1 ] || fail "task/watch endpoint must be deduped"
[ "$(fm_watch_pane_context default:wG:pQ)" = task ] || fail "ordinary task must retain done policy"
[ "$(fm_watch_pane_context default:wD:p1)" = watched-done ] || fail "operator done opt-in missing"
printf wD:p2 > "$TMP/current-pane"
: > "$TMP/watch-calls"
event_wait_or_sleep
assert_contains "$(cat "$TMP/watch-calls")" default:wD:p2 "pane ID must refresh at wait time"
assert_not_contains "$(cat "$TMP/watch-calls")" default:wD:p1 "stale ID must not remain subscribed"
pass "registry merges with task endpoints, retains secondmate/task policy, groups sessions and refreshes IDs"

printf blocked > "$TMP/agent-status"
event_wait_or_sleep
assert_contains "$(cat "$WAKE_LOG")" 'watched pane Design review (default:wD:p2, herdr: agent blocked)' "watch wake must name label and status"
N=$(wc -l < "$WAKE_LOG")
event_wait_or_sleep
[ "$(wc -l < "$WAKE_LOG")" = "$N" ] || fail "reconnect/poll must dedupe watched blocked"
printf "done" > "$TMP/agent-status"
# shellcheck disable=SC2329 # Force the existing polling fallback.
fm_backend_events_capable() { return 1; }
_event_cap_key=
event_wait_or_sleep
assert_contains "$(cat "$WAKE_LOG")" 'watched pane Design review (default:wD:p2, herdr: agent done)' "opted-in done must wake even without push"
assert_not_contains "$(cat "$WAKE_LOG")" 'Other design (other:wD:p2, herdr: agent done)' "done must remain opt-in"
N=$(wc -l < "$WAKE_LOG")
event_wait_or_sleep
[ "$(wc -l < "$WAKE_LOG")" = "$N" ] || fail "done level reconcile must dedupe"
printf working > "$TMP/agent-status"
event_wait_or_sleep
printf blocked > "$TMP/agent-status"
event_wait_or_sleep
[ "$(wc -l < "$WAKE_LOG")" -gt "$N" ] || fail "working must rearm watches"
pass "watch reasons reach the durable wake queue, dedupe blocked/done, rearm on working and poll without push"

echo "# fm-supervision-events.test.sh: all assertions passed"
