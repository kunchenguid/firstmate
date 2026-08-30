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
#   fm-slack-post.sh board <text>   # chat.update when state/slack-board.meta/ exists,
#                                   # otherwise chat.postMessage and record ts
#
# board keeps one permanent live message, identified by state/slack-board.meta/,
# and edits it in place. It also tracks the last applied date and body under
# state/slack-board.meta/slack-board.state. On the first board call whose local
# date differs from that stored date, it posts exactly one ordinary unpinned
# chat.postMessage snapshot of the previous date's body, deduped by a once-file
# under state/slack-board-snapshots/<date>, before updating the live message.
# Days with no board call get no synthetic snapshot. board never calls
# pins.add, pins.remove, or chat.delete, and never edits or deletes a snapshot.
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
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-slack-lib.sh
. "$SCRIPT_DIR/fm-slack-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

BOARD_LOCK="$STATE/.slack-board.lock"
BOARD_PENDING="$STATE/slack-board.meta/slack-board.pending"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

board_state_root_prepare() {
  if [ -e "$STATE" ] || [ -L "$STATE" ]; then
    [ -d "$STATE" ] || die "invalid Slack board state directory"
  else
    (umask 077; mkdir -p "$STATE") || die "could not create Slack board state directory"
  fi
}

fms_load_config
fms_configured || die "Slack captain channel is not configured"

command -v curl >/dev/null 2>&1 || die "missing curl"
command -v jq   >/dev/null 2>&1 || die "missing jq"

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-slack-post.XXXXXX") || exit 1
TEXT_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-slack-post-text.XXXXXX") || exit 1
BOARD_RECOVERY_BODY_FILE=
BOARD_RECOVERY_NEW_BODY_FILE=
BOARD_INPUT_BODY_FILE=
BOARD_LOCK_HELD=0

