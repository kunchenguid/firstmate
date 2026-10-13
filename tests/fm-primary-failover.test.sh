#!/usr/bin/env bash
# tests/fm-primary-failover.test.sh - bin/fm-primary-failover.sh end to end.
#
# A real tmux server (private socket) hosts fake harnesses named claude and
# grok in a throwaway FM_HOME. Each fake records its argv, claims state/.lock
# with its own pid like a real session start, and exits on /exit unless told to
# ignore it. A fake quota-axi serves the quota the case chooses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "ok - skipped: tmux not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "ok - skipped: jq not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "ok - skipped: python3 not installed"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-primary-failover)
BIN="$ROOT/bin/fm-primary-failover.sh"
HOME_DIR="$TMP_ROOT/home"
FAKE_DIR="$TMP_ROOT/fake"
FAKEBIN="$FAKE_DIR/bin"
SOCK="$TMP_ROOT/tmux.sock"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$FAKEBIN"

cat >"$FAKEBIN/claude" <<'PY'
#!/usr/bin/env python3
import os, sys
name = os.path.basename(sys.argv[0])
d, home = os.environ["FAKE_DIR"], os.environ["FM_HOME"]
open(f"{d}/argv.{name}", "w").write("\n".join(sys.argv[1:]))
open(f"{home}/state/.lock", "w").write(str(os.getpid()) + "\n")
if os.path.exists(f"{d}/banner.{name}"):
    print("You've hit your limit - resets 4am", flush=True)
for line in sys.stdin:
    if line.strip() == "/exit" and not os.path.exists(f"{d}/ignore-exit"):
        break
PY
chmod +x "$FAKEBIN/claude"
cp "$FAKEBIN/claude" "$FAKEBIN/grok"
# pi shows its project-trust dialog first and only claims the lock after Enter.
# The lock lib recognizes pi by a `pi` path component of the interpreter, so run
# the fake through a python symlink that lives in a directory named pi.
mkdir -p "$FAKE_DIR/pi"
ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$FAKE_DIR/pi/python3"
cat >"$FAKEBIN/pi" <<SH
#!/usr/bin/env bash
exec "$FAKE_DIR/pi/python3" "$FAKEBIN/pi.py" "\$@"
SH
chmod +x "$FAKEBIN/pi"
cat >"$FAKEBIN/pi.py" <<'PY'
import os, sys
d, home = os.environ["FAKE_DIR"], os.environ["FM_HOME"]
print("Trust project folder?", flush=True)
sys.stdin.readline()
open(f"{d}/argv.pi", "w").write("\n".join(sys.argv[1:]))
open(f"{home}/state/.lock", "w").write(str(os.getpid()) + "\n")
for line in sys.stdin:
    if line.strip() == "/quit":
        break
PY
chmod +x "$FAKEBIN/pi.py"
cat >"$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
cat "$FAKE_DIR/quota.json"
SH
chmod +x "$FAKEBIN/quota-axi"

