#!/usr/bin/env bash
# One bounded long-poll of the Telegram Bot API for the private paired bridge.
#
# Inert by default: a HARD no-op (exit 0, no output) unless the bridge is
# configured with a non-empty FM_TELEGRAM_BOT_TOKEN in the home's .env or the
# environment. The watcher invokes this trusted repository script directly, and
# only after state/telegram-watch.check.sh matches its expected byte-static
# identity shim. Its contract is "output => wake firstmate, silence => keep
# sleeping", so the no-op keeps the watcher behaving exactly as today until a
# home deliberately opts in.
#
# Printed lines (each becomes part of one watcher check: wake payload):
#   telegram-message <request_id>   a newly accepted message is in the inbox
#   telegram-paired <label>         a one-time pairing code was just redeemed
#   telegram-error <message>        a rate-limited configuration or API problem
# Silence means nothing needs firstmate this cycle.
#
# WHO IS HEARD
#   Only the single pinned peer. A message is accepted only when the chat type is
#   private, the sender is not a bot, and BOTH the immutable numeric user id and
#   the chat id equal the pinned pairing (bin/fm-tg-pair.sh). Usernames and
#   display names are never read, so a renamed or impersonated account changes
#   nothing. Everything else - unpaired private chats, groups, supergroups,
#   channels, other bots - is dropped without a reply and without disclosing that
#   anything exists behind the bot.
#
#   The one exception is redeeming a pairing code, handled here because it must
#   work before any peer is pinned. A failed or replayed code is answered with
#   SILENCE, never a message: the bridge sends nothing to an unpaired chat, so an
#   invalid attempt cannot be used as an oracle and cannot be amplified into an
#   outbound-message flood.
#
# EXACTLY-ONCE DELIVERY
#   Telegram redelivers every update until an offset past it is confirmed, so a
#   crash between claiming work and confirming the offset must neither duplicate
#   nor drop it. Per update, in this order:
#     1. skip immediately if state/telegram/seen/<update_id>.json already exists;
#     2. publish the inbox entry with an atomic create-only claim;
#     3. atomically claim the seen marker;
#     4. print the wake line only for a newly claimed marker.
#   Only after the whole batch is processed is the new offset written. Every
#   crash point is then safe: a crash before (3) redelivers and step (2) finds
#   its own entry already there; a crash after (3) redelivers and step (1) drops
#   it, so an entry the agent already drained is never resurrected. A crash
#   between (3) and (4) would leave a pending entry with no wake, so a bounded
#   recovery sweep re-announces inbox entries that have gone unhandled for
#   FM_TELEGRAM_RECOVERY_SECS, at most once per window and at most
#   FM_TELEGRAM_RECOVERY_MAX times per entry. An entry that outlives that budget
#   is reported once as a telegram-error and then never re-announced, but is
#   kept in the inbox: a request that was never answered is not dropped.
#
# The message body is untrusted input at every step. It is normalized (see
# fmtg_normalize_text_program), size-bounded, written to a private file as a JSON
# string by jq, and never interpolated into a shell command, a path, or a prompt.
#
# Config, state schema, and setup live in docs/configuration.md "Telegram bridge
# (.env)"; message policy lives in the agent-only `telegram-respond` skill.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"

fmtg_load_config

TG_DIR=$(fmtg_dir)
ERROR_FILE="$TG_DIR/poll.error"

emit_error_once() {
  local msg=$1
  if fm_private_artifact_file_valid "$TG_DIR" poll.error 600 \
    && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" \
    | fm_private_artifact_publish_stdin "$TG_DIR" poll.error 600 2>/dev/null || true
  printf 'telegram-error %s\n' "$msg"
}

clear_error() {
  fm_private_artifact_dir_device "$TG_DIR" >/dev/null 2>&1 || return 0
  rm -f -- "$ERROR_FILE" 2>/dev/null || true
}

# A malformed token is a configuration problem worth one report; an absent token
# is the inert default and must stay completely silent.
if ! fmtg_active; then
  if [ -n "${FMTG_TOKEN_BAD:-}" ]; then
    emit_error_once "bot token is not in BotFather's <id>:<secret> form"
  fi
  exit 0
fi

command -v jq   >/dev/null 2>&1 || { emit_error_once "missing jq";   exit 0; }
command -v curl >/dev/null 2>&1 || { emit_error_once "missing curl"; exit 0; }

NOW=$(fmtg_now) || exit 0
fmtg_budget_open "$NOW"
fmtg_prune "$NOW"

INBOX="$TG_DIR/inbox"
SEEN="$TG_DIR/seen"

BODY_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tg-poll.XXXXXX") || exit 0
REQ_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tg-req.XXXXXX") || { rm -f "$BODY_FILE"; exit 0; }
trap 'rm -f "$BODY_FILE" "$REQ_FILE"' EXIT

