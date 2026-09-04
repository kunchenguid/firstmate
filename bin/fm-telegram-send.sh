#!/usr/bin/env bash
# fm-telegram-send.sh - drain the outward Telegram card outbox.
#
# Usage:
#   fm-telegram-send.sh [check]
#   fm-telegram-send.sh arm
#   fm-telegram-send.sh disarm
#   fm-telegram-send.sh status
#   fm-telegram-send.sh --help
#
# This is the armed sender behind bin/fm-telegram-lib.sh's outbox. Publishers
# on the critical path of landing work only append a card to a local directory;
# nothing they do touches the network. This script makes the HTTPS calls, out
# of band, where a Telegram outage costs a retry instead of blocking a merge or
# a cleanup.
#
# `check` prints one line when Firstmate should be woken and prints nothing at
# all otherwise, which is the watcher's state-check contract, so the drain needs
# no schedule of its own. `arm` writes state/telegram-outbox.check.sh and binds
# its bytes with fm-check-register.sh; `disarm` removes the shim, its trust
# binding, and the error record. When Telegram is unconfigured, every automatic
# path is a hard no-op: exit 0, no output, nothing written. The deliberate arm
# command instead refuses when its required configuration is unavailable.
#
# SENDS ONLY. The Telegram Bot API's getUpdates is never called, here or
# anywhere else in this repository. The bot has no inbound path at all, so a
# message sent to it cannot reach Firstmate, cannot answer a captain decision,
# and cannot start, stop, or approve anything.
#
# Degradation is by construction rather than by error handling, because the
# durable record is never Telegram (docs/configuration.md, "Telegram
# notifications"):
#   network down or Telegram unreachable   cards stay queued, next cycle retries
#   token rejected or chat refused         one rate-limited wake, not one per cycle
#   token or configuration absent          automatic paths exit 0 silently
#   this check not armed                   cards queue and drain when it is
# A held decision, a registered PR, a failure, and a merge are all already
# durable in the backlog and in state before any card exists, so a card that
# never arrives leaves the work exactly where it was.
#
# The token is read at use time from the path in the home's configuration and
# is passed to curl through a mode-0600 config file, never in the argument
# vector, never in the environment, and never in any output. The card text goes
# the same way, because it is the captain's private work content.
#
# Bounds: at most FM_TELEGRAM_DRAIN_MAX (default 10) cards per invocation, each
# call bounded by FM_TELEGRAM_TIMEOUT_SECS (default 8), so a whole drain stays
# inside the watcher's own per-check bound. A card that cannot be sent stays
# queued and the drain stops there, so a transient failure cannot reorder the
# rest of the queue behind it.
# FM_TELEGRAM_STALE_SECS (default 3600, 0 disables) is how long the queue may
# stop moving before that silence is itself reported, so a channel that has
# quietly stopped delivering cannot pass for a quiet one.
# FM_TELEGRAM_API_BASE (default https://api.telegram.org) exists so a test can
# point the sender at a local server; production never sets it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-telegram-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-telegram-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-check-lib.sh"

CHECK_ID="telegram-outbox"
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
ERROR_FILE="$STATE/telegram-send.error"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"

DRAIN_MAX=${FM_TELEGRAM_DRAIN_MAX:-10}
case "$DRAIN_MAX" in ''|*[!0-9]*|0) DRAIN_MAX=10 ;; esac
[ "$DRAIN_MAX" -le 50 ] || DRAIN_MAX=50

TIMEOUT_SECS=${FM_TELEGRAM_TIMEOUT_SECS:-8}
case "$TIMEOUT_SECS" in ''|*[!0-9]*|0) TIMEOUT_SECS=8 ;; esac
[ "$TIMEOUT_SECS" -le 30 ] || TIMEOUT_SECS=30

# How long a card may sit undelivered before the silence is itself reported. An
# outage is expected to be silent and self-healing; an outbox that has stopped
# moving for an hour is a coverage loss the captain has to know about.
STALE_SECS=${FM_TELEGRAM_STALE_SECS:-3600}
case "$STALE_SECS" in ''|*[!0-9]*) STALE_SECS=3600 ;; esac

