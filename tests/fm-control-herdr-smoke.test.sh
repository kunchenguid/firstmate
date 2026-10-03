#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from herdr's own agent registry.
#
# No real harness is launched. herdr's `pane report-agent` is the same registry
# the adapter reads, and a symlink named like a harness is the same process
# identity the adapter proves through `pane process-info`, so registering an
# agent over a real agent-named process, over a plain shell, and not at all
# exercises exactly the classification the control plane gates on - including
# the registration Herdr keeps after the agent process is gone (issue #4115).
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing. The closing case also moves a live flat tab
# with a stale journal into an ordered child through `reproject`, proving the
# agent, its process, and focus survive the move.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-control-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -z "$SCRATCH" ] || chmod u+w "$SCRATCH/home/state/hsmoke.git-hooks" 2>/dev/null || true
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_provision "$SESSION" || fail "could not provision isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
cat > "$HOME_DIR/data/hsmoke/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Herdr lifecycle control safely.

## Firstmate spec
Keep the isolated endpoint and worktree intact.
EOF

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"
PROJ_REAL=$(cd "$PROJ" && pwd -P)
WT_REAL=$(cd "$WT" && pwd -P)

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

# --- the recovery-grade read, against the real binary ------------------------
#
# The classification that decides whether a task can be recovered at all is read
# out of what herdr actually answers, so a stub can only confirm the assumption
# already written into the stub. Its logic is pinned portably in
# tests/fm-backend-herdr.test.sh; this is the check that notices when the real
# client stops answering the way that logic expects, and it names the version so
# a release change is attributed rather than mysterious.
HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
version_fail() {  # <message>
  fail "$1 [herdr $HERDR_VERSION]"
}

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] \
  || version_fail "a real, present, agent-free pane reads '$STATE' rather than 'dead'; every relaunch would be refused"

# `status --json` is the second signal, and the only one that answers for a
# session whose operational calls cannot be reached at all. A release that drops
# or renames `.server.running` would silently make every gone endpoint
# unrecoverable again, so it is asserted by name on both a live and an absent
# session.
[ "$(fm_backend_herdr_server_running_state "$SESSION")" = running ] \
  || version_fail "this run's own live lab session does not report .server.running=true through status --json"
[ "$(fm_backend_herdr_server_running_state "fm-lab-never-started-$$")" = stopped ] \
  || version_fail "a session with no server does not report .server.running=false, so authoritative absence can no longer be told from an unreadable read"

# Issue #4091's exact stranding shape: an endpoint recorded in a session whose
# server is not running used to read `unreadable` and block recovery.
[ "$(fm_backend_agent_state herdr "fm-lab-never-started-$$:w1:p2")" = missing ] \
  || version_fail "an endpoint in a session with no running server is not classified as recoverable"

# And the safety direction: an uninterpretable read must never license recovery.
[ "$(fm_backend_agent_state herdr "no-separator-here")" = unreadable ] \
  || version_fail "a malformed endpoint target does not stay unreadable"
pass "real herdr $HERDR_VERSION: a gone session reads recoverable while a live pane and a malformed target do not"

FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
: > "$SCRATCH/codex-launched"
EOF
chmod +x "$FAKEBIN/codex"
printf -v FAKEBIN_Q '%q' "$FAKEBIN"
printf -v PROJ_Q '%q' "$PROJ"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "export PATH=$FAKEBIN_Q:\$PATH" \
  || fail "could not put the inert test harness on the pane PATH"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "cd -- $PROJ_Q" \
  || fail "could not move the agent-free pane out of its recorded worktree"
