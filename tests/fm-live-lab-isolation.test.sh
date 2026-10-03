#!/usr/bin/env bash
# Behavior tests for the tmux isolation the live lab depends on:
# fm_tmux_isolation_gate (tests/lib.sh) and bin/fm-live-lab.sh's explicit lab
# socket. tmux resolves its socket under TMUX_TMPDIR only while that directory
# exists and otherwise silently falls back to /tmp/tmux-<uid>, so a lab command
# aimed at a removed lab directory would reach whatever server lives there.
# Here a decoy server stands on that default socket, and every lab command
# aimed at a missing lab directory must leave it alone.
#
# The decoy never runs on the host /tmp: the suite re-executes itself under
# `unshare -Urm` with a fresh tmpfs on /tmp, confirms there that /tmp is not the
# host one, and skips the decoy cases where no such namespace is available.
set -u

if [ -n "${FM_LAB_ISO_HOST_MARKER:-}" ]; then
  if [ -e "$FM_LAB_ISO_HOST_MARKER" ] || [ -n "$(ls -A /tmp)" ]; then
    echo "not ok - /tmp is not a fresh private mount; refusing to start the decoy" >&2
    exit 1
  fi
fi

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
unset TMUX TMUX_TMPDIR

TMP_ROOT=$(fm_test_tmproot fm-lab-iso)
LIVE_LAB="$ROOT/bin/fm-live-lab.sh"
GATE_SOCKET="$TMP_ROOT/base/tmux-$(id -u)/default"
DEFAULT_SOCKET="/tmp/tmux-$(id -u)/default"
DECOY_PID=''

# Poll steps (0.05s each) a process gets to exit after each escalation step.
DECOY_POLLS=100

# signal_decoy <signal> <pid>: one seam, so a case can stand in an unkillable process.
signal_decoy() {
  kill -"$1" "$2" 2>/dev/null
}

# pid_running <pid>: succeeds while the process exists and has not exited.
# An exited but unreaped process (a zombie, state Z) still answers kill -0
# when the runner's PID 1 does not reap orphans, so it counts as gone. A ps
# that errors fails closed: the process counts as still running.
pid_running() {
  local state
  kill -0 "$1" 2>/dev/null || return 1
  state=$(ps -o stat= -p "$1" 2>/dev/null) || return 0
  case $state in
    Z*) return 1 ;;
  esac
}

# wait_gone <pid> <polls>: succeeds once the process is gone, after at most <polls> polls.
wait_gone() {
  local pid=$1 polls=$2
  while pid_running "$pid"; do
    [ "$polls" -gt 0 ] || return 1
    polls=$((polls - 1))
    sleep 0.05
  done
}

# stop_decoy <pid> <socket> [polls]: stop the decoy server recorded at start.
# kill-server on its own explicit socket first, then TERM, then KILL on the
# recorded pid, each step bounded (kill-server too, against a wedged server).
# A decoy that survives all three is reported and fails the call instead of
# stalling the suite on its pane's 600s sleep.
stop_decoy() {
  local pid=$1 socket=$2 polls=${3:-$DECOY_POLLS}
  [ ! -S "$socket" ] || fm_run_timed 5 tmux -S "$socket" kill-server 2>/dev/null
  wait_gone "$pid" "$polls" && return 0
  signal_decoy TERM "$pid"
  wait_gone "$pid" "$polls" && return 0
  signal_decoy KILL "$pid"
  wait_gone "$pid" "$polls" && return 0
  echo "not ok - cleanup: decoy server $pid survived kill-server, TERM and KILL" >&2
  return 1
}

isolation_cleanup() {
  # Only the servers this suite started, each by its own explicit socket, and
  # only while it is still there; the decoy is gone before the suite returns.
  local rc=0
  [ ! -S "$GATE_SOCKET" ] || tmux -S "$GATE_SOCKET" kill-server 2>/dev/null
  if [ -n "$DECOY_PID" ]; then
    stop_decoy "$DECOY_PID" "$DEFAULT_SOCKET" || rc=1
  fi
  fm_test_cleanup
  [ "$rc" -eq 0 ] || exit 1
}
trap isolation_cleanup EXIT

# gate_run <base> [NAME=VALUE...]: the gate's output and exit, in a subshell,
# followed by RAN when the gate let the script continue.
gate_run() {
  local base=$1
  shift
  (
    for assignment in "$@"; do export "${assignment?}"; done
    fm_tmux_isolation_gate "$base"
    echo RAN
  ) 2>&1
}

# ---- the gate ---------------------------------------------------------------