board_lock_release() {
  if [ "$BOARD_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$BOARD_LOCK"
    BOARD_LOCK_HELD=0
  fi
}

trap 'rm -f "$BODY_FILE" "$TEXT_FILE" "$BOARD_RECOVERY_BODY_FILE" "$BOARD_RECOVERY_NEW_BODY_FILE" "$BOARD_INPUT_BODY_FILE"; board_lock_release' EXIT

post_message_file() {
  local text_file=$1 thread_ts=${2:-} data ts
  fms_channel_configured || die "refusing channel mismatch on post"
  [ -f "$text_file" ] && [ ! -L "$text_file" ] || die "invalid message text file"
  data="channel=$(printf '%s' "$FMS_CHANNEL_ID" | jq -sRr @uri)"
  data="${data}&text=$(jq -sRr @uri < "$text_file")"
  if [ -n "$thread_ts" ]; then
    fms_message_ts_valid "$thread_ts" || die "invalid thread_ts"
    data="${data}&thread_ts=$(printf '%s' "$thread_ts" | jq -sRr @uri)"
  fi
  fms_api_post chat.postMessage "$data" "$BODY_FILE" || die "chat.postMessage transport failed"
  fms_api_json_ok "$BODY_FILE" || die "chat.postMessage rejected"
  fms_api_response_channel_ok "$BODY_FILE" || die "refusing response channel mismatch on post"
  ts=$(jq -r '.ts // empty' "$BODY_FILE" 2>/dev/null) || ts=
  [ -n "$ts" ] || die "chat.postMessage returned no ts"
  fms_message_ts_valid "$ts" || die "chat.postMessage returned invalid ts"
  printf '%s\n' "$ts"
}

post_message() {
  printf '%s' "$1" > "$TEXT_FILE" || die "could not prepare message text"
  post_message_file "$TEXT_FILE" "${2:-}"
}

update_message_file() {
  local message_ts=$1 text_file=$2 data
  fms_message_ts_valid "$message_ts" || die "invalid message ts"
  fms_channel_configured || die "refusing channel mismatch on update"
  [ -f "$text_file" ] && [ ! -L "$text_file" ] || die "invalid message text file"
  data="channel=$(printf '%s' "$FMS_CHANNEL_ID" | jq -sRr @uri)"
  data="${data}&ts=$(printf '%s' "$message_ts" | jq -sRr @uri)"
  data="${data}&text=$(jq -sRr @uri < "$text_file")"
  fms_api_post chat.update "$data" "$BODY_FILE" || die "chat.update transport failed"
  fms_api_json_ok "$BODY_FILE" || die "chat.update rejected"
  fms_api_response_channel_ok "$BODY_FILE" || die "refusing response channel mismatch on update"
  printf '%s\n' "$message_ts"
}

update_message() {
  local message_ts=$1 text=$2
  printf '%s' "$text" > "$TEXT_FILE" || die "could not prepare message text"
  update_message_file "$message_ts" "$TEXT_FILE"
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

# Local host date, overridable so the hermetic test suite never depends on the
# wall clock or a midnight boundary.
board_today() {
  if [ -n "${FM_SLACK_BOARD_TODAY_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_SLACK_BOARD_TODAY_OVERRIDE"
  else
    date +%Y-%m-%d
  fi
}

# Sibling private file: the last successfully applied live-board date and body.
# A sibling to slack-board.meta, not a third field on it, because the body may
# contain newlines a key=value grep parser cannot round-trip.
board_state_present() {
  local file=$STATE/slack-board.meta/slack-board.state
  [ -e "$file" ] || [ -L "$file" ]
}

board_state_valid() {
  local file=$STATE/slack-board.meta/slack-board.state
  fmx_private_artifact_file_valid "$STATE/slack-board.meta" "slack-board.state" 600 2>/dev/null || return 1
  jq -e '
    type == "object"
    and (.date | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    and (.body | type == "string")
  ' "$file" >/dev/null 2>&1
}

board_state_read_date() {
  local file=$STATE/slack-board.meta/slack-board.state
  board_state_valid || return 1
  jq -er '.date' "$file" 2>/dev/null
}

board_state_read_body_file() {
  local file=$STATE/slack-board.meta/slack-board.state dest=$1
  board_state_valid || return 1
  jq -j '.body' "$file" > "$dest" 2>/dev/null
}

board_state_write_file() {
  local date=$1 body_file=$2
  jq -n --arg date "$date" --rawfile body "$body_file" \
    '{date: $date, body: $body}' \
    | fmx_private_artifact_publish_stdin "$STATE/slack-board.meta" "slack-board.state" 600
}

board_state_write() {
  local date=$1 body=$2
  printf '%s' "$body" > "$TEXT_FILE" || return 1
  board_state_write_file "$date" "$TEXT_FILE"
}

board_pending_present() {
  [ -e "$BOARD_PENDING" ] || [ -L "$BOARD_PENDING" ]
}

board_pending_valid() {
  fmx_private_artifact_file_valid "$STATE/slack-board.meta" "slack-board.pending" 600 2>/dev/null || return 1
  jq -e '
    type == "object"
    and (.phase == "initial-posting" or .phase == "initial-posted" or
         .phase == "initial-meta-written" or .phase == "initial-state-needs-write" or
         .phase == "snapshot-needed" or .phase == "snapshot-posting" or
         .phase == "snapshot-posted" or .phase == "live-needs-update" or
         .phase == "state-needs-write")
    and (.date | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    and (.today | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    and (.body | type == "string")
    and (.new_body | type == "string")
    and (.live_ts | type == "string")
    and (.snapshot_ts | type == "string")
    and (if (.phase == "initial-posting" or .phase == "initial-posted" or
             .phase == "initial-meta-written" or .phase == "initial-state-needs-write")
         then (.channel | type == "string") else true end)
  ' "$BOARD_PENDING" >/dev/null 2>&1
}

board_pending_write() {
  local phase=$1 date=$2 body_file=$3 today=$4 new_body_file=$5 live_ts=$6 snapshot_ts=$7
  jq -n --arg phase "$phase" --arg date "$date" --rawfile body "$body_file" \
    --arg today "$today" --rawfile new_body "$new_body_file" \
    --arg live_ts "$live_ts" --arg snapshot_ts "$snapshot_ts" \
    --arg channel "$FMS_CHANNEL_ID" \
    '{phase: $phase, date: $date, body: $body, today: $today,
      new_body: $new_body, live_ts: $live_ts, snapshot_ts: $snapshot_ts,
      channel: $channel}' \
    | fmx_private_artifact_publish_stdin "$STATE/slack-board.meta" "slack-board.pending" 600
}

board_pending_copy_body() {
  local dest=$1
  jq -j '.body' "$BOARD_PENDING" > "$dest" 2>/dev/null
}

board_pending_copy_new_body() {
  local dest=$1
  jq -j '.new_body' "$BOARD_PENDING" > "$dest" 2>/dev/null
}

board_pending_clear() {
  rm -f -- "$BOARD_PENDING" || return 1
  [ ! -e "$BOARD_PENDING" ] && [ ! -L "$BOARD_PENDING" ]
}

board_snapshot_post_file() {
  local date=$1 body_file=$2 ts
  { printf 'Fleet board close %s\n' "$date"; cat "$body_file"; } > "$TEXT_FILE" \
    || die "could not prepare board snapshot text"
  ts=$(post_message_file "$TEXT_FILE") \
    || die "board snapshot post failed before its timestamp could be recorded"
  printf '%s\n' "$ts" \
    | fmx_private_artifact_publish_stdin_once "$STATE/slack-board-snapshots" "$date" 600 >/dev/null \
    || die "board snapshot posted at $ts but its once-file could not be recorded; seed state/slack-board-snapshots/$date with that ts before the next board call"
  printf '%s\n' "$ts"
}

board_snapshot_once_ensure() {
  local date=$1 snapshot_ts=$2 rc
  printf '%s\n' "$snapshot_ts" \
    | fmx_private_artifact_publish_stdin_once "$STATE/slack-board-snapshots" "$date" 600 >/dev/null \
    || rc=$?
  case "${rc:-0}" in
    0|1) return 0 ;;
    *) return 1 ;;
  esac
}

board_initial_pending_recover() {
  local existing=$1 phase date today live_ts snapshot_ts channel
  if ! board_pending_present; then
    return 0
  fi
  board_pending_valid || die "invalid board pending journal at $BOARD_PENDING"
  phase=$(jq -er '.phase' "$BOARD_PENDING") || die "invalid board pending journal at $BOARD_PENDING"
  case "$phase" in
    initial-*) ;;
    *) return 0 ;;
  esac
  date=$(jq -er '.date' "$BOARD_PENDING") || die "invalid board pending journal at $BOARD_PENDING"
  today=$(jq -er '.today' "$BOARD_PENDING") || die "invalid board pending journal at $BOARD_PENDING"
  live_ts=$(jq -er '.live_ts' "$BOARD_PENDING") || die "invalid board pending journal at $BOARD_PENDING"
  snapshot_ts=$(jq -er '.snapshot_ts' "$BOARD_PENDING") || die "invalid board pending journal at $BOARD_PENDING"
  channel=$(jq -er '.channel' "$BOARD_PENDING") || die "invalid initial board pending journal at $BOARD_PENDING"
  [ "$channel" = "$FMS_CHANNEL_ID" ] || die "refusing initial board recovery for mismatched channel"
  [ -z "$snapshot_ts" ] || die "invalid initial board pending journal at $BOARD_PENDING"
  if [ -n "$existing" ] && [ -n "$live_ts" ] && [ "$live_ts" != "$existing" ]; then
    die "board pending journal targets a different live message"
  fi
  BOARD_RECOVERY_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-slack-board-body.XXXXXX") || exit 1
  BOARD_RECOVERY_NEW_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-slack-board-new-body.XXXXXX") || exit 1
  board_pending_copy_body "$BOARD_RECOVERY_BODY_FILE" || die "invalid board pending journal body"
  board_pending_copy_new_body "$BOARD_RECOVERY_NEW_BODY_FILE" || die "invalid board pending journal body"

  while :; do
    case "$phase" in
      initial-posting)
        die "initial board delivery outcome is unknown; inspect the live board and clear $BOARD_PENDING before retrying"
        ;;
      initial-posted)
        [ -n "$live_ts" ] || die "invalid initial board pending journal at $BOARD_PENDING"
        board_pending_write initial-meta-written "$date" "$BOARD_RECOVERY_BODY_FILE" "$today" \
          "$BOARD_RECOVERY_NEW_BODY_FILE" "$live_ts" "" \
          || die "initial board recovery journal could not be recorded"
        phase=initial-meta-written
        ;;
      initial-meta-written)
        board_meta_write "$live_ts" || die "initial board posted at $live_ts but its meta could not be recorded"
        board_pending_write initial-state-needs-write "$date" "$BOARD_RECOVERY_BODY_FILE" "$today" \
          "$BOARD_RECOVERY_NEW_BODY_FILE" "$live_ts" "" \
          || die "initial board meta was recorded but its recovery journal could not be recorded"
        phase=initial-state-needs-write
        ;;
      initial-state-needs-write)
        board_state_write_file "$today" "$BOARD_RECOVERY_NEW_BODY_FILE" \
          || die "initial board posted at $live_ts but its state could not be recorded"
        board_pending_clear || die "initial board state was recorded but its recovery journal could not be cleared"
        rm -f -- "$BOARD_RECOVERY_BODY_FILE" "$BOARD_RECOVERY_NEW_BODY_FILE"
        BOARD_RECOVERY_BODY_FILE=
        BOARD_RECOVERY_NEW_BODY_FILE=
        return 0
        ;;
    esac
  done
}

