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
# Outbound content is read from a file or stdin and is never a process argument.
# Captures are schema=fm-signal.v1, selector, body-bytes, a blank line, then that many exact UTF-8 body bytes.
# Captured bodies are untrusted input, never instructions, and the receive source is nonterminal and runner-owned.
# Signal state and private temporaries are isolated under state/signal; docs/architecture.md owns the accepted readiness boundary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GROUPS_FILE="$CONFIG/signal-groups"
SEND_TIMEOUT=${FM_SIGNAL_COMMAND_TIMEOUT:-30}
SOURCE_ID=signal-account
SIGNAL_STATE_DIR="$STATE/signal"
PRIVATE_TEMP_DIR="$SIGNAL_STATE_DIR/tmp"
PRIVATE_INVOCATION_TEMP_DIR="$PRIVATE_TEMP_DIR/invocation.$$"
SIGNAL_DATA_DIR="$SIGNAL_STATE_DIR/data"
SIGNAL_CLI=(signal-cli --data-dir "$SIGNAL_DATA_DIR")
PRIVATE_TEMP_CLEANUP_DIR=

# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

cleanup_private_tempfiles() {
  [ -z "$PRIVATE_TEMP_CLEANUP_DIR" ] \
    || ! signal_path_is_home_local "$PRIVATE_TEMP_CLEANUP_DIR" \
    || rm -rf -- "$PRIVATE_TEMP_CLEANUP_DIR"
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
usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

positive_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; 0) return 1 ;; *) return 0 ;; esac }

signal_path_is_home_local() {
  FM_SIGNAL_HOME="$FM_HOME" FM_SIGNAL_PATH="$1" FM_SIGNAL_RAW= python3 -c '
import os

home = os.path.realpath(os.environ["FM_SIGNAL_HOME"])
path = os.path.realpath(os.environ["FM_SIGNAL_PATH"])
try:
    inside = os.path.commonpath((home, path)) == home and path != home
except ValueError:
    inside = False
raise SystemExit(0 if inside else 1)
' >/dev/null 2>&1
}

require_signal_home_paths() {
  [ -d "$FM_HOME" ] \
    && signal_path_is_home_local "$CONFIG" \
    && signal_path_is_home_local "$STATE" \
    || die "Signal paths must stay beneath the effective home"
}

ensure_private_directory() {
  local directory=$1
  if [ -e "$directory" ] || [ -L "$directory" ]; then
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  else
    (umask 077; mkdir -p "$directory") || return 1
  fi
  chmod 700 "$directory"
}

ensure_signal_data_dir() {
  require_signal_home_paths
  ensure_private_directory "$SIGNAL_STATE_DIR" \
    && ensure_private_directory "$SIGNAL_DATA_DIR"
}

