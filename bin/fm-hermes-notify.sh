#!/usr/bin/env bash
# Durable HOME/AWAY Captain-presence routing for Hermes/Telegram, idempotent
# proactive notifications, and deterministic correlation of an inbound
# Telegram reply back to the exact captain hold it answers.
#
# state/captain-presence is the single routing-state record. Its absence or
# invalid content means HOME. HOME suppresses every proactive send while
# keeping `inbound` available. AWAY permits only the explicit `route` classes
# below and active captain holds registered through `register`. This record is
# intentionally unrelated to state/.afk-contract and state/.afk: changing it
# does not change supervision, authority, permissions, SecondMate ownership,
# approvals, logging, or durable queues.
#
# `inbound` accepts the Hermes plugin's existing Telegram note convention.
# It recognizes explicit HOME/AWAY commands and the documented natural-language
# equivalents, persists and acknowledges each mode command over Telegram,
# classifies status requests in either mode, correlates replies to open holds,
# and returns all other text as an ordinary command. It never answers a hold or
# grants authority; its `answer:` TSV still goes through the existing
# fm-captain-hold keyed-answer judgment and intake.
#
# The Telegram acknowledgement of a mode command is purely informational and
# is never allowed to roll back the (already-persisted) mode change: a mode
# command always prints `mode:AWAY`/`mode:HOME` once persistence succeeds.
# When the acknowledgement itself fails to send, `inbound` prints
# `confirmation:failed` and exits 3 - an explicit partial-success result,
# distinct from persistence failure (which exits 1 before ever printing
# `mode:...`) - and durably records the failed acknowledgement so a later
# `confirm-retry` call can resend the exact same text.
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
#   fm-hermes-notify.sh presence [status|home|away]
#   fm-hermes-notify.sh route <class> --message-file <path> --key <key>
#   fm-hermes-notify.sh register <task-id> --reason-file <path> [--label <text>]
#   fm-hermes-notify.sh resolve-reply <note-file>
#   fm-hermes-notify.sh inbound <note-file>
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
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

NOTIFY_DIR="$STATE/hermes-notify"
PRESENCE_RECORD="$STATE/captain-presence"
NOTIFY_SEQ_FILE="$NOTIFY_DIR/.seq"
NOTIFY_SEQ_LOCK="$NOTIFY_DIR/.seq.lock"
CONFIRM_RECORD="$NOTIFY_DIR/.presence-confirm.record"
CONFIRM_LOCK="$NOTIFY_DIR/.presence-confirm.lock"
CAPTAIN_HOLD="$SCRIPT_DIR/fm-captain-hold.sh"
MAX_TEXT_BYTES=4000

usage() {
  cat >&2 <<'EOF'
usage: fm-hermes-notify.sh presence [status|home|away]
       fm-hermes-notify.sh route <class> --message-file <path> --key <key>
       fm-hermes-notify.sh register <task-id> --reason-file <path> [--label <text>]
       fm-hermes-notify.sh resolve-reply <note-file>
       fm-hermes-notify.sh inbound <note-file>
       fm-hermes-notify.sh confirm-retry
       fm-hermes-notify.sh status <task-id>

route classes: approval permission blocker completion failure report status
EOF
}

# Captain presence is notification routing only. It is deliberately separate
# from state/.afk-contract and state/.afk, which change supervision posture.
# Missing, unreadable, malformed, and future-version records all read HOME.
presence_mode() {
  local schema='' mode=''
  [ -f "$PRESENCE_RECORD" ] && [ ! -L "$PRESENCE_RECORD" ] || {
    printf 'HOME\n'
    return 0
  }
  schema=$(sed -n 's/^schema=//p' "$PRESENCE_RECORD" 2>/dev/null | tail -n1)
  mode=$(sed -n 's/^mode=//p' "$PRESENCE_RECORD" 2>/dev/null | tail -n1)
  if [ "$schema" = fm-captain-presence.v1 ] && [ "$mode" = AWAY ]; then
    printf 'AWAY\n'
  else
    printf 'HOME\n'
  fi
}

