#!/usr/bin/env bash
# Default-on live guard for the busy contract's wiring-liveness proof
# (bin/fm-busy-lib.sh "Wiring liveness").
#
# That proof rests on one thing only a real Pi can answer: that the per-task
# extension fm-spawn generates really does run inside the Pi process, at load,
# and names THAT process - so the identity it records lives exactly as long as
# the agent holding the wiring. A Node stand-in confirms the extension's own
# code; it cannot confirm what Pi does with it. If a Pi release stopped running
# an extension's body at load, or ran it somewhere else, no identity would be
# recorded, the proof would fall silent, and a worker whose agent was replaced
# would go back to reading idle forever. This guard launches the installed Pi
# with the extension the REAL fm-spawn wrote and requires the recorded process
# to be the one in the pane, to read as wired while it lives, and to read as
# lost the moment it is gone, failing loudly with the installed Pi version.
#
# No prompt is submitted and no model turn reaches any provider. The spawn runs
# against a fake pane; only the final launch is the real Pi, in a scratch
# project with a scratch agent directory on a private tmux socket.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_BUSY_WIRING_LIVE pi tmux

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

PI_VERSION=$(pi --version 2>/dev/null || printf 'unknown')
SOCKET="fm-busy-wiring-live-$$"
SESSION="busy-wiring-live"
TMP_ROOT=$(fm_test_tmproot fm-busy-wiring-live)
ID=wiring-live
HOME_DIR="$TMP_ROOT/home"
PROJ_DIR="$TMP_ROOT/project"
WT_DIR="$TMP_ROOT/wt"
STATE="$HOME_DIR/state"
EXT="$STATE/$ID.pi-ext.ts"
WIRED="$STATE/$ID.busy-wired"
mkdir -p "$TMP_ROOT/agent" "$TMP_ROOT/sessions"

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

pane() { tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null; }

# 0 when <pid> is <ancestor> or descends from it within a few generations.
descends_from() {  # <pid> <ancestor>
  local pid=$1 ancestor=$2 hops=0
  while [ "$hops" -lt 6 ]; do
    [ "$pid" = "$ancestor" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    case "$pid" in ''|0|1|*[!0-9]*) return 1 ;; esac
    hops=$((hops + 1))
  done
  return 1
}

# The real fm-spawn writes the extension; the pane it launches into is fake.
FAKEBIN=$(make_spawn_fakebin "$TMP_ROOT/fake" pi)
fm_test_spawn_home "$HOME_DIR" pi
fm_git_worktree "$PROJ_DIR" "$WT_DIR" wt-wiring-live
fm_test_spawn_brief "$HOME_DIR" "$ID"
out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$ID" "$PROJ_DIR" --mode no-mistakes --yolo off) \
  || fail "the fixture spawn that writes the extension failed: $out"
[ -f "$EXT" ] || fail "the spawn wrote no per-task Pi extension"
[ ! -e "$WIRED" ] || fail "a wiring identity existed before any process loaded the extension"
GEN=$(cat "$STATE/$ID.busy-gen")

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 160 -y 36 \
  "cd '$WT_DIR' && env PI_CODING_AGENT_DIR='$TMP_ROOT/agent' PI_OFFLINE=1 pi --approve --no-context-files --no-skills --no-prompt-templates --no-extensions -e '$EXT' --session-dir '$TMP_ROOT/sessions'; sleep 30"
PANE_PID=$(tmux -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_pid}')

# 1. Loading the extension is enough: no turn has to run for Pi to record the
#    process holding the wiring.
i=0
until [ -s "$WIRED" ]; do
  i=$((i + 1))
  [ "$i" -lt 400 ] || fail "Pi $PI_VERSION loaded the Firstmate extension without recording the process it loaded into: $(pane)"
  sleep 0.05
done
case "$(cat "$WIRED")" in
  "v1 gen=$GEN pid="*" start="?*) ;;
  *) fail "Pi $PI_VERSION recorded a wiring identity for another incarnation: $(cat "$WIRED")" ;;
esac
WIRED_PID=$(sed -n 's/^v1 gen=[^ ]* pid=\([0-9][0-9]*\) start=.*/\1/p' "$WIRED")
[ -n "$WIRED_PID" ] || fail "Pi $PI_VERSION's wiring identity carries no pid: $(cat "$WIRED")"
descends_from "$WIRED_PID" "$PANE_PID" \
  || fail "Pi $PI_VERSION recorded pid $WIRED_PID, which is not the agent running in the pane (pane pid $PANE_PID)"
pass "Pi $PI_VERSION records the process its Firstmate extension loaded into, with no turn submitted"

# 2. While that process lives, the wiring has its writer and the record counts.
fm_busy_wiring_lost "$STATE" "$ID" pi \
  && fail "Pi $PI_VERSION: a live agent holding the wiring read as having lost it"
[ "$(fm_busy_classify tmux fake:w pi "$ID" "$STATE")" = "busy fm-spawn" ] \
  || fail "Pi $PI_VERSION: a live writer did not leave the record as written: $(fm_busy_classify tmux fake:w pi "$ID" "$STATE")"
pass "Pi $PI_VERSION: the wiring reads as live while the agent that loaded it is running"

# 3. End that agent the way a manager restart does, without relaunching it
#    through fm-spawn: the record it leaves behind must stop counting.
tmux -L "$SOCKET" kill-server 2>/dev/null || true
i=0
while kill -0 "$WIRED_PID" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 200 ] || fail "Pi $PI_VERSION (pid $WIRED_PID) outlived its pane"
  sleep 0.05
done
fm_busy_wiring_lost "$STATE" "$ID" pi \
  || fail "Pi $PI_VERSION: the wiring still read as live after the agent holding it was gone"
[ "$(fm_busy_classify tmux fake:w pi "$ID" "$STATE")" = "unknown wiring-lost" ] \
  || fail "Pi $PI_VERSION: a record whose writer is gone classified $(fm_busy_classify tmux fake:w pi "$ID" "$STATE"), not unknown wiring-lost"
pass "Pi $PI_VERSION: once the agent holding the wiring is gone its record classifies unknown wiring-lost"
