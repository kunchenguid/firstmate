#!/usr/bin/env bash
# Telegram adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-telegram.sh arm
#   fm-procevent-telegram.sh retire
#   fm-procevent-telegram.sh source-id
#   fm-procevent-telegram.sh poll
#   fm-procevent-telegram.sh classify <result-file>
#   fm-procevent-telegram.sh terminal <result-file>
#   fm-procevent-telegram.sh silent   <result-file>
#
# arm        Register this home's Telegram collector with bin/fm-procevent.sh, so
#            the watcher keeps a collector alive outside firstmate's turn.
# poll       The registered listener command `arm` publishes, never a command to
#            run in a conversational turn. It long-polls Telegram, turns allowed
#            messages into durable captain notes, and exits with a result.
# classify   Print what a handler should act on: unconfigured, error, disabled,
#            busy, idle, or unknown.
# terminal   Exit 0 only when the bridge has been switched off, so removing the
#            token retires the registration instead of leaving a dead poller.
# silent     Exit 0 for a result that carries no news, so a quiet collection
#            cycle never puts a wake in front of firstmate.
#
# WHY THERE IS NO NEW SUPERVISION HERE. A long-poll cannot live inside a
# conversational turn, and this operation already has a generic runner for
# exactly that shape. This adapter therefore supplies only what is specific to
# Telegram - source identity, the argv to run, and how to read a result - while
# ownership, durable capture, publication, and restart recovery stay in
# bin/fm-procevent.sh. Nothing here is a second control plane.
#
# WHY getUpdates AND NOT setWebhook. A webhook needs a publicly reachable HTTPS
# endpoint, which a personal machine does not have and should not grow just to
# receive a handful of messages. getUpdates needs nothing but outbound HTTPS, and
# because Telegram retains undelivered updates for 24 hours, a message sent while
# this machine was asleep is collected on the next poll rather than lost. The two
# mechanisms are mutually exclusive at the API, so this adapter never calls
# setWebhook and a home that has one set must delete it first.
#
# THE ALLOWLIST IS THE SECURITY BOUNDARY. Anyone who discovers the bot's handle
# can message it, so without an authorization check any stranger could queue work
# into this operation's inbox. A message is turned into a note ONLY when its chat
# id equals the configured TELEGRAM_ALLOWED_CHAT_ID. Everything else is consumed
# and dropped: no note, no wake, no reply, and no echo of its text anywhere.
#
# INBOUND TEXT IS UNTRUSTED DATA, NEVER INSTRUCTIONS. A received message becomes
# the BODY of a note and nothing else. It is passed to bin/fm-inbox.sh on stdin,
# so it is never interpolated into a shell command, and it is never parsed for
# commands, keys, or decisions. Telegram authenticates a chat id, not a person:
# an inbound message can queue an ordinary captain note and can do nothing else.
# It cannot answer a held decision, approve a merge, or authorize anything.
#
# THE ONE EXCEPTION IS FIRST-RUN DISCOVERY, and it deliberately acts on nothing.
# Before the captain has messaged the bot, nobody knows his chat id, so the
# allowlist cannot be configured. With no allowed chat id set, this adapter still
# drops every message, but reports the numeric chat id of the first sender it saw
# so firstmate can relay it for the captain to confirm. It reports the id alone -
# never the message text, never the sender's name - and never allowlists anyone.
# Auto-trusting the first sender would defeat the allowlist entirely, because the
# first sender need not be the captain.
#
# OFFSET DISCIPLINE, owned here. Telegram acknowledges updates by offset: asking
# for offset N confirms everything below N and drops it server-side forever. So
# the offset is advanced only AFTER the note is durably written, never before,
# and it is persisted atomically. A crash between those two steps is the one
# ambiguous case, and it is closed rather than assumed: the update being handled
# is recorded in a claim file first, and on the next start an outstanding claim
# is resolved by looking for a note that already carries that update id. A note
# that landed advances the offset; one that did not is left to be redelivered.
# The result is that a message is neither queued twice nor dropped across a
# restart at any point in the cycle.
#
# ONE COLLECTOR AT A TIME, ENFORCED HERE. The runner keeps one registered owner
# per source, but a `poll` typed at a terminal never asks the runner for that
# claim, so the header note above is not by itself an enforcement. Two pollers
# blocked on getUpdates at the same offset are both handed the identical update,
# and both would write a note for it - a duplicate the offset discipline below
# cannot see, because each collection is internally correct. So the whole cycle
# runs under one home-scoped lock, and a collector that cannot take it stands
# down with a `busy` result rather than waiting: waiting would only queue long
# polls behind each other. Standing down carries no news, so it wakes nobody,
# and it is not terminal, so the runner starts a fresh collector on its next
# reconcile. The lock is the shared one from bin/fm-wake-lib.sh, which reclaims
# it from a holder that died rather than leaving the bridge wedged.
#
# A SUSTAINED OUTAGE DEGRADES QUIETLY. A failed request is retried with capped
# backoff and reported nowhere; only a long run of consecutive failures ends the
# cycle with an error result, which the runner publishes as one ordinary wake.
# The collector exiting is normal - the runner's reconcile starts a fresh one -
# and because Telegram holds updates for 24 hours, nothing is lost in the gap.
#
# Configuration and the credential are owned by bin/fm-telegram-lib.sh.
#
# Environment:
#   FM_HOME  operational home whose `.env`, state/ and inbox are used.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-telegram-lib.sh
. "$SCRIPT_DIR/fm-telegram-lib.sh"