if [ -z "${FM_LAB_ISO_HOST_MARKER:-}" ]; then
  out=$(gate_run "$TMP_ROOT/base")
  expect_code 0 "$?" "the gate passes with no socket directory: $out"
  assert_equals RAN "$out" "the gate runs the suite where no tmux server can answer"

  mkdir -p "$TMP_ROOT/base"
  mkdir -m 700 "$TMP_ROOT/base/tmux-$(id -u)"
  tmux -S "$GATE_SOCKET" -f /dev/null new-session -d -s live 'exec sleep 600' || fail "cannot start the gate's own server"
  out=$(gate_run "$TMP_ROOT/base")
  expect_code 0 "$?" "the gate skips cleanly beside a live server: $out"
  assert_contains "$(printf '%s\n' "$out" | head -n 1)" "skip: tmux isolation: a live tmux server answers on $GATE_SOCKET" "the skip is the first line and names the live socket"
  assert_contains "$out" "unshare -Urm" "the skip names the isolation it needs"
  assert_not_contains "$out" RAN "the gate stops the suite beside a live server"

  out=$(gate_run "$TMP_ROOT/base" CI=true)
  expect_code 0 "$?" "under CI the gate skips the same way: $out"
  assert_contains "$out" "skip: tmux isolation" "under CI the gate still says why it skips"
  assert_not_contains "$out" RAN "under CI the gate stops the suite beside a live server"

  tmux -S "$GATE_SOCKET" kill-server 2>/dev/null
  out=$(gate_run "$TMP_ROOT/base")
  assert_equals RAN "$out" "the gate runs again once only a dead socket is left"
  pass "fm_tmux_isolation_gate runs isolated and skips beside a live server"

  # ---- the decoy cleanup is bounded ------------------------------------------

  # No socket for kill-server to reach: TERM stops a plain process.
  victim=$(bash -c 'sleep 600 </dev/null >/dev/null 2>&1 & echo $!')
  start=$(date +%s)
  stop_decoy "$victim" "$TMP_ROOT/no-such-socket" 20 || fail "cleanup could not stop a process that exits on TERM"
  wait_gone "$victim" 0 || fail "cleanup returned success with the process still alive"
  [ $(($(date +%s) - start)) -lt 10 ] || fail "cleanup of a TERM-able process was not prompt"

  # A process that ignores TERM is stopped by the KILL step.
  victim=$(bash -c 'trap "" TERM; exec sleep 600 </dev/null >/dev/null 2>&1 & echo $!')
  stop_decoy "$victim" "$TMP_ROOT/no-such-socket" 20 || fail "cleanup could not stop a process that ignores TERM"
  wait_gone "$victim" 0 || fail "cleanup returned success with the TERM-ignoring process alive"

  # kill-server cannot stop it and neither signal lands: cleanup must return
  # within its poll budget, name the survivor, and report failure.
  victim=$(bash -c 'sleep 600 </dev/null >/dev/null 2>&1 & echo $!')
  start=$(date +%s)
  out=$(signal_decoy() { :; }; stop_decoy "$victim" "$TMP_ROOT/no-such-socket" 10 2>&1)
  code=$?
  kill -KILL "$victim" 2>/dev/null
  expect_code 1 "$code" "cleanup reports a decoy it cannot stop: $out"
  assert_contains "$out" "decoy server $victim survived" "the failure names the surviving decoy"
  [ $(($(date +%s) - start)) -lt 10 ] || fail "cleanup of an unstoppable decoy waited past its bound"
  # An exited decoy its parent never reaps stays a zombie that still answers
  # kill -0: cleanup must count it as gone rather than report a failure.
  bash -c 'sleep 0.2 </dev/null >/dev/null 2>&1 & echo $! $$; exec sleep 30 </dev/null >&3 2>/dev/null' 3>/dev/null >"$TMP_ROOT/zombie.pids" &
  until [ -s "$TMP_ROOT/zombie.pids" ]; do sleep 0.05; done
  read -r victim zombie_parent <"$TMP_ROOT/zombie.pids"
  sleep 0.5
  kill -0 "$victim" 2>/dev/null || fail "the zombie fixture was reaped, so the case would be vacuous"
  stop_decoy "$victim" "$TMP_ROOT/no-such-socket" 10 || fail "cleanup reported failure for an exited, unreaped decoy"
  { kill -KILL "$zombie_parent"; wait "$zombie_parent"; } 2>/dev/null

  pass "decoy cleanup is bounded, escalates to TERM and KILL, and reports a decoy it cannot stop"

  # The decoy cases run only in a private mount namespace with a fresh /tmp.
  if ! unshare -Urm sh -c 'mount -t tmpfs tmpfs /tmp' >/dev/null 2>&1; then
    echo "skip: tmux isolation decoy: needs a private /tmp (unshare -Urm with a tmpfs mount on /tmp)"
    exit 0
  fi
  host_marker=$(mktemp /tmp/fm-lab-iso-host.XXXXXX) || fail "cannot mark the host /tmp"
  FM_TEST_CLEANUP_DIRS+=("$host_marker")
  # shellcheck disable=SC2016 # $0 expands in the namespaced shell.
  FM_LAB_ISO_HOST_MARKER=$host_marker unshare -Urm bash -c 'mount -t tmpfs tmpfs /tmp && exec env -u TMPDIR -u TMP -u TMUX_TMPDIR bash "$0"' "$ROOT/tests/fm-live-lab-isolation.test.sh"
  exit $?
