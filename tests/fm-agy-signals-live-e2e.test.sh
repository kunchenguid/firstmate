#!/usr/bin/env bash
# Opt-in real AGY guard. FM_AGY_BACKEND=tmux (default) uses a private socket;
# herdr uses fm-herdr-lab.sh exclusively, with its default-fleet tripwire.
# Both use a scratch repository, never fm-spawn or a live fleet endpoint. Submits
# trivial prompts and verifies actual tools, native hooks, follow-up delivery,
# process identity, composer, interruption and exit. No account/config edits.
# FM_AGY_LIVE=1 (or FM_LIVE=1) forces the guard, including explicit missing-tool,
# unsupported-model/capability and authentication failures. FM_AGY_MODEL pins a
# catalog model (default gemini-3.8-flash-low); FM_AGY_EFFORT defaults to low.
# FM_AGY_HERDR_LAB_HELPER optionally selects the task brief's helper path.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
BACKEND=${FM_AGY_BACKEND:-tmux}
case "$BACKEND" in tmux|herdr) ;; *) fail "unsupported AGY live backend: $BACKEND" ;; esac
fm_live_gate opt-in FM_AGY_LIVE "$BACKEND" jq python3 agy
# shellcheck source=bin/fm-agy-lib.sh
. "$ROOT/bin/fm-agy-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
AGY=$(command -v agy)
VERSION=$("$AGY" --version)
MODEL=${FM_AGY_MODEL:-gemini-3.8-flash-low}
EFFORT=${FM_AGY_EFFORT:-low}
printf 'AGY live version=%s model=%s effort=%s\n' "$VERSION" "$MODEL" "$EFFORT"
fm_agy_preflight "$AGY" "$MODEL" "$EFFORT" || fail "AGY $VERSION unsupported capability/model"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-live.XXXXXX")
SOCKET="$LAB/tmux.sock"
HERDR_LAB_HELPER=${FM_AGY_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=
cleanup() {
  local code=$?
  if [ "$code" -ne 0 ]; then
    capture > "$LAB/failed-screen.txt" 2>/dev/null || true
    printf 'AGY failed lab evidence preserved at %s\n' "$LAB" >&2
  fi
  if [ "$BACKEND" = herdr ] && [ -n "$HERDR_LAB_SESSION" ]; then
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || exit 1
  else
    command tmux -S "$SOCKET" kill-server 2>/dev/null || true
  fi
  [ "$code" -ne 0 ] || rm -rf -- "$LAB"
}
trap cleanup EXIT
mkdir -p "$LAB/project" "$LAB/state/live.agy-hook/.agents" "$LAB/external"
git -C "$LAB/project" init -q
WT=$(cd "$LAB/project" && pwd -P)
STATE=$(cd "$LAB/state" && pwd -P)
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" live)
write_hooks() {
python3 - "$ROOT" "$STATE" "$GEN" "$WT" <<'PY'
import json,pathlib,shlex,sys
root,state,gen,wt=sys.argv[1:]
hooks={}
for event in ['PreInvocation','Stop']:
    cmd=shlex.join([root+'/bin/fm-agy-hook.sh',event,state,'live',gen,wt])
    hooks[event]=[{'command':cmd,'timeout':10}]
pathlib.Path(state+'/live.agy-hook/.agents/hooks.json').write_text(json.dumps({'firstmate-worker':hooks}))
PY
}
write_hooks
# A real model call, not version/catalog presence, proves authentication.
if ! (cd "$WT" && AGY_CLI_DISABLE_AUTO_UPDATE=true "$AGY" --model "$MODEL" --effort "$EFFORT" \
  --print-timeout 45s --output-format json --print 'Reply exactly AUTH_OK. Do not use tools.') > "$LAB/auth.json" 2> "$LAB/auth.stderr"; then
  # Never print OAuth continuation URLs, account identifiers or tokens.
  fail "AGY $VERSION actual prompt failed; verify AGY account eligibility/authentication and connectivity interactively"
fi
jq -e '.status == "SUCCESS" and (.response | rtrimstr("\n")) == "AUTH_OK"' "$LAB/auth.json" >/dev/null \
  || fail "AGY $VERSION authentication probe did not produce AUTH_OK"
pass "AGY $VERSION actual prompt executes successfully"

# One shell command is constructed as a single argv vector, matching the
# canonical interactive adapter flags without changing an operator's settings.
python3 - "$AGY" "$WT" "$STATE" "$MODEL" "$EFFORT" "$ROOT" "$LAB" <<'PY'
import pathlib,shlex,sys
agy,wt,state,model,effort,root,lab=sys.argv[1:]
prompt=('Use your run_command tool to run exactly: pwd -P > '+shlex.quote(wt+'/cwd.txt')+
        '; '+shlex.quote(root+'/bin/fm-harness.sh')+' > '+shlex.quote(wt+'/identity.txt')+
        '; printf AGY_FIRST_OK > '+shlex.quote(wt+'/first.txt')+
        '. Do not inspect other files, delegate, or change anything else. Stop after the command.')
args=['env','-u','CLAUDECODE','-u','PI_CODING_AGENT','-u','GROK_AGENT','-u','FM_PI_HARNESS',
      '-u','GEMINI_CLI','-u','CURSOR_AGENT','-u','CURSOR_INVOKED_AS','-u','ATLASSIAN_AGENT_TYPE',
      '-u','ROVODEV_CLI','-u','FM_OMP_HARNESS','FM_AGY_HARNESS=agy','AGY_CLI_DISABLE_AUTO_UPDATE=true',
      agy,'--new-project','--add-dir',wt,'--add-dir',state+'/live.agy-hook',
      '--dangerously-skip-permissions','--model',model,'--effort',effort,
      '--prompt-interactive',prompt]
pathlib.Path(lab+'/launch.sh').write_text('#!/bin/bash\n'+shlex.join(args)+'\nexec /bin/bash --noprofile --norc\n')
PY
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source "$BACKEND"
if [ "$BACKEND" = tmux ]; then
  command tmux -S "$SOCKET" -f /dev/null new-session -d -s agy -n proof -x 130 -y 40 -c "$WT" "bash '$LAB/launch.sh'"
  command tmux -S "$SOCKET" set-window-option -t agy:proof automatic-rename off
  tmux() { command tmux -S "$SOCKET" "$@"; }
  capture() { tmux capture-pane -p -t agy; }
  send_text() { tmux send-keys -t agy -l "$1"; }
  send_key() { tmux send-keys -t agy "$1"; }
  composer() { fm_tmux_composer_state agy; }
  identity() { fm_tmux_composer_identity agy; }
  agent_state() { fm_backend_tmux_agent_state agy:proof; }
else
  HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-agy-adapter)
  "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
  # Every Herdr call, including the backend library's capture/identity/key
  # reads, goes through the named-lab helper with its trailing session binding.
  fm_backend_herdr_cli() {
    [ "$1" = "$HERDR_LAB_SESSION" ] || return 1
    shift
    "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
  }
  created=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$WT" --label agy-proof --no-focus)
  PANE=$(printf '%s' "$created" | jq -er '.result.root_pane.pane_id')
  TARGET="$HERDR_LAB_SESSION:$PANE"
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PANE" "bash '$LAB/launch.sh'" >/dev/null
  capture() { fm_backend_herdr_capture "$TARGET" 40; }
  send_text() { fm_backend_herdr_send_literal "$TARGET" "$1"; }
  send_key() { fm_backend_herdr_send_key "$TARGET" "$1"; }
  composer() { fm_backend_herdr_composer_state "$TARGET"; }
  identity() { fm_backend_herdr_composer_identity "$TARGET"; }
  agent_state() { fm_backend_herdr_agent_state "$TARGET"; }
