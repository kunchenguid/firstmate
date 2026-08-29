#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub.
#
# A real OpenCode process is started and killed without its stop hook. Herdr
# retains its idle registration because OpenCode has lifecycle-hook authority,
# while the pane has returned to its login shell. The test proves that the
# control plane trusts the foreground process for non-destructive relaunch
# liveness, while the portable backend test separately proves that this does
# not make the pane a close-and-replace husk.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing; the OpenCode and Codex binaries are required
# only from the stale-registration section down, so the agent-free
# registration gate still runs on a host without them.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-"$ROOT/bin/fm-herdr-lab.sh"}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-control-exit-postcondition) || {
  echo "skip: could not create an isolated Herdr lab session name"
  exit 0
}
export HERDR_LAB_HELPER HERDR_LAB_SESSION
export HERDR_SESSION="$HERDR_LAB_SESSION"
SCRATCH=
CLEANED=0
cleanup_all() {
  local status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  return "$status"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab session"

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

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
  echo "window=$HERDR_LAB_SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=opencode"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$HERDR_LAB_SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=3 FM_CONTROL_LAUNCH_WAIT=30 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

wait_for() {  # <description> <command...>
  local description=$1 attempt
  shift
  attempt=0
  while [ "$attempt" -lt 100 ]; do
    "$@" && return 0
    sleep 0.2
    attempt=$((attempt + 1))
  done
  fail "timed out waiting for $description"
}

agent_is_idle() {
  lab agent get "$PANE_ID" 2>/dev/null \
    | jq -e '.result.agent.agent == "opencode" and .result.agent.agent_status == "idle"' >/dev/null
}

foreground_is_opencode() {
  lab pane process-info --pane "$PANE_ID" 2>/dev/null \
    | jq -e '
        .result.type == "pane_process_info"
        and (.result.process_info.foreground_processes | length) == 1
        and (.result.process_info.foreground_processes[0].name | sub("\\.exe$"; "")) == "opencode"
      ' >/dev/null
}

stale_idle_over_shell() {
  local agent_info process_info
  agent_info=$(lab agent get "$PANE_ID" 2>/dev/null) || return 1
  process_info=$(lab pane process-info --pane "$PANE_ID" 2>/dev/null) || return 1
  printf '%s' "$agent_info" | jq -e \
    '.result.agent.agent == "opencode" and .result.agent.agent_status == "idle"' >/dev/null \
    && printf '%s' "$process_info" | jq -e '
      .result.type == "pane_process_info"
      and (.result.process_info.foreground_processes | length) == 1
      and ((.result.process_info.foreground_processes[0].name | sub("\\.exe$"; "")) as $name
        | ["sh", "bash", "zsh", "dash", "ksh", "fish"] | index($name) != null)
    ' >/dev/null
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
pass "real herdr: interrupt refuses when Herdr has no registered agent"

# --- stale idle registration: a dead agent must not wedge relaunch ----------
#
# Only the remaining cases need real agent binaries, so the agent-free
# registration gate above still runs on a host that has Herdr but neither CLI.

command -v opencode >/dev/null 2>&1 || { echo "skip: opencode not found (agent-free registration cases already ran)"; exit 0; }
command -v codex >/dev/null 2>&1 || { echo "skip: codex not found (agent-free registration cases already ran)"; exit 0; }


lab pane run "$PANE_ID" 'opencode --mini' >/dev/null \
  || fail "could not start real OpenCode in the task pane"
wait_for "OpenCode to register as idle" agent_is_idle
wait_for "OpenCode to own the foreground process" foreground_is_opencode

PROCESS_INFO=$(lab pane process-info --pane "$PANE_ID") \
  || fail "could not read OpenCode foreground process"
OPEN_CODE_PID=$(printf '%s' "$PROCESS_INFO" | jq -r '.result.process_info.foreground_processes[0].pid // empty')
case "$OPEN_CODE_PID" in
  ''|*[!0-9]*) fail "OpenCode foreground process had no numeric pid: $PROCESS_INFO" ;;
esac
kill -KILL "$OPEN_CODE_PID" || fail "could not kill OpenCode process $OPEN_CODE_PID"

wait_for "Herdr's stale idle registration over the login shell" stale_idle_over_shell
STATE=$(fm_backend_agent_state herdr "$HERDR_LAB_SESSION:$PANE_ID")
[ "$STATE" = dead ] || fail "a stale idle registration over a shell must be agent-free, got '$STATE'"

OUT=$(run_control hsmoke exit) || fail "exit against a stale idle registration should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "a stale idle registration should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: stale idle registration over a login shell is agent-free for exit"

OUT=$(run_control hsmoke relaunch --harness codex --note 'process-kill recovery validation') \
  || fail "relaunch after stale idle registration should succeed: $OUT"
case "$OUT" in
  *"relaunched hsmoke harness=codex from=opencode"*) : ;;
  *) fail "relaunch should report the OpenCode-to-Codex handoff, got: $OUT" ;;
esac

grep -Fx "worktree=$WT" "$HOME_DIR/state/hsmoke.meta" >/dev/null \
  || fail "relaunch did not preserve the task worktree"
grep -Fx "herdr_pane_id=$PANE_ID" "$HOME_DIR/state/hsmoke.meta" >/dev/null \
  || fail "relaunch did not preserve the task pane"
grep -Fx 'harness=codex' "$HOME_DIR/state/hsmoke.meta" >/dev/null \
  || fail "relaunch did not record the replacement harness"
grep -F 'process-kill recovery validation' "$HOME_DIR/data/hsmoke/brief.md" >/dev/null \
  || fail "relaunch did not preserve the progress note"
lab pane get "$PANE_ID" >/dev/null 2>&1 \
  || fail "relaunch removed the endpoint it was meant to reuse"
[ -d "$WT" ] || fail "relaunch removed the task's local copy"
pass "real herdr: stale idle process-kill recovery relaunches Codex in the same pane and worktree"
