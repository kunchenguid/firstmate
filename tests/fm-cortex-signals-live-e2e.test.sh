#!/usr/bin/env bash
# Credentialed Cortex Code worker guard. Opt in with FM_CORTEX_SIGNALS_LIVE=1.
# FM_CORTEX_MODEL chooses an account-listed model id (default claude-haiku-5-5).
# Runs the real fm-spawn launch command in a private tmux server; only worktree
# allocation and initial endpoint delivery use fixtures. All later steering,
# interrupt and exit operations use the real Firstmate control plane.
# The run uses the caller's own Cortex connection and spends a few small prompts
# of its Snowflake credits: no SQL is asked for, and the brief never names a
# database object. Cortex's global project-trust record must stay untouched.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_CORTEX_SIGNALS_LIVE cortex tmux jq
CORTEX_BIN=$(command -v cortex)
REAL_TMUX=$(command -v tmux)
VERSION="cortex $(cortex --version 2>/dev/null | head -1)"
TRUST_FILE="$HOME/.snowflake/cortex/cortex.json"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/cx.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
# Unix-domain socket paths have a small OS byte limit. Keep the socket name
# relative when the isolated lab is under this checkout's working directory.
SOCKET="$LAB/tmux.sock"
case "$SOCKET" in "$PWD"/*) SOCKET=${SOCKET#"$PWD"/} ;; esac
cleanup() {
  "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true
  # The spawn-owned commit-msg strip directory is installed read-only.
  chmod -R u+w "$LAB" >/dev/null 2>&1 || true
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
ID=cortex-live
# Cortex rewrites its timestamps and hints on every launch, so only the trusted
# project paths are compared.
trust_projects() { jq -S -c '.projects // {}' "$TRUST_FILE" 2>/dev/null || echo absent; }
trust_before=$(trust_projects)
fm_test_spawn_home "$H" cortex
fm_git_worktree "$PROJ" "$WT" cortex-live
mkdir -p "$LAB/bin"
git -C "$WT" config user.name 'Cortex Live Guard'
git -C "$WT" config user.email cortex-live-guard@example.invalid
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: compute 12345 plus 67890 using your shell tool and write only the result into answer.txt, then commit answer.txt with git using a commit message you write yourself. Also run '$ROOT/bin/fm-harness.sh' and write its output to harness.txt. Do no other work, run no SQL, and do not delegate. Later read and acknowledge Firstmate's instruction inbox when the doorbell arrives."
fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
ln -s "$CORTEX_BIN" "$fakebin/cortex"
FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$PROJ" \
  --scout --harness cortex --model "${FM_CORTEX_MODEL:-claude-haiku-5-5}" --effort low > "$LAB/spawn.log" 2>&1 \
  || fail "fm-spawn failed: $(cat "$LAB/spawn.log")"
# Project hooks record session identity and the SessionStart source for resume.
# Cortex loads them without a trust grant, as it does the plugin's hooks. They
# are written after the spawn, which refuses an unclean worktree.
mkdir -p "$WT/.cortex"
jq -n --arg cmd "cat >> '$LAB/events.jsonl'; printf '\n' >> '$LAB/events.jsonl'" \
  '{hooks: {SessionStart: [{hooks: [{type: "command", command: $cmd}]}]}}' \
  > "$WT/.cortex/settings.local.json"
# Route every backend read/write to this guard's own socket only.
printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/bin/tmux"
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH" FM_HOME="$H"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
unset HERDR_ENV HERDR_PANE_ID HERDR_BIN_PATH
TARGET="firstmate:fm-$ID"
"$REAL_TMUX" -S "$SOCKET" new-session -d -s firstmate -n "fm-$ID" -x 120 -y 40 -c "$WT" \
  "/bin/sh '$LAB/launch.sh'; exec /bin/bash --noprofile --norc" || fail 'could not start pane'
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
    [ "$(fm_busy_classify tmux "$TARGET" cortex "$ID" "$H/state")" = 'idle cortex-hook' ] && return 0
    sleep 0.5
  done
  fail 'Stop did not produce semantic idle'
}
wait_file "$WT/answer.txt"
wait_file "$WT/harness.txt"
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail 'launch brief did not execute'
[ "$(tr -d '[:space:]' < "$WT/harness.txt")" = cortex ] || fail 'tool ancestry did not identify Cortex'
wait_idle
[ -f "$H/state/$ID.turn-ended" ] || fail 'Stop did not notify turn end'
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'real Cortex process not classified alive'
! screen_text | grep -q 'Do you trust this project' || fail 'a trust dialog was left open'
[ "$(trust_projects)" = "$trust_before" ] \
  || fail "the launch added a trusted project to Cortex's global record"
pass "$VERSION: spawn brief, model, autonomy, trust skip, identity and native Stop"
git -C "$WT" log -1 --format=%B -- answer.txt > "$LAB/commit.txt" 2>/dev/null
[ -s "$LAB/commit.txt" ] || fail 'the worker did not commit answer.txt'
! grep -qiE 'co-authored-by|generated with' "$LAB/commit.txt" \
  || fail "worker commit carries Cortex attribution: $(cat "$LAB/commit.txt")"
pass "$VERSION: the worker commit carries no attribution through the spawn-owned strip"
# The real backend composer read, not an invented fixture, must prove the idle
# pane safe to type into even though Cortex parks its cursor outside the box.
verdict=$(fm_backend_composer_state tmux "$TARGET")
[ "$verdict" = empty ] || fail "idle composer was $verdict"
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime steering verification: compute 31 times 37 and write only the result to steer.txt. Acknowledge this instruction by moving its .msg file into handled/ as instructed by the doorbell. Do no other work.' > "$LAB/send.log" 2>&1 || fail "steer failed: $(cat "$LAB/send.log")"
wait_file "$WT/steer.txt"
wait_file "$H/state/$ID.inbox/handled/001.msg"
[ "$(tr -d '[:space:]' < "$WT/steer.txt")" = 1147 ] || fail 'wrong steering result'
wait_idle
pass "$VERSION: real fm-send doorbell read and acknowledged"
# An Escape pressed with no running turn must do nothing.
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/idle-interrupt.log" 2>&1 \
  || fail "idle interrupt failed: $(cat "$LAB/idle-interrupt.log")"
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'an idle interrupt stopped the agent'
[ "$(fm_busy_classify tmux "$TARGET" cortex "$ID" "$H/state")" = 'idle cortex-hook' ] || fail 'an idle interrupt disturbed the idle record'
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime interrupt verification: run sleep 90 in your shell tool, then wait for it to finish. Do not respond before it finishes.' > "$LAB/send.log" 2>&1 || fail 'could not steer interrupt probe'
seen_busy=0
for _ in $(seq 1 240); do
  if [ "$(fm_busy_classify tmux "$TARGET" cortex "$ID" "$H/state")" = 'busy cortex-hook' ] \
    && capture | fm_busy_lines_match cortex; then seen_busy=1; break; fi
  sleep 0.5
done
[ "$seen_busy" = 1 ] || fail 'no semantic and rendered busy during interrupt probe'
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/interrupt.log" 2>&1 || fail "interrupt failed: $(cat "$LAB/interrupt.log")"
for _ in $(seq 1 60); do
  screen_text | grep -q 'Interrupted' && break
  sleep 0.5
done
screen_text | grep -q 'Interrupted' || fail 'a single Escape did not cancel the running turn'
wait_idle
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'the interrupt stopped the agent'
pass "$VERSION: one Escape cancels the turn, keeps the agent, and Stop settles the busy record"
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "exit failed: $(cat "$LAB/exit.log")"
[ "$(fm_backend_agent_state tmux "$TARGET")" = dead ] || fail '/quit did not return to the shell'
session=$(jq -r 'select(.hook_event_name == "SessionStart") | .session_id' "$LAB/events.jsonl" | head -1)
[ -n "$session" ] || fail 'no session id for resume'
screen_text | grep -q "cortex --resume $session" || fail 'the exit summary did not print the resume command for the hook session id'
# Native resume is a vendor fact, not a new fm-control verb.
printf '%s\n' "exec '$CORTEX_BIN' --dangerously-allow-all-tool-calls --plugin-dir '$H/state/$ID.cortex-plugin' --resume '$session' -- 'Runtime resume probe: write the product of 17 and 29 into resumed.txt, then stop.'" > "$LAB/resume.sh"
tmux send-keys -t "$TARGET" -l "sh '$LAB/resume.sh'"
sleep 0.5
tmux send-keys -t "$TARGET" Enter
wait_file "$WT/resumed.txt"
[ "$(tr -d '[:space:]' < "$WT/resumed.txt")" = 493 ] || fail 'resume prompt not processed'
jq -e 'select(.hook_event_name == "SessionStart" and .source == "resume")' "$LAB/events.jsonl" >/dev/null || fail 'native resume source absent'
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "resumed exit failed: $(cat "$LAB/exit.log")"
pass "$VERSION: /quit and native --resume session resume"
