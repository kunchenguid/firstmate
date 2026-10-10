#!/usr/bin/env bash
# tests/fm-presentation-park-e2e.test.sh - real-herdr regression for
# bin/fm-presentation-park.sh and its three callers: bin/fm-control.sh exit,
# bin/fm-watch.sh's stale sweep, and bin/fm-teardown.sh's unlanded-work refusal.
#
# The bug: a crewmate whose agent exited kept a bare-shell Herdr workspace
# forever unless a teardown ran and succeeded. These cases pin the verdicts on a
# real Herdr pane:
#   - exited agent, landed work (clean, pushed, HEAD in main) -> pane closed
#   - exited agent, unmerged, unlanded or uncommitted work    -> "parked: <id>"
#                                                  tab, pane, ids, labels kept
#   - teardown refusal                                -> stub, never a close
#   - live agent, or a status that is not done/paused -> untouched
#   - relaunch restores the label, resumes a stub after a later merge, and
#     refuses a slot another task claimed
#   - an unrelated pane in the same session is never touched
#
# The agent is a symlink named like a harness (the construction
# tests/fm-control-herdr-smoke.test.sh documents); "exited" is that process
# being killed under a nested shell, which is the stale-registration shape a
# real crew leaves. Always runs on a private named lab session.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-park-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
WATCH_PID=
cleanup_all() {
  [ -z "$WATCH_PID" ] || kill "$WATCH_PID" 2>/dev/null || true
  if [ -n "$SCRATCH" ]; then
    chmod -R u+w "$SCRATCH" 2>/dev/null || true
    rm -rf "$SCRATCH"
  fi
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-park.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd -P)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"

# A project with a real remote, so "nothing off a remote" is reachable.
ORIGIN="$SCRATCH/origin.git"
PROJ="$SCRATCH/proj"
git init -q --bare "$ORIGIN"
git init -q "$PROJ"
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" remote add origin "$ORIGIN"
git -C "$PROJ" push -q origin HEAD:refs/heads/main
git -C "$PROJ" fetch -q origin
git -C "$PROJ" remote set-head origin main >/dev/null
# Task worktrees live in a Treehouse-shaped pool (<pool>/<slot>/wt plus a
# state file), so the slot-reservation rule applies to them.
mkdir -p "$SCRATCH/slots"
printf '{"worktrees":[]}\n' > "$SCRATCH/slots/treehouse-state.json"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

AGENT_BIN="$SCRATCH/agentbin"
mkdir -p "$AGENT_BIN"
ln -s "$(command -v sleep)" "$AGENT_BIN/claude"
printf -v AGENT_Q '%q' "$AGENT_BIN/claude"

R() { herdr "$@" --session "$SESSION"; }
fm_backend_herdr_server_ensure "$SESSION" || fail "could not start the lab Herdr server"
PARENT_WS=$(R workspace create --cwd "$SCRATCH" --label firstmate --no-focus | jq -r '.result.workspace.workspace_id')
[ -n "$PARENT_WS" ] || fail "could not create the parent workspace"

