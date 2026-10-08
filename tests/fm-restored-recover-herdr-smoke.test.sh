#!/usr/bin/env bash
# tests/fm-restored-recover-herdr-smoke.test.sh - real-herdr regression for the
# restored-worker sweep (bin/fm-restored-recover.sh) on a Herdr worker whose
# agent runs outside its recorded worktree with no startup gate on screen.
#
# Only a Herdr relaunch moves a drifted endpoint back into its worktree, so this
# is the one path where drift alone stops an agent. It must never stop one that
# is mid-turn, and an agent whose busy state never settles must be reported
# rather than passed over. The agent is a real agent-named foreground process
# (fm_agent_standin) registered through herdr's own `pane report-agent`, as in
# tests/fm-control-herdr-smoke.test.sh, so the busy verdict is read from the
# real binary. Skips cleanly when herdr or jq is missing.
#
# Herdr registers an agent only in a state its classifier reads as busy or
# idle, so an alive agent reads busy-`unknown` only while its status moves
# between the sweep's liveness read and its busy read. That window is held open
# by a `herdr` shim on the sweep's PATH: while $SCRATCH/status-unknown exists,
# every `agent get` after the sweep's first one (its liveness read) reports the
# status `unknown`; every other call is the real binary's.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

STANDIN_DIR=$(fm_test_tmproot fm-restored-herdr-standin) || fail "could not create the stand-in directory"
STANDIN_BIN=$(fm_agent_standin "$STANDIN_DIR") || {
  echo "skip: no long-running stand-in binary survives a rename (multicall coreutils, no C compiler)"
  exit 0
}

SESSION="fm-lab-restored-recover-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
LAB_PREPARED=0
cleanup_all() {
  local status=$? cleanup_status=0
  trap - EXIT
  [ -z "$SCRATCH" ] || fm_test_remove_tree "$SCRATCH" || cleanup_status=1
  if [ "$LAB_PREPARED" = 1 ]; then
    herdr_safe_stop_and_delete "$SESSION" || {
      echo "not ok - could not tear down Herdr lab session: $SESSION" >&2
      cleanup_status=1
    }
  fi
  fm_test_cleanup
  [ "$cleanup_status" = 0 ] || status=1
  exit "$status"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"
LAB_PREPARED=1

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-restored-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd -P)
HOME_DIR="$SCRATCH/home"
ID=hdrift
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$ID"
printf '# Task\n## Captain'"'"'s intent\nRecover %s.\n\n## Firstmate spec\nContinue.\n' "$ID" \
  > "$HOME_DIR/data/$ID/brief.md"
fm_git_worktree "$PROJ" "$WT" "task-$ID" || fail "could not build the task worktree"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-$ID" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<IDS
$TASK_IDS
IDS
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"
TARGET="$SESSION:$PANE_ID"

fm_write_meta "$HOME_DIR/state/$ID.meta" \
  "window=$TARGET" "endpoint_task_id=$ID" "worktree=$WT" "project=$PROJ" \
  harness=claude kind=ship mode=no-mistakes yolo=off "tasktmp=$SCRATCH/tmp" \
  model=default effort=default backend=herdr "herdr_session=$SESSION" \
  "herdr_workspace_id=$WORKSPACE_ID" "herdr_tab_id=$TAB_ID" "herdr_pane_id=$PANE_ID"

# The agent is started from the primary checkout, which is where a restored
# Herdr pane resumes it. The pane's shell finds an inert `claude` first on its
# PATH, so a relaunch never starts the host's real Claude: it records its
# launch and runs the stand-in under the harness's name.
AGENT_BIN="$SCRATCH/agentbin"
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$AGENT_BIN" "$FAKEBIN"
ln -s "$STANDIN_BIN" "$AGENT_BIN/claude"
cat > "$FAKEBIN/claude" <<SH
#!/bin/sh
pwd -P > "$SCRATCH/claude-launched"
exec "$AGENT_BIN/claude" 900
SH
chmod +x "$FAKEBIN/claude"
printf -v AGENT_Q '%q' "$AGENT_BIN/claude"
printf -v FAKEBIN_Q '%q' "$FAKEBIN"
printf -v PROJ_Q '%q' "$PROJ"
fm_backend_herdr_send_text_line "$TARGET" "export PATH=$FAKEBIN_Q:\$PATH" \
  || fail "could not put the inert claude on the pane's PATH"
printf -v RESOLVED_Q '%q' "$SCRATCH/claude-resolved"
fm_backend_herdr_send_text_line "$TARGET" "command -v claude > $RESOLVED_Q" \
  || fail "could not ask the pane's shell which claude it runs"
i=0
while [ ! -s "$SCRATCH/claude-resolved" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ "$(cat "$SCRATCH/claude-resolved" 2>/dev/null)" = "$FAKEBIN/claude" ] \
  || fail "the pane's shell does not run the inert claude, so a relaunch could start the real one: $(cat "$SCRATCH/claude-resolved" 2>/dev/null)"
