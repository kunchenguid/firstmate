#!/usr/bin/env bash
# Inspect and claim durable Telegram topic-board inbox items without deleting them.
#
# Usage:
#   fm-topic-inbox.sh list
#   fm-topic-inbox.sh show <update-id>
#   fm-topic-inbox.sh claim <update-id> <owner>
#   fm-topic-inbox.sh release <update-id>
#   fm-topic-inbox.sh count
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-topic-lib.sh
. "$SCRIPT_DIR/fm-topic-lib.sh"

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
}

fm_topic_prepare_storage

command=${1:-list}
case "$command" in
  list)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    for item in "$FM_TOPIC_INBOX"/update-*.json; do
      [ -f "$item" ] && [ ! -L "$item" ] || continue
      jq -r '[
        (.update_id | tostring),
        .status,
        .topic,
        .project,
        .route,
        (.claimed_by // "-"),
        (.text | gsub("[\\t\\r\\n]"; " ")),
        (.group // "-"),
        (.from_id // "-")
      ] | @tsv' "$item"
    done | sort -n -k1,1
    ;;
  show)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    item=$(fm_topic_any_item "$2") || { echo "error: topic item not found: $2" >&2; exit 1; }
    cat "$item"
    ;;
  claim)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    owner=$3
    case "$owner" in ''|*[!A-Za-z0-9._-]*) echo 'error: owner must use letters, digits, dot, underscore, or dash' >&2; exit 2 ;; esac
    item=$(fm_topic_pending_item "$2") || { echo "error: unanswered topic item not found: $2" >&2; exit 1; }
    status=$(jq -r '.status' "$item")
    claimed_by=$(jq -r '.claimed_by // ""' "$item")
    if [ "$status" = claimed ] && [ "$claimed_by" = "$owner" ]; then
      printf 'ok: update %s already claimed by %s\n' "$(jq -r '.update_id' "$item")" "$owner"
      exit 0
    fi
    [ "$status" = pending ] || {
      printf 'error: update %s is already claimed by %s\n' "$(jq -r '.update_id' "$item")" "${claimed_by:-unknown}" >&2
      exit 1
    }
    jq --arg owner "$owner" --arg claimed_at "$(fm_topic_now)" \
      '.status = "claimed" | .claimed_by = $owner | .claimed_at = $claimed_at' "$item" \
      | fm_topic_atomic_from_stdin "$item"
    printf 'ok: update %s claimed by %s\n' "$(jq -r '.update_id' "$item")" "$owner"
    ;;
  release)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    item=$(fm_topic_pending_item "$2") || { echo "error: unanswered topic item not found: $2" >&2; exit 1; }
    jq 'del(.claimed_by, .claimed_at) | .status = "pending"' "$item" | fm_topic_atomic_from_stdin "$item"
    printf 'ok: update %s released\n' "$(jq -r '.update_id' "$item")"
    ;;
  count)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    fm_topic_unanswered_count
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "error: unknown command: $command" >&2
    usage >&2
    exit 2
    ;;
esac
