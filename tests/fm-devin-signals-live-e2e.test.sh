#!/usr/bin/env bash
# Credentialed Devin worker guard. Opt in with FM_DEVIN_SIGNALS_LIVE=1.
# FM_DEVIN_MODEL chooses an account-listed model (default swe-2-medium).
# Runs the real fm-spawn launch command in a private tmux server; only worktree
# allocation and initial endpoint delivery use fixtures. All later steering,
# interrupt and exit operations use the real Firstmate control plane.
# The isolated home carries a user Claude Code hook that must never fire, and
# the worker's own commit must carry no Devin attribution.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_DEVIN_SIGNALS_LIVE devin tmux jq
DEVIN_BIN=$(command -v devin)
REAL_TMUX=$(command -v tmux)
VERSION=$(devin --version)
if ! devin auth status 2>/dev/null | grep -q '^Logged in'; then
  printf 'skip: live: %s is signed out; run devin auth login\n' "$VERSION"
  exit 0
fi
CREDENTIALS="$HOME/.local/share/devin/credentials.toml"
if [ ! -r "$CREDENTIALS" ]; then
  printf 'skip: live: %s has no file credentials to copy into the isolated home\n' "$VERSION"
  exit 0
fi
LAB=$(mktemp -d "${TMPDIR:-/tmp}/dv.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
# Unix-domain socket paths have a small OS byte limit. Keep the socket name
# relative when the isolated lab is under this checkout's working directory.
SOCKET="$LAB/tmux.sock"
case "$SOCKET" in "$PWD"/*) SOCKET=${SOCKET#"$PWD"/} ;; esac
cleanup() {
  "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT
fail() { printf 'not ok - %s: %s\n' "$VERSION" "$1" >&2; exit 1; }
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
H="$LAB/home"
WT="$LAB/wt"
PROJ="$LAB/project"
ID=devin-live
fm_test_spawn_home "$H" devin
fm_git_worktree "$PROJ" "$WT" devin-live
mkdir -p "$H/user-home/.local/share/devin" "$H/user-home/.config/devin" "$LAB/bin"
cp "$CREDENTIALS" "$H/user-home/.local/share/devin/credentials.toml"
chmod 600 "$H/user-home/.local/share/devin/credentials.toml"
# A user Claude Code hook Devin would import by default; the worker config
# must keep it from ever running.
mkdir -p "$H/user-home/.claude"
jq -n --arg cmd "cat >> '$LAB/claude-hooks.jsonl'" \
  '{hooks: {SessionStart: [{hooks: [{type: "command", command: $cmd}]}], UserPromptSubmit: [{hooks: [{type: "command", command: $cmd}]}], Stop: [{hooks: [{type: "command", command: $cmd}]}]}}' \
  > "$H/user-home/.claude/settings.json"
git -C "$WT" config user.name 'Devin Live Guard'
git -C "$WT" config user.email devin-live-guard@example.invalid
# Keep SessionStart evidence for native resume and command hooks for tool ancestry.
jq -n --arg cmd "cat >> '$LAB/events.jsonl'; printf '\n' >> '$LAB/events.jsonl'" \
  '{hooks: {SessionStart: [{hooks: [{type: "command", command: $cmd}]}], PreToolUse: [{hooks: [{type: "command", command: $cmd}]}]}}' \
  > "$H/user-home/.config/devin/config.json"
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: compute 12345 plus 67890 using your shell tool and write only the result into answer.txt, then commit answer.txt with git using a commit message you write yourself. Also run '$ROOT/bin/fm-harness.sh' and write its output to harness.txt. Do no other work and do not delegate. Later read and acknowledge Firstmate's instruction inbox when the doorbell arrives."
fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
ln -s "$DEVIN_BIN" "$fakebin/devin"
FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$PROJ" \
  --scout --harness devin --model "${FM_DEVIN_MODEL:-swe-2-medium}" --effort high > "$LAB/spawn.log" 2>&1 \
  || fail "fm-spawn failed: $(cat "$LAB/spawn.log")"
# Route every backend read/write to this guard's own socket only.
printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/bin/tmux"
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH" FM_HOME="$H"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
TARGET="firstmate:fm-$ID"
"$REAL_TMUX" -S "$SOCKET" new-session -d -s firstmate -n "fm-$ID" -x 120 -y 40 -c "$WT" \
  "HOME='$H/user-home' /bin/sh '$LAB/launch.sh'; exec /bin/bash --noprofile --norc" || fail 'could not start pane'
capture() { "$REAL_TMUX" -S "$SOCKET" capture-pane -p -e -t "$TARGET"; }
screen_text() { "$REAL_TMUX" -S "$SOCKET" capture-pane -p -t "$TARGET"; }
wait_file() {
  local path=$1 i
  for i in $(seq 1 480); do [ -s "$path" ] && return 0; sleep 0.5; done
  fail "timed out waiting for ${path##*/}"
}
wait_idle() {
  local i
  for i in $(seq 1 240); do
    [ "$(fm_busy_classify tmux "$TARGET" devin "$ID" "$H/state")" = 'idle devin-hook' ] && return 0
    sleep 0.5
  done
  fail 'Stop did not produce semantic idle'
}
wait_file "$WT/answer.txt"
wait_file "$WT/harness.txt"
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail 'launch brief did not execute'
[ "$(tr -d '[:space:]' < "$WT/harness.txt")" = devin ] || fail 'tool ancestry/marker did not identify Devin'
wait_idle
[ -f "$H/state/$ID.turn-ended" ] || fail 'Stop did not notify turn end'
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'real Devin process not classified alive'
pass "$VERSION: spawn brief, model, autonomy, trust, identity and native Stop"
git -C "$WT" log -1 --format=%B -- answer.txt > "$LAB/commit.txt" 2>/dev/null
[ -s "$LAB/commit.txt" ] || fail 'the worker did not commit answer.txt'
! grep -qiE 'co-authored-by|generated with' "$LAB/commit.txt" \
  || fail "worker commit carries Devin attribution: $(cat "$LAB/commit.txt")"
