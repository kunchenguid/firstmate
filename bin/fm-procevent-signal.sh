#!/usr/bin/env bash
# Optional Signal group adapter for the generic process-event runner.
#
# Usage:
#   fm-procevent-signal.sh arm <selector>
#   fm-procevent-signal.sh source
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
# Readiness uses the accepted time-based boundary documented in docs/architecture.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GROUPS_FILE="$CONFIG/signal-groups"
SEND_TIMEOUT=${FM_SIGNAL_COMMAND_TIMEOUT:-30}
SOURCE_ID=signal-account

# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

PRIVATE_TEMPFILES=()

cleanup_private_tempfiles() {
  local file
  for file in "${PRIVATE_TEMPFILES[@]:-}"; do
    [ -n "$file" ] && rm -f -- "$file"
  done
  PRIVATE_TEMPFILES=()
}

exit_on_signal() {
  local status=$1
  trap - EXIT HUP INT TERM
  cleanup_private_tempfiles
  exit "$status"
}

trap cleanup_private_tempfiles EXIT
trap 'exit_on_signal 129' HUP
trap 'exit_on_signal 130' INT
trap 'exit_on_signal 143' TERM

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

positive_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; 0) return 1 ;; *) return 0 ;; esac }

private_tempfile() {
  local target=$1 template=$2 file
  file=$(mktemp "$template") || return 1
  PRIVATE_TEMPFILES+=("$file")
  chmod 600 "$file" || return 1
  printf -v "$target" '%s' "$file"
}

validate_selector() {
  case "${1-}" in
    ''|*[!A-Za-z0-9._-]*) die "invalid Signal group selector" ;;
  esac
  [ "${#1}" -le 48 ] || die "Signal group selector is too long"
}

source_id() {
  validate_selector "$1"
  printf '%s\n' "$SOURCE_ID"
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
  printf '%s/signal/account.lock\n' "$STATE"
}

signal_registration_matches_locked() {
  local registration adapter argc heading program command extra
  registration="$(fm_procevent_registry_dir "$STATE")/$SOURCE_ID.source"
  [ -f "$registration" ] && [ ! -L "$registration" ] || return 1
  {
    IFS= read -r adapter \
      && IFS= read -r argc \
      && IFS= read -r heading \
      && IFS= read -r program \
      && IFS= read -r command \
      && ! IFS= read -r extra
  } < "$registration" || return 1
  [ "$adapter" = adapter=signal ] \
    && [ "$argc" = argc=2 ] \
    && [ "$heading" = argv: ] \
    && [ "$program" = "$SCRIPT_DIR/fm-procevent-signal.sh" ] \
    && [ "$command" = source ]
}

signal_account_accessible() {
  local claim status=0
  fm_procevent_source_lock_acquire "$SOURCE_ID" || return 1
  claim=$(fm_procevent_claim_path "$SOURCE_ID")
  if [ -e "$claim" ] || [ -L "$claim" ]; then
    if [ ! -f "$claim" ] || [ -L "$claim" ] \
      || ! fm_procevent_claim_load_locked "$SOURCE_ID" 2>/dev/null; then
      status=1
    elif [ "$FM_PROCEVENT_CLAIM_HOME" != "$FM_HOME" ]; then
      status=2
    fi
  fi
  fm_procevent_source_lock_release "$SOURCE_ID" || status=1
  return "$status"
}

signal_account_access_error() {
  case "$1" in
    2) die "Signal account is active in another home" ;;
    *) die "cannot verify Signal account ownership" ;;
  esac
}

require_signal_account_access() {
  local status
  signal_account_accessible
  status=$?
  [ "$status" -eq 0 ] || signal_account_access_error "$status"
}

account_from_output() {
  awk '
    /^Number:[[:space:]]*[^[:space:]]+/ { count++; value = $2 }
    END { if (count == 1) print value; else exit 1 }
  ' "$1"
}

account_number() {
  local target=$1 output discovered
  positive_int "$SEND_TIMEOUT" || die "FM_SIGNAL_COMMAND_TIMEOUT must be a positive integer"
  require_signal_account_access
  private_tempfile output "${TMPDIR:-/tmp}/fm-signal-accounts.XXXXXX" || die "cannot create private account result"
  if ! fm_run_timed "$SEND_TIMEOUT" signal-cli listAccounts >"$output" 2>/dev/null; then
    rm -f "$output"
    die "Signal account discovery failed or timed out"
  fi
  discovered=$(account_from_output "$output") || {
    rm -f "$output"
    die "Signal account discovery requires exactly one account"
  }
  rm -f "$output"
  case "$discovered" in
    +[0-9]*)
      case "${discovered#+}" in *[!0-9]*) die "Signal account discovery returned no usable account" ;; esac
      ;;
    *) die "Signal account discovery returned no usable account" ;;
  esac
  printf -v "$target" '%s' "$discovered"
}