# new_task <id>: a projected workspace (journal, "└ <id> · p:<token>" label,
# one fm-<id> tab) whose pane runs a nested shell in its own pool slot
# <scratch>/slots/<id>/wt, plus a task record. Sets TASK_WS TASK_TAB TASK_PANE
# TASK_WT TASK_WS_LABEL.
new_task() {
  local id=$1 out token journal
  TASK_WT="$SCRATCH/slots/$id/wt"
  mkdir -p "$SCRATCH/slots/$id"
  git -C "$PROJ" worktree add -q -b "fm/$id" "$TASK_WT" HEAD
  token=$(fm_backend_herdr_projection_journal_create "$HOME_DIR/state" "$id") || fail "journal create failed for $id"
  journal=$(fm_backend_herdr_projection_journal_path "$HOME_DIR/state" "$id")
  TASK_WS_LABEL=$(fm_backend_herdr_projection_workspace_label "$id" "$token")
  out=$(R workspace create --cwd "$TASK_WT" --label "$TASK_WS_LABEL" --no-focus) \
    || fail "workspace create failed for $id"
  TASK_WS=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')
  TASK_TAB=$(printf '%s' "$out" | jq -r '.result.tab.tab_id')
  TASK_PANE=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')
  R tab rename "$TASK_TAB" "fm-$id" >/dev/null || fail "tab rename failed for $id"
  fm_backend_herdr_projection_journal_bind "$journal" "$id" "$HOME_DIR" "$SESSION" "$TASK_WS" \
    "$TASK_TAB" "$TASK_PANE" "$PARENT_WS" firstmate "$TASK_WS_LABEL" "fm-$id" \
    || fail "journal bind failed for $id"
  {
    echo "window=$SESSION:$TASK_PANE"
    echo "endpoint_task_id=$id"
    echo "worktree=$TASK_WT"
    echo "project=$PROJ"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "backend=herdr"
    echo "herdr_session=$SESSION"
    echo "herdr_workspace_id=$TASK_WS"
    echo "herdr_tab_id=$TASK_TAB"
    echo "herdr_pane_id=$TASK_PANE"
  } > "$HOME_DIR/state/$id.meta"
  mkdir -p "$HOME_DIR/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nlab\n\n## Firstmate spec\nlab\n' > "$HOME_DIR/data/$id/brief.md"
  # The crew shape: the agent runs under a nested shell below the pane's shell.
  fm_backend_herdr_send_text_line "$SESSION:$TASK_PANE" "exec /bin/sh" || fail "nested shell for $id"
  fm_backend_herdr_send_text_line "$SESSION:$TASK_PANE" "/bin/sh" || fail "nested shell for $id"
}

# open_pr <worktree> <id>: a pushed commit that is not in main, the shape of a
# task whose PR is open.
open_pr() {
  printf '%s\n' "$2" > "$1/$2.txt"
  git -C "$1" add "$2.txt"
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -qm "$2"
  git -C "$1" push -q origin "fm/$2"
}

wait_process_state() {  # <pane> <expected>
  local i=0
  while [ "$i" -lt 60 ]; do
    [ "$(fm_backend_herdr_pane_process_state "$SESSION" "$1")" != "$2" ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

start_agent() {  # <pane>
  fm_backend_herdr_send_text_line "$SESSION:$1" "$AGENT_Q 900" || fail "could not start the agent process"
  wait_process_state "$1" agent || fail "agent process did not start in $1"
  R pane report-agent "$1" --source fm-park-test --agent fm-park-test-agent --state idle >/dev/null 2>&1 \
    || fail "could not register the agent on $1"
  [ "$(fm_backend_agent_state herdr "$SESSION:$1")" = alive ] || fail "agent on $1 is not alive"
}

exit_agent() {  # <pane>
  local pid
  pid=$(R pane process-info --pane "$1" | jq -r '.result.process_info.foreground_processes[0].pid // empty')
  [ -n "$pid" ] || fail "no agent pid on $1"
  kill "$pid" || fail "could not stop the agent on $1"
  wait_process_state "$1" shell || fail "pane $1 did not return to a shell"
  [ "$(fm_backend_agent_state herdr "$SESSION:$1")" = dead ] || fail "exited agent on $1 does not read dead"
}

park() {  # <id> <trigger>
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" "$ROOT/bin/fm-presentation-park.sh" "$1" --trigger "$2" 2>&1
}

tab_label() { R tab get "$1" 2>/dev/null | jq -r '.result.tab.label // empty'; }
pane_present() { [ "$(fm_backend_herdr_pane_presence_state "$SESSION" "$1")" = present ]; }
ws_label() { R workspace list | jq -r --arg w "$1" '.result.workspaces[] | select(.workspace_id == $w) | .label'; }

# An unrelated pane in the same session that nothing may touch.
UNRELATED=$(R workspace create --cwd "$SCRATCH" --label unrelated --no-focus | jq -r '.result.root_pane.pane_id')
[ -n "$UNRELATED" ] || fail "could not create the unrelated pane"

# --- live agent: never eligible ------------------------------------------------
new_task live
LIVE_PANE=$TASK_PANE LIVE_TAB=$TASK_TAB
start_agent "$LIVE_PANE"
echo "done [at=1]: finished" > "$HOME_DIR/state/live.status"
for trigger in exit sweep teardown-refused; do
  OUT=$(park live "$trigger") || fail "park on a live agent should not fail ($trigger): $OUT"
  case "$OUT" in
    "presentation=unchanged task=live reason=agent-live") : ;;
    *) fail "a live agent must be left alone on trigger $trigger, got: $OUT" ;;
  esac