OFFSET=$(fmtg_offset_get)

# How long Telegram may hold this connection open. The configured value is a
# ceiling, not an entitlement: whatever the prune already spent is gone from the
# same check budget, so holding the connection for the full ceiling would push
# curl's own deadline past the watcher's kill.
POLL_SECS=$(( $(fmtg_budget_remaining) - FMTG_BUDGET_RESERVE ))
[ "$POLL_SECS" -ge 0 ] || POLL_SECS=0
[ "$POLL_SECS" -le "$FMTG_POLL_TIMEOUT" ] || POLL_SECS=$FMTG_POLL_TIMEOUT

# allowed_updates pins the subscription to plain messages, so edited messages,
# channel posts, callback queries, and every other update type are refused by
# Telegram itself and never reach this client.
jq -cn --argjson offset "$OFFSET" --argjson timeout "$POLL_SECS" \
  '{offset:$offset, limit:25, timeout:$timeout, allowed_updates:["message"]}' \
  > "$REQ_FILE" || exit 0

CODE=$(fmtg_api_call getUpdates "$REQ_FILE" "$BODY_FILE") || exit 0
case "$CODE" in
  200) ;;
  401|403) emit_error_once "Telegram rejected the bot token"; exit 0 ;;
  404) emit_error_once "Telegram bot API returned HTTP 404"; exit 0 ;;
  # 409 means another process is already long-polling this same bot. Two homes
  # sharing one token is a real misconfiguration, not a transient error.
  409) emit_error_once "another process is polling this bot; one bot token belongs to one home"; exit 0 ;;
  429) exit 0 ;;
  *) exit 0 ;;
esac

jq -e '.ok == true and (.result | type == "array")' "$BODY_FILE" >/dev/null 2>&1 || {
  emit_error_once "Telegram bot API returned an unexpected response"
  exit 0
}
clear_error

PEER=$(fmtg_peer_get 2>/dev/null) || PEER=
PEER_USER=
PEER_CHAT=
PEER_LABEL=
PEER_PROJECT=
if [ -n "$PEER" ]; then
  PEER_USER=$(printf '%s' "$PEER" | jq -r '.user_id // empty')
  PEER_CHAT=$(printf '%s' "$PEER" | jq -r '.chat_id // empty')
  PEER_LABEL=$(printf '%s' "$PEER" | jq -r '.label // empty')
  PEER_PROJECT=$(printf '%s' "$PEER" | jq -r '.project // empty')
fi

WAKE_LINES=
add_wake() {
  WAKE_LINES="${WAKE_LINES}$1
"
}

# Redeem a one-time pairing code from an unpaired private chat. Sets PAIRED_LABEL
# and the pinned-peer variables on success and returns 0; returns 1 otherwise.
# Deliberately not a command substitution: a subshell would discard the pinned
# peer, leaving the rest of this batch and the confirmation without a target.
#
# Silence is the only response to any failure, so nothing here can confirm or
# deny that an offer is open, that a label exists, or that this bot belongs to
# anything.
PAIRED_LABEL=
try_pairing() {  # <code> <user_id> <chat_id>
  local code=$1 user=$2 chat=$3 offer expires salt want got label project
  PAIRED_LABEL=
  offer=$(fmtg_pairing_get 2>/dev/null) || return 1
  expires=$(printf '%s' "$offer" | jq -r '.expires_at // 0')
  case "$expires" in ''|*[!0-9]*) return 1 ;; esac
  [ "$NOW" -le "$expires" ] || return 1
  # Consume one attempt before comparing, so a guessing loop exhausts the offer's
  # budget whether or not it ever guesses right.
  fmtg_pairing_attempt >/dev/null 2>&1 || return 1
  salt=$(printf '%s' "$offer" | jq -r '.salt // ""')
  want=$(printf '%s' "$offer" | jq -r '.code_sha256 // ""')
  [ -n "$salt" ] && [ -n "$want" ] || return 1
  got=$(fmtg_code_hash "$salt" "$code") || return 1
  [ "$got" = "$want" ] || return 1
  label=$(printf '%s' "$offer" | jq -r '.label // ""')
  project=$(printf '%s' "$offer" | jq -r '.project // ""')
  fmtg_peer_set "$label" "$project" "$user" "$chat" "$NOW" || return 1
  fmtg_pairing_clear || true
  PEER_USER=$user
  PEER_CHAT=$chat
  PEER_LABEL=$label
  PEER_PROJECT=$project
  PAIRED_LABEL=$label
}