set_quota() {  # <effective> <five-hour>
  cat >"$FAKE_DIR/quota.json" <<JSON
{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","effectivePercentRemaining":$1}]},"windows":[{"id":"five_hour","percentRemaining":$2,"resetsAt":"2030-01-01T00:00:00Z"}]}]}
JSON
}

tmx() { tmux -S "$SOCK" "$@"; }
cleanup_tmux() { tmx kill-server >/dev/null 2>&1 || true; }
trap 'cleanup_tmux; fm_test_cleanup' EXIT

tmx new-session -d -s pf -x 200 -y 50 -e "FM_HOME=$HOME_DIR" -e "FAKE_DIR=$FAKE_DIR" -e "PATH=$FAKEBIN:$PATH" "bash --norc"
PANE=$(tmx list-panes -t pf -F '#{pane_id}')
tmx send-keys -t "$PANE" "export FM_HOME='$HOME_DIR' FAKE_DIR='$FAKE_DIR' PATH='$FAKEBIN':\$PATH; clear" Enter
tmx send-keys -t "$PANE" "command -v claude grok > '$FAKE_DIR/which'" Enter
wait_for_file() { local n=10; while [ "$n" -gt 0 ] && [ ! -s "$1" ]; do sleep 1; n=$((n - 1)); done; }
wait_for_file "$FAKE_DIR/which"
# Guard: never let the pane resolve a real harness.
[ "$(cat "$FAKE_DIR/which")" = "$FAKEBIN/claude"$'\n'"$FAKEBIN/grok" ] || fail "pane does not resolve the fake harnesses: $(cat "$FAKE_DIR/which")"

run() {  # <args...>: acting run with the fake world on PATH
  FM_HOME="$HOME_DIR" FAKE_DIR="$FAKE_DIR" PATH="$FAKEBIN:$PATH" \
    FM_PF_TMUX_BIN=tmux FM_PF_CONFIRM="${CONFIRM:-1}" FM_PF_MIN_DWELL="${DWELL:-0}" \
    FM_PF_EXIT_WAIT="${EXIT_WAIT:-20}" FM_PF_START_WAIT=20 \
    bash "$BIN" "$@" --host tmux --pane "$PANE" 2>&1
}
# tmux needs the private socket; point the script at it through a wrapper.
cat >"$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
echo "\$*" >>"$FAKE_DIR/tmux.args"
exec $(command -v tmux) -S "$SOCK" "\$@"
SH
chmod +x "$FAKEBIN/tmux"

lock_pid() { head -n 1 "$HOME_DIR/state/.lock" 2>/dev/null; }
wait_for() {  # <seconds> <command...>
  local n=$1; shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 1; n=$((n - 1)); done
  "$@"
}
start_fake() {  # <name>
  tmx send-keys -t "$PANE" "$1 start" Enter
  wait_for 10 test -s "$FAKE_DIR/argv.$1" || fail "fake $1 did not start: $(tmx capture-pane -p -t "$PANE")"
  sleep 1
}
alive() { kill -0 "$1" 2>/dev/null; }

# --- usage ---------------------------------------------------------------
out=$(bash "$BIN" bogus 2>&1); rc=$?
expect_code 2 "$rc" "unknown command"
out=$(bash "$BIN" failover --to codex 2>&1); rc=$?
expect_code 2 "$rc" "codex is never a failover target"
assert_contains "$(bash "$BIN" --help)" "SESSION LOCK HANDOVER" "help documents the lock handover"
pass "usage and codex refusal"

# --- dry run changes nothing ----------------------------------------------
set_quota 0 0
start_fake claude
OLD=$(lock_pid)
out=$(run failover --dry-run --to grok); rc=$?
expect_code 0 "$rc" "dry-run exit"
assert_contains "$out" "plan: claude pid $OLD -> grok in tmux pane $PANE" "dry-run prints the plan"
alive "$OLD" || fail "dry-run killed the old session"
assert_absent "$HOME_DIR/state/primary-failover.state" "dry-run wrote state"
assert_absent "$FAKE_DIR/argv.grok" "dry-run launched grok"
pass "dry-run prints the plan and touches nothing"

# --- debounce ---------------------------------------------------------------
out=$(CONFIRM=2 run check); rc=$?
expect_code 0 "$rc" "debounced check exit"
assert_contains "$out" "exhaustion signal 1/2" "first signal is only counted"
alive "$OLD" || fail "debounced check exited the session"
set_quota 80 90
out=$(CONFIRM=2 run check)
assert_contains "$out" "claude healthy" "healthy quota resets the counter"
assert_contains "$(cat "$HOME_DIR/state/primary-failover.state")" "exhaust_count=0" "counter cleared"
pass "exhaustion is debounced"

# --- an old session that ignores /exit is never killed ---------------------
set_quota 0 0
: >"$FAKE_DIR/ignore-exit"
out=$(EXIT_WAIT=3 run check); rc=$?
expect_code 3 "$rc" "stuck old session aborts the handover"
alive "$OLD" || fail "failover killed a session that would not exit"
assert_absent "$FAKE_DIR/argv.grok" "grok launched while the old session lived"
assert_contains "$out" "nothing signalled" "abort is logged"
rm -f "$FAKE_DIR/ignore-exit"
pass "handover aborts without signalling a session that will not exit"

# --- failover ---------------------------------------------------------------
echo "grok" >/dev/null
out=$(run check); rc=$?
expect_code 0 "$rc" "failover exit: $out"
alive "$OLD" && fail "old claude still alive after failover"
NEW=$(lock_pid)
assert_not_equals "$OLD" "$NEW" "lock moved to a new pid"
alive "$NEW" || fail "new session is not running"
assert_contains "$(cat "$FAKE_DIR/argv.grok")" "--always-approve" "grok launched autonomous"
argv=$(cat "$FAKE_DIR/argv.grok")
assert_contains "$argv" "bin/fm-session-start.sh" "first prompt runs session start"
assert_contains "$argv" "OPENCLAW_TALK_PREP.md" "first prompt rereads the talk prep"
assert_contains "$argv" "append a status entry" "first prompt appends a status entry"
st=$(cat "$HOME_DIR/state/primary-failover.state")
assert_contains "$st" "mode=failover" "state records failover"
assert_contains "$st" "primary=grok" "state records the new primary"
pass "failover relaunches grok in the same pane and claims the lock"

# --- stays on grok while claude is still exhausted ----------------------------
out=$(run check)
assert_contains "$out" "claude not ready" "no switch-back while exhausted"
alive "$NEW" || fail "grok disturbed while claude exhausted"

# --- switch-back ---------------------------------------------------------------
rm -f "$FAKE_DIR/argv.claude"
set_quota 90 95
out=$(run check); rc=$?
expect_code 0 "$rc" "switch-back exit: $out"
alive "$NEW" && fail "grok still alive after switch-back"
BACK=$(lock_pid)
alive "$BACK" || fail "claude not running after switch-back"
assert_contains "$(cat "$FAKE_DIR/argv.claude")" "switched back to Claude" "switch-back prompt"
assert_contains "$(cat "$HOME_DIR/state/primary-failover.state")" "mode=normal" "state back to normal"
pass "switch-back relaunches claude when the window has headroom"

# --- pane limit banner alone triggers failover ---------------------------------
tmx send-keys -t "$PANE" "/exit" Enter
wait_for 10 bash -c "! kill -0 $BACK 2>/dev/null" || fail "claude did not exit"
rm -f "$FAKE_DIR/argv.grok"
: >"$FAKE_DIR/banner.claude"
start_fake claude
set_quota 90 95
out=$(run check); rc=$?
expect_code 0 "$rc" "banner failover exit: $out"
assert_present "$FAKE_DIR/argv.grok" "pane banner alone triggered failover"
pass "pane limit banner triggers failover when quota still looks healthy"

# --- forced pane keeps the holder's socket; relaunch with no holder reuses it ---
tmx send-keys -t "$PANE" "/exit" Enter
wait_for 10 bash -c "! kill -0 $(lock_pid) 2>/dev/null" || fail "primary did not exit"
rm -f "$FAKE_DIR/banner.claude" "$FAKE_DIR/argv.pi" "$FAKE_DIR/tmux.args"
start_fake claude
set_quota 90 95
out=$(run failover --to pi); rc=$?
expect_code 0 "$rc" "pi failover exit: $out"
assert_contains "$out" "pi folder-trust dialog: answering Enter" "pi trust dialog answered"
assert_present "$FAKE_DIR/argv.pi" "pi launched and claimed the lock"
assert_contains "$(cat "$HOME_DIR/state/primary-failover.state")" "sock=$SOCK" "state records the tmux socket"
pass "pi folder-trust dialog is answered and the socket is recorded"

tmx send-keys -t "$PANE" "/quit" Enter
wait_for 10 bash -c "! kill -0 $(lock_pid) 2>/dev/null" || fail "pi did not exit"
: >"$FAKE_DIR/tmux.args"
out=$(FM_HOME="$HOME_DIR" FAKE_DIR="$FAKE_DIR" PATH="$FAKEBIN:$PATH" FM_PF_TMUX_BIN=tmux FM_PF_START_WAIT=20 \
  bash "$BIN" switch-back 2>&1); rc=$?
expect_code 0 "$rc" "holderless switch-back exit: $out"
assert_contains "$(cat "$FAKE_DIR/tmux.args")" "-S $SOCK" "holderless relaunch targets the recorded tmux server"
pass "relaunch with no live holder reuses the recorded tmux socket"