done
pane_present "$LIVE_PANE" && [ "$(tab_label "$LIVE_TAB")" = fm-live ] \
  || fail "a live agent's pane or label changed"
pass "real herdr: a live agent's endpoint is never parked or closed"

# --- exited agent with unlanded and uncommitted work: stub ---------------------
new_task dirty
DIRTY_PANE=$TASK_PANE DIRTY_TAB=$TASK_TAB DIRTY_WS=$TASK_WS DIRTY_WT=$TASK_WT
DIRTY_WS_LABEL=$(ws_label "$DIRTY_WS")
start_agent "$DIRTY_PANE"
printf 'wip\n' > "$DIRTY_WT/wip.txt"
exit_agent "$DIRTY_PANE"
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
  "$ROOT/bin/fm-control.sh" dirty exit 2>&1) || fail "exit on an exited agent should succeed: $OUT"
case "$OUT" in
  "already-stopped dirty "*"presentation=parked") : ;;
  *) fail "exit with uncommitted work should park the presentation, got: $OUT" ;;
esac
pane_present "$DIRTY_PANE" || fail "the parked stub lost its pane"
[ "$(tab_label "$DIRTY_TAB")" = "parked: dirty" ] || fail "the stub tab is not labelled parked: dirty"
DIRTY_TOKEN=$(printf '%s' "$DIRTY_WS_LABEL" | sed 's/.* p://')
[ "$(ws_label "$DIRTY_WS")" = "└ parked: dirty · p:$DIRTY_TOKEN" ] \
  || fail "the projected workspace does not read parked with its exact token: $(ws_label "$DIRTY_WS")"
fm_backend_herdr_projection_endpoint_matches_journal "$SESSION" "$DIRTY_WS" \
  "$(fm_backend_herdr_projection_journal_path "$HOME_DIR/state" dirty)" dirty \
  || fail "the parked workspace no longer correlates with its journal token"
[ -f "$DIRTY_WT/wip.txt" ] && [ -f "$HOME_DIR/state/dirty.meta" ] || fail "parking lost source or the task record"
OUT=$(park dirty exit) || fail "a repeated park should succeed: $OUT"
[ "$OUT" = "presentation=parked task=dirty" ] || fail "a repeated park should be the same stub, got: $OUT"
pass "real herdr: exit with uncommitted work keeps everything and shows a parked stub with its token, idempotently"

# --- the label comes back on relaunch ----------------------------------------
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n: > %q\n' "$SCRATCH/codex-launched" > "$FAKEBIN/codex"
chmod +x "$FAKEBIN/codex"
printf -v FAKEBIN_Q '%q' "$FAKEBIN"
fm_backend_herdr_send_text_line "$SESSION:$DIRTY_PANE" "export PATH=$FAKEBIN_Q:\$PATH" || fail "fake harness PATH"
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" dirty --relaunch --harness codex 2>&1) || fail "relaunch of a parked stub failed: $OUT"
[ "$(tab_label "$DIRTY_TAB")" = fm-dirty ] || fail "relaunch did not restore the ordinary tab label"
[ "$(ws_label "$DIRTY_WS")" = "$DIRTY_WS_LABEL" ] || fail "relaunch did not restore the projected workspace label"
[ "$(sed -n 's/^window=//p' "$HOME_DIR/state/dirty.meta" | tail -1)" = "$SESSION:$DIRTY_PANE" ] \
  || fail "relaunch of a parked stub did not reuse its endpoint"