write_presence() {  # HOME|AWAY
  local mode=$1 tmp
  mkdir -p "$STATE"
  tmp=$(mktemp "$STATE/.captain-presence.staging-XXXXXX") || return 1
  {
    printf 'schema=fm-captain-presence.v1\n'
    printf 'mode=%s\n' "$mode"
    printf 'changed_at=%s\n' "$(date +%s)"
  } >"$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$PRESENCE_RECORD"
}

send_telegram_text() {  # <text>
  local text=$1 chat_id
  chat_id=$(resolve_telegram_chat_id) || return 1
  [ -n "$chat_id" ] || return 2
  hermes send --to "telegram:$chat_id" "$text" >/dev/null 2>&1
}

# Durably records the outcome of the one Telegram acknowledgement that a mode
# command sends, so a delivery failure is never simply lost: cmd_inbound
# reports it as an explicit partial success (the mode change itself is never
# rolled back) and `confirm-retry` can resend the exact persisted text later.
write_confirm_record() {  # <mode> <text> <status>
  local mode=$1 text=$2 status=$3 tmp
  mkdir -p "$NOTIFY_DIR"
  tmp=$(mktemp "$NOTIFY_DIR/.confirm-staging-XXXXXX") || return 1
  {
    printf 'mode=%s\n' "$(flatten "$mode")"
    printf 'status=%s\n' "$(flatten "$status")"
    printf 'text=%s\n' "$(flatten "$text")"
  } >"$tmp"
  mv "$tmp" "$CONFIRM_RECORD"
}

# Writes pending, attempts delivery, then writes sent/failed. Assumes
# CONFIRM_LOCK is already held by the caller - never call this directly.
_send_presence_confirmation_locked() {  # <mode> <text>
  local mode=$1 text=$2
  write_confirm_record "$mode" "$text" pending || return 1
  if send_telegram_text "$text"; then
    write_confirm_record "$mode" "$text" sent
    return 0
  else
    write_confirm_record "$mode" "$text" failed || true
    return 1
  fi
}

# Sends and durably records one mode-change acknowledgement. Returns 0 and
# leaves status=sent on success; returns 1 and leaves status=failed (with the
# exact mode/text preserved for a later retry) on delivery failure. Serialized
# on CONFIRM_LOCK against confirm-retry so a slow, stale retry can never
# clobber a newer mode's just-written confirmation record (the same
# read-decide-send-write race this file's register/route locks already close).
send_presence_confirmation() {  # <mode> <text>
  local mode=$1 text=$2 rc=0
  mkdir -p "$NOTIFY_DIR"
  fm_lock_acquire_wait "$CONFIRM_LOCK"
  _send_presence_confirmation_locked "$mode" "$text" || rc=$?
  fm_lock_release "$CONFIRM_LOCK"
  return "$rc"
}

cmd_presence() {
  local action=${1:-status} prior mode acknowledgement rc=0
  case "$action" in
    status)
      presence_mode
      return 0
      ;;
    home) mode=HOME ;;
    away) mode=AWAY ;;
    *) usage; exit 2 ;;
  esac
  prior=$(presence_mode)
  write_presence "$mode" || {
    printf 'fm-hermes-notify: cannot persist Captain presence mode\n' >&2
    exit 1
  }
  if [ "$prior" = "$mode" ]; then
    acknowledgement="Captain presence is already $mode."
  else
    acknowledgement="Captain presence is now $mode."
  fi
  printf '%s\n' "$acknowledgement"
  # A mode command received locally is still acknowledged locally. The
  # inbound command path additionally transports this exact acknowledgement.
  return "$rc"
}

route_record_path() {  # <class> <key>
  printf '%s/routes/%s--%s.record\n' "$NOTIFY_DIR" "$1" "$2"
}