process_update() {  # <update-json>
  local update=$1 uid rid chat_type is_bot from_id chat_id kind unsupported text raw_len entry rc
  uid=$(printf '%s' "$update" | jq -r '.update_id // empty')
  fmtg_update_id_valid "$uid" || return 0

  # (1) Already handled in an earlier poll: never process or resurrect it.
  if fm_private_artifact_file_valid "$SEEN" "$uid.json" 600; then
    return 0
  fi

  chat_type=$(printf '%s' "$update" | jq -r '.message.chat.type // empty')
  [ "$chat_type" = private ] || { fmtg_seen_claim "$uid" "$NOW" >/dev/null 2>&1; return 0; }
  is_bot=$(printf '%s' "$update" | jq -r '.message.from.is_bot // false')
  [ "$is_bot" != true ] || { fmtg_seen_claim "$uid" "$NOW" >/dev/null 2>&1; return 0; }
  from_id=$(printf '%s' "$update" | jq -r '.message.from.id // empty')
  chat_id=$(printf '%s' "$update" | jq -r '.message.chat.id // empty')
  if ! fmtg_chat_id_valid "$from_id" || ! fmtg_chat_id_valid "$chat_id"; then
    fmtg_seen_claim "$uid" "$NOW" >/dev/null 2>&1
    return 0
  fi

  text=$(printf '%s' "$update" | jq -r "(.message.text // \"\") | $(fmtg_normalize_text_program)")

  if [ -z "$PEER_USER" ]; then
    # Unpaired. The only thing an unknown chat can do is redeem a code.
    PAIRED_LABEL=
    case "$text" in
      /start\ *) try_pairing "${text#/start }" "$from_id" "$chat_id" || PAIRED_LABEL= ;;
    esac
    fmtg_seen_claim "$uid" "$NOW" >/dev/null 2>&1
    if [ -n "$PAIRED_LABEL" ]; then
      send_pairing_confirmation
      add_wake "telegram-paired $PAIRED_LABEL"
    fi
    return 0
  fi

  # Paired: identity is the pinned numeric pair, never a name.
  if [ "$from_id" != "$PEER_USER" ] || [ "$chat_id" != "$PEER_CHAT" ]; then
    fmtg_seen_claim "$uid" "$NOW" >/dev/null 2>&1
    return 0
  fi

  # A pairing command from the already-pinned peer is a no-op, and its code is
  # never written into the inbox where it would become agent-visible material.
  case "$text" in
    /start|/start\ *)
      fmtg_seen_claim "$uid" "$NOW" >/dev/null 2>&1
      return 0
      ;;
  esac

  kind=text
  unsupported=
  if [ -z "$text" ]; then
    kind=unsupported
    unsupported=$(printf '%s' "$update" | jq -r '
      .message as $m
      | ["photo","document","voice","video","video_note","audio","animation",
         "sticker","contact","location","venue","poll","dice","game","story",
         "paid_media","new_chat_members","left_chat_member"]
      | map(select($m[.] != null))
      | (.[0] // "non-text content")')
  else
    raw_len=$(printf '%s' "$update" | jq -r '(.message.text // "") | length')
    case "$raw_len" in ''|*[!0-9]*) raw_len=0 ;; esac
    if [ "$raw_len" -gt "$FMTG_MAX_TEXT" ]; then
      kind=oversized
      text=
    fi
  fi

  if ! fmtg_rate_allow "$NOW"; then
    fmtg_seen_claim "$uid" "$NOW" >/dev/null 2>&1
    emit_error_once "message rate limit reached; later messages are being dropped this window"
    return 0
  fi

  rid="tg-$uid"
  fmtg_request_id_valid "$rid" || return 0

  # The stored entry deliberately carries no username, display name, or quoted
  # parent message: identity is the pinned numeric pair, and anything else would
  # be untrusted text masquerading as provenance.
  entry=$(jq -cn \
    --arg rid "$rid" --arg uid "$uid" --arg kind "$kind" \
    --arg unsupported "$unsupported" --arg text "$text" \
    --arg label "$PEER_LABEL" --arg project "$PEER_PROJECT" \
    --argjson chat "$chat_id" --argjson msg "$(printf '%s' "$update" | jq -r '.message.message_id // 0')" \
    --argjson at "$NOW" \
    '{request_id:$rid, update_id:$uid, message_id:$msg, chat_id:$chat,
      label:$label, project:$project, kind:$kind, received_at:$at}
     | if $kind == "text" then .text = $text
       elif $kind == "unsupported" then .unsupported = $unsupported
       else . end') || return 0

  # (2) create-only inbox claim, then (3) the seen marker, then (4) the wake.
  printf '%s\n' "$entry" | fm_private_artifact_publish_stdin_once "$INBOX" "$rid.json" 600
  rc=$?
  if [ "$rc" -eq 2 ]; then
    emit_error_once "cannot write the message inbox"
    return 1
  fi
  fmtg_context_set "$rid" "$chat_id" \
    "$(printf '%s' "$update" | jq -r '.message.message_id // 0')" "$NOW" 2>/dev/null || true
  fmtg_seen_claim "$uid" "$NOW" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || return 0
  add_wake "telegram-message $rid"
}