emit_message() {
  SIGNAL_GROUPS_FILE="$GROUPS_FILE" python3 -c '
import json
import os
import re
import sys

groups = {}
selectors = set()
try:
    with open(os.environ["SIGNAL_GROUPS_FILE"], "rb") as source:
        for raw in source:
            line = raw.rstrip(b"\n")
            if not line.strip() or line.lstrip().startswith(b"#"):
                continue
            parts = line.split(b"\t")
            if len(parts) != 3:
                raise SystemExit(3)
            try:
                selector = parts[0].decode("ascii")
                group = parts[1].decode("ascii")
                label = parts[2].decode()
            except UnicodeDecodeError:
                raise SystemExit(3)
            if not re.fullmatch(r"[A-Za-z0-9._-]{1,48}", selector):
                raise SystemExit(3)
            if not re.fullmatch(r"[A-Za-z0-9+/=_-]+", group):
                raise SystemExit(3)
            if not label or "\r" in label or len(label) > 64:
                raise SystemExit(3)
            if selector in selectors or group in groups:
                raise SystemExit(3)
            selectors.add(selector)
            groups[group] = selector
except OSError:
    raise SystemExit(3)
if not groups:
    raise SystemExit(3)
if os.environ.get("SIGNAL_VALIDATE_ONLY") == "1":
    raise SystemExit(0)

try:
    document = json.load(sys.stdin.buffer)
    message = document["envelope"]["dataMessage"]
    group = message["groupInfo"]["groupId"]
    body = message["message"]
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(2)
if not isinstance(group, str) or not isinstance(body, str) or not body:
    raise SystemExit(2)
selector = groups.get(group)
if selector is None:
    raise SystemExit(2)
body_bytes = body.encode()
sys.stdout.write("schema=fm-signal.v1\n")
sys.stdout.write("selector=" + selector + "\n")
sys.stdout.write("body-bytes=" + str(len(body_bytes)) + "\n\n")
sys.stdout.flush()
sys.stdout.buffer.write(body_bytes)
'
}

validate_routes() {
  SIGNAL_VALIDATE_ONLY=1 emit_message </dev/null
}

cmd_source() {
  local account
  local -a receive_status
  ensure_groups_file
  validate_routes || exit 1
  account_number account || exit 1
  while :; do
    require_signal_account_access
    "$SCRIPT_DIR/fm-procevent.sh" ready "$SOURCE_ID" >/dev/null || return 1
    if signal-cli -a "$account" -o json receive -t -1 --max-messages 1 \
      --ignore-attachments --ignore-stories --ignore-avatars --ignore-stickers 2>/dev/null \
      | emit_message; then
      return 0
    fi
    receive_status=("${PIPESTATUS[@]}")
    "$SCRIPT_DIR/fm-procevent.sh" unready "$SOURCE_ID" >/dev/null || return 1
    [ "${receive_status[1]}" -eq 2 ] || return 1
    [ "${receive_status[0]}" -eq 0 ] || sleep 1
  done
}

cmd_arm_locked() {
  local selector=$1 status=0
  validate_routes || die "Signal group configuration is invalid"
  group_id "$selector" >/dev/null
  fm_procevent_source_lock_acquire "$SOURCE_ID" || die "cannot lock Signal receive source"
  if ! signal_registration_matches_locked \
    && ! fm_procevent_registration_publish_locked "$STATE" signal "$SOURCE_ID" \
      "$SCRIPT_DIR/fm-procevent-signal.sh" source; then
    status=1
  fi
  fm_procevent_source_lock_release "$SOURCE_ID" || status=1
  [ "$status" -eq 0 ] || die "cannot register Signal receive source"
  printf 'armed: Signal source\n'
}

cmd_arm() {
  local selector=${1-} lock
  validate_selector "$selector"
  lock=$(lifecycle_lock)
  mkdir -p "${lock%/*}" || die "cannot create Signal lifecycle state"
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock Signal lifecycle"
    trap 'fm_lock_release "$lock"' EXIT
    cmd_arm_locked "$selector"
  )
}

cmd_retire_locked() {
  "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID"
}

cmd_retire() {
  local selector=${1-} lock
  validate_selector "$selector"
  lock=$(lifecycle_lock)
  mkdir -p "${lock%/*}" || die "cannot create Signal lifecycle state"
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock Signal lifecycle"
    trap 'fm_lock_release "$lock"' EXIT
    cmd_retire_locked "$selector"
  )
}

