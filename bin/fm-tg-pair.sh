#!/usr/bin/env bash
# Captain-facing setup surface for the private Telegram bridge: open a one-time
# pairing, inspect the current link, or revoke it.
#
# The bridge connects exactly one outside human to exactly one project. That is
# structural, not a policy note: one pinned peer record exists at a time, and it
# carries the single project name every downstream step checks against.
#
# Usage:
#   fm-tg-pair.sh begin --label <name> --project <project> [--replace]
#   fm-tg-pair.sh status
#   fm-tg-pair.sh revoke [--yes]
#   fm-tg-pair.sh --help
#
# begin   Print a short one-time code for <name> to send to the bot as
#         "/start <code>". Only a salted hash of the code is stored, so the code
#         cannot be recovered from disk, and it is single-use: redeeming it pins
#         the peer and deletes the offer. It expires after FM_TELEGRAM_PAIR_TTL
#         seconds (default 900) and allows FM_TELEGRAM_PAIR_ATTEMPTS guesses
#         (default 5) before the offer is spent. Refuses to replace an existing
#         pairing unless --replace is given, so re-pairing is always deliberate.
#
# status  Report whether a pairing is open or pinned, the label, the project, the
#         pinned numeric ids, pending message count, and the last bridge error.
#         Never prints the bot token, a pairing code, or any message content.
#
# revoke  Clear the pinned peer, any open offer, every pending message, and every
#         armed publish confirmation. The update offset and duplicate-suppression
#         markers are deliberately KEPT so revoking cannot cause old messages to
#         be replayed. Requires --yes when a peer is currently pinned.
#
# SETUP, once per home:
#   1. Talk to @BotFather in Telegram, send /newbot, and follow the prompts.
#   2. Put the token BotFather gives you in this home's gitignored .env as
#        FM_TELEGRAM_BOT_TOKEN=<token>
#      Nothing else. The token is never copied into config/, state/, a task
#      record, a log line, or an error message.
#   3. Run bin/fm-session-start.sh so bootstrap arms the poll for this home.
#   4. Run this script's `begin`, and give the printed code to that one person.
#   5. They open a private chat with the bot and send "/start <code>".
#
# TOKEN ROTATION: replacing the token of the SAME bot (BotFather /revoke, then
# /token) keeps the pairing valid, because the peer is pinned by Telegram's
# immutable numeric ids and not by the token. Update .env and rerun session
# start. Moving to a DIFFERENT bot is a new bot: run `begin --replace` and pair
# again.
#
# COMPLETE OPT-OUT: run `revoke --yes`, remove FM_TELEGRAM_BOT_TOKEN from .env,
# and rerun session start. Bootstrap then removes the poll shim and the cadence
# file, and the home returns to exactly its pre-Telegram behavior. Delete
# state/telegram/ to erase the remaining local records.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

# Pairing and revocation are captain decisions; a no-mistakes gate agent running
# inside a firstmate checkout must not make them (bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

die() {
  printf 'fm-tg-pair: %s\n' "$1" >&2
  exit 2
}

name_valid() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

COMMAND=${1:-}
[ "$#" -gt 0 ] && shift
case "$COMMAND" in
  -h|--help|help|'') usage; exit 0 ;;
  begin|status|revoke) ;;
  *) die "unknown command: $COMMAND (see --help)" ;;
esac

LABEL=
PROJECT=
REPLACE=0
ASSUME_YES=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --label) [ "$#" -gt 1 ] || die "--label requires a value"; LABEL=$2; shift 2 ;;
    --project) [ "$#" -gt 1 ] || die "--project requires a value"; PROJECT=$2; shift 2 ;;
    --replace) REPLACE=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"
fmtg_load_config
TG_DIR=$(fmtg_dir)
NOW=$(fmtg_now) || die "cannot read the current time"

