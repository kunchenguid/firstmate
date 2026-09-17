#!/usr/bin/env bash
# Durable, idempotent Hermes/Telegram notification for a task held for the
# captain, plus deterministic correlation of an inbound Telegram reply back to
# the exact hold it answers.
#
# Hermes is an external, VPS-local agent tool (not part of this repo) whose
# already-approved plugin forwards an authorized chat's inbound text into
# `bin/fm-inbox.sh note` and skips its own agent turn - Hermes never infers or
# authors a substantive reply, it only transports. This script is the other
# half: it lets Firstmate/Primary proactively push a captain-hold's reason out
# over that same transport (`hermes send --to telegram:<chat_id> "<text>"`,
# a plain CLI call, no code needed) and, later, deterministically resolve
# which open notification an inbound reply note correlates to. It never
# authors captain-facing text of its own - `register` sends exactly the text
# its caller supplies, and `resolve-reply` never composes an answer, it only
# identifies the task and hands back the reply text unmodified.
#
# Usage:
#   fm-hermes-notify.sh register <task-id> --reason-file <path> [--label <text>]
#   fm-hermes-notify.sh resolve-reply <note-file>
#   fm-hermes-notify.sh status <task-id>
#
# `register` requires <task-id> to be a currently active captain hold
# (`bin/fm-captain-hold.sh open <task-id>` must exit 0) and refuses otherwise -
# this script never notifies about a task that is not actually held. On
# success it sends <reason-file>'s content verbatim (trimmed to 4000 bytes,
# Telegram's own message-length ceiling) to the one authorized Telegram target
# `hermes send --list telegram` resolves. A home with no `hermes` binary, or
# with zero configured Telegram targets, is a silent no-op (exit 0,
# `skipped: ...`) so calling this unconditionally is always safe; more than
# one configured target refuses rather than guessing which to use.
#
# DUPLICATE SUPPRESSION uses the hold's own lifecycle identity
# (`bin/fm-captain-hold.sh open <task-id> --identity`, the hold-set timestamp
# plus its recorded-answer count - the exact mechanism that command's own
# contract names for telling two successive calls on one task id apart,
# because re-holding released work starts a new lifecycle without changing
# the task id). A second `register` for the same task id while that identity
# is unchanged and a notification already sent or answered is a pure no-op
# (`duplicate: ...`); a changed identity (a fresh hold cycle) sends again.
#
# RECOVERY AFTER INTERRUPTION: the durable record
# (state/hermes-notify/<task-id>.record, one mktemp+mv atomic write per
# transition) is written `status=pending` BEFORE the `hermes send` call and
# only advances to `status=sent` after that call succeeds. A crash between
# those two writes, or a `hermes send` failure (`status=failed`), leaves the
# record in a state a later `register` call retries automatically - neither
# is treated as a duplicate.
#
# REPLY CORRELATION: `resolve-reply` reads one `state/inbox/*.note` file
# already written by `bin/fm-inbox.sh note` (via the existing, unmodified
# Hermes plugin), matches its body against the plugin's own
# `[Telegram from <name> (chat <id>)] <text>` convention, and looks up the
# most recently sent notification for that chat id whose task is STILL an
# open captain hold (re-checked live via `bin/fm-captain-hold.sh open`, so a
# hold answered through any other channel in the meantime is never matched).
# On a match it prints one ready-to-pipe line,
# `<task-id><TAB><reply-text><TAB><label>`, for
# `bin/fm-captain-hold.sh answers --source hermes-telegram`, exactly the
# `<task-id>\t<answer>\t<label>[\t<mode>]` shape that intake documents. It
# never calls `answers` itself and never marks anything answered: per
# fm-captain-hold.sh's own header, "the invoking agent decides what is
# genuinely waiting on the captain" - correlating a reply to its task is
# mechanical, but deciding a given reply actually settles that call, and
# picking `done` vs `release`, stays the invoking agent's judgment. A note
# that does not match the plugin's convention, or correlates to no open
# notification, exits 1 with nothing on stdout so the caller falls back to
# ordinary note handling.
#
# `status <task-id>` prints the durable record's fields (or `absent`) for
# inspection; it mutates nothing.
#
# This is a standalone follow-up step, run explicitly after
# `bin/fm-captain-hold.sh hold` succeeds and again while draining a matching
# reply note - the same shape as `bin/fm-x-link.sh` running as a separate step
# after `bin/fm-spawn.sh`. It never modifies fm-captain-hold.sh, fm-inbox.sh,
# or the VPS-local Hermes plugin.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

NOTIFY_DIR="$STATE/hermes-notify"
CAPTAIN_HOLD="$SCRIPT_DIR/fm-captain-hold.sh"
MAX_TEXT_BYTES=4000

