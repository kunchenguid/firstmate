#!/usr/bin/env bash
# Add endpoint_task_id= to one pre-update Herdr task only after the recorded
# endpoint is correlated with its live, exact Herdr topology and worktree.
#
# Usage: fm-herdr-endpoint-bind.sh <task-id>
#
# This is the supported bridge for Herdr metadata created before
# endpoint_task_id= became mandatory. It never closes a pane or tears down a
# task. It acquires the task's spawn lock, requires a regular single-link meta
# file on the state device, validates a candidate through
# fm_backend_validate_task_endpoint, and then proves all of the following twice
# against the explicitly recorded named Herdr session:
#
#   - pane, tab, and workspace ids agree across pane get, tab get, tab list, and
#     pane list;
#   - the recorded tab is the unique live tab labeled exactly fm-<task-id> in
#     that workspace and still contains exactly one pane;
#   - the pane's physical foreground cwd is the recorded physical worktree or
#     one of its descendants.
#
# Mutable labels alone never authorize the binding. A missing endpoint, a
# stopped session, an exited agent whose pane returned outside the worktree, a
# changed label or topology, duplicate labels, ambiguous metadata, or any read
# error refuses without changing metadata. After a successful binding,
# fm-teardown.sh still runs its unchanged metadata-only validation before any
# runtime command or cleanup mutation.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  echo "usage: fm-herdr-endpoint-bind.sh <task-id>" >&2
}

refuse() {
  echo "REFUSED: $*; preserving task metadata." >&2
  exit 1
}

[ "$#" -eq 1 ] || { usage; exit 2; }
ID=$1
fm_task_id_path_safe "$ID" || { usage; exit 2; }

[ -d "$STATE" ] && [ ! -L "$STATE" ] \
  || refuse "task state directory is unavailable or unsafe"
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] \
  || refuse "task $ID has no regular endpoint metadata at $META"

TASK_LOCK="$STATE/.spawn-$ID.lock"
LOCK_HELD=0
META_SNAPSHOT=
META_TMP=
cleanup() {
  local status=$?
  [ -z "$META_SNAPSHOT" ] || rm -f -- "$META_SNAPSHOT"
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  [ "$LOCK_HELD" -eq 0 ] || fm_lock_release "$TASK_LOCK" 2>/dev/null || true
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fm_lock_try_acquire "$TASK_LOCK" \
  || refuse "task $ID is being spawned or recovered; retry after its task lock is free"
LOCK_HELD=1

STATE_DEVICE=$(fm_pr_file_device "$STATE") \
  || refuse "could not identify the task state device"
[ "$(fm_pr_file_device "$META")" = "$STATE_DEVICE" ] \
  && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || refuse "task $ID metadata is not a single-link file on the task state device"

BINDING_COUNT=$(grep -c '^endpoint_task_id=' "$META" 2>/dev/null || true)
case "$BINDING_COUNT" in
  ''|*[!0-9]*) refuse "could not read task $ID endpoint metadata" ;;
esac
if [ "$BINDING_COUNT" -ne 0 ]; then
  if fm_backend_validate_task_endpoint "$META" "$ID"; then
    printf 'Herdr endpoint metadata for task %s is already exactly bound.\n' "$ID"
    exit 0
  fi
  refuse "task $ID already has an invalid or ambiguous endpoint binding"
fi

BACKEND=$(fm_backend_meta_exact_value "$META" backend) \
  || refuse "task $ID has missing or ambiguous backend metadata"
[ "$BACKEND" = herdr ] \
  || refuse "task $ID uses backend $BACKEND, not Herdr"

META_SNAPSHOT=$(mktemp "$STATE/.fm-herdr-endpoint-snapshot.XXXXXX") \
  || refuse "could not snapshot task $ID metadata"
META_TMP=$(mktemp "$STATE/.fm-herdr-endpoint-meta.XXXXXX") \
  || refuse "could not prepare task $ID metadata"
cp -- "$META" "$META_SNAPSHOT" \
  || refuse "could not snapshot task $ID metadata"
cp -- "$META_SNAPSHOT" "$META_TMP" \
  || refuse "could not prepare task $ID metadata"
printf 'endpoint_task_id=%s\n' "$ID" >> "$META_TMP" \
  || refuse "could not prepare task $ID endpoint binding"
chmod 0600 "$META_SNAPSHOT" "$META_TMP" \
  || refuse "could not protect task $ID migration files"
fm_pr_private_file_valid "$META_SNAPSHOT" 600 "$STATE_DEVICE" \
  || refuse "task $ID migration files failed private-file validation"
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" \
  || refuse "task $ID migration files failed private-file validation"