case "$COMMAND" in
  begin)
    name_valid "$LABEL" || die "--label must be a short name (letters, digits, . _ -)"
    name_valid "$PROJECT" || die "--project must be a project name (letters, digits, . _ -)"
    if [ -n "${FMTG_TOKEN_BAD:-}" ]; then
      die "FM_TELEGRAM_BOT_TOKEN is not in BotFather's <id>:<secret> form"
    fi
    if ! fmtg_active; then
      die "the bridge is off; put FM_TELEGRAM_BOT_TOKEN in $FM_HOME/.env and rerun bin/fm-session-start.sh first"
    fi
    if fmtg_peer_get >/dev/null 2>&1 && [ "$REPLACE" -eq 0 ]; then
      die "a peer is already paired; pass --replace to deliberately replace it"
    fi
    CODE=$(fmtg_random_code 8) || die "cannot generate a pairing code"
    fmtg_pairing_set "$LABEL" "$PROJECT" "$CODE" "$NOW" "$(( NOW + FMTG_PAIR_TTL ))" \
      || die "cannot record the pairing offer"
    printf 'Pairing open for "%s" on project "%s".\n' "$LABEL" "$PROJECT"
    printf 'Ask them to open a private chat with the bot and send exactly:\n\n'
    printf '  /start %s\n\n' "$CODE"
    printf 'Valid for %s seconds, %s attempts, single use.\n' "$FMTG_PAIR_TTL" "$FMTG_PAIR_ATTEMPTS"
    printf 'A wrong or late code is answered with silence, so ask them to report back if nothing arrives.\n'
    ;;

  status)
    if [ -n "${FMTG_TOKEN_BAD:-}" ]; then
      printf 'token: present but malformed\n'
    elif fmtg_active; then
      printf 'token: present\n'
    else
      printf 'token: absent (bridge inert)\n'
    fi
    if PEER=$(fmtg_peer_get 2>/dev/null); then
      printf 'paired: yes\n'
      printf 'label: %s\n' "$(printf '%s' "$PEER" | jq -r '.label // "?"')"
      printf 'project: %s\n' "$(printf '%s' "$PEER" | jq -r '.project // "?"')"
      printf 'user_id: %s\n' "$(printf '%s' "$PEER" | jq -r '.user_id // "?"')"
      printf 'chat_id: %s\n' "$(printf '%s' "$PEER" | jq -r '.chat_id // "?"')"
      printf 'paired_at: %s\n' "$(printf '%s' "$PEER" | jq -r '.paired_at // "?"')"
    else
      printf 'paired: no\n'
    fi
    if OFFER=$(fmtg_pairing_get 2>/dev/null); then
      EXPIRES=$(printf '%s' "$OFFER" | jq -r '.expires_at // 0')
      case "$EXPIRES" in ''|*[!0-9]*) EXPIRES=0 ;; esac
      if [ "$NOW" -le "$EXPIRES" ]; then
        printf 'offer: open for "%s" on "%s", %ss left, %s attempts used of %s\n' \
          "$(printf '%s' "$OFFER" | jq -r '.label // "?"')" \
          "$(printf '%s' "$OFFER" | jq -r '.project // "?"')" \
          "$(( EXPIRES - NOW ))" \
          "$(printf '%s' "$OFFER" | jq -r '.attempts // 0')" \
          "$FMTG_PAIR_ATTEMPTS"
      else
        printf 'offer: expired, %s attempts used\n' "$(printf '%s' "$OFFER" | jq -r '.attempts // 0')"
      fi
    else
      printf 'offer: none\n'
    fi
    PENDING=0
    if [ -d "$TG_DIR/inbox" ]; then
      for f in "$TG_DIR/inbox"/*.json; do
        [ -e "$f" ] || continue
        PENDING=$(( PENDING + 1 ))
      done
    fi
    printf 'pending messages: %s\n' "$PENDING"
    if fm_private_artifact_file_valid "$TG_DIR" poll.error 600; then
      printf 'last error: %s\n' "$(cat "$TG_DIR/poll.error" 2>/dev/null | fmtg_redact)"
    else
      printf 'last error: none\n'
    fi
    ;;

  revoke)
    if fmtg_peer_get >/dev/null 2>&1 && [ "$ASSUME_YES" -eq 0 ]; then
      die "a peer is currently paired; pass --yes to confirm revoking it"
    fi
    fmtg_peer_clear || die "cannot clear the pinned peer"
    fmtg_pairing_clear || die "cannot clear the pairing offer"
    for sub in inbox context publish outbox; do
      [ -d "$TG_DIR/$sub" ] || continue
      find "$TG_DIR/$sub" -type f -name '*.json' -exec rm -f -- {} + 2>/dev/null || true
    done
    rm -f -- "$TG_DIR/recovery.json" "$TG_DIR/limits.json" "$TG_DIR/poll.error" 2>/dev/null || true
    printf 'Revoked. The pinned peer, any open offer, pending messages, and armed publish confirmations are gone.\n'
    printf 'The update offset and duplicate-suppression markers were kept so nothing replays.\n'
    printf 'To go fully inert, remove FM_TELEGRAM_BOT_TOKEN from %s/.env and rerun bin/fm-session-start.sh.\n' "$FM_HOME"
    ;;
esac