pass "real herdr: relaunching a parked stub reuses the endpoint and restores both labels"

# --- teardown refusal: stub only ----------------------------------------------
new_task refused
REF_PANE=$TASK_PANE REF_TAB=$TASK_TAB REF_WT=$TASK_WT
start_agent "$REF_PANE"
printf 'feature\n' > "$REF_WT/feature.txt"
git -C "$REF_WT" add feature.txt
git -C "$REF_WT" -c user.name=t -c user.email=t@example.invalid commit -qm unlanded
exit_agent "$REF_PANE"
if OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-teardown.sh" refused 2>&1); then
  fail "teardown of unlanded work must refuse: $OUT"
fi
case "$OUT" in
  *"REFUSED"*"presentation=parked task=refused"*) : ;;
  *) fail "an unlanded-work refusal should park the presentation, got: $OUT" ;;
esac
pane_present "$REF_PANE" && [ "$(tab_label "$REF_TAB")" = "parked: refused" ] \
  || fail "the refused teardown did not leave exactly the parked stub"
if ! { [ -f "$REF_WT/feature.txt" ] && [ -f "$HOME_DIR/state/refused.meta" ] \
  && git -C "$REF_WT" log --oneline -1 | grep -q unlanded; }; then
  fail "the refused teardown lost source, commit, or record"
fi
git -C "$REF_WT" push -q origin "fm/refused"
OUT=$(park refused teardown-refused) || fail "park should succeed: $OUT"
[ "$OUT" = "presentation=parked task=refused" ] || fail "teardown-refused must never close, got: $OUT"
pass "real herdr: a refused teardown keeps source and record and shows only the parked stub"

# --- sweep: status gate, then a close of landed work ---------------------------
new_task swept
SW_PANE=$TASK_PANE SW_WS=$TASK_WS SW_WT=$TASK_WT
start_agent "$SW_PANE"
exit_agent "$SW_PANE"
echo "working [at=1]: busy" > "$HOME_DIR/state/swept.status"
OUT=$(park swept sweep)
[ "$OUT" = "presentation=unchanged task=swept reason=status-not-done-or-paused" ] \
  || fail "a working status must not be swept, got: $OUT"
: > "$HOME_DIR/state/swept.status"
OUT=$(park swept sweep)
[ "$OUT" = "presentation=unchanged task=swept reason=status-not-done-or-paused" ] \
  || fail "an empty status must not be swept, got: $OUT"
pane_present "$SW_PANE" || fail "an ineligible sweep touched the pane"
echo "paused [at=1]: parked by Main" > "$HOME_DIR/state/swept.status"

# The real watcher sweeps it once its pane reads stale. A cycle that wakes for
# the status lines ends; acknowledge it and start the next, as a supervisor does.
ack_stopped_cycle() {
  local err sequence generation
  err="$SCRATCH/drain.err"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 0
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1
}
for _ in 1 2 3 4 5 6; do
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" HERDR_SESSION="$SESSION" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$ROOT/bin/fm-watch.sh" >> "$SCRATCH/watch.out" 2>&1 &
  WATCH_PID=$!
  for _ in $(seq 1 40); do
    pane_present "$SW_PANE" || break
    kill -0 "$WATCH_PID" 2>/dev/null || break
    sleep 0.5
  done
  kill "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=
  pane_present "$SW_PANE" || break
  ack_stopped_cycle || fail "could not acknowledge a watcher cycle"