API_BASE=${FM_TELEGRAM_API_BASE:-https://api.telegram.org}

usage() {
  cat <<'EOF'
Usage:
  fm-telegram-send.sh [check]     drain the outbox; print a line only when Firstmate should wake
  fm-telegram-send.sh arm         write and register state/telegram-outbox.check.sh
  fm-telegram-send.sh disarm      remove the check shim, its trust binding, and the error record
  fm-telegram-send.sh status      report whether this home is configured and what is queued
  fm-telegram-send.sh --help      print this help

Configuration lives in config/telegram-chat-id, optional config/telegram-token-path,
and optional config/telegram-secret-files; all are local and gitignored.
See docs/configuration.md, "Telegram notifications".
EOF
}

die_usage() {
  printf 'fm-telegram-send: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# One wake per distinct problem rather than one per cycle: a revoked token
# would otherwise wake Firstmate on every poll forever.
emit_error_once() {  # <message>
  local msg=$1
  if [ -f "$ERROR_FILE" ] && [ ! -L "$ERROR_FILE" ] \
    && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  if [ -d "$STATE" ] && [ ! -L "$STATE" ] \
    && fm_pr_regular_destination_or_absent "$ERROR_FILE"; then
    (umask 077; printf '%s\n' "$msg" > "$ERROR_FILE") 2>/dev/null || true
  fi
  printf 'telegram-send %s\n' "$msg"
}

clear_error() {
  [ ! -L "$ERROR_FILE" ] || return 0
  rm -f -- "$ERROR_FILE" 2>/dev/null || true
}

telegram_response_ok() {  # <body-file>
  if command -v jq >/dev/null 2>&1; then
    jq -e 'type == "object" and .ok == true' "$1" >/dev/null 2>&1
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$1" >/dev/null 2>&1 <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
raise SystemExit(0 if isinstance(value, dict) and value.get("ok") is True else 1)
PY
    return
  fi
  LC_ALL=C awk '
    function ws() { while (substr(s, p, 1) ~ /[ \t\r\n]/) p++ }
    function string(    c, esc, hex, out) {
      if (substr(s, p++, 1) != "\"") return "\001"
      while (p <= n) {
        c = substr(s, p++, 1)
        if (c == "\"") return out
        if (c ~ /[[:cntrl:]]/) return "\001"
        if (c != "\\") { out = out c; continue }
        esc = substr(s, p++, 1)
        if (esc == "u") {
          hex = substr(s, p, 4)
          if (hex !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) return "\001"
          p += 4
          out = out "?"
        } else if (esc ~ /^["\\\/bfnrt]$/) out = out "?"
        else return "\001"
      }
      return "\001"
    }
    function value(depth,    c, token) {
      ws(); c = substr(s, p, 1)
      if (c == "\"") { if (string() == "\001") return 0; kind = "other"; return 1 }
      if (c == "{") { if (!object(depth)) return 0; kind = "other"; return 1 }
      if (c == "[") { if (!array(depth)) return 0; kind = "other"; return 1 }
      token = substr(s, p)
      if (token ~ /^true/) { p += 4; kind = "true"; return 1 }
      if (token ~ /^false/) { p += 5; kind = "false"; return 1 }
      if (token ~ /^null/) { p += 4; kind = "other"; return 1 }
      if (match(token, /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) {
        p += RLENGTH; kind = "other"; return 1
      }
      return 0
    }
    function array(depth,    c) {
      p++; ws(); if (substr(s, p, 1) == "]") { p++; return 1 }
      while (1) {
        if (!value(depth + 1)) return 0
        ws(); c = substr(s, p++, 1)
        if (c == "]") return 1
        if (c != ",") return 0
      }
    }
    function object(depth,    c, key, member_kind) {
      p++; ws(); if (substr(s, p, 1) == "}") { p++; return 1 }
      while (1) {
        ws(); key = string(); if (key == "\001") return 0
        ws(); if (substr(s, p++, 1) != ":") return 0
        if (!value(depth + 1)) return 0
        member_kind = kind
        if (depth == 0 && key == "ok") root_ok = (member_kind == "true")
        ws(); c = substr(s, p++, 1)
        if (c == "}") return 1
        if (c != ",") return 0
      }
    }
    { s = s $0 "\n" }
    END {
      n = length(s); p = 1; root_ok = 0
      ws(); valid = (substr(s, p, 1) == "{" && object(0)); ws()
      exit !(valid && p > n && root_ok)
    }
  ' "$1" >/dev/null 2>&1
}

# Queued cards, oldest first. A name that is not a card this script wrote is
# skipped rather than sent.
queued_cards() {
  local dir card
  dir=$(fm_telegram_outbox_dir "$STATE")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  for card in "$dir"/*.card; do
    [ -f "$card" ] && [ ! -L "$card" ] || continue
    printf '%s\n' "$card"
  done | LC_ALL=C sort
}

# Post one card. Prints the HTTP status code; returns non-zero when curl itself
# could not complete the call.
post_card() {  # <card-file> <body-file>
  local card=$1 body=$2 config code rc=0
  config=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-telegram-curl.XXXXXX") || return 1
  chmod 600 "$config" 2>/dev/null || { rm -f -- "$config"; return 1; }
  {
    printf 'url = "%s/bot%s/sendMessage"\n' "$API_BASE" "$(cat "$FM_TELEGRAM_TOKEN_FILE")"
    printf 'data-urlencode = "chat_id=%s"\n' "$FM_TELEGRAM_CHAT_ID"
    printf 'data-urlencode = "text@%s"\n' "$card"
    printf 'data-urlencode = "disable_web_page_preview=true"\n'
  } > "$config" 2>/dev/null || { rm -f -- "$config"; return 1; }
  code=$(curl -sS -m "$TIMEOUT_SECS" -K "$config" -o "$body" -w '%{http_code}' 2>/dev/null) || rc=$?
  rm -f -- "$config"
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$code"
}

# The key a card file's name encodes. Only its own name identifies it; a card
# file holds exactly the text that is sent and nothing else.
card_key_marker() {  # <card-file>
  local base
  base=$(basename "$1" .card)
  printf '%s\n' "${base##*-}"
}

file_mtime() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

report_stalled_queue() {  # <oldest-card>
  local mtime now age
  [ "$STALE_SECS" -gt 0 ] || return 0
  mtime=$(file_mtime "$1") || return 0
  [ -n "$mtime" ] || return 0
  now=$(date +%s)
  age=$((now - mtime))
  [ "$age" -ge "$STALE_SECS" ] || return 0
  emit_error_once "has not delivered a notification for $((age / 60)) minutes"
}

action_check() {
  local card code body sent=0 oldest='' text secret_rc
  fm_telegram_config_load "$FM_HOME" >/dev/null 2>&1 || exit 0
  command -v curl >/dev/null 2>&1 || { emit_error_once "cannot send: curl is not installed"; exit 0; }
  body=$(mktemp "${TMPDIR:-/tmp}/fm-telegram-body.XXXXXX") || exit 0
  trap 'rm -f -- "$body"' EXIT
  while IFS= read -r card; do
    [ -n "$oldest" ] || oldest=$card
    [ "$sent" -lt "$DRAIN_MAX" ] || break
    text=$(cat "$card" 2>/dev/null) || { rm -f -- "$card"; continue; }
    # The refusal that already ran when this card was built, run again against
    # the bytes about to leave the machine. A card that fails it here is
    # dropped rather than sent, and the drop is reported: a send that silently
    # drops is worse than one that fails.
    secret_rc=0
    fm_telegram_refuse_if_secret "$FM_HOME" "$text" || secret_rc=$?
    case "$secret_rc" in
      0) ;;
      1)
        rm -f -- "$card"
        emit_error_once "refused a notification that would have carried a credential value"
        continue
        ;;
      *)
        emit_error_once "refused notifications because credential file could not be checked: $FM_TELEGRAM_SECRET_ERROR_PATH"
        exit 0
        ;;
    esac
    code=$(post_card "$card" "$body") || {
      # The call did not complete: the network, DNS, or Telegram is unavailable.
      # Cards stay queued in order and the next cycle retries.
      report_stalled_queue "$oldest"
      exit 0
    }
    case "$code" in
      200)
        if telegram_response_ok "$body"; then
          fm_telegram_mark_delivered "$STATE" "$(card_key_marker "$card")" || true
          rm -f -- "$card"
          sent=$((sent + 1))
          clear_error
          continue
        fi
        emit_error_once "was refused by Telegram; check config/telegram-chat-id"
        exit 0
        ;;
      400|401|403|404)
        # A revoked token, a bot that was never started by the captain, or a
        # chat id that does not resolve. Retrying cannot fix any of them, so the
        # cards stay queued and this is reported once.
        emit_error_once "cannot reach the captain: Telegram rejected the request (HTTP $code)"
        exit 0
        ;;
      *)
        report_stalled_queue "$oldest"
        exit 0
        ;;
    esac
  done < <(queued_cards)
  [ -z "$oldest" ] || [ ! -f "$oldest" ] || report_stalled_queue "$oldest"
  exit 0
}

action_status() {
  local dir count=0 card
  if fm_telegram_config_load "$FM_HOME" >/dev/null 2>&1; then
    printf 'configured: yes (token path %s)\n' "$FM_TELEGRAM_TOKEN_FILE"
  else
    printf 'configured: no\n'
  fi
  if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    printf 'armed: yes\n'
  else
    printf 'armed: no\n'
  fi
  dir=$(fm_telegram_outbox_dir "$STATE")
  if [ -d "$dir" ] && [ ! -L "$dir" ]; then
    for card in "$dir"/*.card; do
      [ -f "$card" ] || continue
      count=$((count + 1))
    done
  fi
  printf 'queued: %s\n' "$count"
  if [ -f "$ERROR_FILE" ] && [ ! -L "$ERROR_FILE" ]; then
    printf 'last problem: %s\n' "$(cat "$ERROR_FILE" 2>/dev/null)"
  fi
}

shim_content() {  # <home>
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-telegram-send.sh - outward notification drain shim.' \
    '# The watcher validates these bytes, then dispatches the trusted script.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-telegram-send.sh") check"
}

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes Firstmate about an unauthenticated state check. So a failed arm leaves
# the home plainly unarmed rather than holding a shim with no trust binding.
arm_rollback() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
}

action_arm() {
  local home want device tmp config_dir
  if ! fm_telegram_config_load "$FM_HOME" >/dev/null 2>&1; then
    config_dir=$(_fm_telegram_config_dir "$FM_HOME")
    printf 'fm-telegram-send: arm requires a numeric chat id in %s/telegram-chat-id and a mode-0600 bot token at the path in %s/telegram-token-path (default %s/.mist-telegram-token)\n' \
      "$config_dir" "$config_dir" "$HOME" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-telegram-send: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-telegram-check.XXXXXX") || return 1
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    printf 'fm-telegram-send: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    arm_rollback
    printf 'fm-telegram-send: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$ERROR_FILE"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  status) action_status ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
