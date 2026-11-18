#!/usr/bin/env bash
# Portable regression for bin/fm-copilot-wake.sh: the restart, log-trim and transcript-abort cases of the
# typed wake for an idle GitHub Copilot CLI primary. The first-wake cases are in
# tests/fm-copilot-wake.test.sh; both source tests/fm-copilot-wake-lab.sh, which owns the pane stand-in.
# shellcheck disable=SC2016 # single-quoted conditions are expanded by wait_until's eval
set -u

# shellcheck source=tests/fm-copilot-wake-lab.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-copilot-wake-lab.sh"

# Work in flight, so the home needs supervision and a dead wake process is worth restarting.
: > "$STATE/lab1.meta"
out=$("$WAKE" start 2>&1) || fail "start failed: $out; log: $(cat "$STATE/.copilot-wake.log" 2>/dev/null)"
WAKE_PID=$(cat "$STATE/.copilot-wake.lock/pid")

# A long interrupt grace from here on, so only the transcript can end a busy turn early.
kill "$WAKE_PID"
wait_until 10 '! kill -0 "$WAKE_PID" 2>/dev/null' || fail "the wake process ignored TERM"
CODE="$TMP_ROOT/code/bin"
mkdir -p "$CODE"
for f in "$ROOT"/bin/*; do ln -s "$f" "$CODE/$(basename "$f")"; done
rm "$CODE/fm-copilot-wake.sh"
cp "$WAKE" "$CODE/fm-copilot-wake.sh"
export FM_COPILOT_WAKE_INTERRUPT_GRACE=60 FM_COPILOT_WAKE_LOG_MAX=2500
# A date shim whose epoch can be stepped, for the loop's own timers only.
DSHIM="$TMP_ROOT/dshim"
mkdir -p "$DSHIM"
printf '0\n' > "$DSHIM/offset"
REAL_DATE=$(command -v date)
cat > "$DSHIM/date" <<SH
#!/usr/bin/env bash
if [ "\$*" = "+%s" ]; then echo \$(( \$("$REAL_DATE" +%s) + \$(cat "$DSHIM/offset") )); else exec "$REAL_DATE" "\$@"; fi
SH
chmod +x "$DSHIM/date"
# An old log longer than the cap: start appends and trims it to its newest bytes.
for i in $(seq 1 400); do printf 'old-%05d padding padding\n' "$i"; done > "$STATE/.copilot-wake.log"
out=$(PATH="$DSHIM:$PATH" "$CODE/fm-copilot-wake.sh" start 2>&1) || fail "start from the copy failed: $out"
WAKE_PID=$(cat "$STATE/.copilot-wake.lock/pid")
[ "$(wc -c < "$STATE/.copilot-wake.log")" -le 3000 ] || fail "start did not trim the log: $(wc -c < "$STATE/.copilot-wake.log")"
grep -q 'old-00400' "$STATE/.copilot-wake.log" || fail "start must keep the newest old lines"
! grep -q 'old-00001 ' "$STATE/.copilot-wake.log" || fail "start must drop the oldest lines"
for i in $(seq 1 200); do printf 'junk-%05d padding padding padding\n' "$i"; done >> "$STATE/.copilot-wake.log"
wait_until 15 '[ "$(wc -c < "$STATE/.copilot-wake.log")" -le 3000 ]' || fail "the running loop never trimmed its log"
pass "fm-copilot-wake: the log is appended to, and trimmed in place to its newest bytes at start and while running"
sed 's/ring: typed the doorbell/ring U2: typed the doorbell/' "$WAKE" > "$CODE/fm-copilot-wake.sh.new"
chmod +x "$CODE/fm-copilot-wake.sh.new"
mv "$CODE/fm-copilot-wake.sh.new" "$CODE/fm-copilot-wake.sh"
wait_until 15 'grep -q "restarting: script updated" "$STATE/.copilot-wake.log"' || fail "the loop kept running the old script; log: $(cat "$STATE/.copilot-wake.log")"
wait_until 15 'sed -n "/restarting: script updated/,\$p" "$STATE/.copilot-wake.log" | grep -q "started: target"' || fail "the loop did not come back: $(cat "$STATE/.copilot-wake.log")"
[ "$(cat "$STATE/.copilot-wake.lock/pid")" = "$WAKE_PID" ] || fail "the re-executed loop changed pid"
kill -0 "$WAKE_PID" 2>/dev/null || fail "the re-executed loop died"
clear_queue
hook idle agent-stop
sleep 1
row
n=$(count)
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "the re-executed loop never rang"
grep -q 'ring U2: typed the doorbell' "$STATE/.copilot-wake.log" || fail "the loop still runs pre-update code: $(cat "$STATE/.copilot-wake.log")"
[ "$(pgrep -fc "$CODE/fm-copilot-wake.sh run")" = 1 ] || fail "more than one wake loop is running"
pass "fm-copilot-wake: a loop re-executes itself under the same pid after its script file is replaced"

clear_queue
hook idle agent-stop
row
n=$(count)
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "the first ring never came"
printf -- '-300\n' > "$DSHIM/offset"
wait_until 15 "[ \"\$(count)\" -gt $((n + 1)) ]" || fail "a clock stepped back 300 s held the re-ring"
printf '0\n' > "$DSHIM/offset"
pass "fm-copilot-wake: a backward clock step does not hold the next ring"

TRANSCRIPT="$COPILOT_HOME/session-state/s/events.jsonl"
mkdir -p "$(dirname "$TRANSCRIPT")"
clear_queue
hook idle agent-stop
: > "$FOOTER"
printf '{"type":"user.message","data":{}}\n{"type":"assistant.turn_end","data":{}}\n{"type":"abort","data":{"reason":"user_abort"}}\n' > "$TRANSCRIPT"
hook busy user-prompt-submit
row
n=$(count)
wait_until 12 "[ \"\$(count)\" -gt $n ]" || fail "an abort in the transcript did not release the wake before the grace"
pass "fm-copilot-wake: a transcript abort rings the wake without waiting out the interrupt grace"

clear_queue
hook idle agent-stop
printf '{"type":"abort","data":{}}\n{"type":"user.message","data":{}}\n' > "$TRANSCRIPT"
hook busy user-prompt-submit
row
n=$(count)
expect_no_ring_for 6 "$n" "a stale abort followed by a new prompt"
printf '{"type":"abort","data":{}}\n' >> "$TRANSCRIPT"
wait_until 12 "[ \"\$(count)\" -gt $n ]" || fail "the new turn's abort did not release the wake"
pass "fm-copilot-wake: an abort older than the newest prompt does not release the wake"

clear_queue
hook idle agent-stop
printf '{"type":"user.message","data":{}}\n' > "$TRANSCRIPT"
hook busy user-prompt-submit
: > "$FOOTER"
touch -d '+1 hour' "$STATE/.copilot-primary.busy-state"
row
n=$(count)
wait_until 12 "[ \"\$(count)\" -gt $n ]" || fail "a busy record dated in the future starved the wake"
pass "fm-copilot-wake: a busy record dated in the future counts as old"

kill -9 "$WAKE_PID"
wait_until 10 '! kill -0 "$WAKE_PID" 2>/dev/null' || fail "the wake process survived kill -9"
clear_queue
hook busy user-prompt-submit
wait_until 20 '[ -n "$(cat "$STATE/.copilot-wake.lock/pid" 2>/dev/null)" ] && [ "$(cat "$STATE/.copilot-wake.lock/pid")" != "$WAKE_PID" ] && kill -0 "$(cat "$STATE/.copilot-wake.lock/pid")" 2>/dev/null' \
  || fail "a prompt did not restart the dead wake process; log: $(tail -n 5 "$STATE/.copilot-wake.log")"
WAKE_PID=$(cat "$STATE/.copilot-wake.lock/pid")
grep -q 'restarting: the wake process was gone at a prompt' "$STATE/.copilot-wake.log" || fail "the restart was not logged"
hook busy user-prompt-submit
sleep 1
[ "$(cat "$STATE/.copilot-wake.lock/pid")" = "$WAKE_PID" ] || fail "a prompt replaced a live wake process"
pass "fm-copilot-wake turn: a prompt restarts a dead wake process once and leaves a live one alone"

# First Copilot session of a home with work in flight: no busy-gen record exists when the prompt hook starts the loop.
kill -9 "$WAKE_PID"
wait_until 10 '! kill -0 "$WAKE_PID" 2>/dev/null' || fail "the wake process survived the kill -9 before the first-session case"
dead=$WAKE_PID
orphan=$(cat "$STATE/.watch.lock/pid" 2>/dev/null)
[ -z "$orphan" ] || kill "$orphan" 2>/dev/null
wait_until 10 '[ -z "$orphan" ] || ! kill -0 "$orphan" 2>/dev/null' || fail "the orphaned watcher ignored TERM"
clear_queue
rm -f "$STATE"/.copilot-primary.busy-*
hook busy user-prompt-submit
wait_until 20 '[ -n "$(cat "$STATE/.copilot-wake.lock/pid" 2>/dev/null)" ] && [ "$(cat "$STATE/.copilot-wake.lock/pid")" != "$dead" ] && kill -0 "$(cat "$STATE/.copilot-wake.lock/pid")" 2>/dev/null' \
  || fail "a prompt did not start the wake loop without a busy record"
WAKE_PID=$(cat "$STATE/.copilot-wake.lock/pid")
hook idle agent-stop
: > "$FOOTER"
row
n=$(count)
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "a loop started at the first prompt never rang: the turn record was never armed; log: $(tail -n 5 "$STATE/.copilot-wake.log")"
pass "fm-copilot-wake turn: a loop started by a prompt with no busy record still rings once the turn ends"

# Unattended: no prompt arrives, so `revive` (run by the orphaned watcher) must heal a crash, but only on an idle pane.
lock_pid() { cat "$STATE/.copilot-wake.lock/pid" 2>/dev/null; }
kill -9 "$WAKE_PID"
wait_until 10 '! kill -0 "$WAKE_PID" 2>/dev/null' || fail "the wake process survived the second kill -9"
dead=$WAKE_PID
hook busy tool-use
printf ' Working · 130 B esc esc interrupt\n' > "$FOOTER"
"$WAKE" revive
sleep 1
[ "$(lock_pid)" = "$dead" ] || fail "revive restarted the wake process over a busy turn"
: > "$FOOTER"
hook idle agent-stop
"$WAKE" revive
wait_until 20 '[ "$(lock_pid)" != "$dead" ] && kill -0 "$(lock_pid)" 2>/dev/null' \
  || fail "revive did not restart the dead wake process on an idle pane; log: $(tail -n 5 "$STATE/.copilot-wake.log")"
WAKE_PID=$(lock_pid)
grep -q 'restarting: the wake process was gone while the pane was idle' "$STATE/.copilot-wake.log" || fail "the revive was not logged"
pass "fm-copilot-wake revive: restarts a dead wake process on an idle pane and never over a busy turn"

: > "$STATE/.afk"
wait_until 10 '! kill -0 "$WAKE_PID" 2>/dev/null' || fail "the wake process kept running in away mode"
WAKE_PID=
rm -f "$STATE/.afk"
pass "fm-copilot-wake: stands down when away mode starts"

# The kill -9 above left a deliberately orphaned watcher; away mode did not close it.
orphan=$(cat "$STATE/.watch.lock/pid" 2>/dev/null)
[ -z "$orphan" ] || kill "$orphan" 2>/dev/null
wait_until 10 '[ -z "$orphan" ] || ! kill -0 "$orphan" 2>/dev/null' || fail "the orphaned watcher ignored TERM"
out=$("$WAKE" start 2>&1) || fail "a restart failed: $out; log: $(tail -n 20 "$STATE/.copilot-wake.log")"
WAKE_PID=$(cat "$STATE/.copilot-wake.lock/pid")
tmux kill-window -t lab:main
wait_until 10 '! kill -0 "$WAKE_PID" 2>/dev/null' || fail "the wake process outlived its pane"
WAKE_PID=
pass "fm-copilot-wake: stops when its pane is gone"
