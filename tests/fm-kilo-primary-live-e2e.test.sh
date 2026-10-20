#!/usr/bin/env bash
# Opt-in credentialed kilo (Kilo Code) PRIMARY continuity regression on an
# isolated clone and FM_HOME. Existing kilo credentials stay in their managed
# store. This is the live gate for the `.kilo/plugin/` runtime contract that
# docs/verification/kilo.md marks as parity-only until proven: it loads the
# tracked plugin stack, arms the real bin/fm-watch-arm.sh on session.idle,
# proves the client.session.promptAsync follow-up reaches the model, and checks
# the plugins stay silent in a child worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_KILO_PRIMARY_LIVE_E2E kilo tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMUX=$(command -v tmux)
SOCKET="fm-kilo-primary-live-e2e-$$"
SESSION=kilo-primary-live-e2e
LAB="$ROOT/.kilo-primary-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
KILO_VERSION=$(kilo --version 2>/dev/null | head -1 || true)

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -800 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-180} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture | grep -Fq "$expected" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local watcher_pid arm_pid
  watcher_pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.1
  if [ -n "$watcher_pid" ] && lab_pid_is_safe "$watcher_pid"; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  if [ -n "$arm_pid" ] && lab_pid_is_safe "$arm_pid"; then
    kill -TERM "$arm_pid" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
mkdir -p "$PROJECT/.kilo/plugin/lib"
cp "$ROOT"/.kilo/plugin/fm-primary-*.js "$PROJECT/.kilo/plugin/"
cp "$ROOT/.kilo/plugin/lib/fm-operational-input.js" "$PROJECT/.kilo/plugin/lib/fm-operational-input.js"
cp "$ROOT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-watch-arm.sh"
cp "$ROOT/bin/fm-operational-input.sh" "$PROJECT/bin/fm-operational-input.sh"
chmod +x "$PROJECT/bin/fm-operational-input.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
# A live task meta makes fm_supervision_needed true so the plugin arms on idle.
printf 'project=fixture\n' > "$HOME_DIR/state/kilo-e2e.meta"

# shellcheck disable=SC2016 # The model, not this test shell, expands FM_HOME.
PROMPT='Use the terminal to run `printf ready > "$FM_HOME/state/kilo-model-initial"`, then respond briefly. If a later watcher wake arrives, run bin/fm-wake-drain.sh, then run `printf handled > "$FM_HOME/state/kilo-model-handled"`. Never run or request any watcher arm command.'
"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; kilo --auto; rc=\$?; printf \"KILO_EXIT=%s\\n\" \"\$rc\"; sleep 300'"

wait_for_text "Ask anything" 180 || fail "kilo did not reach its idle composer"
sleep 1
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$PROMPT"
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
i=0
while [ "$i" -lt 240 ]; do
  [ -f "$HOME_DIR/state/kilo-model-initial" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ -f "$HOME_DIR/state/kilo-model-initial" ] || fail "kilo credentialed initial turn did not complete"
pass "the real kilo TUI processed its launch prompt"

i=0
watcher_pid=
while [ "$i" -lt 120 ]; do
  watcher_pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
if [ -z "${watcher_pid:-}" ] || ! kill -0 "$watcher_pid" 2>/dev/null; then
  fail "the .kilo plugin did not arm the watcher on session.idle (plugin-load or role check failed)"
fi
pass "the .kilo watch-arm plugin loaded and armed a live watcher"

printf 'done: kilo live e2e watcher fire\n' > "$HOME_DIR/state/kilo-e2e.status"
i=0
while [ "$i" -lt 240 ]; do
  grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null \
  || fail "the .kilo plugin did not start and ledger-link a successor after the actionable close"
pass "the .kilo watch-arm plugin started a singleton successor on an actionable close"

i=0
while [ "$i" -lt 240 ]; do
  [ -f "$HOME_DIR/state/kilo-model-handled" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ -f "$HOME_DIR/state/kilo-model-handled" ] \
  || fail "the .kilo plugin did not deliver the actionable wake as a follow-up turn (client.session.promptAsync)"
pass "the .kilo plugin delivered the actionable wake through the SDK follow-up"

pane=$(capture)
if printf '%s\n' "$pane" | grep -Fq '$ bin/fm-watch-arm.sh'; then
  fail "the kilo model attempted to re-arm instead of leaving continuity to the plugin"
fi

# Self-silencing: the same plugins must stay inert in a linked child worktree.
WORKTREE="$LAB/kilo-child-wt"
git -C "$PROJECT" worktree add -q -b kilo-child "$WORKTREE" >/dev/null 2>&1 \
  || fail "could not create the child worktree for the self-silencing check"
CHILD_HOME="$LAB/child-home"
mkdir -p "$CHILD_HOME/state" "$CHILD_HOME/config"
# A live task meta would make the primary arm; in a linked worktree the role
# check must keep the plugin silent anyway, so this is a fair test of it.
printf 'project=fixture\n' > "$CHILD_HOME/state/kilo-child.meta"
CHILD_SESSION=kilo-child-wt
"$TMUX" -L "$SOCKET" new-session -d -s "$CHILD_SESSION" -c "$WORKTREE" \
  "env FM_HOME='$CHILD_HOME' FM_ROOT_OVERRIDE='$WORKTREE' bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; kilo --auto; sleep 120'"
child_ready=
for _ in $(seq 1 180); do
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$CHILD_SESSION" 2>/dev/null | grep -Fq "Ask anything" && { child_ready=1; break; }
  sleep 0.5
done
[ -n "$child_ready" ] || fail "the child worktree kilo TUI did not reach its composer"
sleep 4
[ -e "$CHILD_HOME/state/.watch.lock/pid" ] \
  && fail "a .kilo plugin armed inside a child worktree instead of staying silent" || true
pass "the .kilo plugins stay silent in a child worktree"

printf 'ok - kilo %s primary live E2E covered plugin load, plugin-owned re-arm, SDK follow-up delivery, and child-worktree self-silencing\n' "${KILO_VERSION:-unknown}"
cleanup
trap - EXIT
