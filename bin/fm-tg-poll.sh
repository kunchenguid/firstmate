#!/usr/bin/env bash
# One short-poll of Telegram for new messages from the captain.
#
# Inert by default: a HARD no-op (exit 0, no output) unless Telegram mode is
# configured via a non-empty FMTG_BOT_TOKEN (from the home's .env or the
# environment). This script is the body of the watcher check shim
# state/tg-watch.check.sh, where the contract is "output => wake firstmate,
# silence => keep sleeping", so the no-op keeps the watcher behaving exactly
# as today until a user opts in.
#
# Behavior when Telegram mode is on:
#   No new messages              -> print nothing, exit 0 (no wake)
#   auth/config errors           -> print one rate-limited diagnostic
#   a message from an allowed user -> stash the full Update object to
#       state/tg-inbox/<update_id>.json and print one compact line
#       "tg-message <update_id>" (which becomes the watcher's check: wake payload)
#   a message from an unknown user -> send a polite decline once, skip
#
# Config (home .env or env): FMTG_BOT_TOKEN (required),
# FMTG_ALLOWED_USERS (required, comma-separated Telegram user IDs).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"

fmtg_load_config
# Hard no-op when Telegram mode is off.
[ -n "$FMTG_TOKEN" ] || exit 0

ERROR_FILE="$STATE/tg-poll.error"
OFFSET_FILE="$STATE/tg-poll.offset"

emit_error_once() {
  local msg=$1
  mkdir -p "$STATE" 2>/dev/null || true
  if [ -f "$ERROR_FILE" ] && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" > "$ERROR_FILE" 2>/dev/null || true
  printf 'tg-mode-error %s\n' "$msg"
}

clear_error() {
  rm -f "$ERROR_FILE" 2>/dev/null || true
}

# Check if a user id is in the allowed list.
is_allowed_user() {
  local uid=$1 allowed saved_ifs
  [ -n "$FMTG_ALLOWED" ] || return 1

  saved_ifs=$IFS
  IFS=,
  # shellcheck disable=SC2086
  set -- $FMTG_ALLOWED
  IFS=$saved_ifs
  for allowed in "$@"; do
    allowed=$(printf '%s' "$allowed" | tr -d '[:space:]')
    [ "$allowed" = "$uid" ] && return 0
  done
  return 1
}

command -v curl >/dev/null 2>&1 || { emit_error_once "missing curl"; exit 0; }
command -v jq   >/dev/null 2>&1 || { emit_error_once "missing jq"; exit 0; }

# Read last processed offset. Telegram update_ids start at a positive number
# and increase sequentially. offset = last_seen_id + 1 confirms all prior.
offset=0
if [ -f "$OFFSET_FILE" ]; then
  offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
  case "$offset" in ''|*[!0-9]*) offset=0 ;; esac
fi

FMTG_RESPONSE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-tg-poll.XXXXXX") || exit 0
trap 'rm -f "$FMTG_RESPONSE_FILE"' EXIT

if ! updates=$(fmtg_get_updates "$offset"); then
  # Transport or API error: emit once, no wake this cycle.
  emit_error_once "getUpdates failed"
  exit 0
fi

# Empty result: nothing pending.
[ -n "$updates" ] || { clear_error; exit 0; }

update_count=$(printf '%s' "$updates" | jq '.result | length' 2>/dev/null) || update_count=0
case "$update_count" in ''|*[!0-9]*) update_count=0 ;; esac
[ "$update_count" -gt 0 ] || { clear_error; exit 0; }

any_stashed=0
max_update_id=0

