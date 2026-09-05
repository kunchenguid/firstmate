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
# No real harness is launched. Herdr's `pane report-agent` models the retained
# registry entry left after Pi exits, while a real foreground process group
# independently models the non-shell ownership that must remain live.
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

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=
SCRATCH=
PROVISIONED=0
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  if [ "$PROVISIONED" -ne 0 ]; then
    PROVISIONED=0
    "$HERDR_LAB_HELPER" teardown "$SESSION"
  fi
}
trap cleanup_all EXIT
SESSION=$("$HERDR_LAB_HELPER" name control-herdr-smoke) || fail "could not name isolated Herdr lab session"
export HERDR_SESSION="$SESSION"
"$HERDR_LAB_HELPER" provision "$SESSION" || fail "could not provision isolated Herdr lab session"
PROVISIONED=1

lab() {
  "$HERDR_LAB_HELPER" run "$SESSION" "$@"
}

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"

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
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
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

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- a retained registration over the shell is stale for lifecycle recovery -

lab pane report-agent "$PANE_ID" --source fm-control-smoke --agent pi \
  --state idle >/dev/null 2>&1 \
  || fail "could not register the retained-agent fixture on the task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "the ordinary registry view should preserve the registered state, got '$STATE'"
STATE=$(fm_backend_recovery_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] || fail "lifecycle recovery should reconcile a retained registration over an idle shell, got '$STATE'"
OUT=$(run_control hsmoke exit) || fail "exit should reconcile the stale registration as already stopped: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "a stale registered-agent report over the shell should be already stopped, got: $OUT" ;;
esac
pass "real herdr: lifecycle recovery reconciles a retained registration after the agent process exits"

lab pane send-text "$PANE_ID" 'cd /' >/dev/null 2>&1 \
  || fail "could not drift the agent-free pane for path-restoration coverage"
lab pane send-keys "$PANE_ID" enter >/dev/null 2>&1 \
  || fail "could not submit the path-drift fixture"
sleep 0.2
fm_backend_prepare_relaunch_path herdr "$SESSION:$PANE_ID" "$WT" \
  || fail "the backend could not restore the agent-free pane to its recorded worktree"
SEEN=$(fm_backend_herdr_current_path "$SESSION:$PANE_ID")
[ "$SEEN" = "$WT" ] || fail "the restored pane path should be '$WT', got '$SEEN'"
pass "real herdr: an agent-free pane shell returns persistently to the exact recorded worktree"

UNMANAGED_DIR="$SCRATCH/unmanaged"
mkdir -p "$UNMANAGED_DIR"
UNMANAGED_RAW=$(lab workspace create --cwd "$UNMANAGED_DIR" --label unmanaged-fixture --no-focus) \
  || fail "could not create the unrelated-workspace fixture"
UNMANAGED_PANE=$(printf '%s' "$UNMANAGED_RAW" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$UNMANAGED_PANE" ] || fail "unrelated-workspace fixture returned no pane id"
UNMANAGED_BEFORE=$(lab pane get "$UNMANAGED_PANE" | jq -c '.result.pane | {pane_id,tab_id,workspace_id,foreground_cwd}') \
  || fail "could not snapshot the unrelated-workspace fixture"
fm_backend_herdr_relaunch_candidate_create \
  "$SESSION" "$WORKSPACE_ID" replacement-fixture "$WT" \
  || fail "could not create an exact replacement candidate"
CANDIDATE_TAB=$FM_BACKEND_HERDR_RELAUNCH_CANDIDATE_TAB_ID
CANDIDATE_PANE=$FM_BACKEND_HERDR_RELAUNCH_CANDIDATE_PANE_ID
fm_backend_herdr_relaunch_candidate_matches \
  "$SESSION" "$WORKSPACE_ID" "$CANDIDATE_TAB" "$CANDIDATE_PANE" \
  || fail "replacement candidate did not retain its response-derived binding"
[ "$(fm_backend_herdr_current_path "$SESSION:$CANDIDATE_PANE")" = "$WT" ] \
  || fail "replacement candidate did not start in the recorded worktree"
lab pane get "$PANE_ID" >/dev/null 2>&1 \
  || fail "replacement candidate creation removed the recorded endpoint"
UNMANAGED_AFTER=$(lab pane get "$UNMANAGED_PANE" | jq -c '.result.pane | {pane_id,tab_id,workspace_id,foreground_cwd}') \
  || fail "replacement candidate creation removed the unrelated endpoint"
[ "$UNMANAGED_AFTER" = "$UNMANAGED_BEFORE" ] \
  || fail "replacement candidate creation mutated the unrelated workspace"
fm_backend_herdr_relaunch_candidate_cleanup \
  "$SESSION" "$WORKSPACE_ID" "$CANDIDATE_TAB" "$CANDIDATE_PANE" \
  || fail "could not retire the exact agent-free replacement candidate"
fm_backend_herdr_relaunch_candidate_cleanup \
  "$SESSION" "$WORKSPACE_ID" "$CANDIDATE_TAB" "$CANDIDATE_PANE" \
  || fail "repeated exact candidate rollback should be idempotent"
lab pane get "$PANE_ID" >/dev/null 2>&1 \
  || fail "candidate rollback removed the recorded endpoint"
[ "$(lab pane get "$UNMANAGED_PANE" | jq -c '.result.pane | {pane_id,tab_id,workspace_id,foreground_cwd}')" = "$UNMANAGED_BEFORE" ] \
  || fail "candidate rollback mutated the unrelated workspace"
pass "real herdr: replacement candidate creation and rollback stay exact-record scoped"

# A different foreground process group makes the same registration live again.
# This is the structural refusal that prevents a genuine agent process from
# being mistaken for the shell-only stale-registration case.
lab pane send-text "$PANE_ID" "sh -c 'trap \"\" INT; while :; do sleep 1; done'" >/dev/null 2>&1 \
  || fail "could not type the foreground-process fixture"
lab pane send-keys "$PANE_ID" enter >/dev/null 2>&1 \
  || fail "could not start the foreground-process fixture"
sleep 0.5
STATE=$(fm_backend_recovery_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "a registered non-shell foreground process should remain alive, got '$STATE'"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a registered foreground process should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: a non-shell foreground process remains live and cannot be replaced"

lab pane get "$PANE_ID" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# The registered process is not a harness and cannot consume the exit command.
# The control plane must therefore report that it did not stop rather than
# converting the still-live foreground process into success.
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the foreground process does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the exit failure should say the foreground process did not stop, got: $OUT" ;;
esac
pass "real herdr: an agent process that does not stop fails closed instead of being reported as stopped"
