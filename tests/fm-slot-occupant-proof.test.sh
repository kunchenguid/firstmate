#!/usr/bin/env bash
# Pooled-slot disposal must inspect only the process bound to the task endpoint.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-slot-owner-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-slot-occupant-proof)
PROJECT="$TMP_ROOT/project"
WORKTREE="$TMP_ROOT/worktree"
HOME_DIR="$TMP_ROOT/home"
BG_PIDS=()

cleanup() {
  local pid
  for pid in "${BG_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$HOME_DIR/state"
: > "$HOME_DIR/AGENTS.md"
fm_git_worktree "$PROJECT" "$WORKTREE" slot-occupant-proof
fm_slot_stamp_write "$WORKTREE" task-a "$HOME_DIR" \
  || fail "could not stamp focused slot fixture"

(
  cd "$WORKTREE" || exit 1
  exec env FM_AGENT_TASK=task-a FM_AGENT_OWNER_HOME="$HOME_DIR" \
    FM_AGENT_ROLE=crewmate sleep 300
) >/dev/null 2>&1 &
SELF_PID=$!
BG_PIDS+=("$SELF_PID")

for _ in $(seq 1 50); do
  [ "$(readlink "/proc/$SELF_PID/cwd" 2>/dev/null || true)" = "$WORKTREE" ] && break
  sleep 0.02
done

REAL_PROC_CWD=$(declare -f fm_agent_proc_cwd | sed '1s/fm_agent_proc_cwd/_fm_real_agent_proc_cwd/')
eval "$REAL_PROC_CWD"
ENDPOINT_PID=$SELF_PID
fm_agent_proc_cwd() {
  # Exact endpoint proof must never consult an unrelated live process.
  [ "$1" = "$ENDPOINT_PID" ] || return 1
  _fm_real_agent_proc_cwd "$1"
}
fm_backend_foreground_process_pid() {
  [ "$1" = herdr ] && [ "$2" = lab:pane-a ] || return 1
  printf '%s' "$ENDPOINT_PID"
}

verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate live herdr lab:pane-a)
[ "$verdict" = dispose ] \
  || fail "an unrelated unreadable process blocked exact endpoint proof: $verdict"
pass "slot disposal scopes live-process proof to the exact backend endpoint"

SELF_START_TIME=$(fm_agent_proc_start_time "$SELF_PID")
fm_agent_task_pid_index() {
  printf 'task-a\t%s\t%s\t%s\tcrewmate\n' \
    "$SELF_PID" "$SELF_START_TIME" "$HOME_DIR"
  if [ -n "${DUP_PID:-}" ] && kill -0 "$DUP_PID" 2>/dev/null; then
    DUP_START_TIME=$(fm_agent_proc_start_time "$DUP_PID") || return 2
    printf 'task-a\t%s\t%s\t%s\tcrewmate\n' \
      "$DUP_PID" "$DUP_START_TIME" "$DUP_HOME"
  fi
}
fm_backend_foreground_process_pid() { return 1; }
verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate live herdr lab:pane-a)
[ "$verdict" = dispose ] \
  || fail "a declared marker did not prove the live PID-less endpoint: $verdict"
pass "a declared marker proves a live PID-less endpoint"

DUP_HOME="$TMP_ROOT/duplicate-home"
mkdir -p "$DUP_HOME"
(
  cd "$WORKTREE" || exit 1
  exec env FM_AGENT_TASK=task-a FM_AGENT_OWNER_HOME="$DUP_HOME" \
    FM_AGENT_ROLE=crewmate sleep 300
) >/dev/null 2>&1 &
DUP_PID=$!
BG_PIDS+=("$DUP_PID")
for _ in $(seq 1 50); do
  [ "$(readlink "/proc/$DUP_PID/cwd" 2>/dev/null || true)" = "$WORKTREE" ] && break
  sleep 0.02
done
verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate live herdr lab:pane-a)
[ "$verdict" = "retain: authoritative endpoint-occupant evidence is unavailable" ] \
  || fail "ambiguous duplicate task markers did not retain the lease: $verdict"
pass "ambiguous duplicate task markers retain the durable lease"
kill "$DUP_PID" 2>/dev/null || true
wait "$DUP_PID" 2>/dev/null || true

fm_agent_task_pid_index() { return 2; }
verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate live herdr lab:pane-a)
[ "$verdict" = "retain: authoritative endpoint-occupant evidence is unavailable" ] \
  || fail "an incomplete task PID index did not retain the lease: $verdict"
pass "an incomplete task PID index retains the durable lease"

