#!/usr/bin/env bash
# Post a completion follow-up for a Telegram-linked task, up to three within a
# 7-day window, and manage the link's counter.
#
# A Telegram message that spawned real work is linked to its task by
# fm-tg-link.sh (tg_chat/tg_message/tg_followups/tg_link_ts in
# state/<id>.meta). When that task reaches a genuine milestone, firstmate
# composes an outcome and posts it here as one of up to three follow-ups as a
# threaded reply to the original acknowledgment message.
#
# Detection (no reply text needed - cheap pre-check before composing a reply):
#   fm-tg-followup.sh --check <task-id>
#     exit 0, prints <chat_id> <message_id>  -> a follow-up is due
#     exit 1, silent                        -> not linked, or window/cap
#                                              exhausted (link pruned)
#
# Post (after composing the reply to a file or stdin):
#   fm-tg-followup.sh <task-id> [--final] --text-file <path>
#   fm-tg-followup.sh <task-id> [--final] -
#     Linked, within window, and under the cap: posts ONE follow-up via
#       sendMessage with reply_parameters.message_id for threading.
#       On success: increments the counter and KEEPS the link, unless --final
#       was passed or the new count reaches the cap, in which case the link is
#       cleared instead.
#     Window or cap already exhausted: clears the link, posts nothing, exit 0.
#     Not linked: nothing to do, exit 0.
#
# --final marks this as the outcome reply: it always clears the link after a
# successful post, even if follow-ups remain under the cap.
#
# Dry-run (FMTG_DRY_RUN) records the payload to state/tg-outbox/ instead of
# sending, and the counter/link are mutated exactly as a live post would.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"

usage() {
  echo "usage: fm-tg-followup.sh --check <task-id> | <task-id> [--final] --text-file <path> | <task-id> [--final] -" >&2
}

help() {
  cat <<'EOF'
usage: fm-tg-followup.sh --check <task-id>
       fm-tg-followup.sh <task-id> [--final] --text-file <path>
       fm-tg-followup.sh <task-id> [--final] -

Post a completion follow-up (up to 3 per link, within a 7-day window) for a
Telegram-linked task and manage the link's follow-up counter.

Options:
  --check          Print the chat_id and message_id when a follow-up is due.
  --final          Clear the link after this post regardless of the remaining count.
  --text-file <path>
                   Read follow-up text from a file.
  -                Read follow-up text from stdin.
  --help           Show this help.
EOF
}

MAX_AGE=${FMTG_FOLLOWUP_MAX_AGE_SECS:-604800}
case "$MAX_AGE" in
  ''|*[!0-9]*) MAX_AGE=604800 ;;
esac

MAX_COUNT=${FMTG_FOLLOWUP_MAX_COUNT:-3}
case "$MAX_COUNT" in
  ''|*[!0-9]*) MAX_COUNT=3 ;;
esac
[ "$MAX_COUNT" -ge 1 ] 2>/dev/null || MAX_COUNT=3

case "${1:-}" in
  --help|-h) help; exit 0 ;;
esac

FINAL=0
MODE=post
if [ "${1:-}" = --check ]; then
  MODE=check
  ID=${2:-}
  if [ -z "$ID" ] || [ "$#" -gt 2 ]; then usage; exit 2; fi
else
  ID=${1:-}
  if [ -z "$ID" ]; then usage; exit 2; fi
  shift
  TS_ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --final)
        FINAL=1
        ;;
      *) TS_ARGS+=("$1") ;;
    esac
    shift
  done
  if [ "${#TS_ARGS[@]}" -lt 1 ]; then usage; exit 2; fi
fi

case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "fm-tg-followup: unsafe task id: $ID" >&2; exit 2 ;;
esac

META="$STATE/$ID.meta"
CHAT_ID=$(fmtg_meta_get "$META" tg_chat)
MSG_ID=$(fmtg_meta_get "$META" tg_message)
TS=$(fmtg_meta_get "$META" tg_link_ts)
COUNT=$(fmtg_meta_get "$META" tg_followups)
case "$COUNT" in
  ''|*[!0-9]*) COUNT=0 ;;
esac

# Not linked: this task did not originate from a Telegram message.
if [ -z "$CHAT_ID" ] || [ -z "$MSG_ID" ]; then
  if [ "$MODE" = check ]; then
    exit 1
  fi
  echo "fm-tg-followup: $ID is not Telegram-linked; nothing to post" >&2
  exit 0
fi

NOW=${FMTG_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in
  ''|*[!0-9]*) echo "fm-tg-followup: could not read the current time" >&2; exit 1 ;;
esac

EXPIRED=0
REASON="follow-up window elapsed"
case "$TS" in
  ''|*[!0-9]*) EXPIRED=1 ;;
  *) [ "$((NOW - TS))" -gt "$MAX_AGE" ] && EXPIRED=1 ;;
