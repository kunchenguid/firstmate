#!/usr/bin/env bash
# Opt-in credentialed OpenCode secondmate-home arm regression.
#
# The watch-arm plugin must arm a genuine secondmate home - a linked worktree
# that carries a valid .fm-secondmate-home marker and is also the effective
# FM_HOME - while a linked worktree carrying a stale marker whose FM_HOME points
# elsewhere stays inert, and an unmarked linked worktree stays inert too. The
# armability predicate mirrors bin/fm-primary-scope-lib.sh
# fm_root_is_secondmate_home (docs/supervision-protocols/opencode.md owns the
# "applies in the main primary checkout and a secondmate's own home" contract).
#
# Modeled on tests/fm-opencode-primary-live-e2e.test.sh:293-306, whose plain
# clone has no marker and so only exercises the primary path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_OPENCODE_SECONDMATE_LIVE_E2E opencode tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

TMUX=$(command -v tmux)
SOCKET="fm-opencode-secondmate-live-e2e-$$"
LAB="$ROOT/.opencode-secondmate-live-e2e.$$"
REPO="$LAB/repo"
OPENCODE_VERSION=$(opencode --version)

capture() {  # <session>
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$1" -S -800 2>/dev/null || true
}

wait_for_text() {  # <session> <expected> [attempts]
  local session=$1 expected=$2 attempts=${3:-180} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture "$session" | grep -Fq "$expected" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture "$session" >&2
  return 1
}

dismiss_update_offer() {  # <session>
  capture "$1" | grep -Fq "Update Available" || return 0
  "$TMUX" -L "$SOCKET" send-keys -t "$1" Left Enter
  local i=0
  while [ "$i" -lt 60 ]; do
    capture "$1" | grep -Fq "Update Available" || return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

lab_pid_is_safe() {  # <pid>
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

# reap_case_watcher <state-dir>: stop the watcher and its arm parent this case
# started, but only when both still belong to this lab.
reap_case_watcher() {
  local state=$1 watcher_pid arm_pid
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.1
  if [ -n "$watcher_pid" ] && lab_pid_is_safe "$watcher_pid"; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  if [ -n "$arm_pid" ] && lab_pid_is_safe "$arm_pid"; then
    kill -TERM "$arm_pid" 2>/dev/null || true
  fi
}

cleanup() {
  reap_case_watcher "${SM_HOME:-/nonexistent}/state"
  reap_case_watcher "${OTHER_HOME:-/nonexistent}/state"
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

# launch_tui <session> <cwd> <fm-home> <root-override>
launch_tui() {
  local session=$1 cwd=$2 home=$3 root_override=$4
  # shellcheck disable=SC2016 # The model, not this test shell, expands $FM_HOME.
  "$TMUX" -L "$SOCKET" new-session -d -s "$session" -c "$cwd" \
    "env OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' FM_HOME='$home' FM_ROOT_OVERRIDE='$root_override' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; opencode --auto; rc=\$?; printf \"OPENCODE_EXIT=%s\\n\" \"\$rc\"; sleep 300'"
}

# shellcheck disable=SC2016 # The model, not this test shell, expands $FM_HOME.
PROMPT='Use the terminal to run `printf done > "$FM_HOME/state/sm-turn-done"`, then respond briefly. Never run or request any watcher arm command.'

# drive_turn <session> <state-dir>: wait for the TUI, send the prompt, and wait
# for the model turn to complete so session.idle has fired.
drive_turn() {
  local session=$1 state=$2 i=0
  wait_for_text "$session" "$OPENCODE_VERSION" 120 || fail "$session did not reach its TUI"
  dismiss_update_offer "$session" || fail "$session update offer did not dismiss"
  sleep 1
  "$TMUX" -L "$SOCKET" send-keys -t "$session" -l "$PROMPT"
  "$TMUX" -L "$SOCKET" send-keys -t "$session" Enter
  while [ "$i" -lt 240 ]; do
    dismiss_update_offer "$session" || fail "$session update offer obstructed the turn"
    [ -f "$state/sm-turn-done" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture "$session" >&2
  fail "$session credentialed turn did not complete"
}

wait_for_watcher() {  # <state-dir> [attempts]
  local state=$1 attempts=${2:-120} i=0 pid
  while [ "$i" -lt "$attempts" ]; do
    pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# --- fixture ----------------------------------------------------------------
# A clone whose committed tree carries AGENTS.md, bin/, and .opencode/plugins;
# two linked worktrees of it are the secondmate fixtures. The armable home is a
# linked worktree, so a plain git-dir==git-common-dir check would reject it.

mkdir -p "$LAB"
git clone -q "$ROOT" "$REPO"
SM_HOME="$LAB/sm-home"
SM_STALE="$LAB/sm-stale"
OTHER_HOME="$LAB/other-home"
git -C "$REPO" worktree add -q -b sm-arm "$SM_HOME"
git -C "$REPO" worktree add -q -b sm-stale "$SM_STALE"

# The uncommitted change under test, plus the lib it imports, into every tree
# OpenCode might resolve as the project root for each session.
for wt in "$REPO" "$SM_HOME" "$SM_STALE"; do
  mkdir -p "$wt/.opencode/plugins/lib"
  cp "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$wt/.opencode/plugins/fm-primary-watch-arm.js"
  cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$wt/.opencode/plugins/lib/fm-operational-input.js"
done

printf 'sm-arm-live\n' > "$SM_HOME/.fm-secondmate-home"
printf 'sm-stale-live\n' > "$SM_STALE/.fm-secondmate-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/config" "$SM_STALE/state" "$OTHER_HOME/state" "$OTHER_HOME/config"
printf 'project=fixture\n' > "$SM_HOME/state/sm-arm.meta"
printf 'project=fixture\n' > "$OTHER_HOME/state/sm-stale.meta"

# --- armable: marked linked worktree that is the effective home --------------
launch_tui sm-arm "$SM_HOME" "$SM_HOME" "$SM_HOME"
drive_turn sm-arm "$SM_HOME/state"
wait_for_watcher "$SM_HOME/state" 120 \
  || fail "OpenCode did not arm the watcher for a genuine secondmate home"

pane=$(capture sm-arm)
guard_count=$(printf '%s\n' "$pane" | grep -Fc "TURN WOULD END BLIND - supervision is off." || true)
[ "$guard_count" -eq 0 ] || fail "OpenCode secondmate home ended blind despite a live watcher (guard count $guard_count)"
reap_case_watcher "$SM_HOME/state"

# --- inert: stale marker whose FM_HOME points elsewhere ----------------------
launch_tui sm-inert "$SM_STALE" "$OTHER_HOME" "$SM_STALE"
drive_turn sm-inert "$OTHER_HOME/state"
sleep 20
if wait_for_watcher "$OTHER_HOME/state" 1 || wait_for_watcher "$SM_STALE/state" 1; then
  fail "OpenCode armed a stale-marked worktree whose FM_HOME points elsewhere"
fi
reap_case_watcher "$OTHER_HOME/state"

printf 'ok - OpenCode %s secondmate-home live E2E armed a genuine marked home and left a stale-marked one inert\n' "$OPENCODE_VERSION"
