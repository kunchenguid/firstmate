#!/usr/bin/env bash
# tests/fm-launch-prompt-guard-reap.test.sh - portable regression for the
# cleanup of the launch-prompt live guard,
# tests/fm-launch-prompt-signals-live-e2e.test.sh.
#
# The defect it exists for: that guard ended every harness it launched only by
# killing its private tmux server, and a real Gemini CLI outlived that on every
# run. A terminal hangup signals only the pane's session leader; Gemini's
# leader is a relaunch wrapper that swallows SIGHUP, SIGTERM, and SIGINT while
# it waits on the real CLI child, and the child never receives the hangup, so
# both ran on for hours after the guard had exited and removed their worktree.
#
# This drives the REAL guard end to end, with the real claude, pi, and gemini
# hidden from PATH and a stub `gemini` that has that same process shape: a
# pane-leader wrapper that ignores the hangup and the polite signals, and a
# child that renders the guard's expected screen and never sees the hangup.
# It runs real processes in real private tmux servers and needs no harness and
# no credentials, so it runs everywhere CI runs tmux. The guard itself stays the
# live per-harness counterpart. A control case first proves the stub survives a
# bare kill-server on this host, so every reap assertion below is measured
# against a tree that genuinely leaks, never a vacuous one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

GUARD="$ROOT/tests/fm-launch-prompt-signals-live-e2e.test.sh"
REAL_TMUX=$(command -v tmux)
SLEEP_BIN=$(command -v sleep) || fail "sleep not found"
CONTROL_SOCKET="fm-lp-reap-control-$$"
TMP_ROOT=$(fm_test_tmproot fm-lp-reap) || fail "could not create the temp root"
REC="$TMP_ROOT/rec"
FAKEBIN=$(fm_fakebin "$TMP_ROOT") || fail "could not create the fakebin"
mkdir -p "$REC" || fail "could not create the stub record dir"
STUB="$FAKEBIN/gemini"

# stub_pids: every pid the stub recorded for itself in the current case, one
# per line. every_stub_pid also keeps every earlier case's, for the final reap.
stub_pids() {
  cat "$REC"/pids.* 2>/dev/null || true
}

every_stub_pid() {
  cat "$REC/all-pids" 2>/dev/null || true
}

# stub_alive <pid>: the pid is still a live stub process (never a zombie, and
# never an unrelated process that reused the number, because every stub
# process carries this run's unique fakebin path in its argument vector).
stub_alive() {
  local pid=$1 stat args
  stat=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  case "$stat" in '' | Z*) return 1 ;; esac
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  case "$args" in *"$STUB"*) return 0 ;; esac
  return 1
}

stub_survivors() {
  local pid
  for pid in $(stub_pids); do
    stub_alive "$pid" && printf '%s ' "$pid"
  done
}

# Reap whatever stub processes a broken guard (or the control case) left, so a
# failing run of this regression never leaks the tree it is measuring.
reap_stub_leftovers() {
  local pid
  for pid in $(every_stub_pid); do
    stub_alive "$pid" && kill -KILL "$pid" 2>/dev/null
  done
  return 0
}

