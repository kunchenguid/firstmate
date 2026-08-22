#!/usr/bin/env bash
# Post and update messages in the configured Slack captain channel.
#
# Inert without FM_SLACK_BOT_TOKEN and config/slack-captain-channel.
# Every path refuses a channel id that does not match configuration.
#
# Usage:
#   fm-slack-post.sh [--long <reason>] message <text> [thread_ts]
#   fm-slack-post.sh [--long <reason>] update <message_ts> <text>
#   fm-slack-post.sh [--long <reason>] decision <key> <text> [option...]
#   fm-slack-post.sh board <text>   # chat.update when state/slack-board.ts exists,
#                                   # otherwise chat.postMessage and record ts
#
# decision posts a captain decision and records a private binding under
# state/slack-decision-bindings/ from the posted message timestamp to the
# decision key, so a later captain emoji reaction on that message resolves the
# key through the socket reaction path (bin/fm-slack-socket-event.sh). With
# options, each is numbered with its keycap emoji (1..9, more is refused) so a
# one/two/three reaction unambiguously selects it; the option count is recorded
# in the binding so an out-of-range number reaction is refused, never guessed.
# The decision key is slug-shaped ([A-Za-z0-9._-], not dot-leading, <= 120
# chars) and validated before posting. A post that succeeds but cannot record
# its binding dies loudly naming the ts, because reactions on that message
# would be refused as unbound.
#
# Captain message size guard (this header is the contract owner):
# The captain-facing message and update paths cap size before delivery at 12
# lines and 1200 characters by default. The line cap has a second consumer that
# does not deliver anything: bin/fm-turnend-guard.sh measures a completed
# captain-facing reply against it at turn end and emits one non-blocking
# advisory warning over it (docs/turnend-guard.md), sharing this default, this
# override file, this format, this fail-open rule, and FMS_CAPTAIN_COMMS_MEASURE_AWK.
# The character cap and --long apply to Slack delivery only. An operator overrides either cap with a
# single positive integer in gitignored config/slack-captain-comms-lines or
# config/slack-captain-comms-chars; an absent or malformed file keeps that
# built-in default. Characters are counted as characters, not bytes, so UTF-8
# text is measured the way the sender typed it. At or under both caps passes;
# over either cap refuses with one line naming the failed cap, so the sender can
# shorten the message or link the overflow from a file. --long <reason> bypasses
# the guard and records the reason on stderr, collapsed to one line. The fleet
# board path, wedge alarms, and error paths stay exempt, and board ignores a
# --long silently rather than losing a post the exemption already allows. If the
# guard cannot load its configuration or measure the text it steps aside and
# allows delivery, announcing itself with one stderr line reading
# "slack-captain-comms: guard stood down: <reason>" whose reason distinguishes an
# unreadable cap file, a dangling cap symlink, and a failed measurement; that
# line is the evidence trail for a guard that is silently off. So
# FMS_CAPTAIN_COMMS_MEASURE_AWK - the awk the line count runs, overridable the
# way FM_SLACK_CURL_BIN overrides curl - stands the guard down for every message
# when it names a command that is missing or fails.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-slack-lib.sh
. "$SCRIPT_DIR/fm-slack-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

fms_load_config
fms_configured || die "Slack captain channel is not configured"

command -v curl >/dev/null 2>&1 || die "missing curl"
command -v jq   >/dev/null 2>&1 || die "missing jq"

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-slack-post.XXXXXX") || exit 1
trap 'rm -f "$BODY_FILE"' EXIT

post_message() {
  local text=$1 thread_ts=${2:-} data ts
  fms_channel_configured || die "refusing channel mismatch on post"
  data="channel=$(printf '%s' "$FMS_CHANNEL_ID" | jq -sRr @uri)"
  data="${data}&text=$(printf '%s' "$text" | jq -sRr @uri)"
  if [ -n "$thread_ts" ]; then
    fms_message_ts_valid "$thread_ts" || die "invalid thread_ts"
    data="${data}&thread_ts=$(printf '%s' "$thread_ts" | jq -sRr @uri)"
  fi
  fms_api_post chat.postMessage "$data" "$BODY_FILE" || die "chat.postMessage transport failed"
  fms_api_json_ok "$BODY_FILE" || die "chat.postMessage rejected"
  fms_api_response_channel_ok "$BODY_FILE" || die "refusing response channel mismatch on post"
  ts=$(jq -r '.ts // empty' "$BODY_FILE" 2>/dev/null) || ts=
  [ -n "$ts" ] || die "chat.postMessage returned no ts"
  printf '%s\n' "$ts"
}

