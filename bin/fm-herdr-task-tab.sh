#!/usr/bin/env bash
# Update the one real Herdr sibling-worker tab from a task's durable record.
#
# Usage: fm-herdr-task-tab.sh <refresh|working|stopped|complete> <task-id>
#
# This is the lifecycle bridge for config/herdr-presentation-spaces=tabs.
# It never creates a workspace, notification surface, summary tab, or card.
# The Herdr adapter owns exact endpoint verification, focus restoration, label
# grammar, and mutation. This script owns only the task-result-to-marker map:
# working=●, review-ready=◐, captain decision=?, stopped/failed=!, complete=✓.
# A completed tab is intentionally retained. Cleanup remains fm-teardown.sh's
# existing owned path and must be requested separately after the result is safe.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

[ "$#" -eq 2 ] || { echo "usage: fm-herdr-task-tab.sh <refresh|working|stopped|complete> <task-id>" >&2; exit 2; }
ACTION=$1
ID=$2
case "$ACTION" in refresh|working|stopped|complete) ;; *) echo "error: unknown task-tab action '$ACTION'" >&2; exit 2 ;; esac
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid task id" >&2; exit 2 ;; esac

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 0
meta_value() {
  local key=$1 count
  count=$(grep -c "^${key}=" "$META" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^${key}=" "$META" | cut -d= -f2-
}
[ "$(fm_backend_of_meta "$META")" = herdr ] || exit 0
[ "$(meta_value herdr_presentation 2>/dev/null || true)" = tabs ] || exit 0
fm_backend_source herdr || exit 1

SESSION=$(meta_value herdr_session) || exit 1
WORKSPACE=$(meta_value herdr_workspace_id) || exit 1
TAB=$(meta_value herdr_tab_id) || exit 1
PANE=$(meta_value herdr_pane_id) || exit 1
TITLE=$(meta_value task_title) || exit 1
DISAMBIGUATOR=$(meta_value task_title_disambiguator 2>/dev/null || true)
KIND=$(meta_value kind 2>/dev/null || true)
[ -n "$KIND" ] || KIND=ship

marker_for_refresh() {
  local log="$STATE/$ID.status" line verb
  line=$(grep -v '^[[:space:]]*$' "$log" 2>/dev/null | tail -1 || true)
  verb=${line%%:*}
  verb=${verb%% *}
  case "$verb" in
    needs-decision|blocked) printf '?'; return 0 ;;
    failed) printf '!'; return 0 ;;
    done)
      if [ "$KIND" = scout ]; then printf '✓'; else printf '◐'; fi
      return 0
      ;;
  esac
  printf '●'
}

case "$ACTION" in
  refresh) MARKER=$(marker_for_refresh) ;;
  working) MARKER='●' ;;
  stopped) MARKER='!' ;;
  complete) MARKER='✓' ;;
esac
LABEL=$(fm_backend_herdr_task_tab_label "$MARKER" "$TITLE" "$DISAMBIGUATOR") || exit 1
fm_backend_herdr_tab_rename_exact "$SESSION" "$WORKSPACE" "$TAB" "$PANE" "$LABEL"
