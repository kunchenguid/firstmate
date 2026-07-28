#!/usr/bin/env bash
# Send one reply to the paired private Telegram chat.
#
# Usage:
#   fm-tg-reply.sh <request_id> [--final] < body
#   fm-tg-reply.sh --task <task-id> [--final] < body
#   fm-tg-reply.sh --retry <request_id>
#   fm-tg-reply.sh --help
#
# THE BODY IS STAGED, NEVER A PATH
#   The reply text is read from STDIN and staged as a private artifact at
#   state/telegram/reply/<request_id>.txt before anything is sent. There is no
#   path argument: this helper used to accept `--text-file <path>` and read any
#   readable regular file, which made it a generic path-to-Telegram primitive.
#   That is the one capability in the fleet that reaches a person OUTSIDE it, so
#   it must not be pointable at `.env`, a captain-private record, or an
#   unrelated project, and prose in the agent skill is not a capability
#   boundary. Staging gives the body one auditable location with a validated
#   identity and an explicit lifecycle instead.
#
# EVERY SEND NEEDS A REAL, OPEN REQUEST
#   The request id must name a message this home actually accepted from the
#   currently pinned peer: bin/fm-tg-poll.sh writes a context record for every
#   accepted message and for nothing else, so an invented id has none and is
#   refused (exit 4). A request whose recorded chat is no longer the pinned peer
#   is refused (exit 6), and one already closed by a final reply is refused
#   (exit 7). With --task, the task's own recorded project must equal the pinned
#   project (exit 6), so the outbound path checks project scope exactly as the
#   inbound task operations do.
#
# ONE POSSIBLE RECIPIENT
#   The destination is always the pinned peer's chat id from
#   state/telegram/peer.json. A request id or task id only selects which
#   correlation record to check; it can never redirect the message. With no
#   pinned peer nothing is ever sent (exit 3), which is what keeps "sendMessage
#   only after pairing" true by construction rather than by discipline.
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
#   record's `sent` counter, and that advance must become DURABLE before the
#   next chunk is sent.
#
#   If the counter cannot be persisted after a chunk was accepted, delivery is
#   AMBIGUOUS, not resumable: the message reached the person but no durable
#   record proves it, so a later --retry could repeat it. That case exits 9 and
#   says so, rather than claiming the reply is preserved for retry. Only a
#   failure whose progress IS durable exits 5 and is safe to --retry.
#
# FINAL CLEANUP
#   --final marks a terminal outcome. After the last chunk lands it clears the
#   task's Telegram link and closes the request, so no later milestone can post
#   against either. The context record itself is deliberately KEPT as evidence
#   of which conversation the task answered until its retention window expires.
#
# DRY RUN
#   With FM_TELEGRAM_DRY_RUN set truthy, nothing is sent. The would-be payload is
#   recorded to the same outbox path with "dry_run": true, a summary is printed
#   to stderr, and the exit status is 0. `--retry` refuses a dry-run record.
#
# Exit: 0 sent (or previewed); 2 bad usage; 3 no pinned peer; 4 no such request;
#       5 send failed with durable progress preserved for retry; 6 target,
#       project, or peer mismatch; 7 the request is already closed;
#       9 AMBIGUOUS delivery - a chunk was accepted but progress is not durable.
#       A no-mistakes gate agent is refused before any of that, with its own
#       message (bin/fm-gate-refuse-lib.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

# Only firstmate speaks to the paired person. A no-mistakes gate agent runs
# inside a firstmate checkout, auto-loads AGENTS.md, and can therefore read that
# this channel exists - so the same capability-removal guard the fleet
# entrypoints use applies here, where the blast radius is a message to someone
# outside the fleet (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

die() {
  printf 'fm-tg-reply: %s\n' "$1" >&2
  exit 2
}