board_pending_recover() {
  local existing=$1 phase date today live_ts snapshot_ts
  if ! board_pending_present; then
    return 0
  fi
  board_pending_valid || die "invalid board pending journal at $BOARD_PENDING"
  phase=$(jq -er '.phase' "$BOARD_PENDING") || die "invalid board pending journal at $BOARD_PENDING"
  date=$(jq -er '.date' "$BOARD_PENDING") || die "invalid board pending journal at $BOARD_PENDING"
  today=$(jq -er '.today' "$BOARD_PENDING") || die "invalid board pending journal at $BOARD_PENDING"
  live_ts=$(jq -er '.live_ts' "$BOARD_PENDING") || die "invalid board pending journal at $BOARD_PENDING"
  snapshot_ts=$(jq -er '.snapshot_ts' "$BOARD_PENDING") || die "invalid board pending journal at $BOARD_PENDING"
  [ "$live_ts" = "$existing" ] || die "board pending journal targets a different live message"
  BOARD_RECOVERY_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-slack-board-body.XXXXXX") || exit 1
  BOARD_RECOVERY_NEW_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-slack-board-new-body.XXXXXX") || exit 1
  board_pending_copy_body "$BOARD_RECOVERY_BODY_FILE" || die "invalid board pending journal body"
  board_pending_copy_new_body "$BOARD_RECOVERY_NEW_BODY_FILE" || die "invalid board pending journal body"

  while :; do
    case "$phase" in
      snapshot-needed)
        if fmx_private_artifact_file_valid "$STATE/slack-board-snapshots" "$date" 600 2>/dev/null; then
          snapshot_ts=$(cat "$STATE/slack-board-snapshots/$date") || die "could not read board snapshot once-file"
          board_pending_write snapshot-posted "$date" "$BOARD_RECOVERY_BODY_FILE" "$today" \
            "$BOARD_RECOVERY_NEW_BODY_FILE" "$live_ts" "$snapshot_ts" \
            || die "board snapshot recovery journal could not be recorded"
        else
          board_pending_write snapshot-posting "$date" "$BOARD_RECOVERY_BODY_FILE" "$today" \
            "$BOARD_RECOVERY_NEW_BODY_FILE" "$live_ts" "" \
            || die "could not record board snapshot pending phase"
          snapshot_ts=$(board_snapshot_post_file "$date" "$BOARD_RECOVERY_BODY_FILE")
          board_pending_write snapshot-posted "$date" "$BOARD_RECOVERY_BODY_FILE" "$today" \
            "$BOARD_RECOVERY_NEW_BODY_FILE" "$live_ts" "$snapshot_ts" \
            || die "board snapshot posted at $snapshot_ts but its recovery journal could not be recorded"
        fi
        phase='snapshot-posted'
        ;;
      snapshot-posting)
        if fmx_private_artifact_file_valid "$STATE/slack-board-snapshots" "$date" 600 2>/dev/null; then
          snapshot_ts=$(cat "$STATE/slack-board-snapshots/$date") || die "could not read board snapshot once-file"
          board_pending_write snapshot-posted "$date" "$BOARD_RECOVERY_BODY_FILE" "$today" \
            "$BOARD_RECOVERY_NEW_BODY_FILE" "$live_ts" "$snapshot_ts" \
            || die "board snapshot recovery journal could not be recorded"
          phase='snapshot-posted'
        else
          die "board snapshot delivery outcome for $date is unknown; seed state/slack-board-snapshots/$date with its ts before the next board call"
        fi
        ;;
      snapshot-posted)
        board_snapshot_once_ensure "$date" "$snapshot_ts" \
          || die "board snapshot once-file could not be recovered for $date"
        board_pending_write live-needs-update "$date" "$BOARD_RECOVERY_BODY_FILE" "$today" \
          "$BOARD_RECOVERY_NEW_BODY_FILE" "$live_ts" "$snapshot_ts" \
          || die "could not record board live-update pending phase"
        phase=live-needs-update
        ;;
      live-needs-update)
        update_message_file "$live_ts" "$BOARD_RECOVERY_NEW_BODY_FILE" >/dev/null
        board_pending_write state-needs-write "$date" "$BOARD_RECOVERY_BODY_FILE" "$today" \
          "$BOARD_RECOVERY_NEW_BODY_FILE" "$live_ts" "$snapshot_ts" \
          || die "board updated at $live_ts but its recovery journal could not be recorded"
        phase='state-needs-write'
        ;;
      state-needs-write)
        board_state_write_file "$today" "$BOARD_RECOVERY_NEW_BODY_FILE" \
          || die "board updated at $live_ts but its state could not be recorded"
        board_pending_clear || die "board state was recorded but its recovery journal could not be cleared"
        rm -f -- "$BOARD_RECOVERY_BODY_FILE" "$BOARD_RECOVERY_NEW_BODY_FILE"
        BOARD_RECOVERY_BODY_FILE=
        BOARD_RECOVERY_NEW_BODY_FILE=
        return 0
        ;;
    esac
  done
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