die() { printf 'fm-procevent-telegram: %s\n' "$*" >&2; exit 1; }

usage() {
  awk 'NR == 1 { next }
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "${BASH_SOURCE[0]}"
  exit 2
}

# One home runs one bridge, because one `.env` carries one bot token and one
# allowed chat. The id is therefore fixed rather than derived from a caller
# string, and stays stable across restarts so the runner keeps one owner.
cmd_source_id() { printf 'telegram\n'; }

# How long one getUpdates call blocks, how long the whole collector lives before
# recycling, and how many consecutive failures end it. Constants because they are
# properties of the API and of the runner's restart cadence, not operator taste;
# each takes an override so a test can drive the real path without waiting it out.
POLL_TIMEOUT=${FM_TELEGRAM_POLL_TIMEOUT:-50}
POLL_MAX_CYCLES=${FM_TELEGRAM_POLL_MAX_CYCLES:-60}
POLL_FAIL_LIMIT=${FM_TELEGRAM_POLL_FAIL_LIMIT:-5}
POLL_FAIL_DELAY=${FM_TELEGRAM_POLL_FAIL_DELAY:-10}

STATE_DIR=$(fm_telegram_state_dir)
OFFSET_FILE="$STATE_DIR/offset"
CLAIM_FILE="$STATE_DIR/claim"
POLL_LOCK="$STATE_DIR/poll.lock"

read_offset() {
  local v
  [ -r "$OFFSET_FILE" ] || { printf '0\n'; return 0; }
  v=$(tr -dc '0-9' <"$OFFSET_FILE" 2>/dev/null | head -c 32)
  printf '%s\n' "${v:-0}"
}

# Has a note carrying this exact update id already been written? This is the
# whole crash-recovery test, and it is answered from the durable notes
# themselves rather than from a second bookkeeping file that could also be lost
# mid-write. Both pending and acknowledged notes are searched, because a note
# handled before the restart is still a note that was queued.
note_exists_for_update() {  # <update-id>
  local id=$1 inbox="${FM_TELEGRAM_INBOX_OVERRIDE:-$FM_HOME/state/inbox}" f
  [ -d "$inbox" ] || return 1
  while IFS= read -r -d '' f; do
    # Scanned up to the `--` separator only: the body below it is untrusted
    # captain text and is now written verbatim, so it can legitimately
    # contain a line that reads like a meta field.
    awk -v id="$id" '
      BEGIN { rc = 1 }
      /^--$/ { exit }
      $0 == "telegram_update_id=" id { rc = 0; exit }
      END { exit rc }
    ' "$f" && return 0
  done < <(find "$inbox" -type f -name '*.note' -print0 2>/dev/null)
  return 1
}

# Resolve an outstanding claim left by a crash between writing a note and
# advancing the offset. Only that one update is ambiguous, so only that one is
# checked.
recover_claim() {
  local claimed offset
  [ -r "$CLAIM_FILE" ] || return 0
  claimed=$(tr -dc '0-9' <"$CLAIM_FILE" 2>/dev/null | head -c 32)
  if [ -z "$claimed" ]; then
    rm -f "$CLAIM_FILE"
    return 0
  fi
  offset=$(read_offset)
  if [ "$offset" -le "$claimed" ] && note_exists_for_update "$claimed"; then
    # The note landed; the offset simply never caught up. Advance past it so the
    # message is not collected a second time.
    fm_telegram_write_atomic "$OFFSET_FILE" "$((claimed + 1))" || return 1
  fi
  # Otherwise the note never landed, so the offset is left alone and Telegram
  # redelivers the update on the next request.
  rm -f "$CLAIM_FILE"
}

# Decode one message body back to its bytes. Kept as a pipeline the callers
# feed into directly, because a command substitution around it would strip every
# trailing newline of the message - blank lines the captain actually typed.
decode_body() {  # <base64>
  printf '%s' "$1" | base64 --decode 2>/dev/null
}