route_lock_path() {  # <class> <key>
  printf '%s/routes/.lock--%s--%s\n' "$NOTIFY_DIR" "$1" "$2"
}

cmd_route() {
  local class=${1:-} message_file='' key='' message digest record tmp chat_id
  [ -n "$class" ] || { usage; exit 2; }
  shift
  case "$class" in
    approval|permission|blocker|completion|failure|report|status) ;;
    *) printf 'fm-hermes-notify: unsupported route class: %s\n' "$class" >&2; exit 2 ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --message-file) shift; message_file=${1:-} ;;
      --key) shift; key=${1:-} ;;
      *) usage; exit 2 ;;
    esac
    shift
  done
  [ -f "$message_file" ] || { printf 'fm-hermes-notify: --message-file must exist\n' >&2; exit 2; }
  fm_task_id_path_safe "$key" || { printf 'fm-hermes-notify: --key must be a privacy-safe slug\n' >&2; exit 2; }
  if [ "$(presence_mode)" != AWAY ]; then
    printf 'skipped: Captain presence is HOME\n'
    exit 0
  fi
  message=$(cat "$message_file")
  [ -n "${message//[[:space:]]/}" ] || { printf 'fm-hermes-notify: refusing an empty message\n' >&2; exit 2; }
  message=$(truncate_to_max_bytes "$message")
  digest=$(sha256_text "$message")
  record=$(route_record_path "$class" "$key")
  mkdir -p "$NOTIFY_DIR/routes"
  local lock
  lock=$(route_lock_path "$class" "$key")
  fm_lock_acquire_wait "$lock"
  trap 'fm_lock_release "'"$lock"'"' EXIT
  if [ -f "$record" ] && [ "$(record_field "$record" digest)" = "$digest" ] \
      && [ "$(record_field "$record" status)" = sent ]; then
    printf 'duplicate: %s/%s already sent\n' "$class" "$key"
    exit 0
  fi
  chat_id=$(resolve_telegram_chat_id) || exit 1
  if [ -z "$chat_id" ]; then
    printf 'skipped: hermes/telegram not configured on this home\n'
    exit 0
  fi
  tmp=$(mktemp "$NOTIFY_DIR/routes/.staging-XXXXXX") || exit 1
  {
    printf 'class=%s\nkey=%s\ndigest=%s\nstatus=pending\nchat_id=%s\n' "$class" "$key" "$digest" "$chat_id"
  } >"$tmp"
  mv "$tmp" "$record"
  if hermes send --to "telegram:$chat_id" "$message" >/dev/null 2>&1; then
    tmp=$(mktemp "$NOTIFY_DIR/routes/.staging-XXXXXX") || exit 1
    {
      printf 'class=%s\nkey=%s\ndigest=%s\nstatus=sent\nchat_id=%s\nsent_at=%s\n' \
        "$class" "$key" "$digest" "$chat_id" "$(date +%s)"
    } >"$tmp"
    mv "$tmp" "$record"
    printf 'sent: %s/%s -> telegram:%s\n' "$class" "$key" "$chat_id"
  else
    sed 's/^status=pending$/status=failed/' "$record" >"$tmp" 2>/dev/null || true
    [ -n "${tmp:-}" ] && [ -f "$tmp" ] && mv "$tmp" "$record"
    printf 'fm-hermes-notify: hermes send failed for %s/%s\n' "$class" "$key" >&2
    exit 1
  fi
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

# Trims text to MAX_TEXT_BYTES actual bytes, not locale-dependent characters,
# matching Telegram's real per-message byte ceiling. `cut -c` counts locale
# characters by default, which under a UTF-8 locale lets multi-byte text
# survive well past the byte ceiling this promises.
truncate_to_max_bytes() {  # <text>
  local text=$1
  local LC_ALL=C
  printf '%s' "$text" | cut -c1-"$MAX_TEXT_BYTES"
}