fm_backend_validate_task_endpoint "$META_TMP" "$ID" \
  || refuse "task $ID legacy Herdr metadata is malformed or inconsistent"

SESSION=$(fm_backend_meta_exact_value "$META_TMP" herdr_session)
WORKSPACE=$(fm_backend_meta_exact_value "$META_TMP" herdr_workspace_id)
TAB=$(fm_backend_meta_exact_value "$META_TMP" herdr_tab_id)
PANE=$(fm_backend_meta_exact_value "$META_TMP" herdr_pane_id)
WORKTREE=$(fm_backend_meta_exact_value "$META_TMP" worktree)
WORKTREE_REAL=$(CDPATH='' cd -- "$WORKTREE" 2>/dev/null && pwd -P) \
  || refuse "recorded worktree for task $ID is unavailable"
[ "$WORKTREE_REAL" != / ] \
  || refuse "recorded worktree for task $ID resolves to the filesystem root"

fm_backend_source herdr \
  || refuse "could not load the Herdr backend"

live_binding_matches() {
  local pane_out tab_out tabs_out panes_out live_cwd live_cwd_real expected_label
  expected_label="fm-$ID"
  pane_out=$(fm_backend_herdr_cli "$SESSION" pane get "$PANE" 2>/dev/null) || return 1
  tab_out=$(fm_backend_herdr_cli "$SESSION" tab get "$TAB" 2>/dev/null) || return 1
  tabs_out=$(fm_backend_herdr_cli "$SESSION" tab list --workspace "$WORKSPACE" 2>/dev/null) || return 1
  panes_out=$(fm_backend_herdr_cli "$SESSION" pane list --workspace "$WORKSPACE" 2>/dev/null) || return 1

  printf '%s' "$pane_out" | jq -e \
    --arg pane "$PANE" --arg tab "$TAB" --arg workspace "$WORKSPACE" '
      .result.pane
      | .pane_id == $pane
        and .tab_id == $tab
        and .workspace_id == $workspace
        and (.foreground_cwd | type) == "string"
        and (.foreground_cwd | length) > 0
    ' >/dev/null 2>&1 || return 1
  printf '%s' "$tab_out" | jq -e \
    --arg tab "$TAB" --arg workspace "$WORKSPACE" --arg label "$expected_label" '
      .result.tab
      | .tab_id == $tab
        and .workspace_id == $workspace
        and .label == $label
        and .pane_count == 1
    ' >/dev/null 2>&1 || return 1
  printf '%s' "$tabs_out" | jq -e \
    --arg tab "$TAB" --arg label "$expected_label" '
      (.result.tabs | type) == "array"
      and ([.result.tabs[] | select(.tab_id == $tab)] | length) == 1
      and ([.result.tabs[] | select(.label == $label)] | length) == 1
    ' >/dev/null 2>&1 || return 1
  printf '%s' "$panes_out" | jq -e \
    --arg pane "$PANE" --arg tab "$TAB" --arg workspace "$WORKSPACE" '
      (.result.panes | type) == "array"
      and ([.result.panes[] | select(
        .pane_id == $pane and .tab_id == $tab and .workspace_id == $workspace
      )] | length) == 1
      and ([.result.panes[] | select(.tab_id == $tab)] | length) == 1
    ' >/dev/null 2>&1 || return 1

  live_cwd=$(printf '%s' "$pane_out" | jq -er '.result.pane.foreground_cwd') || return 1
  live_cwd_real=$(CDPATH='' cd -- "$live_cwd" 2>/dev/null && pwd -P) || return 1
  case "$live_cwd_real" in
    "$WORKTREE_REAL"|"$WORKTREE_REAL"/*) return 0 ;;
    *) return 1 ;;
  esac
}

live_binding_matches \
  || refuse "live Herdr endpoint does not exactly match task $ID topology, label, and worktree"
cmp -s "$META" "$META_SNAPSHOT" \
  || refuse "task $ID metadata changed during live verification; retry"
live_binding_matches \
  || refuse "live Herdr endpoint changed during task $ID verification"
cmp -s "$META" "$META_SNAPSHOT" \
  || refuse "task $ID metadata changed during live verification; retry"
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" \
  || refuse "task $ID metadata destination changed before publication"
mv -f -- "$META_TMP" "$META" \
  || refuse "could not publish task $ID endpoint binding"
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" \
  || refuse "published endpoint binding for task $ID failed validation"
fm_backend_validate_task_endpoint "$META" "$ID" \
  || refuse "published endpoint binding for task $ID failed validation"

printf 'Bound legacy Herdr endpoint metadata for task %s after exact live topology and worktree verification.\n' "$ID"
