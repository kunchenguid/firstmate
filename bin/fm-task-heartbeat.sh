#!/usr/bin/env bash
# Record one worker heartbeat without creating a watcher status event.
# Usage: fm-task-heartbeat.sh <task-id> <state-dir> <one-line-note>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 3 ] || ! fm_task_id_creation_valid "$1"; then
  echo "usage: fm-task-heartbeat.sh <task-id> <state-dir> <one-line-note>" >&2
  exit 2
fi

ID=$1
STATE=$2
NOTE=$3
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "fm-task-heartbeat: state directory is unavailable" >&2; exit 1; }
[ -n "$NOTE" ] && [ "${#NOTE}" -le 240 ] || { echo "fm-task-heartbeat: note must contain 1 to 240 characters" >&2; exit 2; }
case "$NOTE" in *$'\n'*|*$'\r'*|*$'\t'*) echo "fm-task-heartbeat: note must be one line without tabs" >&2; exit 2 ;; esac

umask 077
TMP=$(mktemp "$STATE/.$ID.heartbeat.XXXXXX") || exit 1
trap 'rm -f -- "$TMP"' EXIT HUP INT TERM
printf '%s\t%s\n' "$(date +%s)" "$NOTE" > "$TMP" || exit 1
chmod 0600 "$TMP" || exit 1
mv -f -- "$TMP" "$STATE/$ID.heartbeat" || exit 1
TMP=