fi
# Only the documented folder-trust choice is allowed. A new isolated path may
# prompt even under --dangerously-skip-permissions; no credential field is typed.
accept_folder_trust() {
  local i pane
  for i in $(seq 1 120); do
    pane=$(capture)
    if printf '%s' "$pane" | grep -Fq 'Do you trust the contents of this project?'; then
      send_key Enter
      break
    fi
    [ ! -f "$WT/first.txt" ] || break
    sleep 0.5
  done
}
accept_folder_trust
wait_file() {
  local path=$1 i
  for i in $(seq 1 180); do
    [ ! -s "$path" ] || return 0
    sleep 0.5
  done
  fail "AGY $VERSION did not produce $(basename "$path") in the isolated lab"
}
wait_idle() {
  local i
  for i in $(seq 1 120); do
    if [ "$(fm_busy_record_read "$STATE" live | cut -d' ' -f1-2)" = 'idle agy-hook' ] \
       && [ "$(composer)" = empty ]; then return 0; fi
    sleep 0.5
  done
  printf 'AGY diagnostics: record=%s composer=%s identity=%s\n' \
    "$(fm_busy_record_read "$STATE" live)" "$(composer)" "$(identity || true)" >&2
  fail "AGY $VERSION did not settle through its native Stop and live composer"
}
wait_file "$WT/first.txt"
wait_idle
[ "$(<"$WT/first.txt")" = AGY_FIRST_OK ] || fail 'first tool write differs'
[ "$(<"$WT/cwd.txt")" = "$WT" ] || fail 'AGY tools escaped the isolated working directory'
[ "$(<"$WT/identity.txt")" = agy ] || fail 'real AGY tool process was misidentified'
[ -f "$STATE/live.turn-ended" ] || fail 'AGY native completion notification missing'
[ "$(agent_state)" = alive ] || fail 'backend could not attribute the real AGY process'
pass "AGY $VERSION interactive prompt executes tools in the isolated workspace, detects agy and settles native hooks"

