#!/usr/bin/env bash
# Credentialed Polytoken worker guard. Opt in with FM_POLYTOKEN_SIGNALS_LIVE=1.
# FM_POLYTOKEN_MODEL chooses a listed <provider>/<model> (default
# codex/gpt-6-luna) and FM_POLYTOKEN_EFFORT a level it lists (default low).
# Runs the real fm-spawn launch command in a private tmux server against the
# operator's own Polytoken config and auth; only worktree allocation and initial
# endpoint delivery use fixtures. Steering, interrupt, relaunch, and exit use
# the real Firstmate control plane. It spends a few short model turns.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_POLYTOKEN_SIGNALS_LIVE polytoken tmux jq
POLYTOKEN_BIN=$(command -v polytoken)
REAL_TMUX=$(command -v tmux)
VERSION=$(polytoken --version)
MODEL=${FM_POLYTOKEN_MODEL:-codex/gpt-6-luna}
EFFORT=${FM_POLYTOKEN_EFFORT:-low}
if ! polytoken models --format json 2>/dev/null | jq -e --arg m "$MODEL" 'any(.models[]; .name == $m)' >/dev/null; then
  printf 'skip: live: %s lists no model %s; set FM_POLYTOKEN_MODEL to a listed model\n' "$VERSION" "$MODEL"
  exit 0