update_message() {
  local message_ts=$1 text=$2 data
  fms_message_ts_valid "$message_ts" || die "invalid message ts"
  fms_channel_configured || die "refusing channel mismatch on update"
  data="channel=$(printf '%s' "$FMS_CHANNEL_ID" | jq -sRr @uri)"
  data="${data}&ts=$(printf '%s' "$message_ts" | jq -sRr @uri)"
  data="${data}&text=$(printf '%s' "$text" | jq -sRr @uri)"
  fms_api_post chat.update "$data" "$BODY_FILE" || die "chat.update transport failed"
  fms_api_json_ok "$BODY_FILE" || die "chat.update rejected"
  fms_api_response_channel_ok "$BODY_FILE" || die "refusing response channel mismatch on update"
  printf '%s\n' "$message_ts"
}

board_meta_read() {
  local meta=$STATE/slack-board.meta/slack-board.meta
  fmx_private_artifact_file_valid "$STATE/slack-board.meta" "slack-board.meta" 600 2>/dev/null || return 1
  grep '^ts=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-
}

board_meta_channel() {
  local meta=$STATE/slack-board.meta/slack-board.meta
  fmx_private_artifact_file_valid "$STATE/slack-board.meta" "slack-board.meta" 600 2>/dev/null || return 1
  grep '^channel=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-
}

board_meta_write() {
  local ts=$1
  fms_message_ts_valid "$ts" || return 1
  fmx_private_artifact_publish_stdin "$STATE/slack-board.meta" "slack-board.meta" 600 <<EOF
channel=$FMS_CHANNEL_ID
ts=$ts
EOF
}

LONG_REASON=
while [ "${1-}" = --long ]; do
  shift
  [ -n "${1-}" ] || die "usage: --long requires a one-line reason"
  LONG_REASON=$1
  shift
done

captain_comms_guard_or_die() {
  fms_captain_comms_guard "$1" "$LONG_REASON" || exit 1
}

# Number each option with its keycap emoji (digit + U+FE0F + U+20E3). The emoji
# bytes are emitted as octal escapes so the script stays ASCII-only and works
# under LC_ALL=C and stock Bash 3.2, where $'\uXXXX' is unsupported.
number_options() {
  local n=0 opt
  for opt in "$@"; do
    n=$((n + 1))
    printf '%d\357\270\217\342\203\243 %s\n' "$n" "$opt"
  done
}

post_decision() {
  local key=$1 text=$2 ts
  shift 2
  fms_decision_key_valid "$key" || die "invalid decision key"
  [ "$#" -le 9 ] || die "too many options (max 9)"
  if [ "$#" -gt 0 ]; then
    text=$(printf '%s\n' "$text"; number_options "$@")
  fi
  captain_comms_guard_or_die "$text"
  ts=$(post_message "$text")
  fms_decision_binding_publish "$STATE" "$ts" "$key" "$#" \
    || die "decision posted at $ts but its binding was not recorded; reactions on it will be refused"
  printf '%s\n' "$ts"
}

cmd=${1-}
shift || true
case "$cmd" in
  message)
    [ "$#" -ge 1 ] || die "usage: fm-slack-post.sh [--long <reason>] message <text> [thread_ts]"
    captain_comms_guard_or_die "$1"
    post_message "$@"
    ;;
  decision)
    [ "$#" -ge 2 ] || die "usage: fm-slack-post.sh [--long <reason>] decision <key> <text> [option...]"
    post_decision "$@"
    ;;
  update)
    [ "$#" -eq 2 ] || die "usage: fm-slack-post.sh [--long <reason>] update <message_ts> <text>"
    captain_comms_guard_or_die "$2"
    update_message "$1" "$2"
    ;;
  board)
    [ "$#" -eq 1 ] || die "usage: fm-slack-post.sh board <text>"
    existing=$(board_meta_read 2>/dev/null || true)
    if [ -n "$existing" ]; then
      stored_channel=$(board_meta_channel 2>/dev/null || true)
      [ "$stored_channel" = "$FMS_CHANNEL_ID" ] || die "refusing board update for mismatched channel"
      update_message "$existing" "$1"
    else
      ts=$(post_message "$1")
      board_meta_write "$ts" || die "could not record board message"
      printf '%s\n' "$ts"
    fi
    ;;
  *)
    die "usage: fm-slack-post.sh [--long <reason>] message|update|decision ... | board <text>"
    ;;
esac
