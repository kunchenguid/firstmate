#!/usr/bin/env bash
# fm-park-stopped.sh - park every ship and scout worker of THIS home whose agent
# already stopped but whose terminal endpoint is still open.
#
# Usage: fm-park-stopped.sh [--dry-run]
#
# A stopped worker keeps an idle shell pane open, and on Herdr each one holds a
# tab or a whole space. Parking it (`bin/fm-control.sh <id> park`) closes that
# endpoint, keeps the worktree and every uncommitted change, and records the
# stop as deliberate, so monitoring and recovery leave it alone and a later
# `relaunch` opens a fresh endpoint. bin/fm-cold-cache-lib.sh owns the policy.
#
# Scope is exact: only task records in this home's state/ directory, each
# addressed by its own task id through fm-control's exact-id targeting. Nothing
# is matched by name pattern, and no other home's endpoints are read. A
# secondmate, a remotely placed task, an already-parked task, a running agent,
# and an endpoint whose state cannot be read positively are skipped. On a tmux
# endpoint park records the stop but keeps the window (fm-control.sh says why).
#
# Prints one line per task: `parked`, `would-park`, `skipped <reason>`, or
# `failed`, then a summary. Exits 1 when any park failed, otherwise 0.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "error: unexpected argument '$arg'" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-park-stopped refuses to guess which home's workers to park" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 1; }

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-cold-cache-lib.sh
. "$SCRIPT_DIR/fm-cold-cache-lib.sh"

parked=0 skipped=0 failed=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  if ! fm_cold_cache_kind_in_scope "$meta"; then
    continue
  fi
  if fm_cold_cache_is_parked "$STATE" "$id"; then
    continue
  fi
  if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    echo "skipped $id remotely placed"
    skipped=$((skipped + 1))
    continue
  fi
  if ! fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1; then
    echo "skipped $id endpoint record does not validate"
    skipped=$((skipped + 1))
    continue
  fi
  backend=$FM_BACKEND_VALIDATED_BACKEND
  if ! fm_control_backend_state_verified "$backend"; then
    echo "skipped $id backend $backend cannot prove an agent stopped"
    skipped=$((skipped + 1))
    continue
  fi
  state=$(fm_backend_agent_state "$backend" "$FM_BACKEND_VALIDATED_TARGET" 2>/dev/null) || state=unknown
  if [ "$state" != dead ]; then
    echo "skipped $id agent state $state"
    skipped=$((skipped + 1))
    continue
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "would-park $id backend=$backend"
    parked=$((parked + 1))
    continue
  fi
  if out=$("$SCRIPT_DIR/fm-control.sh" "$id" park 2>&1); then
    printf '%s\n' "$out" | head -n 1
    parked=$((parked + 1))
  else
    echo "failed $id: $(printf '%s' "$out" | tail -n 1)"
    failed=$((failed + 1))
  fi
done

if [ "$DRY_RUN" = 1 ]; then
  echo "summary: would-park=$parked skipped=$skipped"
else
  echo "summary: parked=$parked skipped=$skipped failed=$failed"
fi
[ "$failed" = 0 ]