fi
# The lab pane is not the invoking pane, so it must not report agent events as
# the invoking terminal's own (a captain's global hooks may forward them).
unset ORCA_PANE_KEY ORCA_TAB_ID ORCA_TERMINAL_HANDLE ORCA_AGENT_HOOK_PORT ORCA_AGENT_HOOK_TOKEN ORCA_AGENT_HOOK_ENDPOINT
# fm_test_run_spawn gives the spawn a throwaway HOME; keep Polytoken's own
# config and data where the operator's login lives for the model check.
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}" XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/pt.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
SOCKET="$LAB/tmux.sock"
case "$SOCKET" in "$PWD"/*) SOCKET=${SOCKET#"$PWD"/} ;; esac
reap_lab_daemons() {
  local pid
  for pid in $(ps -axo pid=,args= 2>/dev/null | awk -v lab="$LAB" 'index($0, "polytoken daemon") && index($0, lab) { print $1 }'); do
    kill -TERM "$pid" 2>/dev/null || true
  done
}
cleanup() {
  "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true
  reap_lab_daemons
  # The spawn leaves its commit-msg strip directory read-only.
  chmod -R u+w "$LAB" 2>/dev/null || true
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
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=bin/fm-polytoken-lib.sh
. "$ROOT/bin/fm-polytoken-lib.sh"
H="$LAB/home"
WT="$LAB/wt"
PROJ="$LAB/project"
ID=polytoken-live
fm_test_spawn_home "$H" polytoken
fm_git_worktree "$PROJ" "$WT" polytoken-live
git -C "$WT" config user.name 'Polytoken Live Guard'
git -C "$WT" config user.email polytoken-live-guard@example.invalid
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: compute 12345 plus 67890 using your shell tool and write only the result into answer.txt, then commit answer.txt with git using a commit message you write yourself. Also run '$ROOT/bin/fm-harness.sh' and write its output to harness.txt. Do no other work and do not delegate. Later read and acknowledge Firstmate's instruction inbox when the doorbell arrives."
mkdir -p "$LAB/bin"
fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
ln -s "$POLYTOKEN_BIN" "$fakebin/polytoken"
FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$PROJ" \
  --scout --harness polytoken --model "$MODEL" --effort "$EFFORT" > "$LAB/spawn.log" 2>&1 \
  || fail "fm-spawn failed: $(cat "$LAB/spawn.log")"
grep -qF -- "--model '$MODEL($EFFORT)'" "$LAB/launch.sh" || fail "the effort did not become the model variant: $(cat "$LAB/launch.sh")"
# Route every backend read/write to this guard's own socket only.
printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/bin/tmux"
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH" FM_HOME="$H"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
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
    [ "$(fm_busy_classify tmux "$TARGET" polytoken "$ID" "$H/state")" = 'idle polytoken-hook' ] && return 0
    sleep 0.5
  done
  fail 'stop did not produce semantic idle'
}
live_session() { fm_polytoken_live_sessions "$POLYTOKEN_BIN" "$WT" | awk 'NR == 1 { print $1 }'; }
wait_file "$WT/answer.txt"
wait_file "$WT/harness.txt"
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail 'launch brief did not execute'
[ "$(tr -d '[:space:]' < "$WT/harness.txt")" = polytoken ] || fail "tool ancestry did not identify Polytoken: $(cat "$WT/harness.txt")"
wait_idle
# The stop hook touches the notification only after its idle apply succeeds.
for _ in $(seq 1 20); do [ -f "$H/state/$ID.turn-ended" ] && break; sleep 0.25; done
[ -f "$H/state/$ID.turn-ended" ] || fail 'stop did not notify turn end'
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'real Polytoken TUI not classified alive'
git -C "$WT" log -1 --format=%s -- answer.txt | grep -q . || fail 'the worker did not commit answer.txt without an approval stop'
! git -C "$WT" status --porcelain | grep -q '\.polytoken' || fail "the worker overlay is visible to git: $(git -C "$WT" status --porcelain)"
pass "$VERSION: spawn brief, model variant, bypass overlay, ancestry identity, and native hooks"
cy=$("$REAL_TMUX" -S "$SOCKET" display-message -p -t "$TARGET" '#{cursor_y}')
[ "$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1\nrows=0' "$(capture)" "$cy")" = need-identity ] \
  || fail 'the idle composer is no longer the separated shape'
[ "$(fm_backend_composer_state tmux "$TARGET")" = empty ] || fail "the tmux identity probe did not prove the idle composer empty"
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime steering verification: compute 31 times 37 and write only the result to steer.txt. Acknowledge this instruction by moving its .msg file into handled/ as instructed by the doorbell. Do no other work.' > "$LAB/send.log" 2>&1 || fail "steer failed: $(cat "$LAB/send.log")"
wait_file "$WT/steer.txt"
wait_file "$H/state/$ID.inbox/handled/001.msg"
[ "$(tr -d '[:space:]' < "$WT/steer.txt")" = 1147 ] || fail 'wrong steering result'
wait_idle
pass "$VERSION: identity-proven empty composer; real fm-send doorbell read and acknowledged"
before=$(cat "$H/state/$ID.busy-state")
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/idle-interrupt.log" 2>&1 \
  || fail "idle interrupt failed: $(cat "$LAB/idle-interrupt.log")"
sleep 1.5
! screen_text | grep -q 'Enter rewind' || fail 'an idle interrupt opened the rewind picker'
[ "$(cat "$H/state/$ID.busy-state")" = "$before" ] || fail 'an idle interrupt rewrote the idle record'
sleep 4
# The hazard is real on this version: an Escape inside the first one's flash
# opens the picker. Exit must refuse to type into it and interrupt must close it
# (the interrupt's own Escape is the picker's close key; the portable suite
# covers the dismissal a mistimed press of its own would need).
picker=0
for _ in 1 2 3; do
  "$REAL_TMUX" -S "$SOCKET" send-keys -t "$TARGET" Escape
  sleep 0.5
  "$REAL_TMUX" -S "$SOCKET" send-keys -t "$TARGET" Escape
  sleep 1
  if screen_text | grep -q 'Enter rewind'; then picker=1; break; fi
  sleep 4
done
[ "$picker" = 1 ] || fail 'a second Escape inside the flash no longer opens the rewind picker; re-verify the hazard'
if "$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/picker-exit.log" 2>&1; then
  fail "exit proceeded with the rewind picker open: $(cat "$LAB/picker-exit.log")"
fi
screen_text | grep -q 'Enter rewind' || fail 'the refused exit closed or typed into the picker'
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/picker-interrupt.log" 2>&1 \
  || fail "interrupt could not close the rewind picker: $(cat "$LAB/picker-interrupt.log")"
sleep 1
! screen_text | grep -q 'Enter rewind' || fail 'interrupt left the rewind picker open'
# A rewind would drop the chosen prompt and return its text to the composer.
[ "$(fm_backend_composer_state tmux "$TARGET")" = empty ] || fail 'the picker rewound a prompt back into the composer'
pass "$VERSION: idle interrupt opens nothing; an open rewind picker blocks exit and is closed without rewinding"
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime interrupt verification: run sleep 90 in your shell tool, then wait for it to finish. Do not respond before it finishes.' > "$LAB/send.log" 2>&1 || fail 'could not steer interrupt probe'
seen_busy=0
for _ in $(seq 1 240); do
  # Interrupt inside the tool call: an Escape before any output cancels too,
  # but leaves no `Canceled after` row to observe. Earlier turns' tool rows
  # stay on screen, so the running sleep itself is the evidence.
  if [ "$(fm_busy_classify tmux "$TARGET" polytoken "$ID" "$H/state")" = 'busy polytoken-hook' ] \
    && screen_text | fm_busy_lines_match polytoken && pgrep -f 'sleep 90' >/dev/null 2>&1 \
    && screen_text | grep -q 'Waiting for result'; then seen_busy=1; break; fi
  sleep 0.5
done
[ "$seen_busy" = 1 ] || fail 'no semantic and rendered busy during the interrupt probe'
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/interrupt.log" 2>&1 || fail "interrupt failed: $(cat "$LAB/interrupt.log")"
grep -q 'cancel=unconfirmed' "$LAB/interrupt.log" || fail "busy interrupt claim changed: $(cat "$LAB/interrupt.log")"
[ "$(fm_busy_classify tmux "$TARGET" polytoken "$ID" "$H/state")" = 'unknown fm-interrupt' ] || fail 'interrupt did not conservatively invalidate state'
for _ in $(seq 1 60); do
  screen_text | grep -q 'Canceled after' && break
  sleep 0.5
done
screen_text | grep -q 'Canceled after' \
  || fail "one Escape did not cancel the running turn: $(screen_text | grep -v '^[[:space:]]*$' | tail -12)"
! pgrep -f 'sleep 90' >/dev/null 2>&1 || fail 'the cancelled tool call kept running'
pass "$VERSION: one Escape cancels the tool call, preserves the agent, and invalidates busy state"
old_session=$(live_session)
[ -n "$old_session" ] || fail 'no live session anchored at the worktree'
"$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Runtime relaunch verification: the earlier work is done; only write the word relaunched into relaunch.txt, then stop.' > "$LAB/relaunch.log" 2>&1 \
  || fail "relaunch failed: $(cat "$LAB/relaunch.log")"
wait_file "$WT/relaunch.txt"
wait_idle
new_session=$(live_session)
[ -n "$new_session" ] && [ "$new_session" != "$old_session" ] || fail "relaunch did not replace the session ($old_session -> $new_session)"
[ "$(fm_polytoken_live_sessions "$POLYTOKEN_BIN" "$WT" | wc -l | tr -d ' ')" = 1 ] || fail 'relaunch left two live sessions in one worktree'
pass "$VERSION: relaunch waits out the old daemon and re-arms one fresh session"
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "exit failed: $(cat "$LAB/exit.log")"
[ "$(fm_backend_agent_state tmux "$TARGET")" = dead ] || fail 'quit did not return to shell'
fm_polytoken_wait_no_live_session "$POLYTOKEN_BIN" "$WT" 20 || fail 'the daemon outlived /quit'
# Native resume is a vendor fact, not an fm-control verb.
"$REAL_TMUX" -S "$SOCKET" send-keys -t "$TARGET" -l "'$POLYTOKEN_BIN' continue '$new_session'"
"$REAL_TMUX" -S "$SOCKET" send-keys -t "$TARGET" Enter
for _ in $(seq 1 60); do
  [ "$(fm_backend_composer_state tmux "$TARGET")" = empty ] && break
  sleep 0.5
done
"$REAL_TMUX" -S "$SOCKET" send-keys -t "$TARGET" -l 'Runtime resume probe: write the product of 17 and 29 into resumed.txt, then stop.'
"$REAL_TMUX" -S "$SOCKET" send-keys -t "$TARGET" Enter
wait_file "$WT/resumed.txt"
[ "$(tr -d '[:space:]' < "$WT/resumed.txt")" = 493 ] || fail 'resume prompt not processed'
pass "$VERSION: /quit stops the daemon; polytoken continue resumes the session"
# A TUI that dies without /quit leaves its daemon anchored at the worktree.
tui=$(ps -axo pid=,args= | awk -v s="$new_session" 'index($0, "continue") && index($0, s) && !index($0, "awk") { print $1; exit }')
[ -n "$tui" ] || fail 'could not find the resumed TUI process'
kill -KILL "$tui"
sleep 2
[ "$(fm_backend_agent_state tmux "$TARGET")" = dead ] || fail 'the pane did not return to its shell'
[ "$(live_session)" = "$new_session" ] || fail 'the detached daemon did not survive its TUI'
if fm_polytoken_wait_no_live_session "$POLYTOKEN_BIN" "$WT" 0 2>"$LAB/guard.err"; then
  fail 'the detached daemon did not refuse another agent'
fi
grep -q "$new_session" "$LAB/guard.err" || fail 'the refusal did not name the session'
polytoken reap "$new_session" --force > "$LAB/reap.log" 2>&1 || fail "reap failed: $(cat "$LAB/reap.log")"
fm_polytoken_wait_no_live_session "$POLYTOKEN_BIN" "$WT" 20 || fail 'reap did not stop the daemon'
pass "$VERSION: a daemon that outlives its pane is detected and refuses another agent until reaped"
# The license gate on a data directory with no recorded acceptance is token-free.
mkdir -p "$LAB/fresh-data"
"$REAL_TMUX" -S "$SOCKET" new-window -t firstmate -n license -c "$WT" \
  "XDG_DATA_HOME='$LAB/fresh-data' POLYTOKEN_SKIP_UPDATE_CHECK=1 '$POLYTOKEN_BIN' new; exec /bin/bash --noprofile --norc"
license=
for _ in $(seq 1 40); do
  license=$("$REAL_TMUX" -S "$SOCKET" capture-pane -p -t firstmate:license)
  printf '%s' "$license" | grep -q 'An explicit choice is required' && break
  sleep 0.5
done
printf '%s' "$license" | fm_busy_launch_prompt_parked polytoken || fail "the license gate signature no longer matches: $license"
pass "$VERSION: the license gate matches the launch-prompt backstop"