cleanup_all() {
  reap_stub_leftovers
  "$REAL_TMUX" -L "$CONTROL_SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_all EXIT

# The stub reads its behavior from files baked in at generation time, so
# nothing depends on which environment the guard's tmux server passes along.
#   mode=prompt  render a screen the guard and its classifier both accept
#   mode=silent  render nothing, leaving the guard waiting for its prompt
#   term=ignore  the child ignores SIGTERM too, so only SIGKILL ends it
#   term=honor   the child exits on SIGTERM, as a real Gemini child does
cat > "$STUB" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' 0.0.0-reap-stub
  exit 0
fi
if [ "\${1:-}" = --fm-reap-stub-child ]; then
  trap '' HUP INT
  [ "\$(cat '$REC/term')" = honor ] || trap '' TERM
  printf '%s\n' "\$\$" > '$REC/pids.child'
  printf '%s\n' "\$\$" >> '$REC/all-pids'
  [ "\$(cat '$REC/mode')" = silent ] || printf '%s\n' 'Enter Gemini API Key'
  exec -a '$STUB-child' '$SLEEP_BIN' '$FM_TEST_STUB_MAX_BLOCK_SECONDS'
fi
trap : HUP TERM INT
printf '%s\n' "\$\$" > '$REC/pids.wrapper'
printf '%s\n' "\$\$" >> '$REC/all-pids'
'$STUB' --fm-reap-stub-child "\$@" &
child=\$!
while kill -0 "\$child" 2>/dev/null; do
  wait "\$child"
done
SH
chmod +x "$STUB"

set_stub() {  # <mode> <term>
  rm -f "$REC"/pids.*
  printf '%s\n' "$1" > "$REC/mode"
  printf '%s\n' "$2" > "$REC/term"
}

wait_stub_up() {  # <seconds>
  local i=0 limit=$(($1 * 10))
  while [ "$i" -lt "$limit" ]; do
    [ -s "$REC/pids.wrapper" ] && [ -s "$REC/pids.child" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

BASE_PATH=$(fm_test_base_path_sans "$PATH" claude pi gemini) || fail "could not build a PATH without the real harnesses"
GUARD_PATH="$FAKEBIN:$BASE_PATH"

run_guard() {  # <out-file>: run the real guard in the foreground
  PATH="$GUARD_PATH" FM_LAUNCH_PROMPT_SIGNALS_LIVE=1 FM_TEST_SKIP_ORPHAN_REAP=1 \
    bash "$GUARD" > "$1" 2>&1
}

assert_no_stub_survivor() {  # <case> <out-file>
  local survivors
  survivors=$(stub_survivors)
  [ -z "$survivors" ] \
    || fail "$1: launched stub process(es) outlived the guard: ${survivors}- guard output:
$(cat "$2")"
}

# --- control: the stub really leaks through a bare kill-server -------------

set_stub prompt ignore
mkdir -p "$TMP_ROOT/control-wt"
"$REAL_TMUX" -L "$CONTROL_SOCKET" new-session -d -s control -n w -c "$TMP_ROOT/control-wt" -- "$STUB" -y hello \
  || fail "control: could not launch the stub"
wait_stub_up 15 || fail "control: the stub never started"
"$REAL_TMUX" -L "$CONTROL_SOCKET" kill-server >/dev/null 2>&1 || true
sleep 1
for role in wrapper child; do
  pid=$(cat "$REC/pids.$role")
  stub_alive "$pid" \
    || fail "control: the stub $role did not survive a bare kill-server, so this host cannot prove the reap"
done
reap_stub_leftovers
pass "control: the stub's wrapper and child both outlive a bare tmux kill-server"

# --- the guard's passing path ----------------------------------------------

set_stub prompt ignore
OUT="$TMP_ROOT/pass.out"
run_guard "$OUT" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "pass path: the guard exited $rc, expected 0 - output:
$(cat "$OUT")"
assert_grep "checked 1 launch-prompt signature" "$OUT" "pass path: the guard did not check exactly the stub - output:
$(cat "$OUT")"
[ -n "$(stub_pids)" ] || fail "pass path: the guard never launched the stub"
assert_no_stub_survivor "pass path" "$OUT"
pass "pass path: the guard reaps a launched tree that only SIGKILL can end"

# --- the guard's failing path: the prompt never renders --------------------

set_stub silent honor
OUT="$TMP_ROOT/fail.out"
run_guard "$OUT" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "fail path: the guard exited $rc, expected 1 - output:
$(cat "$OUT")"
assert_grep "never rendered its expected prompt" "$OUT" "fail path: the guard failed for another reason - output:
$(cat "$OUT")"
[ -n "$(stub_pids)" ] || fail "fail path: the guard never launched the stub"
assert_no_stub_survivor "fail path" "$OUT"
pass "fail path: a guard that fails on a launch still reaps what it launched"

# --- the guard's interrupt path: SIGTERM while a launch is parked ----------

set_stub silent honor
OUT="$TMP_ROOT/term.out"
PATH="$GUARD_PATH" FM_LAUNCH_PROMPT_SIGNALS_LIVE=1 FM_TEST_SKIP_ORPHAN_REAP=1 \
  bash "$GUARD" > "$OUT" 2>&1 &
guard_pid=$!
if ! wait_stub_up 30; then
  kill -KILL "$guard_pid" 2>/dev/null
  fail "interrupt path: the guard never launched the stub - output:
$(cat "$OUT")"
fi
kill -TERM "$guard_pid"
wait "$guard_pid" && rc=0 || rc=$?
[ "$rc" -eq 143 ] || fail "interrupt path: the guard exited $rc, expected 143 - output:
$(cat "$OUT")"
assert_no_stub_survivor "interrupt path" "$OUT"
pass "interrupt path: a guard stopped by SIGTERM still reaps what it launched"