cmd_send_locked() {
  local selector=$1 message=${2:--} group label account raw prefixed ownership_status
  [ "$message" = - ] || { [ -f "$message" ] && [ ! -L "$message" ] || die "message file is not a regular file"; }
  validate_routes || die "Signal group configuration is invalid"
  group=$(group_id "$selector") || exit 1
  label=$(display_label "$selector") || exit 1
  cmd_retire_locked "$selector" >/dev/null || die "could not retire Signal receive source"
  account_number account || exit 1
  private_tempfile raw "${TMPDIR:-/tmp}/fm-signal-raw.XXXXXX" || die "cannot create private Signal message"
  if [ "$message" = - ]; then
    cat >"$raw" || { rm -f "$raw"; die "cannot read Signal message"; }
  else
    cp "$message" "$raw" || { rm -f "$raw"; die "cannot stage Signal message"; }
  fi
  [ -s "$raw" ] || { rm -f "$raw"; die "Signal message is empty"; }
  private_tempfile prefixed "${TMPDIR:-/tmp}/fm-signal-message.XXXXXX" || { rm -f "$raw"; die "cannot create private Signal message"; }
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
  signal_account_accessible
  ownership_status=$?
  if [ "$ownership_status" -ne 0 ]; then
    rm -f "$prefixed"
    signal_account_access_error "$ownership_status"
  fi
  # shellcheck disable=SC2016
  if ! fm_run_timed "$SEND_TIMEOUT" bash -c \
    'signal-cli -a "$1" send -g "$2" --message-from-stdin <"$3"' \
    _ "$account" "$group" "$prefixed" >/dev/null 2>&1; then
    rm -f "$prefixed"
    die "Signal send failed or timed out"
  fi
  rm -f "$prefixed"
  printf 'sent: Signal message\n'
}

cmd_send() {
  local selector=${1-} message=${2:--} lock send_rc=0 staged='' ownership_status
  validate_selector "$selector"
  if [ "$message" = - ]; then
    private_tempfile staged "${TMPDIR:-/tmp}/fm-signal-input.XXXXXX" || die "cannot create private Signal message"
    cat >"$staged" || { rm -f "$staged"; die "cannot read Signal message"; }
    message=$staged
  fi
  lock=$(lifecycle_lock)
  mkdir -p "${lock%/*}" || die "cannot create Signal lifecycle state"
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock Signal lifecycle"
    # shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
    interrupt_send() {
      local status=$1
      trap - EXIT HUP INT TERM
      cleanup_private_tempfiles
      fm_lock_release "$lock"
      exit "$status"
    }
    trap 'interrupt_send 129' HUP
    trap 'interrupt_send 130' INT
    trap 'interrupt_send 143' TERM
    signal_account_accessible
    ownership_status=$?
    if [ "$ownership_status" -ne 0 ]; then
      [ -z "$staged" ] || rm -f "$staged"
      fm_lock_release "$lock"
      signal_account_access_error "$ownership_status"
    fi
    # shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
    restore_source() {
      local status=$?
      trap - EXIT
      cleanup_private_tempfiles
      if ! (cmd_arm_locked "$selector") >/dev/null 2>&1 \
        || ! "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 \
        || ! "$SCRIPT_DIR/fm-procevent.sh" wait-ready "$SOURCE_ID" "$SEND_TIMEOUT" >/dev/null 2>&1; then
        printf 'error: could not restore Signal receive source: %s\n' "$selector" >&2
        status=1
      fi
      [ -z "$staged" ] || rm -f "$staged"
      fm_lock_release "$lock"
      exit "$status"
    }
    trap restore_source EXIT
    cmd_send_locked "$selector" "$message" || send_rc=$?
    return "$send_rc"
  )
}

cmd_classify() {
  local file=${1-}
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist"
  grep -q '^schema=fm-signal.v1$' "$file" && printf 'message\n' || printf 'unknown\n'
}

case "${1:-}" in
  arm) shift; [ "$#" -eq 1 ] || usage; cmd_arm "$1" ;;
  source) shift; [ "$#" -eq 0 ] || usage; cmd_source ;;
  send) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_send "$@" ;;
  retire) shift; [ "$#" -eq 1 ] || usage; cmd_retire "$1" ;;
  source-id) shift; [ "$#" -eq 1 ] || usage; source_id "$1" ;;
  classify) shift; [ "$#" -eq 1 ] || usage; cmd_classify "$1" ;;
  terminal) shift; [ "$#" -eq 1 ] || usage; exit 1 ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command" ;;
esac