send_pairing_confirmation() {
  local out
  out=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tg-pair.XXXXXX") || return 0
  # Deliberately bare: it confirms the link and nothing about what is behind it.
  fmtg_send_text "$PEER_CHAT" "Connected. You can send your requests here." "$out" >/dev/null 2>&1 || true
  rm -f -- "$out"
}

NEXT=$OFFSET
COUNT=$(jq -r '.result | length' "$BODY_FILE" 2>/dev/null) || COUNT=0
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
i=0
while [ "$i" -lt "$COUNT" ]; do
  UPDATE=$(jq -c --argjson i "$i" '.result[$i]' "$BODY_FILE" 2>/dev/null) || break
  UID_RAW=$(printf '%s' "$UPDATE" | jq -r '.update_id // empty')
  if ! process_update "$UPDATE"; then
    # A durable write failed. Leave the offset where it is so Telegram redelivers
    # this update rather than losing it, and stop the batch here.
    break
  fi
  if fmtg_update_id_valid "$UID_RAW" && [ "$UID_RAW" -ge "$NEXT" ]; then
    NEXT=$(( UID_RAW + 1 ))
  fi
  i=$(( i + 1 ))
done

# The offset is confirmed only after the whole processed prefix is durable.
if [ "$NEXT" != "$OFFSET" ]; then
  fmtg_offset_set "$TG_DIR" "$NEXT" || emit_error_once "cannot record the Telegram update offset"
fi

# Bounded recovery sweep: re-announce inbox entries that were claimed but whose
# wake was lost (a crash between the seen claim and the wake line). Bounded
# twice, so a genuinely stuck drain cannot become a wake loop: at most one sweep
# per recovery window, and at most FMTG_RECOVERY_MAX re-announcements per entry
# ever. An entry that survives its budget - a reply that keeps failing, a turn
# interrupted after the claim - is reported once and then stays silent. It is
# deliberately NOT deleted: an undelivered request is kept in the inbox, counted
# by `fm-tg-pair.sh status`, and drained on the next wake for any other reason.
recovery_due() {
  local last
  if fm_private_artifact_file_valid "$TG_DIR" recovery.json 600; then
    last=$(jq -r '.last_sweep // 0' "$TG_DIR/recovery.json" 2>/dev/null) || last=0
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $(( NOW - last )) -ge "$FMTG_RECOVERY_SECS" ] || return 1
  fi
  jq -cn --argjson at "$NOW" '{last_sweep:$at}' \
    | fm_private_artifact_publish_stdin "$TG_DIR" recovery.json 600 || return 1
}

if [ -z "$WAKE_LINES" ] && [ -d "$INBOX" ]; then
  STRANDED=
  STRANDED_N=0
  for f in "$INBOX"/*.json; do
    [ -e "$f" ] || continue
    [ "$STRANDED_N" -lt 5 ] || break
    AGE_AT=$(jq -r '.received_at // 0' "$f" 2>/dev/null) || continue
    case "$AGE_AT" in ''|*[!0-9]*) continue ;; esac
    [ $(( NOW - AGE_AT )) -ge "$FMTG_RECOVERY_SECS" ] || continue
    RID=$(jq -r '.request_id // empty' "$f" 2>/dev/null) || continue
    fmtg_request_id_valid "$RID" || continue
    # An entry past its budget was already reported once and must never wake
    # firstmate again; it stays in the inbox to be drained.
    [ "$(fmtg_announce_count "$RID")" -le "$FMTG_RECOVERY_MAX" ] || continue
    STRANDED="${STRANDED}$RID
"
    STRANDED_N=$(( STRANDED_N + 1 ))
  done
  # The budget is spent only when a sweep actually announces, so a cycle that
  # finds nothing due leaves every entry's remaining attempts untouched.
  if [ -n "$STRANDED" ] && recovery_due; then
    while IFS= read -r RID; do
      [ -n "$RID" ] || continue
      N=$(fmtg_announce_bump "$RID" "$NOW") || continue
      if [ "$N" -le "$FMTG_RECOVERY_MAX" ]; then
        add_wake "telegram-message $RID"
      else
        add_wake "telegram-error $RID stayed undelivered across $FMTG_RECOVERY_MAX re-announcements; it is kept in the inbox but will not wake firstmate again"
      fi
    done < <(printf '%s' "$STRANDED")
  fi
fi

[ -n "$WAKE_LINES" ] || exit 0
printf '%s' "$WAKE_LINES"