# A strictly increasing counter, shared across every route/register send in
# this NOTIFY_DIR, that records true send order. sent_at alone (whole-second
# `date +%s`) cannot break a tie between two sends in the same wall-clock
# second; this can, without depending on nanosecond clock resolution that
# isn't portable across this project's supported platforms.
next_seq() {
  local cur=0 tmp
  mkdir -p "$NOTIFY_DIR"
  fm_lock_acquire_wait "$NOTIFY_SEQ_LOCK"
  [ -f "$NOTIFY_SEQ_FILE" ] && cur=$(cat "$NOTIFY_SEQ_FILE" 2>/dev/null)
  case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  cur=$((cur + 1))
  tmp=$(mktemp "$NOTIFY_DIR/.seq.staging-XXXXXX") || {
    fm_lock_release "$NOTIFY_SEQ_LOCK"
    return 1
  }
  printf '%s\n' "$cur" >"$tmp"
  mv "$tmp" "$NOTIFY_SEQ_FILE"
  fm_lock_release "$NOTIFY_SEQ_LOCK"
  printf '%s\n' "$cur"
}

record_path() {  # <task-id>
  printf '%s/%s.record\n' "$NOTIFY_DIR" "$1"
}

register_lock_path() {  # <task-id>
  printf '%s/.lock.%s\n' "$NOTIFY_DIR" "$1"
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
    printf 'task=%s\n' "$(flatten "$task")"
    printf 'chat_id=%s\n' "$(flatten "$chat_id")"
    printf 'label=%s\n' "$(flatten "$label")"
    printf 'reason_digest=%s\n' "$(flatten "$digest")"
    printf 'lifecycle=%s\n' "$(flatten "$lifecycle")"
    printf 'status=%s\n' "$(flatten "$status")"
    printf 'created_at=%s\n' "$(flatten "$created_at")"
    if [ -n "$sent_at" ]; then
      printf 'sent_at=%s\n' "$(flatten "$sent_at")"
      printf 'seq=%s\n' "$(next_seq)"
    fi
    [ -z "$answered_at" ] || printf 'answered_at=%s\n' "$(flatten "$answered_at")"
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
  reason=$(truncate_to_max_bytes "$reason")
  [ -n "$label" ] || label=$task

  local identity rc=0
  identity=$("$CAPTAIN_HOLD" open "$task" --identity 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'fm-hermes-notify: %s is not an active captain hold (open check exit %s)\n' "$task" "$rc" >&2
    exit 1
  fi
  if [ "$(presence_mode)" != AWAY ]; then
    printf 'skipped: Captain presence is HOME\n'
    exit 0
  fi

  local chat_id
  chat_id=$(resolve_telegram_chat_id) || exit 1
  if [ -z "$chat_id" ]; then
    printf 'skipped: hermes/telegram not configured on this home\n'
    exit 0
  fi

  local record="$NOTIFY_DIR/$task.record" prior_status='' prior_lifecycle='' created_at=''
  local lock
  lock=$(register_lock_path "$task")
  mkdir -p "$NOTIFY_DIR"
  fm_lock_acquire_wait "$lock"
  trap 'fm_lock_release "'"$lock"'"' EXIT
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

  local best='' best_sent_at=-1 best_seq=-1 file task status record_chat_id sent_at seq label rc
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
    seq=$(record_field "$file" seq)
    case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
    # sent_at alone (whole-second resolution) cannot tell two same-second
    # sends apart; seq (true send order, assigned once per record at the
    # moment it becomes sent) breaks that tie deterministically instead of
    # falling back to directory-glob (task id alphabetical) iteration order.
    if [ "$sent_at" -gt "$best_sent_at" ] \
        || { [ "$sent_at" -eq "$best_sent_at" ] && [ "$seq" -gt "$best_seq" ]; }; then
      best=$task
      best_sent_at=$sent_at
      best_seq=$seq
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

cmd_inbound() {
  local note=${1:-} parsed chat_id text normalized acknowledgement correlated rc=0
  [ -n "$note" ] && [ -f "$note" ] || { usage; exit 2; }
  parsed=$(parse_telegram_note "$note") || {
    printf 'fm-hermes-notify: %s does not match the Hermes/Telegram inbound convention\n' "$note" >&2
    exit 1
  }
  chat_id=$(printf '%s\n' "$parsed" | sed -n '1p')
  text=$(printf '%s\n' "$parsed" | sed -n '2,$p')
  text=$(flatten "$text")
  normalized=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' \
    | sed "s/’/'/g; s/^[[:space:]]*//; s/[.!][[:space:]]*$//")

  case "$normalized" in
    'captain away'|'i am heading out, use telegram'|'i am heading out use telegram'|"i'm heading out, use telegram"|"i'm heading out use telegram"|'heading out, use telegram'|'use telegram while i am away')
      cmd_presence away >/dev/null || exit 1
      acknowledgement='Captain presence is now AWAY. Proactive Telegram routing is enabled.'
      printf 'mode:AWAY\n'
      if send_presence_confirmation AWAY "$acknowledgement"; then
        printf 'confirmation:sent\n'
        return 0
      else
        printf 'fm-hermes-notify: mode changed to AWAY, but the Telegram acknowledgement failed; it will be retried via confirm-retry\n' >&2
        printf 'confirmation:failed\n'
        exit 3
      fi
      ;;
    'captain home'|'i am back home, stop proactive telegram notifications'|'i am back home stop proactive telegram notifications'|"i'm back home, stop proactive telegram notifications"|"i'm back home stop proactive telegram notifications"|'back home, stop proactive telegram notifications'|'stop proactive telegram notifications')
      cmd_presence home >/dev/null || exit 1
      acknowledgement='Captain presence is now HOME. Proactive Telegram routing is disabled.'
      printf 'mode:HOME\n'
      if send_presence_confirmation HOME "$acknowledgement"; then
        printf 'confirmation:sent\n'
        return 0
      else
        printf 'fm-hermes-notify: mode changed to HOME, but the Telegram acknowledgement failed; it will be retried via confirm-retry\n' >&2
        printf 'confirmation:failed\n'
        exit 3
      fi
      ;;
    'status'|'status report'|'send status'|'send me a status report'|'what is the status')
      printf 'request:status\t%s\n' "$text"
      return 0
      ;;
  esac

  correlated=$("$0" resolve-reply "$note" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'answer:%s\n' "$correlated"
  else
    printf 'command:%s\n' "$text"
  fi
}

