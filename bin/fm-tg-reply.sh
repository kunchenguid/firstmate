#!/usr/bin/env bash
# Send one reply to the paired private Telegram chat.
#
# Usage:
#   fm-tg-reply.sh <request_id> --text-file <path> [--final]
#   fm-tg-reply.sh --task <task-id> --text-file <path> [--final]
#   fm-tg-reply.sh --retry <request_id>
#   fm-tg-reply.sh --help
#
# The reply body is read from a FILE (or "-" for stdin) and never from an
# argument, so agent prose that was influenced by an incoming message can never
# be interpolated into a shell command.
#
# ONE POSSIBLE RECIPIENT
#   The destination is always the pinned peer's chat id from state/telegram/peer.json.
#   A request id or task id only selects which correlation record to check and
#   clean up; it can never redirect the message. If the recorded chat for that
#   request or task no longer matches the pinned peer, the send is refused (exit
#   6) instead of delivered somewhere else. With no pinned peer nothing is ever
#   sent (exit 3), which is what keeps "sendMessage only after pairing" true by
#   construction rather than by discipline.
#
# ESCAPING
#   No parse_mode is ever set, so Telegram delivers the body literally. Text
#   containing *, _, [, `, or a stray backslash arrives exactly as written and
#   can neither be reinterpreted as markup nor rejected as an unbalanced entity.
#   The body reaches the API as a JSON string built by jq.
#
# SPLITTING AND RETRY
#   A reply longer than FM_TELEGRAM_MAX_CHARS is split deterministically on
#   fenced-code, paragraph, line, and word boundaries into at most
#   FM_TELEGRAM_MAX_MESSAGES numbered messages (bin/fm-message-split-lib.sh).
#   Before the first send, the whole plan is written to
#   state/telegram/outbox/<request_id>.json. Each delivered chunk advances the
#   record's `sent` counter. A failure leaves that record in place and exits 5,
#   so `--retry <request_id>` resumes at the first undelivered chunk: the reply
#   is completed without re-running whatever produced it and without repeating
#   messages the person already received.
#
# FINAL CLEANUP
#   --final marks a terminal outcome. After the last chunk lands it clears the
#   task's Telegram link so no later milestone can post against it. It
#   deliberately does NOT delete the per-request context record, which stays as
#   evidence of which conversation the task answered until its normal retention
#   window expires.
#
# DRY RUN
#   With FM_TELEGRAM_DRY_RUN set truthy, nothing is sent. The would-be payload is
#   recorded to the same outbox path with "dry_run": true, a summary is printed
#   to stderr, and the exit status is 0. `--retry` refuses a dry-run record.
#
# Exit: 0 sent (or previewed); 2 bad usage; 3 no pinned peer; 4 nothing to send;
#       5 send failed with the record preserved for retry; 6 target mismatch.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

die() {
  printf 'fm-tg-reply: %s\n' "$1" >&2
  exit 2
}

REQUEST=
TASK=
TEXT_FILE=
FINAL=0
RETRY=

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --task) [ "$#" -gt 1 ] || die "--task requires a task id"; TASK=$2; shift 2 ;;
    --text-file) [ "$#" -gt 1 ] || die "--text-file requires a path"; TEXT_FILE=$2; shift 2 ;;
    --retry) [ "$#" -gt 1 ] || die "--retry requires a request id"; RETRY=$2; shift 2 ;;
    --final) FINAL=1; shift ;;
    -*) die "unknown option: $1" ;;
    *)
      [ -z "$REQUEST" ] || die "only one request id may be given"
      REQUEST=$1
      shift
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"
fmtg_load_config
TG_DIR=$(fmtg_dir)
NOW=$(fmtg_now) || die "cannot read the current time"

PEER=$(fmtg_peer_get 2>/dev/null) || {
  printf 'fm-tg-reply: no paired peer; nothing was sent\n' >&2
  exit 3
}
PEER_CHAT=$(printf '%s' "$PEER" | jq -r '.chat_id // empty')
fmtg_chat_id_valid "$PEER_CHAT" || die "the pinned peer record has no usable chat id"

send_chunks() {  # <record-name> <record-json>
  local name=$1 record=$2 total sent i chunk body code
  total=$(printf '%s' "$record" | jq -r '.chunks | length')
  sent=$(printf '%s' "$record" | jq -r '.sent // 0')
  case "$sent" in ''|*[!0-9]*) sent=0 ;; esac
  body=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tg-resp.XXXXXX") || die "cannot create a temp file"
  i=$sent
  while [ "$i" -lt "$total" ]; do
    chunk=$(printf '%s' "$record" | jq -r --argjson i "$i" '.chunks[$i]')
    code=$(fmtg_send_text "$PEER_CHAT" "$chunk" "$body" 2>/dev/null) || code=
    if [ "$code" != 200 ]; then
      rm -f -- "$body"
      # Preserve exactly what is left so a retry never repeats a delivered chunk
      # and never re-runs whatever produced the text.
      printf '%s\n' "$record" | jq -c --argjson n "$i" --argjson at "$NOW" \
        '.sent = $n | .last_error_at = $at' \
        | fm_private_artifact_publish_stdin "$TG_DIR/outbox" "$name.json" 600 || true
      printf 'fm-tg-reply: send failed after %s of %s messages; retry with --retry %s\n' \
        "$i" "$total" "$name" >&2
      exit 5
    fi
    i=$(( i + 1 ))
    record=$(printf '%s' "$record" | jq -c --argjson n "$i" '.sent = $n')
    printf '%s\n' "$record" \
      | fm_private_artifact_publish_stdin "$TG_DIR/outbox" "$name.json" 600 || true
  done
  rm -f -- "$body"
  rm -f -- "$TG_DIR/outbox/$name.json" 2>/dev/null || true
}

