#!/usr/bin/env bash
# Optional Signal group adapter for the generic process-event runner.
#
# Usage:
#   fm-procevent-signal.sh arm <selector>
#   fm-procevent-signal.sh source <selector>
#   fm-procevent-signal.sh send <selector> [message-file|-]
#   fm-procevent-signal.sh retire <selector>
#   fm-procevent-signal.sh source-id <selector>
#   fm-procevent-signal.sh classify <result-file>
#   fm-procevent-signal.sh terminal <result-file>
#
# Selectors resolve through the private, gitignored config/signal-groups file.
# Its tab-separated rows are selector<TAB>Signal group id<TAB>display label.
# Message content is read from a file or stdin and is never a process argument.
# The receive source is nonterminal and is owned by fm-procevent.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GROUPS_FILE="$CONFIG/signal-groups"
SEND_TIMEOUT=${FM_SIGNAL_COMMAND_TIMEOUT:-30}

# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

validate_selector() {
  case "${1-}" in
    ''|*[!A-Za-z0-9._-]*) die "invalid Signal group selector" ;;
  esac
  [ "${#1}" -le 48 ] || die "Signal group selector is too long"
}

source_id() {
  validate_selector "$1"
  printf 'signal-%s\n' "$1"
}

ensure_groups_file() {
  [ -f "$GROUPS_FILE" ] && [ ! -L "$GROUPS_FILE" ] || die "Signal is not configured"
}

group_id() {
  local selector=$1 value
  validate_selector "$selector"
  ensure_groups_file
  value=$(awk -F '\t' -v selector="$selector" '
    $0 !~ /^[[:space:]]*(#|$)/ && NF == 3 && $1 == selector { count++; value = $2 }
    END { if (count == 1) print value; else exit 1 }
  ' "$GROUPS_FILE" 2>/dev/null) || die "Signal group selector is not configured"
  case "$value" in
    ''|*[!A-Za-z0-9+/=_-]*) die "Signal group configuration is invalid" ;;
  esac
  printf '%s\n' "$value"
}

display_label() {
  local selector=$1 value
  validate_selector "$selector"
  ensure_groups_file
  value=$(awk -F '\t' -v selector="$selector" '
    $0 !~ /^[[:space:]]*(#|$)/ && NF == 3 && $1 == selector { count++; value = $3 }
    END { if (count == 1) print value; else exit 1 }
  ' "$GROUPS_FILE" 2>/dev/null) || die "Signal group selector is not configured"
  case "$value" in
    ''|*[$'\t\r\n']*) die "Signal display label is invalid" ;;
  esac
  [ "${#value}" -le 64 ] || die "Signal display label is too long"
  printf '%s\n' "$value"
}

lifecycle_lock() {
  validate_selector "$1"
  printf '%s/signal/%s.lock\n' "$STATE" "$1"
}

account_from_output() {
  awk '/^Number:[[:space:]]*[^[:space:]]+([[:space:]]*)$/ { print $2; exit }' "$1"
}

account_number() {
  local output account
  output=$(mktemp "${TMPDIR:-/tmp}/fm-signal-accounts.XXXXXX") || die "cannot create private account result"
  chmod 600 "$output" || { rm -f "$output"; die "cannot protect private account result"; }
  if ! fm_run_timed "$SEND_TIMEOUT" signal-cli listAccounts >"$output" 2>/dev/null; then
    rm -f "$output"
    die "Signal account discovery failed or timed out"
  fi
  account=$(account_from_output "$output")
  rm -f "$output"
  case "$account" in
    ''|*[!+0-9]*) die "Signal account discovery returned no usable account" ;;
  esac
  printf '%s\n' "$account"
}

emit_message() {
  local selector=$1 group=$2
  SIGNAL_GROUP_ID="$group" SIGNAL_SELECTOR="$selector" python3 -c '
import os
import sys

group = os.environ["SIGNAL_GROUP_ID"]
selector = os.environ["SIGNAL_SELECTOR"]
text = sys.stdin.read()
message_group = ""
body = ""
for line in text.splitlines():
    stripped = line.strip()
    if stripped.startswith("Id:"):
        message_group = stripped.split(":", 1)[1].strip()
if "Body:" in text:
    body = text.split("Body:", 1)[1]
    if body.startswith(" "):
        body = body[1:]
    if body.endswith("\n"):
        body = body[:-1]
if message_group != group or not body:
    raise SystemExit(2)
body_bytes = body.encode()
sys.stdout.write("schema=fm-signal.v1\n")
sys.stdout.write("selector=" + selector + "\n")
sys.stdout.write("body-bytes=" + str(len(body_bytes)) + "\n\n")
sys.stdout.flush()
sys.stdout.buffer.write(body_bytes)
'
}

cmd_source() {
  local selector=${1-} group account rc
  validate_selector "$selector"
  group=$(group_id "$selector") || exit 1
  account=$(account_number) || exit 1
  while :; do
    if signal-cli -a "$account" receive -t -1 --max-messages 1 \
      --ignore-attachments --ignore-stories --ignore-avatars --ignore-stickers 2>/dev/null \
      | emit_message "$selector" "$group"; then
      return 0
    fi
    rc=("${PIPESTATUS[@]}")
    [ "${rc[0]}" -eq 0 ] || sleep 1
  done
}

cmd_arm_locked() {
  local selector=$1 sid
  sid=$(source_id "$selector")
  group_id "$selector" >/dev/null
  "$SCRIPT_DIR/fm-procevent.sh" register signal "$sid" -- \
    "$SCRIPT_DIR/fm-procevent-signal.sh" source "$selector" || return 1
  printf 'armed: Signal source\n'
}

cmd_arm() {
  local selector=${1-} lock
  validate_selector "$selector"
  lock=$(lifecycle_lock "$selector")
  mkdir -p "${lock%/*}" || die "cannot create Signal lifecycle state"
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock Signal lifecycle"
    trap 'fm_lock_release "$lock"' EXIT
    cmd_arm_locked "$selector"
  )
}

