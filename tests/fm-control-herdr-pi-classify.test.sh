#!/usr/bin/env bash
# tests/fm-control-herdr-pi-classify.test.sh - real-herdr regression test for
# pi worker classification (bin/backends/herdr.sh).
#
# A live pi worker runs under the node executable, so herdr reports its
# foreground process as {name:"node", argv0:"pi"} - and on some versions with
# no cmdline at all. Classifying on basename(name) alone counted that worker
# as unsafe, so fm-control's exit and relaunch refused on every herdr+pi task
# with `not a stable bare shell in its recorded task directory`, even though
# herdr's own pane record showed a live pi agent.
#
# This suite pins the fix against the REAL binary with REAL processes and no
# harness stub: a node executable invoked with argv0 pi classifies as the pi
# agent (exit and relaunch may proceed past the foreground proof), while a
# bare node process and a genuinely unexpected process still classify unsafe
# (exit and relaunch must still refuse). The credentialed live-harness proof
# that a real pi comes up and stays available is owned separately by
# tests/fm-pi-herdr-luna-live-e2e.test.sh.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr, jq, or a C compiler is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Herdr gives its server login shell to new panes. Pin a shell without
# operator startup helpers so the live process proof is deterministic.
SHELL=/bin/bash
export SHELL

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || command -v clang 2>/dev/null || true)
[ -n "$CC_BIN" ] || { echo "skip: a C compiler (cc, gcc, or clang) is required for the node-shaped stub"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || { echo "skip: could not source the herdr backend"; exit 0; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-classify.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)

SESSION="fm-lab-pi-classify-$$"
export HERDR_SESSION="$SESSION"
CLEANED=0
cleanup_all() {
  # fail() and the EXIT trap both call this, and the lab teardown consumes its
  # fleet-state tripwire on the first successful call, so a second call would
  # only print a spurious "missing fleet-state tripwire" refusal instead of a
  # clean failure report.
  [ "$CLEANED" = 1 ] && return 0
  CLEANED=1
  [ -n "${SCRATCH:-}" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/pismoke"
printf '# brief\n' > "$HOME_DIR/data/pismoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b pismoke "$WT"

# A stub executable NAMED node, so herdr reports name=node for it exactly as
# it does for a real pi worker. argv0 is set per phase with `exec -a`.
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
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-pismoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=pismoke"
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
} > "$HOME_DIR/state/pismoke.meta"

lab() { fm_herdr_lab_cli "$SESSION" "$@"; }

# foreground_shape prints "<name> <argv0>" using the SAME field expression the
# classifier and the capability probe use. Reading only .argv0 here let the
# probe pass on a herdr that reports the invoked name as argv[0] while the live
# assertion saw an empty second field it could never match.
foreground_shape() {
  lab pane process-info --pane "$PANE_ID" 2>/dev/null | jq -r \
    '.result.process_info.foreground_processes[0] | "\(.name // "") \(.argv0 // .argv[0] // "")"' 2>/dev/null
}

# wait_shape <want-name> <want-argv0>: poll until the pane foreground matches.
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

# wait_bare_node: poll until the foreground is the stub under its own name -
# name=node with an argv0 that does not name pi (herdr reports argv0
# verbatim, so an exec without -a shows the invoked path, not a basename).
wait_bare_node() {
  local attempt=0 shape name argv0
  while [ "$attempt" -lt 60 ]; do
    shape=$(foreground_shape)
    name=${shape%% *}
    argv0=${shape#* }
    [ "$name" = node ] && [ "$argv0" != pi ] && return 0
    sleep 0.5
    attempt=$((attempt + 1))
  done
  return 1
}

stop_foreground() {
  lab pane send-keys "$PANE_ID" C-c >/dev/null 2>&1 || true
  local attempt=0 info fg_pid shell_pid
  while [ "$attempt" -lt 20 ]; do
    info=$(lab pane process-info --pane "$PANE_ID" 2>/dev/null)
    fg_pid=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_process_group_id // empty' 2>/dev/null)
    shell_pid=$(printf '%s' "$info" | jq -r '.result.process_info.shell_pid // empty' 2>/dev/null)
    [ -n "$fg_pid" ] && [ "$fg_pid" = "$shell_pid" ] && return 0
    sleep 0.5
    attempt=$((attempt + 1))
  done
  return 1
}

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 FM_CONTROL_LAUNCH_WAIT=20 \
    FM_SPAWN_FIRSTTURN=off FM_SPAWN_SKIP_PARLAY=1 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- live capability probe: can the installed herdr name the invoked argv0? --
# A live pi worker runs under node, and the classification added here keys on
# the pane's own argv0 because that is where the agent identity lives. Herdr
# exposes that name as `argv0` on some versions and as `argv[0]` on others, so
# the probe reads both - exactly the expression the classifier uses - and takes
# the declared gate-skip path only when the installed herdr exposes neither,
# rather than failing a capability the backend was never given. Every reader
# below must use that same expression: a probe that passes while the live
# assertion reads a different field would assert against a shape it can never
# match. The unit-level identity pins stay unconditional when this test runs.
lab pane run "$PANE_ID" "bash -c 'exec -a pi $FAKEBIN/node'" >/dev/null 2>&1 \
  || fail "could not start the pi-shaped stub in the lab pane"
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
  printf 'skip: installed herdr (%s) does not expose a pane argv0 field, so the argv0-keyed live classification cannot be exercised\n' \
    "$(lab status --json 2>/dev/null | jq -r '.client.version // "unknown"' 2>/dev/null)"
  exit 0
fi

# --- unit pins: argv0 carries the agent identity, the name alone does not --
if ! fm_backend_herdr_identity_is_agent "node" "pi" ""; then
  printf 'not ok - %s\n' "name=node argv0=pi with empty cmdline must identify the pi agent" >&2
  exit 1
fi
pass "identity: name=node argv0=pi with empty cmdline identifies the pi agent"
if fm_backend_herdr_identity_is_agent "node" "node" ""; then
  printf 'not ok - %s\n' "a bare node process must not identify any agent" >&2
  exit 1
fi
pass "identity: a bare node process identifies no agent"
if fm_backend_herdr_identity_is_agent "sleep" "sleep" "sleep 300"; then
  printf 'not ok - %s\n' "an unexpected process must not identify any agent" >&2
  exit 1
fi
pass "identity: an unexpected process identifies no agent"

# --- the incident shape: name=node, argv0=pi -------------------------------
wait_shape "node" "pi" || fail "the lab pane never showed the name=node argv0=pi shape, got: $(foreground_shape)"

fm_backend_herdr_pane_shell_foreground_sample "$SESSION" "$PANE_ID" "$WT" >/dev/null
[ "${FM_BACKEND_HERDR_FOREGROUND_RESULT:-unsafe}" = agent ] \
  || fail "the name=node argv0=pi shape must sample as agent, got '${FM_BACKEND_HERDR_FOREGROUND_RESULT:-unset}'"
pass "real herdr: the name=node argv0=pi shape samples as agent"

# Seed a stale-style pi registration so the exit path reads alive from the
# registry while the process proof reads agent from the pane, exactly the
# combination do_exit needs before it may send the exit command.
lab pane report-agent "$PANE_ID" --source herdr:pi-stale --agent pi --state idle \
  >/dev/null 2>&1 || fail "could not seed a stale pi-style registration on the agent pane"
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" = alive ] \
  || fail "herdr should classify the seeded pi registration as alive"
if fm_backend_herdr_reconcile_stale_agent "$SESSION:$PANE_ID" "$WT"; then
  fail "stale-agent reconciliation must not clear a genuinely live pi-shaped process"
fi
[ "${FM_BACKEND_HERDR_RECONCILE_RESULT:-}" = not-stale ] \
  || fail "live pi protection should report not-stale, got '${FM_BACKEND_HERDR_RECONCILE_RESULT:-unset}'"
pass "real herdr: a live pi-shaped process is protected from stale-registration repair"

# --- a bare node process is not evidence of any agent -----------------------
stop_foreground || fail "could not stop the pi-shaped stub before the bare-node phase"
lab pane run "$PANE_ID" "bash -c 'exec $FAKEBIN/node'" >/dev/null 2>&1 \
  || fail "could not start the bare node stub in the lab pane"
wait_bare_node || fail "the lab pane never showed the bare node shape, got: $(foreground_shape)"

fm_backend_herdr_pane_shell_foreground_sample "$SESSION" "$PANE_ID" "$WT" >/dev/null
[ "${FM_BACKEND_HERDR_FOREGROUND_RESULT:-unsafe}" = unsafe ] \
  || fail "a bare node process must sample as unsafe, got '${FM_BACKEND_HERDR_FOREGROUND_RESULT:-unset}'"
pass "real herdr: a bare node process without a pi argv0 samples as unsafe"

# --- a genuinely unexpected process still refuses on exit AND relaunch ------
stop_foreground || fail "could not stop the bare node stub before the unexpected phase"
lab pane report-agent "$PANE_ID" --source herdr:pi-stale --agent pi --state idle \
  >/dev/null 2>&1 || fail "could not seed a stale pi-style registration on the shell pane"
lab pane run "$PANE_ID" "sleep 300" >/dev/null 2>&1 \
  || fail "could not start the unexpected process in the lab pane"
wait_shape "sleep" "sleep" || fail "the lab pane never showed the unexpected shape, got: $(foreground_shape)"

if OUT=$(run_control pismoke exit 2>&1); then
  fail "exit should refuse an unexpected foreground process: $OUT"
fi
case "$OUT" in
  *"not a stable bare shell"*) : ;;
  *) fail "the exit refusal should name the unattributed process, got: $OUT" ;;
esac
pass "real herdr: exit refuses a genuinely unexpected process"

if OUT=$(run_control pismoke relaunch --note "Probing the refusal path with an unexpected foreground process." 2>&1); then
  fail "relaunch should refuse an unexpected foreground process: $OUT"
fi
case "$OUT" in
  *"not a stable bare shell"*) : ;;
  *) fail "the relaunch refusal should name the unattributed process, got: $OUT" ;;
esac
pass "real herdr: relaunch refuses a genuinely unexpected process"

lab pane get "$PANE_ID" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: refusals preserved the endpoint and the task's local copy"

lab pane send-keys "$PANE_ID" C-c >/dev/null 2>&1 || true
fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