[ ! -e "$LAB/claude-hooks.jsonl" ] \
  || fail "the worker ran imported Claude Code hooks: $(head -c 300 "$LAB/claude-hooks.jsonl")"
pass "$VERSION: no Claude Code hook ran and the worker commit carries no attribution"
# The full styled screen, not an invented glyph-only fixture, must be safe to type into.
verdict=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1\nrows=0' "$(capture)" \
  "$(tmux display-message -p -t "$TARGET" '#{cursor_y}')" devin)
case "$verdict" in empty*) ;; *) fail "idle composer was $verdict" ;; esac
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime steering verification: compute 31 times 37 and write only the result to steer.txt. Acknowledge this instruction by moving its .msg file into handled/ as instructed by the doorbell. Do no other work.' > "$LAB/send.log" 2>&1 || fail "steer failed: $(cat "$LAB/send.log")"
wait_file "$WT/steer.txt"
wait_file "$H/state/$ID.inbox/handled/001.msg"
[ "$(tr -d '[:space:]' < "$WT/steer.txt")" = 1147 ] || fail 'wrong steering result'
wait_idle
pass "$VERSION: real fm-send doorbell read and acknowledged"
# An idle Devin opens its /revert picker (Enter reverts) on a fast Escape pair,
# so an interrupt with no running turn must send one press and open nothing.
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/idle-interrupt.log" 2>&1 \
  || fail "idle interrupt failed: $(cat "$LAB/idle-interrupt.log")"
grep -q 'cancel=not-running' "$LAB/idle-interrupt.log" \
  || fail "idle interrupt did not report not-running: $(cat "$LAB/idle-interrupt.log")"
sleep 1.5
! screen_text | grep -q 'Revert to step' || fail 'idle interrupt opened the revert picker'
# The hazard is real on this version: a raw fast pair opens the picker. Exit
# must refuse to type into it and interrupt must close it with no revert.
picker=0
for _ in 1 2 3; do
  tmux send-keys -t "$TARGET" Escape
  tmux send-keys -t "$TARGET" Escape
  sleep 1
  if screen_text | grep -q 'Revert to step'; then picker=1; break; fi
  sleep 1
