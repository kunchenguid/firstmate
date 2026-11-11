#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
export PATH="$ROOT/.live-tools/claude/node_modules/.bin:$PATH"
E=~/.no-mistakes/evidence/01M742GVY0TYVH8CG9X6SG2B0Y
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
SUB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
cleanup() {
  if [ -n "${SOCKET:-}" ] && [ -S "$SOCKET" ]; then tmux -S "$SOCKET" kill-server; fi
  find "$LAB" "$SUB" -type d -exec chmod u+w {} +
  rm -rf "$LAB" "$SUB"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
LAB=$(cd "$LAB" && pwd -P)
rmdir "$SUB"
mkdir -p "$LAB/tmux"
touch "$LAB/config/supervision-host"
export FM_HOME="$LAB" FM_BACKEND=tmux
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
# The harness is the actual installed Claude CLI with the existing login.
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$ROOT" -e FM_HOME="$LAB" claude
SOCKET="$LAB/tmux/tmux-$(id -u)/fm-lab"
export TMUX="$SOCKET,0,0" TMUX_PANE=%0
export FM_SECONDMATE_CHARTER='Disposable environment isolation proof. Follow only the test request; do not operate on other homes or projects.'
export FM_SECONDMATE_SCOPE='Disposable environment isolation validation'
bin/fm-home-seed.sh envproof "$SUB" --no-projects
for v in FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE; do tmux -S "$SOCKET" set-environment -g "$v" "$LAB/parent-poison"; done
bin/fm-spawn.sh envproof "$SUB" claude --secondmate
sleep 8
tmux -S "$SOCKET" list-windows -a -F '#S:#W #{pane_id} #{pane_current_command}'
tmux -S "$SOCKET" capture-pane -p -t primary:fm-envproof > "$E/template-initial.txt"
# Print current UI before proceeding.
head -60 "$E/template-initial.txt"
printf '%s\n' "$LAB" "$SUB" "$SOCKET" > "$ROOT/.live-tools/active-lab"
# Keep ownership in this synchronous driver while an operator drives via its socket.
for ((i=0;i<900;i++)); do [ ! -e "$ROOT/.live-tools/continue" ] || break; sleep 1; done
[ -e "$ROOT/.live-tools/continue" ]
rm -f "$ROOT/.live-tools/continue"
