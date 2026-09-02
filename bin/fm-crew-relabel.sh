#!/usr/bin/env bash
# bin/fm-crew-relabel.sh - refresh one live herdr-presentation task's visible
# crew-label workspace title from its recorded crew_label and current backlog
# title, without allocating a new crew_label number or touching anything else
# about its projection.
#
# Usage: fm-crew-relabel.sh <task-id>
#
# Reads state/<id>.meta for backend=herdr, crew_label=, herdr_session=, and
# herdr_workspace_id=; reads state/<id>.herdr-presentation for the projection
# token; reads the current backlog title (best effort). Prints the new label
# to stdout on success. A task that is not a herdr task, or has no recorded
# crew_label (presentation was off or it is a secondmate at spawn time), is a
# silent no-op (exit 0, no output) so a caller can sweep every state/*.meta
# safely. See bin/backends/herdr.sh's fm_backend_herdr_projection_workspace_label
# for the label grammar this recomputes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

id=${1:-}
if [ -z "$id" ]; then
  echo "usage: fm-crew-relabel.sh <task-id>" >&2
  exit 2
fi

meta="$STATE/$id.meta"
[ -f "$meta" ] || {
  echo "error: no task record at $meta" >&2
  exit 1
}

backend=$(fm_backend_of_meta "$meta")
[ "$backend" = herdr ] || exit 0

crew_label=$(fm_meta_get "$meta" crew_label)
[ -n "$crew_label" ] || exit 0

session=$(fm_meta_get "$meta" herdr_session)
workspace=$(fm_meta_get "$meta" herdr_workspace_id)
if [ -z "$session" ] || [ -z "$workspace" ]; then
  echo "error: task $id has crew_label=$crew_label but no recorded herdr_session/herdr_workspace_id" >&2
  exit 1
fi

journal=$(fm_backend_herdr_projection_journal_path "$STATE" "$id")
if ! fm_backend_herdr_projection_journal_snapshot "$journal" "$id"; then
  echo "error: task $id has no valid presentation journal to read its projection token from" >&2
  exit 1
fi
token=$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID

title=
if fm_backlog_row_probe "$DATA" "$id"; then
  title=$FM_BACKLOG_ROW_TITLE
fi

label=$(fm_backend_herdr_projection_workspace_label "$id" "$token" "$crew_label" "$title")

if ! fm_backend_herdr_cli "$session" workspace rename "$workspace" "$label" >/dev/null; then
  echo "error: herdr workspace rename failed for task $id" >&2
  exit 1
fi
printf '%s\n' "$label"