done
[ "$picker" = 1 ] || fail 'a raw fast Escape pair no longer opens the revert picker; re-verify the interrupt arm gate'
if "$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/picker-exit.log" 2>&1; then
  fail "exit proceeded with the revert picker open: $(cat "$LAB/picker-exit.log")"
fi
screen_text | grep -q 'Revert to step' || fail 'the refused exit closed or typed into the picker'
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/picker-interrupt.log" 2>&1 \
  || fail "interrupt could not close the revert picker: $(cat "$LAB/picker-interrupt.log")"
sleep 1
! screen_text | grep -q 'Revert to step' || fail 'interrupt left the revert picker open'
[ "$(tr -d '[:space:]' < "$WT/steer.txt")" = 1147 ] && [ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] \
  || fail 'the revert picker changed the worker files'
pass "$VERSION: idle interrupt sends one press; an open revert picker blocks exit and is closed without reverting"
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime interrupt verification: run sleep 90 in your shell tool, then wait for it to finish. Do not respond before it finishes.' > "$LAB/send.log" 2>&1 || fail 'could not steer interrupt probe'
seen_busy=0
for _ in $(seq 1 240); do
  if [ "$(fm_busy_classify tmux "$TARGET" devin "$ID" "$H/state")" = 'busy devin-hook' ] \
    && capture | fm_busy_lines_match devin; then seen_busy=1; break; fi
  sleep 0.5
done
[ "$seen_busy" = 1 ] || fail 'no semantic and rendered busy during interrupt probe'
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/interrupt.log" 2>&1 || fail "interrupt failed: $(cat "$LAB/interrupt.log")"
grep -q 'cancel=unconfirmed' "$LAB/interrupt.log" || fail "busy interrupt was not armed: $(cat "$LAB/interrupt.log")"
[ "$(fm_busy_classify tmux "$TARGET" devin "$ID" "$H/state")" = 'unknown fm-interrupt' ] || fail 'interrupt did not conservatively invalidate state'
for _ in $(seq 1 60); do
  capture | grep -q 'Canceled. What should Devin do?' && break
  sleep 0.5
done
capture | grep -q 'Canceled. What should Devin do?' || fail 'double Escape did not cancel'
pass "$VERSION: double Escape cancels, preserves agent, and invalidates busy state"
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "exit failed: $(cat "$LAB/exit.log")"
[ "$(fm_backend_agent_state tmux "$TARGET")" = dead ] || fail 'quit did not return to shell'
session=$(jq -r 'select(.hook_event_name == "SessionStart") | .session_id' "$LAB/events.jsonl" | head -1)
[ -n "$session" ] || fail 'no session id for resume'
# Native resume is a vendor fact, not a new fm-control verb.
printf '%s\n' "exec env -u NO_COLOR HOME='$H/user-home' '$DEVIN_BIN' --config '$H/state/$ID.devin-config.json' --permission-mode dangerous --respect-workspace-trust false -r '$session' -- 'Runtime resume probe: write the product of 17 and 29 into resumed.txt, then stop.'" > "$LAB/resume.sh"
tmux send-keys -t "$TARGET" -l "sh '$LAB/resume.sh'"
sleep 0.5
tmux send-keys -t "$TARGET" Enter
wait_file "$WT/resumed.txt"
[ "$(tr -d '[:space:]' < "$WT/resumed.txt")" = 493 ] || fail 'resume prompt not processed'
jq -e 'select(.hook_event_name == "SessionStart" and .source == "resume")' "$LAB/events.jsonl" >/dev/null || fail 'native resume source absent'
# Exit via the actual table-backed control plane once more. The retired busy
# generation remains absent, so control observes unknown and interrupts first.
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "resumed exit failed: $(cat "$LAB/exit.log")"
pass "$VERSION: /quit and native -r session resume"