idx=0
while [ "$idx" -lt "$update_count" ]; do
  update=$(printf '%s' "$updates" | jq -c ".result[$idx]" 2>/dev/null) || { idx=$((idx + 1)); continue; }
  uid=$(printf '%s' "$update" | jq -r '.update_id // empty' 2>/dev/null) || uid=
  [ -n "$uid" ] || { idx=$((idx + 1)); continue; }

  # Track max update_id for offset advancement.
  [ "$uid" -gt "$max_update_id" ] 2>/dev/null && max_update_id=$uid

  # Extract the message. We only subscribed to "message" updates.
  msg=$(printf '%s' "$update" | jq -c '.message // empty' 2>/dev/null) || msg=
  [ -n "$msg" ] || { idx=$((idx + 1)); continue; }

  # Check sender is allowed.
  from_id=$(printf '%s' "$msg" | jq -r '.from.id // empty' 2>/dev/null) || from_id=
  if [ -z "$from_id" ] || ! is_allowed_user "$from_id"; then
    # Unknown sender: send a polite decline once, then skip.
    chat_id=$(printf '%s' "$msg" | jq -r '.chat.id // empty' 2>/dev/null) || chat_id=
    if [ -n "$chat_id" ] && [ -z "$FMTG_DRY" ]; then
      decline_file="$STATE/tg-declined-$from_id"
      if [ ! -f "$decline_file" ]; then
        msg_text="Sorry, this bot is private. Only the captain can use it."
        # Send decline; ignore failures.
        tmp_decline=$(mktemp "${TMPDIR:-/tmp}/fm-tg-decline.XXXXXX") || true
        if [ -n "$tmp_decline" ]; then
          printf '%s\n' "$msg_text" > "$tmp_decline"
          FMTG_RESPONSE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-tg-resp.XXXXXX") || true
          if [ -n "$FMTG_RESPONSE_FILE" ]; then
            fmtg_send_message "$chat_id" "$tmp_decline" >/dev/null 2>&1 || true
            rm -f "$FMTG_RESPONSE_FILE"
          fi
          rm -f "$tmp_decline"
        fi
        touch "$decline_file" 2>/dev/null || true
      fi
    fi
    idx=$((idx + 1))
    continue
  fi

  # Check for non-empty text.
  text=$(printf '%s' "$msg" | jq -r '(.text // "") | gsub("[[:space:]]+"; " ") | gsub("^ +| +$"; "")' 2>/dev/null) || text=
  if [ -z "$text" ]; then
    idx=$((idx + 1))
    continue
  fi

  # Defend the inbox filename.
  case "$uid" in
    ''|.*|*[!A-Za-z0-9._-]*) idx=$((idx + 1)); continue ;;
  esac

  # Stash the full update atomically.
  INBOX="$STATE/tg-inbox"
  mkdir -p "$INBOX" 2>/dev/null || { emit_error_once "cannot create inbox"; idx=$((idx + 1)); continue; }
  if printf '%s' "$update" | jq '.' > "$INBOX/$uid.json.tmp" 2>/dev/null; then
    if ! mv -f "$INBOX/$uid.json.tmp" "$INBOX/$uid.json" 2>/dev/null; then
      rm -f "$INBOX/$uid.json.tmp"
      emit_error_once "cannot write inbox"
      idx=$((idx + 1)); continue
    fi
  else
    rm -f "$INBOX/$uid.json.tmp"
    emit_error_once "cannot write inbox"
    idx=$((idx + 1)); continue
  fi

  any_stashed=1
  idx=$((idx + 1))
done

# Advance the offset cursor to confirm processed updates.
if [ "$max_update_id" -gt 0 ] 2>/dev/null; then
  printf '%s\n' "$((max_update_id + 1))" > "$OFFSET_FILE" 2>/dev/null || true
fi

clear_error

# Only wake firstmate if we stashed at least one message.
if [ "$any_stashed" -eq 1 ]; then
  # Print all stashed update IDs so the wake payload lists them.
  for f in "$STATE/tg-inbox"/*.json; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .json)
    case "$base" in
      ''|.*|*[!A-Za-z0-9._-]*) continue ;;
    esac
    printf 'tg-message %s\n' "$base"
  done
fi