esac
if [ "$COUNT" -ge "$MAX_COUNT" ]; then
  EXPIRED=1
  REASON="follow-up cap reached"
fi

if [ "$EXPIRED" = 1 ]; then
  fmtg_meta_link_clear "$META" || echo "fm-tg-followup: warning: could not clear the elapsed link in state/$ID.meta" >&2
  if [ "$MODE" = check ]; then
    exit 1
  fi
  echo "fm-tg-followup: $REASON for $ID; skipped and cleared the link" >&2
  exit 0
fi

# Linked, within window, and under the cap.
if [ "$MODE" = check ]; then
  printf '%s %s\n' "$CHAT_ID" "$MSG_ID"
  exit 0
fi

# Post the follow-up as a threaded reply.
fmtg_load_config

TEXT_FILE=""
TEXT_SOURCE=""
for arg in "${TS_ARGS[@]}"; do
  if [ "$TEXT_SOURCE" = "next_file" ]; then
    TEXT_FILE="$arg"
    TEXT_SOURCE=""
  elif [ "$arg" = "--text-file" ]; then
    TEXT_SOURCE="next_file"
  fi
done

if [ -n "$TEXT_SOURCE" ] && [ -z "$TEXT_FILE" ]; then
  echo "fm-tg-followup: missing --text-file path" >&2
  exit 2
fi

if [ -n "$TEXT_FILE" ]; then
  TEXT=$(cat -- "$TEXT_FILE") || { echo "fm-tg-followup: cannot read text file: $TEXT_FILE" >&2; exit 1; }
else
  TEXT=$(cat)
fi

if [ -z "$TEXT" ]; then
  echo "fm-tg-followup: empty follow-up text" >&2
  exit 2
fi

# Dry-run: record and mutate counters as a live post would.
if [ -n "$FMTG_DRY" ]; then
  outbox_dir="$STATE/tg-outbox"
  outbox_file="$outbox_dir/followup-$(date +%s)-${CHAT_ID}.json"
  mkdir -p "$outbox_dir" 2>/dev/null || {
    echo "fm-tg-followup: cannot create dry-run outbox: $outbox_dir" >&2
    exit 1
  }
  jq -cn --arg chat_id "$CHAT_ID" --arg reply_to "$MSG_ID" --arg text "$TEXT" \
    '{chat_id:$chat_id,reply_to_message_id:$reply_to,text:$text}' > "$outbox_file" 2>/dev/null || {
    echo "fm-tg-followup: cannot write dry-run outbox: $outbox_file" >&2
    exit 1
  }
  printf 'fm-tg-followup: DRY RUN - would post threaded reply to chat %s msg %s (recorded: state/tg-outbox/%s): %s\n' \
    "$CHAT_ID" "$MSG_ID" "$(basename "$outbox_file")" "$TEXT" >&2
else
  # Live: send as threaded reply via sendMessage with reply_parameters.
  TEXT_FILE_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-tg-followup-text.XXXXXX") || exit 1
  printf '%s' "$TEXT" > "$TEXT_FILE_TMP" || { rm -f "$TEXT_FILE_TMP"; exit 1; }

  if ! response=$(fmtg_send_message_threaded "$CHAT_ID" "$MSG_ID" "$TEXT_FILE_TMP"); then
    rm -f "$TEXT_FILE_TMP"
    echo "fm-tg-followup: follow-up post failed for $ID; left the link in place to retry" >&2
    exit 1
  fi
  rm -f "$TEXT_FILE_TMP"

  sent_id=$(printf '%s' "$response" | jq -r '.result.message_id // empty' 2>/dev/null) || sent_id=
  if [ -z "$sent_id" ]; then
    echo "fm-tg-followup: could not confirm follow-up delivery for $ID; left the link in place to retry" >&2
    exit 1
  fi
fi

# Success: update counter or clear.
NEWCOUNT=$((COUNT + 1))
if [ "$FINAL" = 1 ] || [ "$NEWCOUNT" -ge "$MAX_COUNT" ]; then
  if ! fmtg_meta_link_clear "$META"; then
    echo "fm-tg-followup: error: posted but could not clear the link in state/$ID.meta" >&2
    exit 1
  fi
elif ! fmtg_meta_followups_set "$META" "$NEWCOUNT"; then
  if ! fmtg_meta_link_clear "$META"; then
    echo "fm-tg-followup: error: posted but could not record the follow-up count or clear the link in state/$ID.meta" >&2
    exit 1
  fi
  echo "fm-tg-followup: warning: posted but could not record the follow-up count; cleared the link to avoid duplicates" >&2
fi

printf '%s %s\n' "$CHAT_ID" "$MSG_ID"
exit 0