fm_backend_herdr_send_text_line "$TARGET" "cd -- $PROJ_Q && $AGENT_Q 900" \
  || fail "could not start the agent-named process in the primary checkout"
i=0
while [ "$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")" != agent ] && [ "$i" -lt 50 ]; do
  sleep 0.1
  i=$((i + 1))
done
[ "$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")" = agent ] \
  || fail "the agent-named process never read as the pane's agent"

report() {  # <state>
  herdr pane report-agent "$PANE_ID" --source fm-restored-recover-test --agent claude \
    --state "$1" --session "$SESSION" >/dev/null 2>&1 \
    || fail "could not report agent state $1"
}

REAL_HERDR=$(command -v herdr)
mkdir -p "$SCRATCH/shim"
cat > "$SCRATCH/shim/herdr" <<SH
#!/usr/bin/env bash
if [ "\${1:-} \${2:-}" = "agent get" ] && [ -e "$SCRATCH/status-unknown" ]; then
  if [ -e "$SCRATCH/liveness-read" ]; then
    "$REAL_HERDR" "\$@" | jq -c 'if .result.agent then .result.agent.agent_status = "unknown" else . end'
    exit "\${PIPESTATUS[0]}"
  fi
  : > "$SCRATCH/liveness-read"
fi
exec "$REAL_HERDR" "\$@"
SH
chmod +x "$SCRATCH/shim/herdr"

run_recover() {
  rm -f "$SCRATCH/liveness-read"
  env FM_HOME="$HOME_DIR" PATH="$SCRATCH/shim:$PATH" \
    FM_RESTORED_RECOVER_RECHECK=0.2 FM_RESTORED_RECOVER_SETTLE=2 FM_RESTORED_RECOVER_SETTLE_POLL=0.3 \
    FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=2 FM_CONTROL_LAUNCH_WAIT=0.5 \
    "$ROOT/bin/fm-restored-recover.sh" 2>&1
}

PROJ_REAL=$(cd "$PROJ" && pwd -P)
for verdict in busy unknown; do
  case "$verdict" in
    busy) report working ;;
    unknown) report idle; : > "$SCRATCH/status-unknown"; : > "$SCRATCH/liveness-read" ;;
  esac
  [ "$(fm_backend_agent_state herdr "$TARGET")" = alive ] \
    || fail "the registered agent does not read alive, so the $verdict case proves nothing"
  [ "$(PATH="$SCRATCH/shim:$PATH" fm_backend_busy_state herdr "$TARGET")" = "$verdict" ] \
    || fail "the agent's busy state does not read $verdict, so that case proves nothing"
  OUT=$(run_recover) || fail "the sweep exited nonzero: $OUT"
  [ "$OUT" = "RESTORED_WORKER: $ID: was running in $PROJ_REAL instead of its recorded worktree; not relaunched: its agent read $verdict, not idle" ] \
    || fail "a drifted Herdr agent that reads $verdict should be reported and not relaunched, got:
$OUT"
  [ ! -e "$HOME_DIR/state/$ID.control-relaunch" ] || fail "the sweep started a relaunch of a $verdict agent"
  [ "$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")" = agent ] \
    || fail "the sweep stopped a $verdict agent"
done
pass "real herdr: a drifted agent that is busy, or whose busy state never settles, is reported and not relaunched"

# A busy state that reads unknown at first is re-read inside the settle window,
# so an agent that turns idle there is relaunched rather than reported.
( sleep 0.8; rm -f "$SCRATCH/status-unknown" ) &
SETTLER=$!
OUT=$(run_recover) || fail "the sweep exited nonzero: $OUT"
wait "$SETTLER"
[ -e "$HOME_DIR/state/$ID.control-relaunch" ] \
  || fail "a drifted agent that settled idle was not relaunched, got:
$OUT"
# The stand-in draws no composer, so the relaunch may refuse to type the exit
# command and launch nothing; whatever it does launch must be the inert claude,
# in the recorded worktree.
case "$OUT" in
  "BOOTSTRAP_INFO: worker $ID was running in $PROJ_REAL instead of its recorded worktree; relaunched"*)
    i=0
    while [ ! -e "$SCRATCH/claude-launched" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    ;;
  "RESTORED_WORKER: $ID: was running in $PROJ_REAL instead of its recorded worktree; relaunch failed: "*) : ;;
  *) fail "an agent that settled idle should have been relaunched, got: $OUT" ;;
esac
[ ! -e "$SCRATCH/claude-launched" ] || [ "$(cat "$SCRATCH/claude-launched")" = "$(cd "$WT" && pwd -P)" ] \
  || fail "the relaunch started the inert claude outside the recorded worktree: $(cat "$SCRATCH/claude-launched")"
case "$OUT" in
  BOOTSTRAP_INFO:*) [ -e "$SCRATCH/claude-launched" ] || fail "the relaunch reported success but did not start the inert claude: $OUT" ;;
esac
pass "real herdr: a busy state that settles idle inside the window leads to a relaunch"