usage() {
  cat >&2 <<'EOF'
usage: fm-hermes-notify.sh register <task-id> --reason-file <path> [--label <text>]
       fm-hermes-notify.sh resolve-reply <note-file>
       fm-hermes-notify.sh status <task-id>
EOF
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf 'fm-hermes-notify: shasum or sha256sum is required\n' >&2
    exit 1
  fi
}

record_path() {  # <task-id>
  printf '%s/%s.record\n' "$NOTIFY_DIR" "$1"
}

# Read one field's value out of a record file. Empty when the file or the
# field is absent.
record_field() {  # <record-file> <field>
  local file=$1 field=$2
  [ -f "$file" ] || return 0
  sed -n "s/^${field}=//p" "$file" | tail -n1
}

# Write a record atomically (mktemp in the same directory, then mv), mirroring
# bin/fm-inbox.sh's queue_note() publication pattern.
write_record() {  # <task-id> <chat_id> <label> <reason_digest> <lifecycle> <status> <created_at> [<sent_at>] [<answered_at>]
  local task=$1 chat_id=$2 label=$3 digest=$4 lifecycle=$5 status=$6 created_at=$7
  local sent_at=${8:-} answered_at=${9:-} tmp
  mkdir -p "$NOTIFY_DIR"
  tmp=$(mktemp "$NOTIFY_DIR/.staging-XXXXXX") || {
    printf 'fm-hermes-notify: cannot stage record for %s\n' "$task" >&2
    return 1
  }
  {
    printf 'task=%s\n' "$task"
    printf 'chat_id=%s\n' "$chat_id"
    printf 'label=%s\n' "$label"
    printf 'reason_digest=%s\n' "$digest"
    printf 'lifecycle=%s\n' "$lifecycle"
    printf 'status=%s\n' "$status"
    printf 'created_at=%s\n' "$created_at"
    [ -z "$sent_at" ] || printf 'sent_at=%s\n' "$sent_at"
    [ -z "$answered_at" ] || printf 'answered_at=%s\n' "$answered_at"
  } >"$tmp"
  mv "$tmp" "$(record_path "$task")"
}

# One-line-per-field text, safe to embed in a TSV row downstream
# (bin/fm-captain-hold.sh answers already flattens \n\r\t to spaces on the
# fields it splits on, but flattening here too keeps our own TSV well-formed
# regardless of that downstream behavior).
flatten() {  # <text>
  printf '%s' "$1" | tr '\n\r\t' '   '
}

# Resolve the single authorized Telegram target as "hermes send --list
# telegram" reports it (a non-secret CLI surface - never reads ~/.hermes/.env
# or any credential file). Prints the bare chat id on success.
# Exit 0 + prints nothing: hermes is not installed or has no configured target
#   (caller treats this as "skip, not configured").
# Exit 1: hermes reports more than one target (ambiguous, refuse rather than
#   guess).
resolve_telegram_chat_id() {
  local out chat_id count=0 line LAST_CHAT_ID=''
  command -v hermes >/dev/null 2>&1 || return 0
  out=$(hermes send --list telegram 2>/dev/null) || return 0
  while IFS= read -r line; do
    case "$line" in
      *'telegram:'*'['*']'*)
        chat_id=${line##*\[}
        chat_id=${chat_id%%\]*}
        case "$chat_id" in
          ''|*[!0-9]*) continue ;;
        esac
        count=$((count + 1))
        LAST_CHAT_ID=$chat_id
        ;;
    esac
  done <<EOF
$out
EOF
  case "$count" in
    0) return 0 ;;
    1) printf '%s\n' "$LAST_CHAT_ID"; return 0 ;;
    *)
      printf 'fm-hermes-notify: hermes reports %s Telegram targets, refusing to guess which one\n' "$count" >&2
      return 1
      ;;
  esac
}

