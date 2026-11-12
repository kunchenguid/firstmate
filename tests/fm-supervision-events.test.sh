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
  _event_cap_off_at=0
  _event_cap_panes=""
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

# --- event_wait_or_sleep: the switch-off is named, and it recovers -----------

triage_text() { cat "$STATE_DIR/.watch-triage.log" 2>/dev/null || true; }

reset_state
fm_write_meta "$STATE_DIR/tk6.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
export EVENT_CAP_FAIL_MAX=2
EVENT_CAP_RETRY_SECS=300
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() {
  printf 'WT\n' >> "$TMP/wtcalls"
  printf 'herdr subscription rejected (pane_not_found: pane wG:pGone not found)\n' >> "${FM_BACKEND_EVENTS_DIAG_FILE:-/dev/null}"
  return 2
}
: > "$TMP/wtcalls"
event_wait_or_sleep   # fails=1
event_wait_or_sleep   # fails=2 -> off
event_wait_or_sleep   # off: polls only
[ "$(wc -l < "$TMP/wtcalls" | tr -d '[:space:]')" = 2 ] || fail "setup: the path must be off after EVENT_CAP_FAIL_MAX failures"
assert_contains "$(triage_text)" "event path off after 2 consecutive failures (herdr:default)" "the shutoff must be named in the triage log"
assert_contains "$(triage_text)" "pane wG:pGone not found" "the shutoff line must carry the backend's cause"
[ "$(triage_text | grep -c 'event path off after')" = 1 ] || fail "the switch-off must be logged once, not every cycle, got: $(triage_text)"
pass "event_wait_or_sleep: the failure switch-off is named in the triage log with its cause"

# A changed pane set lifts the switch-off.
fm_write_meta "$STATE_DIR/tk7.meta" "window=default:wG:pR" "backend=herdr" "kind=ship"
event_wait_or_sleep
[ "$(wc -l < "$TMP/wtcalls" | tr -d '[:space:]')" = 3 ] || fail "a changed watched-pane set must re-arm the event path"
assert_contains "$(triage_text)" "event path re-armed: watched pane set changed" "the re-arm must be logged"
pass "event_wait_or_sleep: a changed pane set re-arms a switched-off event path"

# The retry timer lifts it too, with one probationary cycle.
reset_state
fm_write_meta "$STATE_DIR/tk6.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
: > "$TMP/wtcalls"
event_wait_or_sleep
event_wait_or_sleep   # off
_event_cap_off_at=$(( $(date +%s) - EVENT_CAP_RETRY_SECS - 1 ))
event_wait_or_sleep   # timer re-arm -> probation: one failure switches it off again
[ "$(wc -l < "$TMP/wtcalls" | tr -d '[:space:]')" = 3 ] || fail "the retry timer must re-arm the event path, got $(wc -l < "$TMP/wtcalls") calls"
assert_contains "$(triage_text)" "event path re-armed: retrying after 300s" "the timer re-arm must be logged"
[ "$_event_cap_ok" = 0 ] || fail "a failed probationary cycle must switch the path off again"
[ "$(triage_text | grep -c 'event path off after')" = 2 ] || fail "the second switch-off must be named too: $(triage_text)"
event_wait_or_sleep   # still off, timer not due
[ "$(wc -l < "$TMP/wtcalls" | tr -d '[:space:]')" = 3 ] || fail "the path must stay off until the next retry is due"
pass "event_wait_or_sleep: the retry timer re-arms the path for one probationary cycle and a repeat failure is named again"

# A recovered probation stays on.
reset_state
fm_write_meta "$STATE_DIR/tk6.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
fm_backend_wait_transition() { printf 'WT\n' >> "$TMP/wtcalls"; return 1; }
: > "$TMP/wtcalls"
_event_cap_key="herdr:default"; _event_cap_ok=0; _event_cap_off_at=$(( $(date +%s) - EVENT_CAP_RETRY_SECS - 1 ))
_event_cap_panes="default:wG:pQ "
event_wait_or_sleep
event_wait_or_sleep
[ "$(wc -l < "$TMP/wtcalls" | tr -d '[:space:]')" = 2 ] || fail "a probationary cycle that succeeds must leave the event path on"
pass "event_wait_or_sleep: a probationary cycle that succeeds leaves the event path on"

# --- event_wait_or_sleep + real herdr adapter: one gone pane, one blocked pane -

reset_state
export EVENT_CAP_FAIL_MAX=3
. "$ROOT/bin/fm-backend.sh"   # restore the real dispatchers over the overrides above
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.9.5","protocol":22},"server":{"running":true}}\n' ;;
  "session list") printf '{"sessions":[{"name":"default","running":true,"default":true,"socket_path":"/tmp/fm-fake.sock"}]}\n' ;;
  "pane get")
    if [ "${3:-}" = "wG:pGone" ]; then printf '{"error":{"code":"pane_not_found","message":"pane wG:pGone not found"}}\n'; exit 1; fi
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "agent get") printf '{"result":{"agent":{"agent":"claude","agent_status":"blocked"}}}\n' ;;
esac
exit 0
SH
cat > "$FAKEBIN/reader" <<'SH'
#!/usr/bin/env bash
shift 2
for pane in "$@"; do
  if [ "$pane" = "wG:pGone" ]; then printf '@error\tpane_not_found\tpane wG:pGone not found\n'; exit 3; fi
done
printf '@subscribed\n'
exit 0
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/reader"
fm_write_meta "$STATE_DIR/tkgone.meta" "window=default:wG:pGone" "backend=herdr" "kind=ship"
fm_write_meta "$STATE_DIR/tklive.meta" "window=default:wG:pLive" "backend=herdr" "kind=ship"
PATH="$FAKEBIN:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_BACKEND_HERDR_EVENT_READER="$FAKEBIN/reader" event_wait_or_sleep
grep -q 'default:wG:pLive' "$STATE_DIR/.wake-queue" 2>/dev/null || fail "the blocked pane's push wake must still fire past one gone pane, queue: $(cat "$STATE_DIR/.wake-queue" 2>/dev/null)"
grep -q 'herdr: agent blocked' "$STATE_DIR/.wake-queue" || fail "the wake must name the herdr-blocked cause"
[ "$_event_cap_fails" = 0 ] || fail "a recovered cycle must not count toward the shutoff, got $_event_cap_fails"
pass "event_wait_or_sleep: one gone pane plus one blocked pane still wakes on the blocked pane"

echo "# fm-supervision-events.test.sh: all assertions passed"