for _ in $(seq 1 20); do
  [ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" != "$PROJ_REAL" ] || break
  sleep 0.1
done
[ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" = "$PROJ_REAL" ] \
  || fail "the real Herdr pane did not drift out of its recorded worktree"

OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" hsmoke --relaunch --harness codex) \
  || fail "a drifted, agent-free Herdr pane should be re-homed and relaunched: $OUT"
for _ in $(seq 1 20); do
  [ ! -e "$SCRATCH/codex-launched" ] || break
  sleep 0.1
done
[ -e "$SCRATCH/codex-launched" ] || fail "the replacement harness was not launched"
[ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" = "$WT_REAL" ] \
  || fail "the relaunched Herdr shell did not end up in its recorded worktree"
[ "$(sed -n 's/^window=//p' "$HOME_DIR/state/hsmoke.meta" | tail -1)" = "$SESSION:$PANE_ID" ] \
  || fail "the Herdr relaunch replaced its endpoint instead of reusing it"
herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the Herdr relaunch removed the endpoint it was required to reuse"
awk -F= '$1 == "harness" {$0="harness=claude"} {print}' "$HOME_DIR/state/hsmoke.meta" \
  > "$HOME_DIR/state/hsmoke.meta.tmp"
mv "$HOME_DIR/state/hsmoke.meta.tmp" "$HOME_DIR/state/hsmoke.meta"
pass "real herdr: a drifted agent-free shell returns to its worktree and reuses the same endpoint"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- a registered agent WITH a live process: classification flips ------------
#
# A registration alone no longer proves an agent (issue #4115): the adapter
# verifies the pane's processes through the real `pane process-info` view. So
# the registered agent is backed by a real agent-named foreground process - a
# symlink to a long-running system binary named `claude`, the same construction
# tests/fm-tmux-agent-liveness.test.sh uses (a copied platform binary fails code
# signing on macOS arm64; the symlink name is what the kernel records as argv[0]).
AGENT_BIN="$SCRATCH/agentbin"
mkdir -p "$AGENT_BIN"
PYTHON_BIN=$(command -v python3) || fail "python3 not found"
ln -s "$PYTHON_BIN" "$AGENT_BIN/claude"
printf -v AGENT_CMD '%q -c %q' "$AGENT_BIN/claude" 'import time; time.sleep(900)'

wait_process_state() {  # <expected> <tries>
  local expected=$1 tries=$2 i=0
  while [ "$i" -lt "$tries" ]; do
    [ "$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")" != "$expected" ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

start_agent_process() {
  fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "$AGENT_CMD" \
    || fail "could not start the agent-named foreground process in the task pane"
  wait_process_state agent 50 \
    || version_fail "a real agent-named foreground process reads '$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")' rather than 'agent' through pane process-info: $(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>&1 | tr -d '\n'); pane: $(fm_backend_herdr_capture "$SESSION:$PANE_ID" 12 2>&1 | tr -d '\n')"
}

start_agent_process
herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a live agent on the task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "herdr should classify a registered agent with a live process as alive, got '$STATE'"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a registered agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the agent survived it"

herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# --- the stale registration (issue #4115): the agent process is gone, the ---
# --- record is not, and recovery must proceed anyway ------------------------
#
# Stopping the agent-named process leaves the pane a plain shell while Herdr
# keeps the registration, which is exactly the shape a Pi crew leaves behind
# when it exits under a nested shell. Before the fix this read `alive` forever:
# exit waited out its timeout and refused, and relaunch was refused for good.
AGENT_PID=$(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null \
  | jq -r '.result.process_info.foreground_processes[0].pid // empty')
[ -n "$AGENT_PID" ] || fail "could not read the agent-named process pid from pane process-info"
kill "$AGENT_PID" 2>/dev/null || fail "could not stop the agent-named process"
wait_process_state shell 50 \
  || version_fail "after the agent process exited the pane reads '$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")' rather than 'shell' through pane process-info. Raw process-info: $(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>&1 | tr -d '\n')"

# The divergence that makes this case non-vacuous: Herdr's own registry still
# reports the agent, and only the process-level view disagrees.
REGISTERED=$(herdr agent get "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
[ -n "$REGISTERED" ] \
  || version_fail "Herdr released the registration when the agent process exited, so this run cannot prove the stale-registration path; the classifier still reads dead through agent_not_found"

PANE_STATE=$(fm_backend_herdr_pane_agent_state "$SESSION" "$PANE_ID")
[ "$PANE_STATE" = stale-agent ] \
  || version_fail "a registration over a shell-only pane reads '$PANE_STATE' rather than 'stale-agent'"
STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] \
  || version_fail "a registration over a shell-only pane recovers as '$STATE' rather than 'dead'; every relaunch would be refused"
pass "real herdr $HERDR_VERSION: a registration Herdr keeps after its agent exits reads stale-agent and recovers as dead"

OUT=$(run_control hsmoke exit) || fail "exit against a stale-registration pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "a stale-registration pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with a stale registration is idempotent success"

rm -f "$SCRATCH/codex-launched"
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" hsmoke --relaunch --harness codex) \
  || fail "a stale-registration Herdr pane should be relaunched: $OUT"
for _ in $(seq 1 20); do
  [ ! -e "$SCRATCH/codex-launched" ] || break
  sleep 0.1
done
[ -e "$SCRATCH/codex-launched" ] || fail "the replacement harness was not launched after the stale registration"
[ "$(sed -n 's/^window=//p' "$HOME_DIR/state/hsmoke.meta" | tail -1)" = "$SESSION:$PANE_ID" ] \
  || fail "the relaunch replaced its endpoint instead of reusing it"
herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the relaunch removed the endpoint it was required to reuse"
[ -d "$WT" ] || fail "the relaunch must never remove the task's local copy"
awk -F= '$1 == "harness" {$0="harness=claude"} {print}' "$HOME_DIR/state/hsmoke.meta" \
  > "$HOME_DIR/state/hsmoke.meta.tmp"
mv "$HOME_DIR/state/hsmoke.meta.tmp" "$HOME_DIR/state/hsmoke.meta"
pass "real herdr: a stale registration no longer blocks relaunch, and the endpoint and local copy survive"

# Last: the foreground process is a plain `sleep`, so the pane never draws any
# recognized composer chrome. exit's composer-empty guard (bin/fm-control.sh)
# therefore refuses before ever typing the exit command, rather than typing it
# into a live agent that ignores it and reporting a stop that did not happen.
start_agent_process
herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not re-register the live agent on the task pane"
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent's composer is not proven empty: $OUT"
fi
case "$OUT" in
  *"not proven empty"*|*"visibly holds pending text"*) : ;;
  *) fail "the exit failure should say the composer is not proven empty, got: $OUT" ;;