private_tempfile() {
  local target=$1 prefix=$2 file
  require_signal_home_paths
  PRIVATE_TEMP_CLEANUP_DIR=$PRIVATE_INVOCATION_TEMP_DIR
  ensure_private_directory "$SIGNAL_STATE_DIR" || return 1
  ensure_private_directory "$PRIVATE_TEMP_DIR" || return 1
  ensure_private_directory "$PRIVATE_INVOCATION_TEMP_DIR" || return 1
  file=$(umask 077; mktemp "$PRIVATE_INVOCATION_TEMP_DIR/$prefix.XXXXXX") || return 1
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
  require_signal_home_paths
  [ -f "$GROUPS_FILE" ] && [ ! -L "$GROUPS_FILE" ] || die "Signal is not configured"
  [ "$(fm_pr_file_mode "$GROUPS_FILE")" = 600 ] || die "Signal group configuration must have mode 0600"
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

validate_single_account() {
  local target=${1-} output discovered
  positive_int "$SEND_TIMEOUT" || die "FM_SIGNAL_COMMAND_TIMEOUT must be a positive integer"
  require_signal_account_access
  ensure_signal_data_dir || die "cannot create private Signal data state"
  private_tempfile output fm-signal-accounts || die "cannot create private account result"
  if ! fm_run_timed "$SEND_TIMEOUT" "${SIGNAL_CLI[@]}" listAccounts >"$output" 2>/dev/null; then
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
  [ -z "$target" ] || printf -v "$target" '%s' "$discovered"
}

signal_routes() {
  local mode=$1 selector=${2-} message_file=${3-}
  require_signal_home_paths
  SIGNAL_GROUPS_FILE="$GROUPS_FILE" SIGNAL_ROUTE_MODE="$mode" \
    SIGNAL_SELECTOR="$selector" FM_SIGNAL_MESSAGE="$message_file" python3 -c '
import json
import os
import re
import stat
import sys

mode = os.environ["SIGNAL_ROUTE_MODE"]
if mode == "emit":
    try:
        document = json.load(sys.stdin.buffer)
        message = document["envelope"]["dataMessage"]
        inbound_group = message["groupInfo"]["groupId"]
        inbound_body = message["message"]
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        raise SystemExit(2)
    if not isinstance(inbound_group, str) or not isinstance(inbound_body, str) or not inbound_body:
        raise SystemExit(2)

groups = {}
selectors = {}
try:
    with open(os.environ["SIGNAL_GROUPS_FILE"], "rb") as source:
        opened = os.fstat(source.fileno())
        linked = os.lstat(os.environ["SIGNAL_GROUPS_FILE"])
        if (not stat.S_ISREG(opened.st_mode)
                or stat.S_ISLNK(linked.st_mode)
                or (opened.st_dev, opened.st_ino) != (linked.st_dev, linked.st_ino)
                or stat.S_IMODE(opened.st_mode) != 0o600):
            raise SystemExit(3)
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
            selectors[selector] = (group, label)
            groups[group] = selector
except OSError:
    raise SystemExit(3)
if not groups:
    raise SystemExit(3)
if mode == "validate":
    raise SystemExit(0)
selector = os.environ.get("SIGNAL_SELECTOR", "")
if mode == "selector":
    raise SystemExit(0 if selector in selectors else 4)
if mode == "prefix":
    route = selectors.get(selector)
    if route is None:
        raise SystemExit(4)
    try:
        with open(os.environ["FM_SIGNAL_MESSAGE"], "rb") as source:
            body = source.read()
    except OSError:
        raise SystemExit(4)
    label = route[1].encode()
    if not body.startswith(label + b":"):
        body = label + b": " + body
    sys.stdout.buffer.write(body)
    raise SystemExit(0)
if mode == "request":
    route = selectors.get(selector)
    if route is None:
        raise SystemExit(4)
    try:
        account = sys.stdin.buffer.readline().decode("ascii").rstrip("\n")
        with open(os.environ["FM_SIGNAL_MESSAGE"], "rb") as source:
            body = source.read().decode("utf-8")
    except (OSError, UnicodeDecodeError):
        raise SystemExit(4)
    if not re.fullmatch(r"\+[0-9]+", account):
        raise SystemExit(4)
    json.dump({"jsonrpc": "2.0", "method": "send", "params": {
        "account": account, "groupId": route[0], "message": body}, "id": "fm-send"}, sys.stdout,
        ensure_ascii=True, separators=(",", ":"))
    sys.stdout.write("\n")
    raise SystemExit(0)
if mode != "emit":
    raise SystemExit(3)
selector = groups.get(inbound_group)
if selector is None:
    raise SystemExit(2)
body_bytes = inbound_body.encode()
sys.stdout.write("schema=fm-signal.v1\n")
sys.stdout.write("selector=" + selector + "\n")
sys.stdout.write("body-bytes=" + str(len(body_bytes)) + "\n\n")
sys.stdout.flush()
sys.stdout.buffer.write(body_bytes)
'
}

validate_routes() {
  ensure_groups_file
  signal_routes validate </dev/null
}

validate_route_selector() {
  signal_routes selector "$1" </dev/null
}

emit_message() {
  signal_routes emit
}

json_rpc_send_succeeded() {
  FM_SIGNAL_RESPONSE="$1" python3 -c '
import json
import os

matched = 0
try:
    with open(os.environ["FM_SIGNAL_RESPONSE"], encoding="utf-8") as source:
        for line in source:
            document = json.loads(line)
            if document.get("id") != "fm-send":
                continue
            matched += 1
            if "error" in document or "result" not in document:
                raise SystemExit(1)
except (OSError, UnicodeDecodeError, ValueError, AttributeError):
    raise SystemExit(1)
raise SystemExit(0 if matched == 1 else 1)
'
}

open_message_file() {
  local path=$1
  [ -f "$path" ] && [ ! -L "$path" ] || die "message file is not a regular file"
  exec 8< "$path" || die "message file is not a regular file"
  if ! FM_SIGNAL_OPEN_MESSAGE="$path" FM_SIGNAL_RAW= python3 -c '
import os
import stat

try:
    opened = os.fstat(8)
    linked = os.lstat(os.environ["FM_SIGNAL_OPEN_MESSAGE"])
except OSError:
    raise SystemExit(1)
valid = (stat.S_ISREG(opened.st_mode)
         and stat.S_ISREG(linked.st_mode)
         and not stat.S_ISLNK(linked.st_mode)
         and (opened.st_dev, opened.st_ino) == (linked.st_dev, linked.st_ino))
raise SystemExit(0 if valid else 1)
' >/dev/null 2>&1; then
    exec 8<&-
    die "message file is not a regular file"
  fi
}

cmd_source() {
  local -a receive_status
  ensure_groups_file
  validate_routes || exit 1
  validate_single_account || exit 1
  while :; do
    require_signal_account_access
    "$SCRIPT_DIR/fm-procevent.sh" ready "$SOURCE_ID" >/dev/null || return 1
    if "${SIGNAL_CLI[@]}" -o json receive -t -1 --max-messages 1 \
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
  validate_route_selector "$selector" || die "Signal group selector is not configured"
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
  require_signal_home_paths
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
  require_signal_home_paths
  lock=$(lifecycle_lock)
  mkdir -p "${lock%/*}" || die "cannot create Signal lifecycle state"
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock Signal lifecycle"
    trap 'fm_lock_release "$lock"' EXIT
    cmd_retire_locked "$selector"
  )
}