cmd_register() {
  local task=${1:-} reason_file='' label=''
  [ -n "$task" ] || { usage; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason-file) shift; reason_file=${1:-} ;;
      --label) shift; label=${1:-} ;;
      *) usage; exit 2 ;;
    esac
    shift
  done
  fm_task_id_path_safe "$task" || { printf 'fm-hermes-notify: unsafe task id: %s\n' "$task" >&2; exit 2; }
  [ -n "$reason_file" ] && [ -f "$reason_file" ] || {
    printf 'fm-hermes-notify: --reason-file <path> is required and must exist\n' >&2
    exit 2
  }

  local reason
  reason=$(cat "$reason_file")
  [ -n "${reason//[[:space:]]/}" ] || {
    printf 'fm-hermes-notify: refusing an empty reason\n' >&2
    exit 2
  }
  reason=$(printf '%s' "$reason" | cut -c1-"$MAX_TEXT_BYTES")
  [ -n "$label" ] || label=$task

  local identity rc=0
  identity=$("$CAPTAIN_HOLD" open "$task" --identity 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'fm-hermes-notify: %s is not an active captain hold (open check exit %s)\n' "$task" "$rc" >&2
    exit 1
  fi

  local chat_id
  chat_id=$(resolve_telegram_chat_id) || exit 1
  if [ -z "$chat_id" ]; then
    printf 'skipped: hermes/telegram not configured on this home\n'
    exit 0
  fi

  local record="$NOTIFY_DIR/$task.record" prior_status='' prior_lifecycle='' created_at=''
  prior_status=$(record_field "$record" status)
  prior_lifecycle=$(record_field "$record" lifecycle)
  if [ "$prior_lifecycle" = "$identity" ]; then
    case "$prior_status" in
      sent|answered)
        printf 'duplicate: %s already notified this hold cycle (status=%s)\n' "$task" "$prior_status"
        exit 0
        ;;
    esac
    created_at=$(record_field "$record" created_at)
  fi
  [ -n "$created_at" ] || created_at=$(date +%s)

  local digest
  digest=$(sha256_text "$reason")
  write_record "$task" "$chat_id" "$label" "$digest" "$identity" pending "$created_at" || exit 1

  if hermes send --to "telegram:$chat_id" "$reason" >/dev/null 2>&1; then
    write_record "$task" "$chat_id" "$label" "$digest" "$identity" sent "$created_at" "$(date +%s)" || exit 1
    printf 'sent: %s -> telegram:%s\n' "$task" "$chat_id"
    exit 0
  else
    write_record "$task" "$chat_id" "$label" "$digest" "$identity" failed "$created_at" || exit 1
    printf 'fm-hermes-notify: hermes send failed for %s\n' "$task" >&2
    exit 1
  fi
}

# Parse a note file's body for the Hermes plugin's own
# "[Telegram from <name> (chat <id>)] <text>" convention. On a match, prints
# "<chat_id>\n<reply-text>"; exits 1 with nothing on stdout otherwise.
parse_telegram_note() {  # <note-file>
  local file=$1 in_body=0 line first=1 chat_id='' reply=''
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_body" -eq 0 ]; then
      [ "$line" = "--" ] && in_body=1
      continue
    fi
    if [ "$first" -eq 1 ]; then
      first=0
      case "$line" in
        '[Telegram from '*' (chat '*')] '*)
          chat_id=${line#*\(chat }
          chat_id=${chat_id%%\)*}
          case "$chat_id" in
            ''|*[!0-9]*) return 1 ;;
          esac
          reply=${line#*)\] }
          ;;
        *) return 1 ;;
      esac
    else
      reply="$reply $line"
    fi
  done <"$file"
  [ -n "$chat_id" ] || return 1
  printf '%s\n%s\n' "$chat_id" "$reply"
}

cmd_resolve_reply() {
  local note=${1:-}
  [ -n "$note" ] && [ -f "$note" ] || { usage; exit 2; }

  local parsed chat_id reply
  parsed=$(parse_telegram_note "$note") || {
    printf 'fm-hermes-notify: %s does not match the Hermes/Telegram inbound convention\n' "$note" >&2
    exit 1
  }
  chat_id=$(printf '%s\n' "$parsed" | sed -n '1p')
  reply=$(printf '%s\n' "$parsed" | sed -n '2,$p')
  reply=$(flatten "$reply")

  local best='' best_sent_at=-1 file task status record_chat_id sent_at label rc
  for file in "$NOTIFY_DIR"/*.record; do
    [ -e "$file" ] || continue
    status=$(record_field "$file" status)
    [ "$status" = sent ] || continue
    record_chat_id=$(record_field "$file" chat_id)
    [ "$record_chat_id" = "$chat_id" ] || continue
    task=$(record_field "$file" task)
    [ -n "$task" ] || continue
    rc=0
    "$CAPTAIN_HOLD" open "$task" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || continue
    sent_at=$(record_field "$file" sent_at)
    case "$sent_at" in ''|*[!0-9]*) sent_at=0 ;; esac
    if [ "$sent_at" -ge "$best_sent_at" ]; then
      best=$task
      best_sent_at=$sent_at
      label=$(record_field "$file" label)
    fi
  done

  if [ -z "$best" ]; then
    printf 'fm-hermes-notify: no open Hermes notification correlates to chat %s\n' "$chat_id" >&2
    exit 1
  fi
  [ -n "${label:-}" ] || label=$best
  printf '%s\t%s\t%s\n' "$best" "$reply" "$label"
}

cmd_status() {
  local task=${1:-}
  [ -n "$task" ] || { usage; exit 2; }
  local record="$NOTIFY_DIR/$task.record"
  if [ ! -f "$record" ]; then
    printf 'absent\n'
    exit 0
  fi
  cat "$record"
}

CMD=${1:-}
[ -n "$CMD" ] || { usage; exit 2; }
shift
case "$CMD" in
  register) cmd_register "$@" ;;
  resolve-reply) cmd_resolve_reply "$@" ;;
  status) cmd_status "$@" ;;
  --help|-h) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