# The same literal text + Enter transport fm-send uses. Verify the produced
# external report, never the return value of send-keys or echoed prompt text.
send_text "Use run_command to run exactly: printf AGY_FOLLOW_OK > '$LAB/external/report.txt'. Do not inspect other files or delegate. Stop after the command."
send_key Enter
wait_file "$LAB/external/report.txt"
wait_idle
[ "$(<"$LAB/external/report.txt")" = AGY_FOLLOW_OK ] || fail 'external reporting failed'
pass "AGY $VERSION follow-up steering performs external task reporting and completes"

# A bounded slow tool provides a genuine active-turn cancellation window.
send_text "Use run_command to run exactly: touch '$WT/slow-started'; sleep 20. Wait for it to finish. Do not delegate."
send_key Enter
for _ in $(seq 1 120); do
  [ ! -e "$WT/slow-started" ] || break
  sleep 0.5
done
[ -e "$WT/slow-started" ] || fail 'AGY did not start the slow tool'
[ "$(fm_busy_record_read "$STATE" live | cut -d' ' -f1-2)" = 'busy agy-hook' ] || fail 'real active tool lacked native busy state'
send_key "$(fm_control_interrupt_key agy)"
for _ in $(seq 1 120); do
  pane=$(capture)
  if printf '%s' "$pane" | grep -Fq 'Interrupted' && [ "$(composer)" = empty ]; then break; fi
  sleep 0.5
done
printf '%s' "$pane" | grep -Fq 'Interrupted' || fail 'AGY did not acknowledge Escape'
[ "$(composer)" = empty ] || fail 'Escape left input behind'
# A fresh turn proves the process survived; no cancellation claim relies only
# on a vendor banner, spinner or process presence.
send_text "Use run_command to run exactly: printf AGY_AFTER_CANCEL > '$WT/after.txt'. Stop after the command."
send_key Enter
wait_file "$WT/after.txt"
wait_idle
pass "AGY $VERSION Escape interrupts, clears the composer and accepts subsequent work"
send_text "$(fm_control_exit_command agy)"
send_key Enter
for _ in $(seq 1 60); do
  if ! identity 2>/dev/null | grep -q '^agy'; then break; fi
  sleep 0.5
done
! identity 2>/dev/null | grep -q '^agy' || fail 'AGY remained alive after /exit'
[ "$(composer)" = unknown ] || fail 'exited AGY still looks like an empty agent composer'
pass "AGY $VERSION /exit stops only the lab agent and stale shell input stays protected"

# Deterministic recovery starts the same durable instructions in the preserved
# directory, with fresh hook custody. The old conversation binding is retained
# deliberately to prove it cannot settle or poison this replacement.
old_gen=$GEN
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" live)
[ "$GEN" != "$old_gen" ] || fail 'relaunch generation did not change'
write_hooks
mv "$WT/first.txt" "$WT/first-before-relaunch.txt"
rm "$STATE/live.turn-ended"
send_text "bash '$LAB/launch.sh'"
send_key Enter
accept_folder_trust
wait_file "$WT/first.txt"
wait_idle
[ "$(<"$WT/first.txt")" = AGY_FIRST_OK ] || fail 'relaunch instructions were not processed'
[ "$(<"$WT/cwd.txt")" = "$WT" ] || fail 'relaunch changed tool workspace'
[ -s "$STATE/live.agy-hook/$GEN.conversation" ] || fail 'replacement conversation was not bound'
[ -f "$STATE/live.turn-ended" ] || fail 'replacement completion notification missing'
send_text "$(fm_control_exit_command agy)"
send_key Enter
for _ in $(seq 1 60); do
  if ! identity 2>/dev/null | grep -q '^agy'; then break; fi
  sleep 0.5
done
! identity 2>/dev/null | grep -q '^agy' || fail 'replacement remained alive after /exit'
pass "AGY $VERSION deterministic relaunch preserves the workspace and completes with fresh hook custody"
