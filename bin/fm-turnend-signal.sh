#!/usr/bin/env bash
# Publish one task turn-end notification only while the exact spawning
# incarnation still owns that task's metadata.
#
# Usage:
#   fm-turnend-signal.sh <state-dir> <task-id> <spawn-gen>
#
# Every per-task harness hook embeds the spawn_gen minted by fm-spawn.sh.
# This writer takes the task metadata lock without waiting, verifies both the
# task identity and that generation, then touches state/<id>.turn-ended.
# A hook retained in harness memory after teardown, or one from an older worker
# after a same-id relaunch, is therefore a silent no-op. Contention is also a
# silent no-op so a notification hook can never delay or break harness shutdown.
set -u

STATE_DIR=${1:-}
ID=${2:-}
SPAWN_GEN=${3:-}

case "$ID" in
  ''|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
case "$SPAWN_GEN" in
  ''|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
[ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_STATE_OVERRIDE=$STATE_DIR
export FM_STATE_OVERRIDE
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

META="$STATE_DIR/$ID.meta"
LOCK=$(fm_meta_lock_path "$META") || exit 0
fm_lock_try_acquire "$LOCK" || exit 0
trap 'fm_lock_release "$LOCK"' EXIT

[ -f "$META" ] && [ ! -L "$META" ] || exit 0
META_ID=$(fm_meta_get "$META" endpoint_task_id)
META_GEN=$(fm_meta_get "$META" spawn_gen)
[ "$META_ID" = "$ID" ] && [ "$META_GEN" = "$SPAWN_GEN" ] || exit 0

touch -- "$STATE_DIR/$ID.turn-ended" 2>/dev/null || true
exit 0