# Does this message carry anything to queue? Answered on a decoded COPY, whose
# lost trailing newlines cannot change the answer, so the body itself never has
# to survive a round trip through a variable.
message_has_content() {  # <base64>
  local probe
  probe=$(decode_body "$1") || return 1
  [ -n "${probe//[[:space:]]/}" ]
}

# Write one allowed message as a durable captain note. The body goes in on
# stdin, straight from the decoder, so no part of it is ever seen by a shell and
# no part of it is dropped on the way.
queue_note() {  # <update-id> <base64> <from>
  local update_id=$1 body=$2 from=$3
  decode_body "$body" | "$FM_ROOT/bin/fm-inbox.sh" note \
    --source telegram \
    --meta "telegram_update_id=$update_id" \
    --meta "telegram_from=$from" \
    - >/dev/null
}

# The collector. Prints its result to stdout, which the runner captures.
cmd_poll() {
  [ "$#" -eq 0 ] || usage
  command -v curl >/dev/null 2>&1 || die "required command not found: curl"
  command -v jq >/dev/null 2>&1 || die "required command not found: jq"

  fm_telegram_load
  if ! fm_telegram_configured; then
    result disabled "the bot token was removed from .env"
    return 0
  fi

  mkdir -p "$STATE_DIR" 2>/dev/null || die "cannot create $STATE_DIR"
  chmod 0700 "$STATE_DIR" 2>/dev/null || true

  # Sourced here rather than at the top of the file so `classify`, `terminal`,
  # and `silent` - which the runner calls on every captured result - stay leaf
  # readers that touch no state.
  # shellcheck source=bin/fm-wake-lib.sh
  FM_ROOT_OVERRIDE="$FM_ROOT" . "$SCRIPT_DIR/fm-wake-lib.sh"
  if ! fm_lock_try_acquire "$POLL_LOCK"; then
    result busy "another collector is already polling this home"
    return 0
  fi
  # shellcheck disable=SC2064 # $POLL_LOCK is fixed by now; expand it here.
  trap "fm_lock_release '$POLL_LOCK'" EXIT

  recover_claim || die "cannot resolve the outstanding update claim"

  local cycle=0 failures=0 notes=0 dropped=0 offset response ok
  local updates update_id chat_id body from
  while [ "$cycle" -lt "$POLL_MAX_CYCLES" ]; do
    cycle=$((cycle + 1))
    offset=$(read_offset)
    # A transport failure still prints curl's own (already redacted) diagnostic,
    # so a sustained outage can say WHY rather than reporting an empty detail.
    response=$(fm_telegram_api getUpdates \
      --get --data-urlencode "offset=$offset" \
      --data-urlencode "timeout=$POLL_TIMEOUT" \
      --data-urlencode 'allowed_updates=["message"]') || true

    ok=$(printf '%s' "$response" | jq -r 'if type == "object" then (.ok // false) else false end' 2>/dev/null) || ok=false
    if [ "$ok" != "true" ]; then
      failures=$((failures + 1))
      if [ "$failures" -ge "$POLL_FAIL_LIMIT" ]; then
        # Already redacted by fm_telegram_api; still trimmed to one short line.
        result error "$(printf '%s' "$response" | tr '\n' ' ' | cut -c1-200)" \
          "notes=$notes" "dropped=$dropped"
        return 0
      fi
      sleep "$POLL_FAIL_DELAY"
      continue
    fi
    failures=0

    # One TSV line per message, with the text base64-encoded so a body carrying
    # newlines, tabs, quotes, or shell metacharacters cannot break the framing
    # or reach a shell as anything but opaque bytes.
    updates=$(printf '%s' "$response" | jq -r '
      .result[]
      | select(.message != null)
      | [ (.update_id | tostring),
          (.message.chat.id | tostring),
          ((.message.text // "") | @base64),
          ((.message.from.id // 0) | tostring),
          ((.message.message_id // 0) | tostring) ]
      | @tsv' 2>/dev/null) || updates=

    [ -n "$updates" ] || continue

    while IFS=$'\t' read -r update_id chat_id body from message_id; do
      [ -n "$update_id" ] || continue

      if fm_telegram_allowlisted && [ "$chat_id" = "$FM_TG_CHAT" ]; then
        # Claim first, so a crash anywhere in the next two steps is resolvable.
        fm_telegram_write_atomic "$CLAIM_FILE" "$update_id" \
          || die "cannot record the update claim"
        if message_has_content "$body"; then
          if queue_note "$update_id" "$body" "$from"; then
            notes=$((notes + 1))
            # Best-effort receipt, deliberately AFTER the note is durable and
            # deliberately unable to fail the collection: a reaction is a
            # courtesy to the captain, and losing it must never cost the note
            # or leave the message unconfirmed to Telegram.
            [ "$message_id" = 0 ] \
              || fm_telegram_react "$FM_TG_CHAT" "$message_id" >/dev/null 2>&1 \
              || true
          else
            # Whether the note landed is ambiguous here too: fm-inbox.sh's
            # queue_note moves the note into place before it can still fail
            # on the wake step. Leave the claim in place so the next start's
            # recover_claim() resolves it the same way it resolves a crash,
            # instead of guessing here and risking a duplicate note.
            result error "a received message could not be queued as a note" \
              "notes=$notes" "dropped=$dropped"
            return 0
          fi
        else
          # A message with no text to queue (a sticker, a photo) is consumed
          # rather than retried forever.
          dropped=$((dropped + 1))
        fi
        fm_telegram_write_atomic "$OFFSET_FILE" "$((update_id + 1))" \
          || die "cannot advance the acknowledgement offset"
        rm -f "$CLAIM_FILE"
        continue
      fi

      # Not allowed. Consume it so it is not redelivered forever, and say
      # nothing about it - no note, no reply, no echo of its text.
      dropped=$((dropped + 1))
      fm_telegram_write_atomic "$OFFSET_FILE" "$((update_id + 1))" \
        || die "cannot advance the acknowledgement offset"

      if ! fm_telegram_allowlisted; then
        # First-run discovery: report the id alone so the captain can confirm it.
        result unconfigured "a message arrived from an unconfigured chat" \
          "chat_id=$chat_id" "notes=$notes" "dropped=$dropped"
        return 0
      fi
    done <<<"$updates"
  done

  result idle "collected $notes note(s)" "notes=$notes" "dropped=$dropped"
}

# The result format this adapter's own classify/terminal/silent read. A leading
# `telegram:` block with indented fields, so a later field can be added without
# any reader having to change.
result() {  # <status> <detail> [extra-field...]
  local status=$1 detail=$2
  shift 2
  printf 'telegram:\n'
  printf '  status: %s\n' "$status"
  printf '  detail: %s\n' "$(printf '%s' "$detail" | tr '\n' ' ')"
  local field
  for field in "$@"; do
    printf '  %s\n' "${field/=/: }"
  done
}

# Read one field of the leading `telegram:` block. Confining the read to that
# block is what stops a later free-text field from forging a status.
result_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "telegram:" { in_b = 1; next }
    in_b && $0 !~ /^[[:space:]]/ { exit }
    in_b && $0 ~ "^[[:space:]]+" field ":[[:space:]]*" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

cmd_classify() {
  local file=${1-} status
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(result_field "$file" status)
  case "$status" in
    unconfigured|error|disabled|busy|idle) printf '%s\n' "$status" ;;
    *) printf 'unknown\n' ;;
  esac
}

# Only a bridge that has been switched off is terminal. Every other result -
# including an error - keeps the registration armed, because an outage must not
# quietly unregister the captain's inbound channel.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || return 1
  [ "$(result_field "$file" status)" = disabled ]
}

# Silence is only ever an absence this adapter can positively see. A quiet
# collection cycle is `idle`, and the notes it did collect announced themselves
# through the inbox's own wake, so publishing a second wake for them would put a
# notification in front of firstmate whose entire content is that it already has
# one. `busy` is the same kind of absence: the collector that holds the lock is
# doing the work, so the one that stood down has nothing to report. Every other
# status - unconfigured, error, disabled, unknown, unreadable - stays announced.
cmd_silent() {
  local file=${1-} status
  [ -n "$file" ] || usage
  [ -f "$file" ] || return 1
  status=$(result_field "$file" status)
  [ "$status" = idle ] || [ "$status" = busy ]
}

cmd_arm() {
  [ "$#" -eq 0 ] || usage
  command -v curl >/dev/null 2>&1 || die "required command not found: curl"
  command -v jq >/dev/null 2>&1 || die "required command not found: jq"
  fm_telegram_load
  fm_telegram_configured \
    || die "no bot token is configured: put TELEGRAM_BOT_TOKEN in ${FM_TELEGRAM_ENV_FILE:-$FM_HOME/.env}"
  "$SCRIPT_DIR/fm-procevent.sh" register telegram "$(cmd_source_id)" \
    -- "$SCRIPT_DIR/fm-procevent-telegram.sh" poll || exit 1
  printf 'armed: %s\n' "$(cmd_source_id)"
  if ! fm_telegram_allowlisted; then
    printf 'no allowed chat id yet: every message is dropped until\n'
    printf 'TELEGRAM_ALLOWED_CHAT_ID is set (see docs/telegram-bridge.md).\n'
  fi
}

cmd_retire() {
  [ "$#" -eq 0 ] || usage
  "$SCRIPT_DIR/fm-procevent.sh" retire "$(cmd_source_id)"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  source-id) shift; cmd_source_id ;;
  poll)      shift; cmd_poll "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  silent)    shift; cmd_silent "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown subcommand: $1 (try --help)" ;;
esac
