#!/usr/bin/env bash
# Retire one remote Orca worker, called only by fm-teardown.sh after its lease
# guard. Usage: fm-orca-worker-teardown.sh <id> [--force] [--legacy-record]
# The remote fm-teardown performs the ordinary worktree/endpoint/decision gates
# on the owning host. Its durable receipt makes a lost SSH reply retryable.
# This leg owns only the parent task's backlog transition and record archive.
# Open captain holds refuse; no remote cleanup can close a parent's decision.
# Local-only landing evidence is the approved parent's default-branch bundle,
# never the worker's delivery branch. No merge or forced fetch happens here.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
ID=$1
shift
case "$ID" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
META="$STATE/$ID.meta"
CONTROL_LOCK="$STATE/.control-$ID.lock"
META_LOCK=$(fm_meta_lock_path "$META")
fm_lock_try_acquire "$CONTROL_LOCK" || exit 1
trap 'fm_lock_release "$CONTROL_LOCK" || true' EXIT
fm_lock_try_acquire "$META_LOCK" || exit 1
trap 'fm_lock_release "$META_LOCK" || true; fm_lock_release "$CONTROL_LOCK" || true' EXIT
fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
[ -n "$(fm_meta_get "$META" orca_machine_host)" ] || exit 1
hold_rc=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_rc=$?
case "$hold_rc" in
  1|3) ;;
  *) echo "error: remote cleanup refused: $ID has an open or unreadable captain hold" >&2; exit 1 ;;
esac
BACKLOG=0
if fm_backlog_transition_applies "$CONFIG" "$DATA" "$(fm_meta_get "$META" kind)"; then
  BACKLOG=1
  fm_backlog_meta_spawn_gen "$META" "$STATE" || exit 1
  fm_backlog_row_probe "$DATA" "$ID" || exit 1
else
  [ "$?" != 2 ] || exit 1
fi
forced=0
for arg in "$@"; do [ "$arg" != --force ] || forced=1; done
if [ "$(fm_meta_get "$META" kind)" = scout ] && [ "$forced" = 0 ]; then
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-captain-hold.sh" verify "$ID" || exit 1
fi
receipt=$(python3 "$SCRIPT_DIR/fm-orca-worker.py" receipt "$STATE" "$ID") || exit 1
case "$receipt" in
  complete) ;;
  pending)
    if [ "$forced" = 0 ]; then
      if [ "$(fm_meta_get "$META" kind)" = scout ]; then
        python3 "$SCRIPT_DIR/fm-orca-worker.py" complete-empty "$STATE" "$ID" || exit 1
      fi
      python3 "$SCRIPT_DIR/fm-orca-worker.py" landing "$STATE" "$ID" || exit 1
    fi
    python3 "$SCRIPT_DIR/fm-orca-worker.py" run "$STATE" "$ID" fm-teardown.sh "$ID" "$@" || exit 1
    ;;
  *) echo "error: invalid remote cleanup receipt response" >&2; exit 1 ;;
esac
# The remote has verified removal. Keep every local record if publication or
# the authoritative backlog transition fails; the receipt supports a retry.
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
  "$SCRIPT_DIR/fm-inactive-reconcile.sh" report "$ID" || exit 1
archive="$DATA/$ID/remote-state"
mkdir -p "$archive"
cp "$META" "$archive/task.meta"
done_args=(--note "remote Orca worktree cleaned up")
if [ "$(fm_meta_get "$META" kind)" = scout ] && [ -f "$DATA/$ID/report.md" ]; then
  data_relative=$(fm_backlog_data_relative "$DATA") || exit 1
  done_args=(--report "$data_relative/$ID/report.md")
elif [ "$(fm_meta_get "$META" mode)" = local-only ] && [ "$forced" = 0 ]; then
  done_args=(--note "local main")
elif [ -n "$(fm_meta_get "$META" pr)" ]; then
  done_args=(--pr "$(fm_meta_get "$META" pr)")
fi
if [ "$BACKLOG" = 1 ]; then
  fm_backlog_close_marker_write "$STATE" "$ID" "$DATA" "$FM_BACKLOG_META_SPAWN_GEN" "${done_args[@]}" || exit 1
  marker=$(fm_backlog_close_marker_path "$STATE" "$ID")
  fm_backlog_atomic_transition close "$META" "$marker" "$DATA" "$ID" "$STATE" "${done_args[@]}" || exit 1
else
  fm_backlog_atomic_transition remove "$META" 'task record' "$STATE" || exit 1
fi
for suffix in status inbox busy-state busy-gen progress turn-ended model-stream model-stream-order model-progress orca-route.json orca-last-sync orca-sync.lock; do
  file="$STATE/$ID.$suffix"
  [ ! -e "$file" ] || mv "$file" "$archive/"
done
fm_wake_queue_prune_task "$STATE" "$ID" "$(fm_backend_target_of_meta "$archive/task.meta")" || true
echo "teardown $ID complete (remote Orca worktree and endpoint verified removed)"