# Clearing the link stops later milestone replies from posting against a finished
# task. The per-request context record is intentionally left alone: it is the
# evidence of which conversation this task answered.
finalize() {  # <task-id>
  local task=$1 meta
  [ -n "$task" ] || return 0
  meta="$STATE/$task.meta"
  [ -f "$meta" ] || return 0
  fmtg_meta_link_clear "$meta" || true
}

if [ -n "$RETRY" ]; then
  [ -z "$TEXT_FILE" ] || die "--retry resends a preserved reply; do not pass --text-file"
  fmtg_request_id_valid "$RETRY" || die "invalid request id: $RETRY"
  fm_private_artifact_file_valid "$TG_DIR/outbox" "$RETRY.json" 600 \
    || die "no preserved reply for $RETRY"
  RECORD=$(cat "$TG_DIR/outbox/$RETRY.json")
  if [ "$(printf '%s' "$RECORD" | jq -r '.dry_run // false')" = true ]; then
    die "$RETRY holds a dry-run preview, not a failed send"
  fi
  RECORD_CHAT=$(printf '%s' "$RECORD" | jq -r '.chat_id // empty')
  if [ "$RECORD_CHAT" != "$PEER_CHAT" ]; then
    printf 'fm-tg-reply: preserved reply targets a chat that is no longer the paired peer; refusing\n' >&2
    exit 6
  fi
  send_chunks "$RETRY" "$RECORD"
  [ "$(printf '%s' "$RECORD" | jq -r '.final // false')" != true ] \
    || finalize "$(printf '%s' "$RECORD" | jq -r '.task_id // ""')"
  printf '%s\n' "$RETRY"
  exit 0
fi

[ -n "$TEXT_FILE" ] || die "a reply needs --text-file <path> (or --text-file -)"

# Resolve the correlation record, and verify it still points at the pinned peer.
if [ -n "$TASK" ]; then
  fmtg_publish_task_valid "$TASK" || die "invalid task id: $TASK"
  META="$STATE/$TASK.meta"
  [ -f "$META" ] || die "no task record at $META"
  LINKED_CHAT=$(fmtg_meta_get "$META" tg_chat) || LINKED_CHAT=
  [ -n "$LINKED_CHAT" ] || die "task $TASK is not linked to a Telegram request"
  if [ "$LINKED_CHAT" != "$PEER_CHAT" ]; then
    printf 'fm-tg-reply: task %s is linked to a chat that is no longer the paired peer; refusing\n' "$TASK" >&2
    exit 6
  fi
  [ -n "$REQUEST" ] || REQUEST=$(fmtg_meta_get "$META" tg_request) || REQUEST=
fi

[ -n "$REQUEST" ] || die "give a request id, or --task <id> for a linked task"
fmtg_request_id_valid "$REQUEST" || die "invalid request id: $REQUEST"

if CTX=$(fmtg_context_get "$REQUEST" 2>/dev/null); then
  CTX_CHAT=$(printf '%s' "$CTX" | jq -r '.chat_id // empty')
  if [ -n "$CTX_CHAT" ] && [ "$CTX_CHAT" != "$PEER_CHAT" ]; then
    printf 'fm-tg-reply: request %s came from a chat that is no longer the paired peer; refusing\n' "$REQUEST" >&2
    exit 6
  fi
fi

if [ "$TEXT_FILE" = - ]; then
  TEXT=$(cat)
else
  [ -f "$TEXT_FILE" ] || die "no such reply file: $TEXT_FILE"
  TEXT=$(cat "$TEXT_FILE")
fi

CHUNKS=$(printf '%s' "$TEXT" | fm_message_split_thread "$FMTG_MAX_CHARS" "$FMTG_MAX_MESSAGES") \
  || die "cannot split the reply"
N=$(printf '%s' "$CHUNKS" | jq -r 'length')
case "$N" in ''|*[!0-9]*) N=0 ;; esac
if [ "$N" -eq 0 ]; then
  printf 'fm-tg-reply: the reply is empty; nothing was sent\n' >&2
  exit 4
fi

RECORD=$(jq -cn --arg rid "$REQUEST" --arg task "$TASK" --argjson chat "$PEER_CHAT" \
  --argjson chunks "$CHUNKS" --argjson at "$NOW" \
  --argjson final "$([ "$FINAL" -eq 1 ] && printf true || printf false)" \
  --argjson dry "$([ -n "$FMTG_DRY" ] && printf true || printf false)" \
  '{request_id:$rid, task_id:$task, chat_id:$chat, chunks:$chunks, sent:0,
    final:$final, dry_run:$dry, created_at:$at}') || die "cannot build the reply record"

fmtg_outbox_record "$REQUEST" "$RECORD" || die "cannot record the outgoing reply"

if [ -n "$FMTG_DRY" ]; then
  printf 'DRY RUN: %s message(s) to the paired chat, recorded at %s\n' \
    "$N" "$TG_DIR/outbox/$REQUEST.json" >&2
  printf '%s\n' "$REQUEST"
  exit 0
fi

send_chunks "$REQUEST" "$RECORD"
[ "$FINAL" -eq 0 ] || finalize "$TASK"
printf '%s\n' "$REQUEST"