fi

# ---- a lab aimed at a missing tmux directory --------------------------------

# /tmp is a fresh private tmpfs, so the decoy is a server of this suite's own
# that no one outside this namespace can reach.
env -u TMUX -u TMUX_TMPDIR tmux -f /dev/null new-session -d -s firstmate -n main \
  "printf 'DECOY-PANE\n'; exec sleep 600" || fail "cannot start the decoy default server"
DECOY_PID=$(tmux -S "$DEFAULT_SOCKET" display-message -p '#{pid}')
[ -n "$DECOY_PID" ] || fail "the decoy is not on the default socket"

# shellcheck disable=SC2119 # No bases: the gate checks the real default ones.
out=$( (fm_tmux_isolation_gate; echo RAN) 2>&1)
assert_contains "$out" "skip: tmux isolation: a live tmux server answers on $DEFAULT_SOCKET" "the gate's default bases see a server on the default socket"
assert_not_contains "$out" RAN "the gate stops a suite beside the default server"

HOME="$TMP_ROOT/home"
mkdir -p "$HOME/.pi/agent" "$HOME/.treehouse"
printf '{}\n' > "$HOME/.pi/agent/trust.json"
printf '{"projects":{}}\n' > "$HOME/.claude.json"
LAB_ROOT="$TMP_ROOT/lab"
MISSING_DIR=$(mktemp -d /tmp/fml.XXXXXX) || fail "cannot name a missing lab tmux directory"
rmdir "$MISSING_DIR" || fail "cannot remove the lab tmux directory"
mkdir -p "$LAB_ROOT/home/state"
: > "$LAB_ROOT/.treehouse-before"
{
  echo 'fm-live-lab v1'
  echo "harness=claude"
  echo "home=$LAB_ROOT/home"
  echo "expect_host=no"
  echo "host_off=no"
  echo "mate=no"
  echo "worker=no"
  echo "nonce=deadbeef0000"
  echo "mate_id=labdeadbeef0000-mate"
  echo "worker_id=labdeadbeef0000-worker"
  echo "pi_trust=$(shasum -a 256 "$HOME/.pi/agent/trust.json" | awk '{print $1}')"
  echo "claude_config_dir="
  echo "claude_store=$HOME/.claude.json"
  echo "pi_trust_store=$HOME/.pi/agent/trust.json"
  echo "treehouse_dir=$HOME/.treehouse"
  echo "tmux_dir=$MISSING_DIR"
} > "$LAB_ROOT/.fm-live-lab"

# The divergence this suite exists for: the TMUX_TMPDIR-only form reaches the
# decoy once the lab directory is gone.
env -u TMUX TMUX_TMPDIR="$MISSING_DIR" tmux has-session -t firstmate 2>/dev/null \
  || fail "this tmux no longer falls back to the default socket; the decoy cases would prove nothing"

out=$("$LIVE_LAB" pane "$LAB_ROOT" 2>&1)
assert_not_contains "$out" DECOY-PANE "pane never reads the default server's window"
"$LIVE_LAB" say "$LAB_ROOT" "LAB-TYPED-TEXT" >/dev/null 2>&1
sleep 0.2
assert_not_contains "$(tmux -S "$DEFAULT_SOCKET" capture-pane -p -t firstmate:=main)" LAB-TYPED-TEXT "say never types into the default server"
out=$("$LIVE_LAB" check "$LAB_ROOT" 2>&1)
assert_not_contains "$out" "ok primary" "check never reads the default server as the lab"
out=$("$LIVE_LAB" down "$LAB_ROOT" 2>&1)
expect_code 0 "$?" "down cleans a lab whose tmux directory is gone: $out"
assert_absent "$LAB_ROOT" "down removed the lab root"
kill -0 "$DECOY_PID" 2>/dev/null || fail "down killed the default tmux server"
tmux -S "$DEFAULT_SOCKET" has-session -t firstmate 2>/dev/null || fail "the default server lost its session"
pass "a lab aimed at a missing tmux directory never reaches the default tmux server"