REQUEST=
TASK=
FINAL=0
RETRY=

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --task) [ "$#" -gt 1 ] || die "--task requires a task id"; TASK=$2; shift 2 ;;
    --text-file)
      die "--text-file was removed: the reply body is read from stdin and staged under bridge state, so no path can be pointed at the channel"
      ;;
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
      # Nothing was delivered for this chunk, so the retry point is exactly here.
      # Preserving it is what lets a retry finish the reply without repeating a
      # delivered chunk and without re-running whatever produced the text - but
      # only if the preservation itself becomes durable.
      if printf '%s\n' "$record" | jq -c --argjson n "$i" --argjson at "$NOW" \
        '.sent = $n | .last_error_at = $at' \
        | fm_private_artifact_publish_stdin "$TG_DIR/outbox" "$name.json" 600; then
        printf 'fm-tg-reply: send failed after %s of %s messages; retry with --retry %s\n' \
          "$i" "$total" "$name" >&2
        exit 5
      fi
      printf 'fm-tg-reply: send failed after %s of %s messages AND the retry record could not be written; do not retry blindly - %s messages already reached the chat\n' \
        "$i" "$total" "$i" >&2
      exit 9
    fi
    # The chunk is delivered. Advancing the counter must become durable BEFORE
    # the next send, because a --retry that starts from a stale counter repeats
    # a message the person already received. A write that fails here therefore
    # makes delivery AMBIGUOUS rather than resumable, and saying "preserved for
    # retry" would be false.
    i=$(( i + 1 ))
    record=$(printf '%s' "$record" | jq -c --argjson n "$i" '.sent = $n')
    if ! printf '%s\n' "$record" \
      | fm_private_artifact_publish_stdin "$TG_DIR/outbox" "$name.json" 600; then
      rm -f -- "$body"
      printf 'fm-tg-reply: %s of %s messages were delivered but the progress record could not be written; delivery is ambiguous and --retry may repeat a delivered message\n' \
        "$i" "$total" >&2
      exit 9
    fi
  done
  rm -f -- "$body"
  fm_private_artifact_remove "$TG_DIR/outbox" "$name.json" >/dev/null 2>&1 || true
  fmtg_reply_stage_clear "$name" >/dev/null 2>&1 || true
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
  if [ "$(printf '%s' "$RECORD" | jq -r '.final // false')" = true ]; then
    finalize "$(printf '%s' "$RECORD" | jq -r '.task_id // ""')"
    fmtg_request_close "$RETRY" "$NOW" || true
  fi
  printf '%s\n' "$RETRY"
  exit 0
fi

# Resolve the correlation record, and verify it still points at the pinned peer.
if [ -n "$TASK" ]; then
  fmtg_publish_task_valid "$TASK" || die "invalid task id: $TASK"
  META="$STATE/$TASK.meta"
  [ -f "$META" ] || die "no task record at $META"
  # The outbound path checks project scope exactly as the inbound task
  # operations do. Without this, a task in an unrelated project could be used to
  # address the paired channel, and the pinned project would be enforced in one
  # direction only.
  PINNED_PROJECT=$(printf '%s' "$PEER" | jq -r '.project // empty')
  [ -n "$PINNED_PROJECT" ] || die "the pinned peer record has no project"
  TASK_PROJECT=$(fmtg_meta_get "$META" project) || TASK_PROJECT=
  TASK_PROJECT=$(basename "${TASK_PROJECT:-}")
  if [ "$TASK_PROJECT" != "$PINNED_PROJECT" ]; then
    printf 'fm-tg-reply: task %s is in project "%s", but the bridge is paired for "%s"; refusing\n' \
      "$TASK" "${TASK_PROJECT:-<none>}" "$PINNED_PROJECT" >&2
    exit 6
  fi
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

# The request must be one this home really accepted from the pinned peer, and
# must still be open. This is the check that makes an invented id inert.
AUTH_RC=0
fmtg_request_authentic "$REQUEST" "$PEER_CHAT" || AUTH_RC=$?
case "$AUTH_RC" in
  0) ;;
  4)
    printf 'fm-tg-reply: %s is not a message this home accepted from the paired peer; refusing\n' "$REQUEST" >&2
    exit 4
    ;;
  6)
    printf 'fm-tg-reply: request %s came from a chat that is no longer the paired peer; refusing\n' "$REQUEST" >&2
    exit 6
    ;;
  7)
    printf 'fm-tg-reply: request %s was already closed by a final reply; refusing\n' "$REQUEST" >&2
    exit 7
    ;;
  *) die "cannot verify request $REQUEST" ;;
esac

# The body arrives on stdin and is staged as a private artifact before it can be
# sent, so there is no caller-supplied path anywhere on this path.
fmtg_reply_stage "$REQUEST" || die "cannot stage the reply body under bridge state"
TEXT=$(fmtg_reply_staged_read "$REQUEST") || die "cannot read back the staged reply body"

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
  fmtg_reply_stage_clear "$REQUEST" >/dev/null 2>&1 || true
  printf '%s\n' "$REQUEST"
  exit 0
fi

send_chunks "$REQUEST" "$RECORD"
if [ "$FINAL" -ne 0 ]; then
  finalize "$TASK"
  # Close the request so no later milestone, and no replayed command, can post
  # against a finished exchange.
  fmtg_request_close "$REQUEST" "$NOW" || true
fi
printf '%s\n' "$REQUEST"
