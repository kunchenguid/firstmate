#!/usr/bin/env bash
set -u

usage() {
  echo "usage: fm-status-append.sh <state-dir> <task-id> <status-line>" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage
STATE=$1
ID=$2
LINE=$3
case "$ID" in ''|*[!A-Za-z0-9._-]*) usage ;; esac
[ -d "$STATE" ] || usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-classify-lib.sh"

if status_is_paused "$LINE"; then
  snapshot=$(fm_busy_record_read "$STATE" "$ID" snapshot 2>/dev/null || true)
  read -r busy_state _ _ busy_seq _ busy_gen <<EOF
$snapshot
EOF
  if [ "$busy_state" = busy ] && fm_busy_token_valid "$busy_gen"; then
    case "$busy_seq" in
      ''|*[!0-9]*) ;;
      *)
        current=$(fm_busy_record_read "$STATE" "$ID" snapshot 2>/dev/null || true)
        if [ "$current" = "$snapshot" ]; then
          head=${LINE%%:*}
          [ "$head" = "$LINE" ] || LINE="$head [busy-gen=$busy_gen] [busy-seq=$busy_seq]:${LINE#*:}"
        fi
        ;;
    esac
  fi
fi

printf '%s\n' "$LINE" >> "$STATE/$ID.status"
