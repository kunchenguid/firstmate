#!/usr/bin/env bash
# Portable regression for bin/fm-copilot-wake.sh: the typed wake for an idle
# GitHub Copilot CLI primary. A real tmux pane on a private socket runs a stand-in
# that draws Copilot's rule-box composer (tests/captures/copilot-1.0.105-tmux) and
# logs every submitted line, and a real watcher drives the first wake. Vendor
# facts are recorded in docs/verification/copilot.md; no Copilot install is needed.
# This half covers the first wake, deferral, retries and busy-state handling; the restart, log and
# transcript cases are in tests/fm-copilot-wake-restart.test.sh. Both source tests/fm-copilot-wake-lab.sh.
# shellcheck disable=SC2016 # single-quoted conditions are expanded by wait_until's eval
set -u

# shellcheck source=tests/fm-copilot-wake-lab.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-copilot-wake-lab.sh"

out=$("$WAKE" start 2>&1) || fail "start failed: $out; log: $(cat "$STATE/.copilot-wake.log" 2>/dev/null)"
case "$out" in 'copilot wake: running pid='*) ;; *) fail "start must report a running process: $out" ;; esac
WAKE_PID=$(cat "$STATE/.copilot-wake.lock/pid")
out=$("$WAKE" start 2>&1) || fail "a second start failed: $out"
[ "$(cat "$STATE/.copilot-wake.lock/pid")" = "$WAKE_PID" ] || fail "a second start replaced the running process"
pass "fm-copilot-wake start: confirms a live watcher and is idempotent"

printf 'done [at=%s]: lab event\n' "$(date +%s)" >> "$STATE/lab1.status"
: > "$STATE/lab1.meta"
wait_until 30 '[ -s "$STATE/.wake-queue" ]' || fail "the real watcher did not queue the status line; log: $(cat "$STATE/.copilot-wake.log")"
expect_no_ring_for 5 0 "a running turn"
pass "fm-copilot-wake: a wake waits while the busy record and footer both show a turn running"

hook idle agent-stop
wait_until 15 '[ "$(count)" -ge 1 ]' || fail "an idle pane was never woken; log: $(cat "$STATE/.copilot-wake.log")"
line=$(sed -n 1p "$SUBMITTED")
kind=$(printf '%s' "$line" | FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-operational-input.sh" doorbell-kind) || fail "not a verifiable doorbell: $line"
[ "$kind" = watcher ] || fail "the doorbell record must be a watcher input: $kind"
pass "fm-copilot-wake: a real watcher event reaches an idle pane as a watcher doorbell"

hook busy user-prompt-submit
wait_until 15 '[ "$(cat "$STATE/.watch.lock/pid" 2>/dev/null)" != "" ]' || fail "the watcher was not re-armed after its close"
fm_pid=$(cat "$STATE/.watch.lock/pid")
kill -0 "$fm_pid" 2>/dev/null || fail "no live watcher after the wake closed the first cycle"
pass "fm-copilot-wake: the watcher runs again after the wake's close"

hook idle agent-stop
n=$(count)
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "an unacknowledged wake was not re-rung"
pass "fm-copilot-wake: an unacknowledged wake is re-rung"

clear_queue
sleep 1
n=$(count)
expect_no_ring_for 5 "$n" "an acknowledged queue"
pass "fm-copilot-wake: an acknowledged queue stops the rings"

tmux send-keys -t lab:main -l 'half written'
wait_until 5 'pane_text | grep -q "half written"' || fail "the draft did not reach the composer"
row
n=$(count)
expect_no_ring_for 5 "$n" "a half-written operator line"
pane_text | grep -q '❯ half written$' || fail "the operator's draft changed: $(pane_text)"
tmux send-keys -t lab:main C-u
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "the wake was lost after the draft cleared"
grep -q 'half written' "$SUBMITTED" && fail "the wake merged with the draft: $(cat "$SUBMITTED")"
pass "fm-copilot-wake: a half-written line defers the wake, stays intact, and the wake lands after it clears"

clear_queue
: > "$INJECT"
row
n=$(count)
wait_until 15 '[ ! -e "$INJECT" ]' || fail "the key was never injected"
wait_until 15 'grep -q "the composer changed before the doorbell landed" "$STATE/.copilot-wake.log"' \
  || fail "the ring did not refuse after the key landed; log: $(cat "$STATE/.copilot-wake.log")"
pane_text | grep -q '❯ Q$' || fail "the operator's key was not left alone: $(pane_text)"
# The doorbell names a mktemp path that can itself contain a Q.
sed "s#${TMP_ROOT}[^ ']*##g" "$SUBMITTED" | grep -q 'Q' && fail "the key merged with the doorbell: $(cat "$SUBMITTED")"
tmux send-keys -t lab:main C-u
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "the wake was lost after the refused ring"
pass "fm-copilot-wake: a key landing right after the composer read makes the ring refuse and stay out of the draft"

clear_queue
printf 'picker\n' > "$MODE"
sleep 1
row
n=$(count)
expect_no_ring_for 5 "$n" "an unrecognized screen"
printf 'box\n' > "$MODE"
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "the wake was lost after the picker closed"
pass "fm-copilot-wake: an unrecognized screen defers the wake"

clear_queue
printf '5\n' > "$DROP"
row
n=$(count)
wait_until 20 'pane_text | grep -q "operational input waiting"' || fail "the doorbell was never typed"
wait_until 20 '[ "$(cat "$DROP")" = 0 ]' || fail "the swallowed Enters were not retried: $(cat "$DROP")"
wait_until 20 "[ \"\$(count)\" -gt $n ]" || fail "the unsent doorbell was never submitted: $(pane_text)"
[ "$(tail -n 1 "$SUBMITTED" | grep -o 'operational input waiting' | wc -l | tr -d ' ')" = 1 ] \
  || fail "a retyped doorbell was concatenated: $(tail -n 1 "$SUBMITTED")"
pass "fm-copilot-wake: a swallowed Enter resubmits the unsent doorbell without retyping it"

clear_queue
hook busy user-prompt-submit
: > "$FOOTER"
sleep 1
row
n=$(count)
wait_until 12 "[ \"\$(count)\" -gt $n ]" || fail "an interrupted turn's stale busy record starved the wake"
pass "fm-copilot-wake: a stale busy record with no busy footer is treated as an interrupted turn"

clear_queue
hook idle agent-stop
sleep 1
n=$(cat "$STATE/.copilot-primary.busy-state")
hook busy user-prompt-submit ',"parentAgentId":"p1"'
[ "$(cat "$STATE/.copilot-primary.busy-state")" = "$n" ] || fail "a subagent's event changed the primary's record"
printf '{}' | FM_ROOT_OVERRIDE="$TMP_ROOT" "$WAKE" turn busy user-prompt-submit
[ "$(cat "$STATE/.copilot-primary.busy-state")" = "$n" ] || fail "a non-primary directory changed the record"
pass "fm-copilot-wake turn: subagent payloads and non-primary directories leave the record alone"