fm_backend_foreground_process_pid() {
  [ "$1" = herdr ] && [ "$2" = lab:pane-a ] || return 1
  printf '%s' "$ENDPOINT_PID"
}

REAL_PROC_START_TIME=$(declare -f fm_agent_proc_start_time | sed '1s/fm_agent_proc_start_time/_fm_real_agent_proc_start_time/')
eval "$REAL_PROC_START_TIME"
START_TIME_SENTINEL="$TMP_ROOT/start-time-sentinel"
rm -f "$START_TIME_SENTINEL"
fm_agent_proc_start_time() {
  if [ "$1" = "$ENDPOINT_PID" ] && [ -e "$START_TIME_SENTINEL" ]; then
    printf 'reused-start-time'
    return 0
  fi
  if [ "$1" = "$ENDPOINT_PID" ]; then
    : > "$START_TIME_SENTINEL"
  fi
  _fm_real_agent_proc_start_time "$1"
}
verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate live herdr lab:pane-a)
[ "$verdict" = "retain: authoritative endpoint-occupant evidence is unavailable" ] \
  || fail "a reused endpoint PID did not retain the durable lease: $verdict"
pass "a reused endpoint PID retains the durable lease"
fm_agent_proc_start_time() {
  _fm_real_agent_proc_start_time "$1"
}

(
  cd "$WORKTREE" || exit 1
  exec env FM_AGENT_TASK=foreign-task FM_AGENT_OWNER_HOME="$HOME_DIR" \
    FM_AGENT_ROLE=crewmate sleep 300
) >/dev/null 2>&1 &
ENDPOINT_PID=$!
BG_PIDS+=("$ENDPOINT_PID")
for _ in $(seq 1 50); do
  [ "$(readlink "/proc/$ENDPOINT_PID/cwd" 2>/dev/null || true)" = "$WORKTREE" ] && break
  sleep 0.02
done
verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate live herdr lab:pane-a)
case "$verdict" in
  "retain: the endpoint-bound process for task(s) foreign-task is running in the slot"*) ;;
  *) fail "a foreign endpoint-bound occupant did not retain the slot: $verdict" ;;
esac
pass "a foreign endpoint-bound occupant retains the durable lease"
kill "$ENDPOINT_PID" 2>/dev/null || true
wait "$ENDPOINT_PID" 2>/dev/null || true

OTHER_HOME="$TMP_ROOT/other-home"
mkdir -p "$OTHER_HOME"
(
  cd "$WORKTREE" || exit 1
  exec env FM_AGENT_TASK=task-a FM_AGENT_OWNER_HOME="$HOME_DIR" \
    FM_AGENT_ROLE=crewmate FM_HOME="$OTHER_HOME" sleep 300
) >/dev/null 2>&1 &
CONTRACT_PID=$!
BG_PIDS+=("$CONTRACT_PID")
for _ in $(seq 1 50); do
  [ "$(readlink "/proc/$CONTRACT_PID/cwd" 2>/dev/null || true)" = "$WORKTREE" ] && break
  sleep 0.02
done
ENDPOINT_PID=$CONTRACT_PID
fm_backend_foreground_process_pid() {
  [ "$1" = herdr ] && [ "$2" = lab:pane-a ] || return 1
  printf '%s' "$ENDPOINT_PID"
}
verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate live herdr lab:pane-a)
case "$verdict" in
  "retain: the endpoint-bound process for task(s) task-a is running in the slot"*) ;;
  *) fail "a self-labeled worker with a foreign home override released the slot: $verdict" ;;
esac
pass "an incomplete self-owner home contract retains the durable lease"
kill "$CONTRACT_PID" 2>/dev/null || true
wait "$CONTRACT_PID" 2>/dev/null || true

fm_backend_foreground_process_pid() { return 1; }
verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate live herdr lab:pane-a)
[ "$verdict" = "retain: authoritative endpoint-occupant evidence is unavailable" ] \
  || fail "missing exact endpoint proof did not retain the durable lease: $verdict"
pass "missing exact endpoint proof retains the durable lease"

kill "$ENDPOINT_PID" "$SELF_PID" 2>/dev/null || true
wait "$ENDPOINT_PID" 2>/dev/null || true
wait "$SELF_PID" 2>/dev/null || true
fm_agent_proc_cwd() {
  _fm_real_agent_proc_cwd "$1"
}
(
  cd "$WORKTREE" || exit 1
  exec env -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME -u FM_AGENT_ROLE sleep 300
) >/dev/null 2>&1 &
LEGACY_PID=$!
BG_PIDS+=("$LEGACY_PID")
for _ in $(seq 1 50); do
  [ "$(readlink "/proc/$LEGACY_PID/cwd" 2>/dev/null || true)" = "$WORKTREE" ] && break
  sleep 0.02
