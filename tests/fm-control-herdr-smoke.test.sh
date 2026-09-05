#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from herdr's own agent registry corroborated against its own process
# inventory.
#
# The two signals are driven apart deliberately, because a registration alone
# is not evidence that an agent exists. herdr's `pane report-agent` is the same
# registry the adapter reads, and a report is not withdrawn when the process
# that made it goes away, so an identical registered reading is exercised twice
# over: once on a pane holding nothing but its shell (the worker already
# exited - agent-free, and eligible for the same-task replacement its operator
# is trying to launch), and once on a pane genuinely running a foreground
# process (alive, and a lifecycle verb that cannot stop it must say so).
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
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

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

# harness=pi, the harness of the task this case was written from: its exit
# command is /quit, which is exactly what a stale classification would type
# into a shell.
{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=pi"
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

register_agent() {  # <state>
  herdr pane report-agent "$PANE_ID" --source fm-control-smoke \
    --agent fm-control-smoke-agent --state "$1" --session "$SESSION" >/dev/null 2>&1
}

# The same read the backend's own capture performs
# (fm_backend_herdr_capture in bin/backends/herdr.sh): --source recent with a
# generous --lines, because a small bound returns nothing at all. The exit
# status is propagated so callers can refuse to treat a failed read as evidence
# that nothing was typed into the pane.
pane_text() {
  herdr pane read "$PANE_ID" --session "$SESSION" --source recent --lines 200
}

registered_status() {
  herdr agent get "$PANE_ID" --session "$SESSION" 2>/dev/null \
    | jq -r '.result.agent.agent_status // empty' 2>/dev/null
}

# wait_agent_state: poll the recovery-grade verdict for <want> across a bounded
# settle window and echo the last verdict observed.
#
# The classifier settles its NEGATIVE verdict from one strict instantaneous
# sample of the pane's process inventory, and an idle interactive shell
# transiently hosts short-lived prompt helpers (a zsh prompt redraw spawning
# starship as a second foreground process), so a single sample can legitimately
# still read `alive` while one is in flight. That is the documented contract in
# bin/backends/herdr.sh and docs/herdr-backend.md, and every production caller
# that acts on the negative verdict polls, so this case polls too. It still
# fails when the pane never reaches the verdict at all.
wait_agent_state() {  # <want>
  local want=$1 attempt=0 state=
  while [ "$attempt" -lt 100 ]; do
    state=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
    [ "$state" = "$want" ] && break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  printf '%s' "$state"
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

# --- a registration the pane's own processes contradict ---------------------
#
# The worker exited to its shell and nothing withdrew its report. Trusting the
# registry alone left the task alive forever, so every replacement attempt
# typed the harness's exit command into a shell and refused to relaunch.

register_agent idle || fail "could not leave a registration on the task pane"
[ -n "$(registered_status)" ] \
  || fail "herdr did not keep the registration, so this case cannot exercise the contradiction"

STATE=$(wait_agent_state dead)
[ "$STATE" = dead ] \
  || fail "a registration whose pane holds only its shell must classify agent-free within the settle window, got '$STATE'"
# The classifier reaches agent-free by two independent grounds, and only the
# process-inventory contradiction is this case's subject. herdr has been seen to
# drop a bare registration mid-test, which would settle the verdict through
# `agent get` answering agent_not_found instead and let this case pass without
# ever consulting the corroboration.
[ -n "$(registered_status)" ] \
  || fail "herdr dropped the registration during the settle window, so the agent-free verdict came from an absent registration rather than from the process inventory contradicting a present one"
pass "real herdr: a reported registration the pane's own process inventory contradicts reads agent-free"

OUT=$(run_control hsmoke exit) \
  || fail "exit should be idempotent success once the pane is proved agent-free: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free pane should report already-stopped, got: $OUT" ;;
esac
PANE_TEXT=$(pane_text) \
  || fail "could not read the task pane, so an absent /quit proves nothing about what exit typed into it"
case "$PANE_TEXT" in
  *"/quit"*) fail "exit typed the harness's exit command into a pane that hosts a plain shell" ;;
esac
pass "real herdr: an exited worker's pane is positively eligible for its replacement instead of being typed into"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse on a pane proved agent-free: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt still refuses on a pane whose registration outlived its agent"

# --- the same registration over a genuinely running process ----------------
#
# The identical registered reading, with a real non-shell foreground process
# in the pane. Nothing here may be reclassified as recoverable.

fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" 'sleep 600' \
  || fail "could not start a foreground process in the task pane"
ATTEMPT=0
while [ "$ATTEMPT" -lt 100 ]; do
  case "$(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null \
    | jq -r '[.result.process_info.foreground_processes[]?.name] | join(",")' 2>/dev/null)" in
    *sleep*) break ;;
  esac
  sleep 0.1
  ATTEMPT=$((ATTEMPT + 1))
done
[ "$ATTEMPT" -lt 100 ] || fail "the foreground process never appeared in herdr's process inventory"
register_agent idle || fail "could not register an agent over the running process"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] \
  || fail "a registration over a genuinely running foreground process must stay alive, got '$STATE'"
pass "real herdr: the same registration over a running foreground process stays alive"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a registered agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=pi backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the agent survived it"

# Last, because it deliberately types a harness command into a pane whose
# foreground process cannot act on it: the agent cannot be stopped that way,
# and the control plane must say so rather than report a stop it did not
# achieve.
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the exit failure should say the agent did not stop, got: $OUT" ;;
esac
pass "real herdr: an agent that does not stop fails closed instead of being reported as stopped"

herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null | grep -qx hsmoke \
  || fail "the control plane must never move the task's branch"
pass "real herdr: no control verb removed the endpoint, the task's local copy, or its branch"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