board_initial_create() {
  local text=$1 today ts
  today=$(board_today)
  printf '%s' "$text" > "$TEXT_FILE" || die "could not prepare board text"
  board_pending_write initial-posting "$today" "$TEXT_FILE" "$today" "$TEXT_FILE" "" "" \
    || die "could not record initial board pending journal"
  ts=$(post_message_file "$TEXT_FILE")
  board_pending_write initial-posted "$today" "$TEXT_FILE" "$today" "$TEXT_FILE" "$ts" "" \
    || die "initial board posted at $ts but its recovery journal could not be recorded"
  board_initial_pending_recover ""
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
    board_state_root_prepare
    fm_lock_acquire_wait "$BOARD_LOCK" || die "could not acquire board lock"
    BOARD_LOCK_HELD=1
    if [ -e "$STATE/slack-board.meta/slack-board.meta" ] || [ -L "$STATE/slack-board.meta/slack-board.meta" ]; then
      existing=$(board_meta_read 2>/dev/null) \
        || die "invalid board meta at $STATE/slack-board.meta/slack-board.meta"
      [ -n "$existing" ] \
        || die "invalid board meta at $STATE/slack-board.meta/slack-board.meta"
    else
      existing=
    fi
    if [ -n "$existing" ]; then
      stored_channel=$(board_meta_channel 2>/dev/null || true)
      [ "$stored_channel" = "$FMS_CHANNEL_ID" ] || die "refusing board update for mismatched channel"
    fi
    if board_pending_present; then
      board_pending_valid || die "invalid board pending journal at $BOARD_PENDING"
      pending_phase=$(jq -er '.phase' "$BOARD_PENDING") || die "invalid board pending journal at $BOARD_PENDING"
      case "$pending_phase" in
        initial-*)
          board_initial_pending_recover "$existing"
          existing=$(board_meta_read 2>/dev/null) \
            || die "invalid board meta at $STATE/slack-board.meta/slack-board.meta"
          [ -n "$existing" ] \
            || die "invalid board meta at $STATE/slack-board.meta/slack-board.meta"
          ;;
        *)
          [ -n "$existing" ] || die "board pending journal has no live board meta"
          ;;
      esac
    fi
    if [ -n "$existing" ]; then
      board_pending_recover "$existing"
      today=$(board_today)
      printf '%s' "$1" > "$TEXT_FILE" || die "could not prepare board text"
      if board_state_present; then
        stored_date=$(board_state_read_date) || die "invalid board state at $STATE/slack-board.meta/slack-board.state"
        BOARD_INPUT_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-slack-board-body.XXXXXX") || exit 1
        board_state_read_body_file "$BOARD_INPUT_BODY_FILE" \
          || die "invalid board state at $STATE/slack-board.meta/slack-board.state"
      else
        stored_date=
        BOARD_INPUT_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-slack-board-body.XXXXXX") || exit 1
      fi
      if [ -n "$stored_date" ] && [ "$stored_date" != "$today" ]; then
        board_pending_write snapshot-needed "$stored_date" "$BOARD_INPUT_BODY_FILE" "$today" \
          "$TEXT_FILE" "$existing" "" \
          || die "could not record board rollover pending journal"
      else
        board_pending_write live-needs-update "${stored_date:-$today}" "$BOARD_INPUT_BODY_FILE" "$today" \
          "$TEXT_FILE" "$existing" "" \
          || die "could not record board update pending journal"
      fi
      board_pending_recover "$existing"
      rm -f -- "$BOARD_INPUT_BODY_FILE"
      BOARD_INPUT_BODY_FILE=
      printf '%s\n' "$existing"
    else
      board_initial_create "$1"
    fi
    ;;
  *)
    die "usage: fm-slack-post.sh [--long <reason>] message|update|decision ... | board <text>"
    ;;
esac
