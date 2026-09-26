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
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-control-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
CLEANED=0
# Idempotent: fail() cleans up before exiting and the EXIT trap fires after it,
# so a second teardown would otherwise report the already-consumed fleet-state
# tripwire as if the lab had gone wrong.
cleanup_all() {
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  if [ -n "$SCRATCH" ]; then
    # Spawn leaves each state/<id>.git-hooks strip dir read-only.
    find "$SCRATCH" -type d -exec chmod u+rwx {} + 2>/dev/null
    rm -rf "$SCRATCH"
  fi
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
# A relaunch replaces the task's pane with a fresh one, whose shell inherits the
# lab server's environment rather than anything typed into the old pane, so the
# inert test harness is on the server's PATH from the start.
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
: > "$SCRATCH/codex-launched"
EOF
chmod +x "$FAKEBIN/codex"
export PATH="$FAKEBIN:$PATH"
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"
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

# The pane is created in the primary checkout, the shape every Herdr task
# spawned before its pane was created in its worktree still has, so the first
# relaunch below also proves such a task is repaired.
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$PROJ" "$SEEDED_TAB_ID") \
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

printf -v PROJ_Q '%q' "$PROJ"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "cd -- $PROJ_Q" \
  || fail "could not move the agent-free pane out of its recorded worktree"
for _ in $(seq 1 20); do
  [ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" != "$PROJ_REAL" ] || break
  sleep 0.1
done
[ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" = "$PROJ_REAL" ] \
  || fail "the real Herdr pane did not drift out of its recorded worktree"

# assert_replaced_in_worktree <label>: the relaunch retired PANE_ID and the
# record now names a replacement pane in the same workspace whose creation
# directory - what Herdr saves and restores - is the task's worktree.
assert_replaced_in_worktree() {
  local label=$1 new_pane
  new_pane=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/hsmoke.meta" | tail -1)
  [ -n "$new_pane" ] && [ "$new_pane" != "$PANE_ID" ] \
    || fail "$label kept pane $PANE_ID instead of replacing it"
  [ "$(sed -n 's/^window=//p' "$HOME_DIR/state/hsmoke.meta" | tail -1)" = "$SESSION:$new_pane" ] \
    || fail "$label did not record its replacement endpoint"
  [ "$(herdr pane get "$PANE_ID" --session "$SESSION" 2>&1 | jq -r '.error.code // empty')" = pane_not_found ] \
    || fail "$label left the superseded pane $PANE_ID open"
  [ "$(herdr pane get "$new_pane" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.cwd // empty')" = "$WT_REAL" ] \
    || fail "$label created its replacement pane outside the worktree"
  [ "$(herdr pane get "$new_pane" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')" = "$WORKSPACE_ID" ] \
    || fail "$label moved the task out of its workspace"
  [ "$(fm_backend_herdr_current_path "$SESSION:$new_pane" 2>/dev/null || true)" = "$WT_REAL" ] \
    || fail "$label's replacement shell is not in its recorded worktree"
  PANE_ID=$new_pane
}

OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" hsmoke --relaunch --harness codex) \
  || fail "a drifted, agent-free Herdr pane should be re-homed and relaunched: $OUT"
for _ in $(seq 1 20); do
  [ ! -e "$SCRATCH/codex-launched" ] || break
  sleep 0.1
done
[ -e "$SCRATCH/codex-launched" ] || fail "the replacement harness was not launched"
assert_replaced_in_worktree "the drifted pane's relaunch"
awk -F= '$1 == "harness" {$0="harness=claude"} {print}' "$HOME_DIR/state/hsmoke.meta" \
  > "$HOME_DIR/state/hsmoke.meta.tmp"
mv "$HOME_DIR/state/hsmoke.meta.tmp" "$HOME_DIR/state/hsmoke.meta"
pass "real herdr: a relaunch replaces a primary-created, drifted pane with one created in the worktree, in the same workspace"

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
# symlink named `claude` to a long-running stand-in, the same construction
# tests/fm-tmux-agent-liveness.test.sh uses (a copied platform binary fails code
# signing on macOS arm64; the symlink name is what the kernel records as argv[0]).
# A multicall coreutils `sleep` (uutils or busybox) dispatches on argv[0] and
# exits at once under that name, so, as there, a dedicated spinner is built and
# the host's `sleep` is used only when it demonstrably survives the rename, with
# python3 (which ignores its own name) as the last stand-in.
AGENT_BIN="$SCRATCH/agentbin"
mkdir -p "$AGENT_BIN"
STANDIN_ARGS=(900)
standin_alive() {  # <path>
  local pid
  "$1" "${STANDIN_ARGS[@]}" >/dev/null 2>&1 &
  pid=$!
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 1; }
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
if [ -n "$CC_BIN" ] &&
  printf '%s\n' '#include <unistd.h>' 'int main(void){int i;for(i=0;i<900;i++)sleep(1);return 0;}' > "$SCRATCH/standin.c" &&
  "$CC_BIN" -o "$AGENT_BIN/standin" "$SCRATCH/standin.c" 2>/dev/null &&
  ln -s "$AGENT_BIN/standin" "$AGENT_BIN/claude" &&
  standin_alive "$AGENT_BIN/claude"; then
  :
else
  rm -f "$AGENT_BIN/standin" "$AGENT_BIN/claude"
  SLEEP_BIN=$(command -v sleep) || fail "sleep not found"
  ln -s "$SLEEP_BIN" "$AGENT_BIN/claude"
  if ! standin_alive "$AGENT_BIN/claude"; then
    rm -f "$AGENT_BIN/claude"
    STANDIN_ARGS=(-c 'import time; time.sleep(900)')
    PYTHON_BIN=$(command -v python3 2>/dev/null || true)
    if [ -z "$PYTHON_BIN" ] || ! ln -s "$PYTHON_BIN" "$AGENT_BIN/claude" || ! standin_alive "$AGENT_BIN/claude"; then
      echo "skip: no long-running stand-in binary survives a rename (multicall coreutils, no C compiler, no python3)"
      exit 0
    fi
  fi
fi
printf -v AGENT_Q '%q' "$AGENT_BIN/claude"
printf -v STANDIN_ARGS_Q ' %q' "${STANDIN_ARGS[@]}"

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
  fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "$AGENT_Q$STANDIN_ARGS_Q" \
    || fail "could not start the agent-named foreground process in the task pane"
  wait_process_state agent 50 \
    || version_fail "a real agent-named foreground process reads '$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")' rather than 'agent' through pane process-info"
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
assert_replaced_in_worktree "the stale-registration relaunch"
[ -d "$WT" ] || fail "the relaunch must never remove the task's local copy"
awk -F= '$1 == "harness" {$0="harness=claude"} {print}' "$HOME_DIR/state/hsmoke.meta" \
  > "$HOME_DIR/state/hsmoke.meta.tmp"
mv "$HOME_DIR/state/hsmoke.meta.tmp" "$HOME_DIR/state/hsmoke.meta"
pass "real herdr: a stale registration no longer blocks relaunch, and the task keeps its workspace and local copy"

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
  *"not proven empty"*) : ;;
  *) fail "the exit failure should say the composer is not proven empty, got: $OUT" ;;
esac
pass "real herdr: an agent behind an unproven composer fails closed instead of typing an exit command into it"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