done
pane_present "$SW_PANE" && fail "the watcher did not sweep a paused, exited, landed presentation: $(tail -5 "$SCRATCH/watch.out")"
[ -z "$(ws_label "$SW_WS")" ] || fail "the swept projected workspace is still listed"
[ -f "$HOME_DIR/state/swept.meta" ] && [ -d "$SW_WT" ] || fail "the sweep removed the record or worktree"
OUT=$(park swept sweep)
[ "$OUT" = "presentation=gone task=swept" ] || fail "a repeated sweep should report gone, got: $OUT"
pass "real herdr: the watcher closes a paused exited presentation whose work is landed, idempotently"

# --- an open PR is still resumable: stub, kept across a later merge -----------
new_task openpr
OP_PANE=$TASK_PANE OP_TAB=$TASK_TAB OP_WS=$TASK_WS OP_WT=$TASK_WT
OP_WS_LABEL=$(ws_label "$OP_WS")
open_pr "$OP_WT" openpr
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
  "$ROOT/bin/fm-control.sh" openpr exit 2>&1) || fail "exit should succeed: $OUT"
case "$OUT" in
  "already-stopped openpr "*"presentation=parked") : ;;
  *) fail "exit with a pushed but unmerged HEAD should park the presentation, got: $OUT" ;;
esac
echo "paused [at=1]: parked by Main" > "$HOME_DIR/state/openpr.status"
OUT=$(park openpr sweep)
[ "$OUT" = "presentation=parked task=openpr" ] || fail "a sweep of unmerged work must keep the stub, got: $OUT"
pane_present "$OP_PANE" && [ "$(tab_label "$OP_TAB")" = "parked: openpr" ] || fail "the open-PR task lost its stub"
# The branch lands later; the stub's shell still holds the endpoint, so the
# task resumes in place.
git -C "$PROJ" push -q origin "fm/openpr:main"
git -C "$PROJ" fetch -q origin
git -C "$OP_WT" merge-base --is-ancestor HEAD origin/main || fail "the lab merge did not land the open-PR head"
fm_backend_herdr_send_text_line "$SESSION:$OP_PANE" "export PATH=$FAKEBIN_Q:\$PATH" || fail "fake harness PATH"
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" openpr --relaunch --harness codex 2>&1) || fail "relaunch after a later merge failed: $OUT"
[ "$(sed -n 's/^window=//p' "$HOME_DIR/state/openpr.meta" | tail -1)" = "$SESSION:$OP_PANE" ] \
  || fail "relaunch after a later merge did not reuse the parked endpoint"
[ "$(ws_label "$OP_WS")" = "$OP_WS_LABEL" ] || fail "relaunch after a later merge did not restore the workspace label"
pass "real herdr: unmerged work stays one parked stub and resumes in place after its branch later lands"

# --- exit of landed work closes; relaunch refuses a reassigned slot ------------
new_task clean
CL_PANE=$TASK_PANE
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
  "$ROOT/bin/fm-control.sh" clean exit 2>&1) || fail "exit should succeed: $OUT"
case "$OUT" in
  "already-stopped clean "*"presentation=closed") : ;;
  *) fail "exit of landed work should close the presentation, got: $OUT" ;;
esac
pane_present "$CL_PANE" && fail "the closed presentation's pane is still present"
printf 'task=someone-else\nhome=%s\n' "$HOME_DIR" > "$SCRATCH/slots/clean/.fm-slot-owner"
if OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" clean --relaunch --harness codex 2>&1); then
  fail "relaunch into a slot another task claimed must refuse: $OUT"
fi
case "$OUT" in
  *"now claimed by task someone-else"*) : ;;
  *) fail "the reassigned-slot refusal should name the claimant, got: $OUT" ;;
esac
pass "real herdr: exit of landed work closes the presentation, and relaunch refuses a reassigned slot"

pane_present "$UNRELATED" && [ "$(ws_label "$(R pane get "$UNRELATED" | jq -r .result.pane.workspace_id)")" = unrelated ] \
  || fail "an unrelated pane was touched"
pane_present "$LIVE_PANE" || fail "the live agent's pane did not survive the run"
pass "real herdr: the unrelated pane and the live agent survived every park"