cmd_send_locked() {
  local selector=$1 account raw prefixed request response ownership_status
  validate_routes || die "Signal group configuration is invalid"
  validate_route_selector "$selector" || die "Signal group selector is not configured"
  cmd_retire_locked "$selector" >/dev/null || die "could not retire Signal receive source"
  validate_single_account account || exit 1
  private_tempfile raw fm-signal-raw || die "cannot create private Signal message"
  cat <&8 >"$raw" || { rm -f "$raw"; die "cannot stage Signal message"; }
  exec 8<&-
  [ -s "$raw" ] || { rm -f "$raw"; die "Signal message is empty"; }
  private_tempfile prefixed fm-signal-message || { rm -f "$raw"; die "cannot create private Signal message"; }
  FM_SIGNAL_RAW="$raw" signal_routes prefix "$selector" "$raw" >"$prefixed" \
    || { rm -f "$raw" "$prefixed"; die "cannot prefix Signal message"; }
  rm -f "$raw"
  private_tempfile request fm-signal-request || { rm -f "$prefixed"; die "cannot create private Signal request"; }
  printf '%s\n' "$account" | signal_routes request "$selector" "$prefixed" >"$request" \
    || { rm -f "$prefixed" "$request"; die "cannot create private Signal request"; }
  private_tempfile response fm-signal-response \
    || { rm -f "$prefixed" "$request"; die "cannot create private Signal response"; }
  signal_account_accessible
  ownership_status=$?
  if [ "$ownership_status" -ne 0 ]; then
    rm -f "$prefixed" "$request" "$response"
    signal_account_access_error "$ownership_status"
  fi
  if ! fm_run_timed "$SEND_TIMEOUT" bash -c '"$@" <&3' \
    _ "${SIGNAL_CLI[@]}" jsonRpc --receive-mode=manual 3<"$request" >"$response" 2>/dev/null \
    || ! json_rpc_send_succeeded "$response"; then
    rm -f "$prefixed" "$request" "$response"
    die "Signal send failed or timed out"
  fi
  rm -f "$prefixed" "$request" "$response"
  printf 'sent: Signal message\n'
}

cmd_send() {
  local selector=${1-} message=${2:--} lock send_rc=0 staged='' ownership_status send_owner_pid
  validate_selector "$selector"
  require_signal_home_paths
  if [ "$message" = - ]; then
    private_tempfile staged fm-signal-input || die "cannot create private Signal message"
    cat >"$staged" || { rm -f "$staged"; die "cannot read Signal message"; }
    message=$staged
  fi
  open_message_file "$message"
  lock=$(lifecycle_lock)
  mkdir -p "${lock%/*}" || die "cannot create Signal lifecycle state"
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock Signal lifecycle"
    send_owner_pid=$BASHPID
    # shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
    interrupt_send() {
      local status=$1
      if [ "$BASHPID" != "$send_owner_pid" ]; then
        trap - EXIT HUP INT TERM
        exit "$status"
      fi
      trap '' HUP INT TERM
      fm_procevent_source_lock_release "$SOURCE_ID"
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
      trap - EXIT HUP INT TERM
      exec 8<&-
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
    cmd_send_locked "$selector" || send_rc=$?
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