esac
pass "real herdr: an agent behind an unproven composer fails closed instead of typing an exit command into it"

# --- live reproject: a flat tab with a stale journal moves to a child -------
#
# The model-switch incident left workers as flat tabs in the owning parent
# with stale v2 journals pointing at destroyed workspaces. reproject moves the
# live tab into a new child workspace under the same parent and rebinds the
# record and the journal, keeping the agent, its process, and focus.
REPROJ_PARENT_RAW=$(herdr workspace create --cwd "$WT" --label firstmate --no-focus --session "$SESSION") \
  || fail "could not create the reproject parent workspace"
REPROJ_PWS=$(printf '%s' "$REPROJ_PARENT_RAW" | jq -r '.result.workspace.workspace_id // empty')
[ -n "$REPROJ_PWS" ] || fail "reproject parent creation returned no workspace id"
# The earlier hsmoke home workspace may carry the same home label, which would
# make the no-pane parent lookup ambiguous; give it a unique label first.
herdr workspace rename "$WORKSPACE_ID" hsmoke-flat --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not rename the hsmoke workspace away from the home label"
REPROJ_TAB_RAW=$(herdr tab create --workspace "$REPROJ_PWS" --cwd "$WT" --label fm-hreproj --no-focus --session "$SESSION") \
  || fail "could not create the flat reproject tab"