cmd_confirm_retry() {
  local status mode text rc=0
  mkdir -p "$NOTIFY_DIR"
  fm_lock_acquire_wait "$CONFIRM_LOCK"
  status=$(record_field "$CONFIRM_RECORD" status)
  if [ "$status" != failed ]; then
    fm_lock_release "$CONFIRM_LOCK"
    printf 'confirmation:none\n'
    return 0
  fi
  mode=$(record_field "$CONFIRM_RECORD" mode)
  text=$(record_field "$CONFIRM_RECORD" text)
  _send_presence_confirmation_locked "$mode" "$text" || rc=$?
  fm_lock_release "$CONFIRM_LOCK"
  if [ "$rc" -eq 0 ]; then
    printf 'confirmation:sent\n'
    return 0
  else
    printf 'fm-hermes-notify: retry failed to deliver the pending %s confirmation on Telegram\n' "$mode" >&2
    printf 'confirmation:failed\n'
    exit 3
  fi
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
  presence) cmd_presence "$@" ;;
  route) cmd_route "$@" ;;
  register) cmd_register "$@" ;;
  resolve-reply) cmd_resolve_reply "$@" ;;
  inbound) cmd_inbound "$@" ;;
  confirm-retry) cmd_confirm_retry "$@" ;;
  status) cmd_status "$@" ;;
  --help|-h) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