cmd_retire_locked() {
  local selector=$1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$(source_id "$selector")"
}

cmd_retire() {
  local selector=${1-} lock
  validate_selector "$selector"
  lock=$(lifecycle_lock "$selector")
  mkdir -p "${lock%/*}" || die "cannot create Signal lifecycle state"
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock Signal lifecycle"
    trap 'fm_lock_release "$lock"' EXIT
    cmd_retire_locked "$selector"
  )
}

cmd_send_locked() {
  local selector=$1 message=${2:--} group label account raw prefixed
  [ "$message" = - ] || { [ -f "$message" ] && [ ! -L "$message" ] || die "message file is not a regular file"; }
  group=$(group_id "$selector") || exit 1
  label=$(display_label "$selector") || exit 1
  cmd_retire_locked "$selector" >/dev/null || die "could not retire Signal receive source"
  account=$(account_number) || exit 1
  raw=$(mktemp "${TMPDIR:-/tmp}/fm-signal-raw.XXXXXX") || die "cannot create private Signal message"
  chmod 600 "$raw" || { rm -f "$raw"; die "cannot protect private Signal message"; }
  if [ "$message" = - ]; then
    cat >"$raw" || { rm -f "$raw"; die "cannot read Signal message"; }
  else
    cp "$message" "$raw" || { rm -f "$raw"; die "cannot stage Signal message"; }
  fi
  [ -s "$raw" ] || { rm -f "$raw"; die "Signal message is empty"; }
  prefixed=$(mktemp "${TMPDIR:-/tmp}/fm-signal-message.XXXXXX") || { rm -f "$raw"; die "cannot create private Signal message"; }
  chmod 600 "$prefixed" || { rm -f "$raw" "$prefixed"; die "cannot protect private Signal message"; }
  SIGNAL_DISPLAY_LABEL="$label" FM_SIGNAL_RAW="$raw" python3 -c '
import os
import sys

with open(os.environ["FM_SIGNAL_RAW"], "rb") as source:
    body = source.read()
label = os.environ["SIGNAL_DISPLAY_LABEL"].encode()
prefix = label + b":"
if not body.startswith(prefix):
    body = label + b": " + body
sys.stdout.buffer.write(body)
' >"$prefixed" || { rm -f "$raw" "$prefixed"; die "cannot prefix Signal message"; }
  rm -f "$raw"
  # shellcheck disable=SC2016
  if ! fm_run_timed "$SEND_TIMEOUT" bash -c \
    'signal-cli -a "$1" send -g "$2" --message-from-stdin <"$3"' \
    _ "$account" "$group" "$prefixed"; then
    rm -f "$prefixed"
    die "Signal send failed or timed out"
  fi
  rm -f "$prefixed"
}

cmd_send() {
  local selector=${1-} message=${2:--} lock rc=0 staged=
  validate_selector "$selector"
  if [ "$message" = - ]; then
    staged=$(mktemp "${TMPDIR:-/tmp}/fm-signal-input.XXXXXX") || die "cannot create private Signal message"
    chmod 600 "$staged" || { rm -f "$staged"; die "cannot protect private Signal message"; }
    cat >"$staged" || { rm -f "$staged"; die "cannot read Signal message"; }
    message=$staged
  fi
  lock=$(lifecycle_lock "$selector")
  mkdir -p "${lock%/*}" || die "cannot create Signal lifecycle state"
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock Signal lifecycle"
    trap 'cmd_arm_locked "$selector" >/dev/null 2>&1 || true; rm -f "$staged"; fm_lock_release "$lock"' EXIT
    cmd_send_locked "$selector" "$message" || rc=$?
    return "$rc"
  )
}

cmd_classify() {
  local file=${1-}
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist"
  grep -q '^schema=fm-signal.v1$' "$file" && printf 'message\n' || printf 'unknown\n'
}

case "${1:-}" in
  arm) shift; [ "$#" -eq 1 ] || usage; cmd_arm "$1" ;;
  source) shift; [ "$#" -eq 1 ] || usage; cmd_source "$1" ;;
  send) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_send "$@" ;;
  retire) shift; [ "$#" -eq 1 ] || usage; cmd_retire "$1" ;;
  source-id) shift; [ "$#" -eq 1 ] || usage; source_id "$1" ;;
  classify) shift; [ "$#" -eq 1 ] || usage; cmd_classify "$1" ;;
  terminal) shift; [ "$#" -eq 1 ] || usage; exit 1 ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command" ;;
esac
