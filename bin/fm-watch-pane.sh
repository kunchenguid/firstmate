#!/usr/bin/env bash
# Manage operator-owned Herdr pane watches in this explicit FM_HOME.
# Usage:
#   fm-watch-pane.sh add <session> <workspace-label> <tab-label> <label> [--notify-done]
#   fm-watch-pane.sh remove <label>
#   fm-watch-pane.sh list
# add validates a unique live single-pane tab and replaces the entry for label.
# remove is idempotent; list prints the stored TSV without contacting Herdr.
# No command creates, closes, or changes a Herdr pane or session.
set -euo pipefail

usage() { sed -n '2,10s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ -n "${FM_HOME:-}" ] || { echo 'error: set FM_HOME explicitly' >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-watch-pane-lib.sh
. "$SCRIPT_DIR/fm-watch-pane-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
REGISTRY="$STATE/watched-panes"
COMMAND=${1:-}; shift || true
case "$COMMAND:$#" in
  list:0)
    fm_watch_pane_validate "$REGISTRY" || { echo 'error: invalid watched-pane registry' >&2; exit 1; }
    [ ! -f "$REGISTRY" ] || cat "$REGISTRY"
    exit 0 ;;
  add:4|add:5) LABEL=$4 ;;
  remove:1) LABEL=$1 ;;
  *) usage >&2; exit 2 ;;
esac
if [ -z "$LABEL" ] || printf '%s' "$LABEL" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  echo 'error: invalid watched-pane label' >&2
  exit 2
fi
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo 'error: state directory unavailable' >&2; exit 1; }
LOCK="$STATE/.watched-panes.lock"
fm_lock_try_acquire "$LOCK" || { echo 'error: watched-pane registry busy' >&2; exit 1; }
TMP=
trap '[ -z "$TMP" ] || rm -f -- "$TMP"; fm_lock_release "$LOCK"' EXIT
trap 'exit 1' HUP INT TERM
fm_watch_pane_validate "$REGISTRY" || { echo 'error: invalid watched-pane registry' >&2; exit 1; }
umask 077
TMP=$(mktemp "$STATE/.watched-panes.XXXXXX")
if [ -f "$REGISTRY" ]; then
  FM_WATCH_PANE_LABEL="$LABEL" awk -F '\t' '$4 != ENVIRON["FM_WATCH_PANE_LABEL"]' "$REGISTRY" > "$TMP"
fi
if [ "$COMMAND" = add ]; then
  NOTIFY=0
  if [ "$#" -eq 5 ]; then
    [ "$5" = --notify-done ] || { usage >&2; exit 2; }
    NOTIFY=1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$LABEL" "$NOTIFY" >> "$TMP"
  fm_watch_pane_validate "$TMP" || { echo 'error: invalid or duplicate watched-pane identity' >&2; exit 2; }
  fm_backend_source herdr
  fm_backend_herdr_resolve_watched_pane "$1" "$2" "$3" >/dev/null || exit 1
fi
mv -f -- "$TMP" "$REGISTRY"
TMP=
