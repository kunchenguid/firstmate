#!/usr/bin/env bash
# tests/fm-control-herdr-stale-nested.test.sh - real-herdr regression test for
# stale pi agent registrations over a persistent nested task shell
# (bin/backends/herdr.sh, bead task-py5n4).
#
# Herdr releases a detected agent only when the pane's foreground process
# group returns to the pane's OWN shell. A ship pane leaves a persistent
# nested shell behind (treehouse get opens a subshell in the worktree), so a
# pi worker that exits inside it keeps its agent registration indefinitely:
# the pane reads alive forever and fm-control exit/relaunch can neither stop
# nor replace the worker. The stale-authority reconciliation accepts that
# nested shell shape as authority - one recognized shell, in the recorded
# task directory, stable across repeated reads - and, because Herdr applies
# an accepted clear asynchronously over several seconds, waits for the
# registry to converge to agent-free instead of judging the repair by a
# single immediate re-read.
#
# This suite pins that recovery end to end against the REAL binary with REAL
# processes and no harness stub: a pi-shaped worker (name=node, argv0=pi)
# runs in a nested task shell, exits, and the pane still reports alive; the
# reconciliation must then repair it and fm-control exit must stop it. A
# genuinely unexpected foreground process must still refuse on exit and
# relaunch without touching the endpoint.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr, jq, or a C compiler is missing, and takes the declared
# gate-skip path when the installed herdr never registers the worker (older
# releases expose less process identity, so their detector may not fire).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL=/bin/bash
export SHELL

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || command -v clang 2>/dev/null || true)
[ -n "$CC_BIN" ] || { echo "skip: a C compiler (cc, gcc, or clang) is required for the pi-shaped stub"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || { echo "skip: could not source the herdr backend"; exit 0; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-stale-nested.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)

SESSION="fm-lab-stale-nested-$$"
export HERDR_SESSION="$SESSION"
CLEANED=0
cleanup_all() {
  [ "$CLEANED" = 1 ] && return 0
  CLEANED=1
  [ -n "${SCRATCH:-}" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/stnested"
printf '# brief\n' > "$HOME_DIR/data/stnested/brief.md"

PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b stnested "$WT"

# A stub executable NAMED node, so herdr reports name=node for it exactly as
# it does for a real pi worker. Run under argv0 pi per phase.
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
cat > "$SCRATCH/node.c" << 'EOF'
#include <unistd.h>
int main(void) { for (;;) sleep(60); return 0; }
EOF
"$CC_BIN" -O2 -o "$FAKEBIN/node" "$SCRATCH/node.c" || fail "could not compile stub node executable"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-stnested" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=stnested"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=pi"
  echo "kind=ship"
  echo "mode=direct-PR"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/stnested.meta"

lab() { fm_herdr_lab_cli "$SESSION" "$@"; }

type_line() {
  lab pane send-text "$PANE_ID" "$1" >/dev/null 2>&1 \
    || fail "could not type into the lab pane: $1"
  lab pane send-keys "$PANE_ID" Enter >/dev/null 2>&1 \
    || fail "could not submit a line in the lab pane: $1"
}

foreground_shape() {
  lab pane process-info --pane "$PANE_ID" 2>/dev/null | jq -r \
    '.result.process_info.foreground_processes[0] | "\(.name // "") \(.argv0 // .argv[0] // "")"' 2>/dev/null
}

wait_shape() {
  local attempt=0 shape
  while [ "$attempt" -lt 60 ]; do
    shape=$(foreground_shape)
    [ "$shape" = "$1 $2" ] && return 0
    sleep 0.5
    attempt=$((attempt + 1))
  done
  return 1
}

agent_registration() {
  lab agent get "$PANE_ID" 2>/dev/null | jq -r \
    '"\(.result.agent.agent // "") \(.result.agent.agent_status // "")"' 2>/dev/null
}

# wait_nested_shell: poll until the foreground is the nested interactive
# shell again. Herdr reports argv0 verbatim, so the spelling depends on how
# the pane resolved the command (bare `bash` or the full path); the name is
# what proves the worker is gone and the shell holds the foreground.
wait_nested_shell() {
  local attempt=0 shape name
  while [ "$attempt" -lt 40 ]; do
    shape=$(foreground_shape)
    name=${shape%% *}
    [ "$name" = bash ] && return 0
    sleep 0.5
    attempt=$((attempt + 1))
  done
  return 1
}

# wait_stale_registration: poll until herdr reports a pi registration for the
# pane - through its own detector when the release exposes enough identity,
# or through an explicit stale-style seed when it does not. Either way the
# pane ends with a pi registration over a worker that is about to exit,
# which is the defect shape under test.
wait_stale_registration() {
  local attempt=0 reg
  while [ "$attempt" -lt 30 ]; do
    reg=$(agent_registration)
    if [ "$reg" = "pi idle" ] || [ "$reg" = "pi working" ]; then
      printf 'auto-detected\n'
      return 0
    fi
    sleep 0.5
    attempt=$((attempt + 1))
  done
  lab pane report-agent "$PANE_ID" --source herdr:pi-stale --agent pi --state idle \
    >/dev/null 2>&1 || fail "could not seed a stale pi-style registration on the nested-shell pane"
  reg=$(agent_registration)
  { [ "$reg" = "pi idle" ] || [ "$reg" = "pi working" ]; } \
    || fail "herdr did not hold the seeded pi registration, got '$reg'"
  printf 'seeded\n'
}

# stop_nested_foreground: interrupt the nested shell's foreground worker and
# wait until the foreground is the nested shell itself again.
stop_nested_foreground() {
  lab pane send-keys "$PANE_ID" C-c >/dev/null 2>&1 || true
  wait_nested_shell
}

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=10 FM_CONTROL_LAUNCH_WAIT=20 \
    FM_SPAWN_FIRSTTURN=off FM_SPAWN_SKIP_PARLAY=1 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- the persistent nested-shell pane shape --------------------------------
type_line "cd \"$WT\" && bash --noprofile --norc"
wait_nested_shell \
  || fail "the lab pane never entered the nested task shell, got: $(foreground_shape)"
pass "real herdr: the pane holds a persistent nested shell in the recorded task directory"

# --- a pi-shaped worker runs in the nested shell, then exits ----------------
type_line "bash -c 'exec -a pi $FAKEBIN/node'"
# Live capability probe: the pi-shaped worker is only exerciseable when the
# installed herdr exposes the invoked argv0 (0.7.4 reports just node), so
# probe exactly the expression the classifier uses and take the declared
# gate-skip path otherwise, rather than failing a capability the backend
# was never given. The hermetic pins stay unconditional when this runs.
PROCESS_SHAPE='{}'
attempt=0
while [ "$attempt" -lt 20 ]; do
  PROCESS_SHAPE=$(lab pane process-info --pane "$PANE_ID" 2>/dev/null | jq -c '.result.process_info.foreground_processes[0] // {}' 2>/dev/null) || PROCESS_SHAPE='{}'
  [ "$(printf '%s' "$PROCESS_SHAPE" | jq -r '.name // empty' 2>/dev/null)" = node ] && break
  sleep 0.5
  attempt=$((attempt + 1))
done
if ! printf '%s' "$PROCESS_SHAPE" \
  | jq -e '((.argv0 // .argv[0] // "") == "pi")' >/dev/null 2>&1; then
  printf 'skip: installed herdr (%s) does not expose a pane argv0 field, so the nested-shell stale repair cannot be exercised\n' \
    "$(lab status --json 2>/dev/null | jq -r '.client.version // "unknown"' 2>/dev/null)"
  exit 0
fi
wait_shape "node" "pi" \
  || fail "the lab pane never showed the name=node argv0=pi worker, got: $(foreground_shape)"
wait_stale_registration \
  || fail "herdr never registered the pi-shaped worker"
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" = alive ] \
  || fail "herdr should classify the registered pi worker as alive"
pass "real herdr: a pi-shaped worker in the nested shell registers as alive"

stop_nested_foreground \
  || fail "the pi-shaped worker never returned the foreground to the nested shell, got: $(foreground_shape)"
sleep 2
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" = alive ] \
  || fail "the exited worker should leave a stale alive registration over the nested shell"
pass "real herdr: the exited worker leaves a stale alive registration over the nested shell"

# --- the reconciliation repairs the stale nested-shell registration ---------
if ! fm_backend_herdr_reconcile_stale_agent "$SESSION:$PANE_ID" "$WT"; then
  fail "stale-agent reconciliation did not repair the nested-shell pane: ${FM_BACKEND_HERDR_RECONCILE_RESULT:-unset}"
fi
[ "${FM_BACKEND_HERDR_RECONCILE_RESULT:-}" = repaired ] \
  || fail "nested-shell repair should report repaired, got '${FM_BACKEND_HERDR_RECONCILE_RESULT:-unset}'"
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" = dead ] \
  || fail "the repaired pane should read agent-free"
pass "real herdr: stale-agent reconciliation repairs a nested-shell pane to agent-free"

# --- fm-control exit succeeds against the same stale scenario ---------------
type_line "bash -c 'exec -a pi $FAKEBIN/node'"
wait_shape "node" "pi" \
  || fail "the lab pane never showed the second pi-shaped worker, got: $(foreground_shape)"
wait_stale_registration \
  || fail "herdr never registered the second pi-shaped worker"
stop_nested_foreground \
  || fail "the second worker never returned the foreground to the nested shell, got: $(foreground_shape)"
sleep 2
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" = alive ] \
  || fail "the second exited worker should leave a stale alive registration"

if ! OUT=$(run_control stnested exit 2>&1); then
  fail "exit should stop a stale nested-shell pane through reconciliation: $OUT"
fi
case "$OUT" in
  *"stopped stnested"*) : ;;
  *) fail "exit should report the stopped pane, got: $OUT" ;;
esac
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" = dead ] \
  || fail "the stopped pane should read agent-free"
pass "real herdr: fm-control exit stops a stale nested-shell pane"

# --- a genuinely unexpected process still refuses ----------------------------
type_line "sleep 300"
wait_shape "sleep" "sleep" \
  || fail "the lab pane never showed the unexpected shape, got: $(foreground_shape)"
lab pane report-agent "$PANE_ID" --source herdr:pi-stale --agent pi --state idle \
  >/dev/null 2>&1 || fail "could not seed a stale pi-style registration on the unexpected pane"

if OUT=$(run_control stnested exit 2>&1); then
  fail "exit should refuse an unexpected foreground process: $OUT"
fi
case "$OUT" in
  *"not a stable bare shell"*) : ;;
  *) fail "the exit refusal should name the unattributed process, got: $OUT" ;;
esac
pass "real herdr: exit refuses a genuinely unexpected process over a stale registration"

lab pane get "$PANE_ID" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
[ "$(foreground_shape)" = "sleep sleep" ] \
  || fail "the refused endpoint must be untouched, got: $(foreground_shape)"
pass "real herdr: the refusal preserved the endpoint and the task's local copy"

lab pane send-keys "$PANE_ID" C-c >/dev/null 2>&1 || true
fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
