#!/usr/bin/env bash
# Opt-in live check that an OpenCode 1.18.x pane whose working directory lies
# OUTSIDE $HOME, on a wide (300-column) tmux pane, reads `empty` through
# fm_tmux_composer_state both mid-turn and idle: the absolute cwd rail drawn
# right-aligned in the composer is furniture, never typed text.
# Opt-in because it submits a real prompt with the operator's OpenCode
# credentials; it runs on an isolated tmux socket and a throwaway directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_OPENCODE_ABS_CWD_LIVE opencode tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-opencode-abs-cwd-$$"
SESSION=opencode-abs-cwd
TARGET="$SESSION:oc"
LAB=

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# The rail must render as an absolute path, so the lab lives under /tmp and
# must resolve outside $HOME.
LAB=$(mktemp -d /tmp/fm-opencode-abs-cwd.XXXXXX) || fail "could not create the lab under /tmp"
trap cleanup EXIT
LAB=$(cd "$LAB" && pwd -P) || fail "could not resolve the lab"
case "$LAB/" in "$HOME"/*) fail "the lab $LAB resolves under \$HOME; the check needs a cwd outside it" ;; esac
# A cwd longer than the rail's width wraps, so its first fragment lands in a
# composer row above the Build footer - the shape the classifier must read as
# furniture. A short cwd fits on the footer row alone and proves nothing.
WORK="$LAB/a-rather-long-worktree-pool-directory/slot-0123456789/project-under-test"
mkdir -p "$WORK" || fail "could not create the lab worktree"
git -C "$WORK" init -q || fail "could not initialize the lab repository"

# fm_tmux_composer_state calls plain `tmux`; scope it to the isolated socket.
tmux() { "$REAL_TMUX" -L "$SOCKET" "$@"; }
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

tmux new-session -d -s "$SESSION" -n oc -x 300 -y 60 -c "$WORK" \
  || fail "could not start the isolated tmux server"
tmux set-option -t "$SESSION" window-size manual >/dev/null 2>&1 || true
tmux resize-window -t "$TARGET" -x 300 -y 60 >/dev/null 2>&1 || true

capture() { tmux capture-pane -p -t "$TARGET" -S 0 -E - 2>/dev/null || true; }

wait_for() {  # <grep -E pattern> <attempts>
  local i=0
  while [ "$i" -lt "$2" ]; do
    capture | grep -Eq "$1" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

tmux send-keys -t "$TARGET" -l "opencode" || fail "could not type the opencode launch line"
tmux send-keys -t "$TARGET" Enter || fail "could not launch opencode"
wait_for 'Build' 120 || { capture >&2; fail "opencode did not render its composer"; }
tmux send-keys -t "$TARGET" -l "Run the shell command 'sleep 25' and then reply with exactly DONE." \
  || fail "could not type the prompt"
tmux send-keys -t "$TARGET" Enter || fail "could not submit the prompt"

wait_for 'esc interrupt' 120 || { capture >&2; fail "opencode never showed a running turn"; }
# Non-vacuousness: the rail's first fragment, an absolute path start, must sit
# alone on a composer row above the footer.
capture | grep -Eq '┃ +/[^/[:space:]][^[:space:]]* *$' \
  || { capture >&2; fail "the absolute cwd rail did not wrap into a composer row"; }
verdict=$(fm_tmux_composer_state "$TARGET")
[ "$verdict" = empty ] || { capture >&2; fail "mid-turn absolute cwd rail read '$verdict', want empty"; }
pass "opencode mid-turn absolute cwd rail on a 300-column pane reads empty"

# The reply row starts with DONE; the echoed prompt row starts with "Run". On a
# wide pane the sidebar shares the reply's row, so text may follow DONE.
wait_for '^[^[:alnum:]]*DONE([[:space:]]|$)' 240 || { capture >&2; fail "the turn never finished"; }
i=0
while capture | grep -Fq 'esc interrupt'; do
  [ "$i" -lt 120 ] || { capture >&2; fail "opencode still showed a running turn after the reply"; }
  sleep 0.5
  i=$((i + 1))
done
verdict=$(fm_tmux_composer_state "$TARGET")
[ "$verdict" = empty ] || { capture >&2; fail "idle absolute cwd rail read '$verdict', want empty"; }
pass "opencode idle absolute cwd rail on a 300-column pane reads empty"
