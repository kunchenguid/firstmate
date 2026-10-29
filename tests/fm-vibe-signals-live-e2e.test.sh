#!/usr/bin/env bash
# Credentialed Vibe 3.0.2 worker guard. FM_VIBE_SIGNALS_LIVE=1 opts in.
# FM_VIBE_MODEL selects a configured alias; default zai-glm-5-3-flash.
# Capture fm-spawn with fixture allocation, then use real tmux/send/control.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_VIBE_SIGNALS_LIVE vibe tmux jq python3
VERSION=$(vibe --version)
fail() {
  printf 'not ok - %s: %s\n' "$VERSION" "$1" >&2
  if [ -n "${TARGET:-}" ] && [ -n "${SOCKET_DIR:-}" ]; then
    tmux capture-pane -p -t "$TARGET" >&2 || true
  fi
  exit 1
}
[ "$VERSION" = 'vibe 3.0.2' ] || fail 'refresh adapter verification before using this version'
VIBE_BIN=$(command -v vibe)
export VIBE_HOME=${VIBE_HOME:-$HOME/.vibe}
MODEL=${FM_VIBE_MODEL:-zai-glm-5-3-flash}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/vibe-guard.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
H="$LAB/home"
SOCKET_DIR=
cleanup() {
  if [ -n "$SOCKET_DIR" ]; then
    TMUX_TMPDIR="$SOCKET_DIR" tmux kill-server >/dev/null 2>&1 || true
    "$ROOT/bin/fm-lab-home.sh" teardown "$H"
  fi
  # Vibe caches read-only plugin packages beneath its task session directory.
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
"$ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null
SOCKET_DIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$H")
export TMUX_TMPDIR="$SOCKET_DIR"
unset TMUX
ID=vibe-live
WT="$LAB/worker-project"
PROJ="$LAB/source-project"
fm_git_init_commit "$PROJ"
fm_git_add_origin "$PROJ" "$LAB/origin.git"
fm_git_init_commit "$WT"
git -C "$WT" remote add origin "$LAB/origin.git"
fm_test_spawn_home "$H" vibe
fm_test_spawn_brief "$H" "$ID" "Runtime verification only. Run '$ROOT/bin/fm-harness.sh' and write its output to harness.txt, then reply VIBE_GUARD_READY. Do not edit other project files, run git, or delegate. On a steering doorbell read numbered messages in '$H/state/$ID.inbox' and acknowledge by moving to handled/."
fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
ln -s "$VIBE_BIN" "$fakebin/vibe"
# Unlike Claude fixtures, Vibe must keep HOME for the OS credential lookup.
# The real launch uses the same HOME; all Firstmate state stays in the lab.
FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" FM_HOME="$H" FM_ROOT_OVERRIDE='' \
  FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" FM_PROJECTS_OVERRIDE="$H/projects" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" TMUX=fake,1,0 PATH="$fakebin:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" --scout --harness vibe --model "$MODEL" --backend tmux > "$LAB/spawn.log" 2>&1 \
  || fail "spawn refused: $(cat "$LAB/spawn.log")"
export FM_HOME="$H"
unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
TARGET="firstmate:fm-$ID"
tmux new-session -d -s firstmate -n "fm-$ID" -c "$WT" -x 120 -y 40
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
classify() { fm_busy_classify tmux "$TARGET" vibe "$ID" "$H/state"; }
screen_text() { tmux capture-pane -p -t "$TARGET"; }
wait_for() { # <function> <expected> [argument]
  local function=$1 expected=$2 argument=${3:-} deadline=$((SECONDS + 90)) value=
  while [ "$SECONDS" -lt "$deadline" ]; do
    value=$("$function" "$argument" 2>/dev/null) || value=
    [ "$value" = "$expected" ] && return 0
    sleep 0.2
  done
  fail "$function expected $expected, got $value"
}
reply_seen() { screen_text | grep -Eq "^[[:space:]]*$1[[:space:]]*$" && printf yes; }
composer() { fm_backend_composer_state tmux "$TARGET"; }
agent() { fm_backend_agent_state tmux "$TARGET"; }
harness_written() { [ -s "$WT/harness.txt" ] && printf yes; }
tmux send-keys -t "$TARGET" "bash '$LAB/launch.sh'" Enter
wait_for classify 'busy vibe-session'
wait_for harness_written yes
wait_for reply_seen yes VIBE_GUARD_READY
wait_for classify 'idle vibe-session'
[ "$(tr -d '[:space:]' < "$WT/harness.txt")" = vibe ] || fail 'real tool ancestry was not vibe'
wait_for agent alive
wait_for composer empty
# Draft proof uses raw input, never a lifecycle command through fm-send.
tmux send-keys -t "$TARGET" -l 'unsent draft'
wait_for composer pending
tmux send-keys -t "$TARGET" C-u
wait_for composer empty
"$ROOT/bin/fm-send.sh" "$ID" 'Reply exactly VIBE_GUARD_STEER_OK; acknowledge this message in handled/ and do no other work.' > "$LAB/steer.log" 2>&1 || fail "steer failed: $(cat "$LAB/steer.log")"
wait_for reply_seen yes VIBE_GUARD_STEER_OK
wait_for classify 'idle vibe-session'
find "$H/state/$ID.inbox/handled" -name '*.msg' | grep -q . || fail 'steer was not acknowledged'
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/interrupt.log" 2>&1 || fail "interrupt failed: $(cat "$LAB/interrupt.log")"
wait_for agent alive
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "exit failed: $(cat "$LAB/exit.log")"
wait_for agent dead
old_gen=$(fm_meta_get "$H/state/$ID.meta" spawn_gen)
"$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Runtime verification only: reply VIBE_GUARD_RELAUNCH_OK and do no other work.' > "$LAB/relaunch.log" 2>&1 || fail "relaunch failed: $(cat "$LAB/relaunch.log")"
[ "$(fm_meta_get "$H/state/$ID.meta" spawn_gen)" != "$old_gen" ] || fail 'relaunch reused session generation'
wait_for reply_seen yes VIBE_GUARD_RELAUNCH_OK
wait_for classify 'idle vibe-session'
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/final-exit.log" 2>&1 || fail "final exit failed: $(cat "$LAB/final-exit.log")"
wait_for agent dead
printf 'ok - %s: real spawn, ancestry, busy/idle, draft, steer, interrupt, exit and replacement reply (model %s; effort unsupported)\n' "$VERSION" "$MODEL"
