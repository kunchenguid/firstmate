#!/usr/bin/env bash
# Refresh one tmux atelier task's optional native Herdr presentation.
#
# Usage:
#   FM_HOME=<firstmate-home> bin/fm-tmux-herdr-present.sh <task-id> [<status-line>]
#
# With no status line, the last non-empty state/<id>.status event is used.
# config/tmux-atelier must select the authoritative named tmux socket/session
# and may add herdr_session=<named-non-default-session>. The Herdr session must
# already be running at protocol 19 or newer; this command never starts, stops,
# reloads, updates, or deletes Herdr state.
#
# The command validates the task's ordinary tmux metadata under its metadata
# lock, then serializes this home's presentation writes before asking the tmux
# adapter to create or refresh a disposable Herdr pane attached to a one-window
# linked tmux proxy session. The task's recorded tmux endpoint and worktree
# remain the only capture, steering, recovery, and cleanup authority.
# Presentation absence or failure never blocks the tmux task.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

ID=${1:-}
STATUS_LINE=${2:-}
fm_task_id_creation_valid "$ID" || {
  echo "usage: fm-tmux-herdr-present.sh <task-id> [<status-line>]" >&2
  exit 2
}

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 0
META_LOCK=$(fm_meta_lock_path "$META") || exit 0
attempt=0
while ! fm_lock_try_acquire "$META_LOCK"; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 50 ] || exit 0
  sleep 0.1
done
META_LOCK_HELD=1
PRESENTATION_LOCK="$STATE/.tmux-herdr-presentation.lock"
PRESENTATION_LOCK_HELD=0
cleanup() {
  if [ "$PRESENTATION_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$PRESENTATION_LOCK" 2>/dev/null || true
  fi
  if [ "$META_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$META_LOCK" 2>/dev/null || true
  fi
}
trap cleanup EXIT

[ -f "$META" ] && [ ! -L "$META" ] || exit 0
fm_backend_validate_task_endpoint "$META" "$ID" >/dev/null 2>&1 || exit 0
[ "$FM_BACKEND_VALIDATED_BACKEND" = tmux ] || exit 0
fm_backend_source tmux || exit 0

if [ -z "$STATUS_LINE" ]; then
  STATUS_FILE="$STATE/$ID.status"
  [ -f "$STATUS_FILE" ] || exit 0
  STATUS_LINE=$(grep -v '^[[:space:]]*$' "$STATUS_FILE" 2>/dev/null | tail -1)
fi
[ -n "$STATUS_LINE" ] || exit 0

WORKTREE=$(fm_meta_get "$META" worktree)
PROJECT=$(fm_meta_get "$META" project)
[ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] || exit 0
[ -n "$PROJECT" ] || PROJECT=$WORKTREE
PROJECT_LABEL=${PROJECT##*/}
[ -n "$PROJECT_LABEL" ] || PROJECT_LABEL=project

attempt=0
while ! fm_lock_try_acquire "$PRESENTATION_LOCK"; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 50 ] || exit 0
  sleep 0.1
done
PRESENTATION_LOCK_HELD=1

fm_backend_tmux_atelier_presentation_sync \
  "$FM_BACKEND_VALIDATED_TARGET" "$ID" "$WORKTREE" "$PROJECT_LABEL" "$STATUS_LINE"