done
verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate closed herdr lab:pane-a)
case "$verdict" in
  "retain: declared worker process for task(s) unidentified-process-"*) ;;
  *) fail "an undeclared process did not retain a closed endpoint lease: $verdict" ;;
esac
pass "an undeclared process retains a closed endpoint lease"
kill "$LEGACY_PID" 2>/dev/null || true
wait "$LEGACY_PID" 2>/dev/null || true
(
  cd "$WORKTREE" || exit 1
  exec env FM_AGENT_TASK=legacy-reparented FM_AGENT_OWNER_HOME="$OTHER_HOME" \
    FM_AGENT_ROLE=crewmate sleep 300
) >/dev/null 2>&1 &
REParent_PID=$!
BG_PIDS+=("$REParent_PID")
for _ in $(seq 1 50); do
  [ "$(readlink "/proc/$REParent_PID/cwd" 2>/dev/null || true)" = "$WORKTREE" ] && break
  sleep 0.02
done
verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate closed herdr lab:pane-a)
case "$verdict" in
  "retain: declared worker process for task(s) legacy-reparented is running in the slot"*) ;;
  *) fail "a reparented worker did not retain a closed endpoint lease: $verdict" ;;
esac
pass "a reparented worker retains a closed endpoint lease"
kill "$REParent_PID" 2>/dev/null || true
wait "$REParent_PID" 2>/dev/null || true

stat() { return 1; }
if fm_agent_worktree_process_census "$WORKTREE"; then
  census_status=0
else
  census_status=$?
fi
unset -f stat
[ "$census_status" -eq 2 ] \
  || fail "an unreadable process census did not retain uncertainty: $census_status"
pass "an unreadable process census retains uncertainty"

fm_agent_worktree_process_census() { return 1; }
FOREIGN_HOME="$TMP_ROOT/foreign-home"
mkdir -p "$FOREIGN_HOME/state" "$HOME_DIR/data"
fm_write_meta "$FOREIGN_HOME/state/foreign-paused.meta" \
  "window=firstmate:fm-foreign-paused" "worktree=$WORKTREE" \
  "project=$PROJECT" "kind=ship" "mode=no-mistakes" "home=$FOREIGN_HOME"
printf '%s\n' "- foreign-paused - paused task (home: $FOREIGN_HOME; scope: alpha; projects: alpha; added 2026-08-10)" \
  > "$HOME_DIR/data/secondmates.md"
verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate closed herdr lab:pane-a)
case "$verdict" in
  "retain: slot is also recorded by task(s) foreign-paused"*) : ;;
  *) fail "a paused task in another home did not retain the slot: $verdict" ;;
esac
pass "cross-home paused metadata retains a pooled slot"
rm -f "$FOREIGN_HOME/state/foreign-paused.meta" "$HOME_DIR/data/secondmates.md"

ORDINARY_HOME="$TMP_ROOT/ordinary-home"
mkdir -p "$ORDINARY_HOME/state"
fm_write_meta "$ORDINARY_HOME/state/ordinary-paused.meta" \
  "window=firstmate:fm-ordinary-paused" "worktree=$WORKTREE" \
  "project=$PROJECT" "kind=ship" "mode=no-mistakes" "home=$ORDINARY_HOME"
printf '%s\n' \
  "## Secondmate Backlogs" \
  "- ordinary-paused - paused task (home: $ORDINARY_HOME; scope: alpha; projects: alpha; added 2026-08-10)" \
  > "$HOME_DIR/AGENTS.md"
verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate closed herdr lab:pane-a)
case "$verdict" in
  "retain: slot is also recorded by task(s) ordinary-paused"*) : ;;
  *) fail "an ordinary registered task home did not retain the slot: $verdict" ;;
esac
pass "registered ordinary task homes retain a pooled slot"
rm -f "$ORDINARY_HOME/state/ordinary-paused.meta" "$HOME_DIR/AGENTS.md"

verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate closed herdr lab:pane-a)
[ "$verdict" = "retain: all-home slot metadata evidence is unavailable" ] \
  || fail "missing home registry did not retain the closed endpoint: $verdict"
pass "missing home registry retains a closed endpoint lease"
: > "$HOME_DIR/AGENTS.md"
verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate closed herdr lab:pane-a)
[ "$verdict" = dispose ] \
  || fail "a complete empty occupancy census did not dispose the closed endpoint: $verdict"
pass "a closed endpoint disposes after a complete empty occupancy census"

echo "# all fm-slot-occupant-proof tests passed"
