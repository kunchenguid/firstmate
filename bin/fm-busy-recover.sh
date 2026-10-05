#!/usr/bin/env bash
# Implementation of fm-busy-event.sh recover; invoke that public entrypoint.
# Requires explicit FM_HOME and exactly its configured state directory.
# --check --terminal ORIGINAL --pid ORIGINAL_PID prints a provenance receipt without changing
# records. The caller must obtain ORIGINAL from retained launch evidence,
# not infer historical ownership from today's pane label or current terminal.
# --apply RECEIPT accepts the unchanged JSON printed by --check or a file
# containing that JSON, then repeats every check under the task lease, control,
# metadata and busy locks before publishing the original busy generation.
# It acquires the busy lock through fm-wake-lib's stale-owner recovery and
# hands that exact ownership to the transcript verifier. No trust key, input,
# process replacement, spawn generation or cleanup authority is created.
# Apply can be repeated with the same receipt. A signal between publications
# leaves a refusal or the same proven process binding; rerun preflight/apply.
# Missing provenance, changed terminal/process, conflicting generations and
# unaccounted input refuse. Retain the work and evidence; never arm a new busy
# generation as a substitute for this proof. Platforms outside Linux/Herdr and
# Pi's extension event contract are deliberately outside this narrow recovery.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE=${1:?state directory required}
ID=${2:?task id required}
shift 2
case "$ID" in ''|.|..|*[!A-Za-z0-9._-]*) echo 'error: invalid task id' >&2; exit 2 ;; esac
[ -n "${FM_HOME:-}" ] || { echo 'error: recovery requires explicit FM_HOME' >&2; exit 1; }
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 1
expected_state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
[ "$(cd "$STATE" && pwd -P)" = "$(cd "$expected_state" && pwd -P)" ] || {
  echo 'error: recovery state does not belong to the explicit home' >&2; exit 1;
}
STATE=$(cd "$STATE" && pwd -P)
if [ "${1:-}" = --check ] && [ "${2:-}" = --terminal ] && [ "${4:-}" = --pid ] && [ "$#" = 5 ]; then
  exec python3 "$SCRIPT_DIR/fm-busy-transcript.py" recover-check "$STATE" "$ID" "$3" "$5"
fi
[ "${1:-}" = --apply ] && [ "$#" = 2 ] || { echo 'error: use --check --terminal ID --pid ORIGINAL_PID or --apply RECEIPT' >&2; exit 2; }
RECEIPT=$2
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
CONTROL_LOCK="$STATE/.control-$ID.lock"
META="$STATE/$ID.meta"
META_LOCK=$(fm_meta_lock_path "$META")
BUSY_LOCK="$STATE/$ID.busy-state.lock"
LAUNCH_STATE=$(fm_meta_get "$META" launch_state || true)
CONTROL_HELD=0
META_HELD=0
BUSY_HELD=0
BUSY_OWNER=
TMP=
cleanup() {
  [ -z "$TMP" ] || rm -f "$TMP"
  [ "$BUSY_HELD" = 0 ] || fm_lock_release "$BUSY_LOCK"
  [ "$META_HELD" = 0 ] || fm_lock_release "$META_LOCK"
  [ "$CONTROL_HELD" = 0 ] || fm_lock_release "$CONTROL_LOCK"
  fm_lease_guard_release
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
fm_lease_guard "$ID" 'busy binding recovery'
fm_lock_try_acquire "$CONTROL_LOCK" || { echo 'error: task lifecycle action in progress' >&2; exit 1; }
CONTROL_HELD=1
fm_lock_acquire_wait "$META_LOCK"
META_HELD=1
if ! fm_lock_acquire_wait_bounded "$BUSY_LOCK" "${FM_BUSY_RECOVERY_LOCK_WAIT_SECS:-3}"; then
  echo "error: recovery refused: transcript binding lock is held by a live or unverified process${FM_LOCK_HELD_PID:+ (pid $FM_LOCK_HELD_PID)}" >&2
  exit 1
fi
BUSY_HELD=1
BUSY_OWNER=$(readlink "$BUSY_LOCK") || {
  echo 'error: recovery refused: transcript binding lock ownership is unreadable' >&2
  exit 1
}
FM_BUSY_RECOVERY_LOCK_HOLDER=$$ FM_BUSY_RECOVERY_LOCK_OWNER=$BUSY_OWNER \
  python3 "$SCRIPT_DIR/fm-busy-transcript.py" recover-apply "$STATE" "$ID" "$RECEIPT" >/dev/null
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
FM_TASKS_AXI_TIMEOUT=${FM_TASKS_AXI_TIMEOUT:-30}
backlog_status=0
fm_backlog_transition_applies "$CONFIG" "$DATA" "$(fm_meta_get "$META" kind)" || backlog_status=$?
case "$backlog_status" in
  0) fm_backlog_atomic_transition dispatch "$META" "$DATA" "$ID" "$STATE" || {
    echo "error: binding preserved but backlog reconciliation failed: $FM_BACKLOG_TRANSITION_ERROR" >&2; exit 1;
  } ;;
  1) : ;;
  *) echo "error: $FM_BACKLOG_TRANSITION_ERROR" >&2; exit 1 ;;
esac
TMP="$STATE/.$ID.meta.recover.$$"
awk -F= '$1 != "launch_state"' "$META" >"$TMP"
printf 'launch_state=confirmed\n' >>"$TMP"
[ "$LAUNCH_STATE" = confirmed ] || fm_task_inbox_request_rearm "$STATE" "$ID" || {
  echo 'error: binding preserved but steering inbox rearm failed' >&2
  exit 1
}
fm_backlog_atomic_transition publish "$TMP" "$META" 'task record' "$STATE"
TMP=
printf 'recovered %s: original busy generation and live process verified; no worker restarted or input sent\n' "$ID"