REPROJ_TAB=$(printf '%s' "$REPROJ_TAB_RAW" | jq -r '.result.tab.tab_id // empty')
REPROJ_PANE=$(printf '%s' "$REPROJ_TAB_RAW" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$REPROJ_TAB" ] && [ -n "$REPROJ_PANE" ] || fail "flat reproject tab creation returned no ids"
fm_backend_herdr_send_text_line "$SESSION:$REPROJ_PANE" "$AGENT_CMD" \
  || fail "could not start the agent-named process in the flat tab"
OLD_PANE_ID=$PANE_ID
PANE_ID=$REPROJ_PANE
wait_process_state agent 50 \
  || version_fail "the flat tab reads '$(fm_backend_herdr_pane_process_state "$SESSION" "$REPROJ_PANE")' rather than 'agent' before reproject"
PANE_ID=$OLD_PANE_ID
herdr pane report-agent "$REPROJ_PANE" --source fm-control-smoke --agent claude \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a live agent on the flat tab"
REPROJ_SHELL=$(herdr pane process-info --pane "$REPROJ_PANE" --session "$SESSION" 2>/dev/null \
  | jq -r '.result.process_info.shell_pid // empty')
[ -n "$REPROJ_SHELL" ] || fail "could not read the flat tab shell pid before reproject"
{
  echo "window=$SESSION:$REPROJ_PANE"
  echo "endpoint_task_id=hreproj"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$REPROJ_PWS"
  echo "herdr_tab_id=$REPROJ_TAB"
  echo "herdr_pane_id=$REPROJ_PANE"
} > "$HOME_DIR/state/hreproj.meta"
REPROJ_TOKEN=$(fm_backend_herdr_projection_journal_create "$HOME_DIR/state" hreproj) \
  || fail "could not publish the reproject attempt journal"
REPROJ_LABEL=$(fm_backend_herdr_projection_workspace_label hreproj "$REPROJ_TOKEN")
HOME_REAL=$(cd "$HOME_DIR" && pwd -P)
fm_backend_herdr_projection_journal_write_v2 "$HOME_DIR/state/hreproj.herdr-presentation" \
  hreproj "$REPROJ_TOKEN" "$HOME_REAL" "$SESSION" w9 w9:t9 w9:p9 \
  "$REPROJ_PWS" firstmate "$REPROJ_LABEL" fm-hreproj \
  || fail "could not stage the stale reproject binding"
REPROJ_OLD_RAW=$(herdr workspace create --cwd "$WT" --label "$REPROJ_LABEL" --no-focus --session "$SESSION") \
  || fail "could not create the old reproject child"
REPROJ_OLD_WS=$(printf '%s' "$REPROJ_OLD_RAW" | jq -r '.result.workspace.workspace_id // empty')
REPROJ_OLD_TAB=$(printf '%s' "$REPROJ_OLD_RAW" | jq -r '.result.tab.tab_id // empty')
REPROJ_OLD_PANE=$(printf '%s' "$REPROJ_OLD_RAW" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$REPROJ_OLD_WS" ] && [ -n "$REPROJ_OLD_TAB" ] && [ -n "$REPROJ_OLD_PANE" ] \
  || fail "old reproject child creation returned no ids"
fm_backend_herdr_projection_journal_write_v2 "$HOME_DIR/state/hreproj.herdr-presentation" \
  hreproj "$REPROJ_TOKEN" "$HOME_REAL" "$SESSION" "$REPROJ_OLD_WS" "$REPROJ_OLD_TAB" "$REPROJ_OLD_PANE" \
  "$REPROJ_PWS" firstmate "$REPROJ_LABEL" fm-hreproj \
  || fail "could not bind the old reproject child"
herdr workspace rename "$REPROJ_OLD_WS" renamed-old-hreproj --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not rename the old reproject child"
if OUT=$(run_control hreproj reproject 2>&1); then
  fail "reproject moved a live worker while its old child survived under a renamed label: $OUT"
fi
[ "$(herdr pane get "$REPROJ_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')" = "$REPROJ_PWS" ] \
  || fail "the renamed old child refusal moved the flat live pane"
[ "$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/hreproj.meta" | tail -1)" = "$REPROJ_PANE" ] \
  || fail "the renamed old child refusal rebound task metadata"
[ "$(sed -n 's/^workspace_id=//p' "$HOME_DIR/state/hreproj.herdr-presentation" | tail -1)" = "$REPROJ_OLD_WS" ] \
  || fail "the renamed old child refusal changed the journal"
pass "real herdr: a renamed old child blocks a live move without rebinding the worker"
herdr pane close "$REPROJ_OLD_PANE" --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not close the test's empty old child"
[ "$(fm_backend_herdr_workspace_presence_state "$SESSION" "$REPROJ_OLD_WS")" = dead ] \
  || fail "the test's empty old child survived pane close"
fm_backend_herdr_projection_journal_write_v2 "$HOME_DIR/state/hreproj.herdr-presentation" \
  hreproj "$REPROJ_TOKEN" "$HOME_REAL" "$SESSION" w9 w9:t9 w9:p9 \
  "$REPROJ_PWS" firstmate "$REPROJ_LABEL" fm-hreproj \
  || fail "could not restore the stale reproject binding"
REPROJ_FOCUS_BEFORE=$(herdr workspace list --session "$SESSION" 2>/dev/null \
  | jq -c '[.result.workspaces[] | select(.focused == true) | {id: .workspace_id, active: .active_tab_id}]')
OUT=$(run_control hreproj reproject) || fail "live reproject of a flat tab should succeed: $OUT"
case "$OUT" in
  "reprojected hreproj harness=claude backend=herdr endpoint=$SESSION:"*" worktree=$WT") : ;;
  *) fail "reproject should report the rebound endpoint, got: $OUT" ;;
esac
REPROJ_NEW_PANE=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/hreproj.meta" | tail -1)
REPROJ_NEW_TAB=$(sed -n 's/^herdr_tab_id=//p' "$HOME_DIR/state/hreproj.meta" | tail -1)
REPROJ_NEW_WS=$(sed -n 's/^herdr_workspace_id=//p' "$HOME_DIR/state/hreproj.meta" | tail -1)
[ -n "$REPROJ_NEW_PANE" ] && [ "$REPROJ_NEW_PANE" != "$REPROJ_PANE" ] \
  || fail "reproject did not rebind the record to a new pane id"
[ -n "$REPROJ_NEW_TAB" ] && [ "$REPROJ_NEW_TAB" != "$REPROJ_TAB" ] \
  || fail "reproject did not rebind the record to a new tab id"
[ "$(sed -n 's/^tab_id=//p' "$HOME_DIR/state/hreproj.herdr-presentation" | tail -1)" = "$REPROJ_NEW_TAB" ] \
  || fail "reproject did not advance the journal to the new tab"
[ "$(sed -n 's/^workspace_id=//p' "$HOME_DIR/state/hreproj.herdr-presentation" | tail -1)" = "$REPROJ_NEW_WS" ] \
  || fail "reproject did not advance the journal to the new child workspace"
[ "$(herdr workspace list --session "$SESSION" 2>/dev/null | jq -r --arg ws "$REPROJ_NEW_WS" '.result.workspaces[] | select(.workspace_id == $ws) | .label')" = "$REPROJ_LABEL" ] \
  || fail "the new child workspace does not carry the bound projection label"
# Child order: the new child sits immediately after its owning parent block.
herdr workspace list --session "$SESSION" 2>/dev/null | jq -e --arg parent "$REPROJ_PWS" --arg child "$REPROJ_NEW_WS" '
  (.result.workspaces | map(.workspace_id)) as $ids
  | ($ids | index($parent)) as $p
  | ($ids | index($child)) as $c
  | $p != null and $c == $p + 1
' >/dev/null 2>&1 || fail "the reprojected child is not ordered immediately after its parent"
[ "$(herdr workspace list --session "$SESSION" 2>/dev/null | jq -c '[.result.workspaces[] | select(.focused == true) | {id: .workspace_id, active: .active_tab_id}]')" = "$REPROJ_FOCUS_BEFORE" ] \
  || fail "reproject moved the captain's focus"
[ "$(herdr agent get "$REPROJ_NEW_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.agent.agent // empty')" = claude ] \
  || fail "reproject lost the live agent registration"
[ "$(herdr pane process-info --pane "$REPROJ_NEW_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.process_info.shell_pid // empty')" = "$REPROJ_SHELL" ] \
  || fail "reproject did not preserve the live shell process"
herdr tab get "$REPROJ_TAB" --session "$SESSION" >/dev/null 2>&1 \
  && fail "reproject left the old flat tab behind"
[ "$(herdr pane list --workspace "$REPROJ_NEW_WS" --session "$SESSION" 2>/dev/null | jq -r '.result.panes | length')" = 1 ] \
  || fail "the new child does not hold exactly one task pane"
[ ! -e "$HOME_DIR/state/hreproj.control-reproject" ] \
  || fail "a completed reproject retained an unresolved-move receipt"
pass "real herdr $HERDR_VERSION: reproject moves a live flat tab to an ordered child with its agent, process, and focus intact"

herdr workspace rename "$REPROJ_NEW_WS" renamed-receipt-hreproj --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not rename the receipt-named child"
REPROJ_ORDER_ATTEMPT="$SCRATCH/reproject-order-attempt"
if (
  fm_backend_herdr_projection_order_best_effort() { : > "$REPROJ_ORDER_ATTEMPT"; }
  fm_backend_herdr_projection_reproject_live_tab "$SESSION" "$HOME_DIR/state/hreproj.herdr-presentation" \
    hreproj "$HOME_DIR" "$REPROJ_NEW_WS" "$REPROJ_NEW_TAB" "$REPROJ_NEW_PANE" \
    firstmate fm-hreproj "$REPROJ_NEW_WS" "$REPROJ_NEW_TAB" "$REPROJ_NEW_PANE" 1
); then
  fail "reproject resumed a receipt whose child had been renamed"
fi
[ ! -e "$REPROJ_ORDER_ATTEMPT" ] \
  || fail "reproject attempted to order a renamed receipt-named child"
[ "$(sed -n 's/^workspace_id=//p' "$HOME_DIR/state/hreproj.herdr-presentation" | tail -1)" = "$REPROJ_NEW_WS" ] \
  || fail "the renamed receipt refusal changed the journal"
[ "$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/hreproj.meta" | tail -1)" = "$REPROJ_NEW_PANE" ] \
  || fail "the renamed receipt refusal changed task metadata"
[ "$(herdr pane process-info --pane "$REPROJ_NEW_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.process_info.shell_pid // empty')" = "$REPROJ_SHELL" ] \
  || fail "the renamed receipt refusal disturbed the live worker"
pass "real herdr: a renamed receipt-named child is rejected before ordering"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
