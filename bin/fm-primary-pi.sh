#!/usr/bin/env bash
# fm-primary-pi.sh - guarded Pi-on-Herdr primary launch and exact recovery.
#
# This file is the sole owner of the primary-custody schema, lifetime lease,
# exact-session validation, and attach-first recovery state machine.
#
# Supported entry points:
#   fm-primary-pi.sh launch [--pi pi|pi-signed] [-- <ordinary Pi options>]
#   fm-primary-pi.sh recover [--no-attach] [--no-server-start]
#   fm-primary-pi.sh status
#   fm-primary-pi.sh server-ensure
#   fm-primary-pi.sh attest --token T --actual-id ID --session-file PATH
#       --session-dir DIR --cwd DIR --pi-pid PID --pi-start START
#       --reason REASON [--recovery]
#
# `launch` is the supported lifetime-custody boundary for a new Pi primary in
# an existing Herdr pane. It requires Herdr 0.7.5's complete injected identity,
# records a PID/start-bound lease before Pi starts, and explicitly loads the
# custody, turn-end, and watcher extensions. Session-selection flags are refused;
# ordinary exact recovery belongs to `recover`.
#
# `recover` reads state/primary-pi/custody.v1, addresses only its exact named
# Herdr session/workspace/tab/pane, and chooses one of two paths:
#   - a live registered Pi with a Pi foreground process is attached, never
#     relaunched;
#   - an exact restored shell with no agent may resume only after two stable
#     reads, a dead/absent old lease, strict session-file validation, and an
#     atomic lease handoff inside that pane.
# Every other live, unknown, contradictory, raced, or malformed shape refuses.
# Labels, focus, ambient HERDR_SESSION, partial Pi IDs, -c, -r, --session-id,
# and unchecked paths are never recovery authority.
#
# Private state (mode 0600 files under mode 0700 state/primary-pi):
#
# custody.v1 (exactly one of every field):
#   version=1
#   home=<canonical FM_HOME>
#   herdr_session=<name>
#   herdr_socket=<canonical socket path reported by Herdr>
#   herdr_workspace_id=<id>
#   herdr_tab_id=<id>
#   herdr_pane_id=<id>
#   pi_harness=pi|pi-signed
#   pi_session_id=<full Pi header id>
#   pi_session_file=<canonical intended or existing JSONL path>
#   pi_session_dir=<canonical directory>
#   pi_cwd=<canonical session cwd>
#   session_integrity=ok|pending
#   lease_token=<128-bit hex token>
#   lease_owner_pid=<wrapper pid>
#   lease_owner_start=<normalized ps lstart identity>
#   updated_epoch=<integer>
#
# lease/ contains version, token, owner_pid, and owner_start. The wrapper keeps
# that directory for Pi's whole lifetime. Clean exit removes only a token-matched
# lease. A stale recorded lease can be replaced only by the internal resume
# action after recover proves the exact pane is a stable restored shell. A stale
# pre-attestation lease with no custody can be replaced by `launch` only after
# two reads prove its exact injected pane is an agent-free bare shell.
#
# recovery.lock is the mkdir-created single-flight directory that keeps two
# wrappers from deciding custody at once. Its owner record holds pid and start,
# so ownership is PID/start-bound rather than mtime-guessed. `launch` takes it
# before reading custody and drops it once the lifetime lease is written, before
# Pi starts. `recover` holds it across the whole decision, including a restart's
# post-launch attestation, and drops it at the exact attach, before that attach
# can exec away. Every other exit releases through the EXIT trap. Only a
# self-owned lock is removed, and a PID/start-dead owner is reclaimed only
# through the .recovery-steal guard, never a live or unreadable owner.
#
# attestation.v1 contains version, token, result=ok|pending|failed, exact Pi
# session identity, Pi PID/start identity, and a one-word reason. The tracked Pi
# custody extension calls `attest` synchronously on session_start and after
# persistence-relevant events. Recovery does not attach or report success until
# it observes result=ok for its fresh token. Failed or timed-out launch cleanup
# signals only the exact token/PID/start-bound wrapper.
#
# Strict JSONL validation requires: canonical existing regular non-symlink file,
# canonical session directory and cwd, every nonblank physical line valid JSON,
# supported session header with exact full id/cwd, and exactly one file with that
# id in the session directory. Missing files are `pending` only for a brand-new
# ordinary launch; recovery always refuses them.
#
# Availability is bounded by FM_PRIMARY_SERVER_ATTEMPTS (default 6),
# FM_PRIMARY_SERVER_DELAY (default 0.25s), FM_PRIMARY_ATTEST_ATTEMPTS (default
# 40), and FM_PRIMARY_ATTEST_DELAY (default 0.10s). `recover` may start only the
# recorded named server after the initial wait; --no-server-start disables that.
#
# Test-only transport overrides: FM_PRIMARY_HERDR_BIN and the timing variables.
# They do not weaken identity, file, lease, or attestation checks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PRIVATE_DIR="$STATE/primary-pi"
CUSTODY="$PRIVATE_DIR/custody.v1"
LEASE="$PRIVATE_DIR/lease"
LEASE_STEAL="$PRIVATE_DIR/.lease-steal"
RECOVERY_LOCK="$PRIVATE_DIR/recovery.lock"
ATTESTATION="$PRIVATE_DIR/attestation.v1"
HERDR_BIN="${FM_PRIMARY_HERDR_BIN:-herdr}"
SERVER_ATTEMPTS="${FM_PRIMARY_SERVER_ATTEMPTS:-6}"
SERVER_DELAY="${FM_PRIMARY_SERVER_DELAY:-0.25}"
ATTEST_ATTEMPTS="${FM_PRIMARY_ATTEST_ATTEMPTS:-40}"
ATTEST_DELAY="${FM_PRIMARY_ATTEST_DELAY:-0.10}"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-primary-pi: %s\n' "$*" >&2
  return 1
}

die() {
  fail "$*"
  exit 1
}

validate_count() {
  case "$2" in ''|*[!0-9]*|0) die "$1 must be a positive integer" ;; esac
}

validate_delay() {
  case "$2" in ''|*[!0-9.]*|.*|*.*.*) die "$1 must be a positive decimal" ;; esac
}

validate_value() {
  local label=$1 value=$2
  [ -n "$value" ] || die "$label must not be empty"
  case "$value" in *$'\n'*|*$'\r'*) die "$label must be one line" ;; esac
}

token_is_valid() {
  case "$1" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
    *) return 1 ;;
  esac
}

session_id_is_valid() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*|[-_.]*|*[-_.]) return 1 ;;
  esac
  return 0
}

validate_token() {
  token_is_valid "$1" || die "invalid custody token"
}

validate_session_id() {
  session_id_is_valid "$1" || die "invalid full Pi session id"
}

canonical_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  (cd "$1" 2>/dev/null && pwd -P)
}

canonical_home() {
  local home
  home=$(canonical_dir "$FM_HOME") || die "FM_HOME is not a canonical existing directory: $FM_HOME"
  [ "$home" = "$FM_HOME" ] || die "FM_HOME must use its canonical spelling: $home"
  printf '%s' "$home"
}

private_dir_is_canonical() {
  local state private
  state=$(canonical_dir "$STATE") || return 1
  [ "$state" = "$STATE" ] || return 1
  private=$(canonical_dir "$PRIVATE_DIR") || return 1
  [ "$private" = "$PRIVATE_DIR" ]
}

ensure_private_dir() {
  local state private
  mkdir -p "$STATE" || return 1
  state=$(canonical_dir "$STATE") || return 1
  [ "$state" = "$STATE" ] || return 1
  if [ ! -e "$PRIVATE_DIR" ] && [ ! -L "$PRIVATE_DIR" ]; then
    mkdir "$PRIVATE_DIR" || return 1
  fi
  private=$(canonical_dir "$PRIVATE_DIR") || return 1
  [ "$private" = "$PRIVATE_DIR" ] || return 1
  chmod 700 "$PRIVATE_DIR"
}

canonical_file_path() {
  local path=$1 dir base canon_dir
  case "$path" in /*) ;; *) return 1 ;; esac
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  dir=${path%/*}; base=${path##*/}
  [ -n "$dir" ] || dir=/
  canon_dir=$(canonical_dir "$dir") || return 1
  [ "$path" = "$canon_dir/$base" ] || return 1
  printf '%s' "$path"
}

canonical_intended_file_path() {
  local path=$1 dir base canon_dir
  case "$path" in /*) ;; *) return 1 ;; esac
  [ ! -L "$path" ] || return 1
  dir=${path%/*}; base=${path##*/}
  [ -n "$base" ] && [ "$base" != . ] && [ "$base" != .. ] || return 1
  canon_dir=$(canonical_dir "$dir") || return 1
  [ "$path" = "$canon_dir/$base" ] || return 1
  printf '%s' "$path"
}

process_start() {
  ps -o lstart= -p "$1" 2>/dev/null | awk '{$1=$1; print}'
}

pid_matches() {
  local pid=$1 expected=$2 actual
  case "$pid" in ''|*[!0-9]*|1) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  actual=$(process_start "$pid")
  [ -n "$actual" ] && [ "$actual" = "$expected" ]
}

pid_descends_from() {
  local pid=$1 ancestor=$2 i=0
  while [ "$i" -lt 24 ]; do
    [ "$pid" = "$ancestor" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [ -n "$pid" ] && [ "$pid" != 1 ] || break
    i=$((i + 1))
  done
  return 1
}

new_token() {
  local token
  token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  validate_token "$token"
  printf '%s' "$token"
}

record_field() {
  local file=$1 key=$2 value count
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  count=$(grep -c "^$key=" "$file" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  value=$(grep "^$key=" "$file" | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

write_record() {
  local path=$1 tmp key value
  shift
  ensure_private_dir || return 1
  tmp="$PRIVATE_DIR/.record.$$.$(new_token)"
  ( umask 077; : > "$tmp" ) || return 1
  while [ "$#" -gt 0 ]; do
    key=$1; value=$2; shift 2
    validate_value "$key" "$value"
    printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }
  done
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path"
}

load_lease() {
  local canonical
  private_dir_is_canonical || return 1
  canonical=$(canonical_dir "$LEASE") || return 1
  [ "$canonical" = "$LEASE" ] || return 1
  LEASE_VERSION=$(record_field "$LEASE/version" version) || return 1
  LEASE_TOKEN=$(record_field "$LEASE/token" token) || return 1
  LEASE_PID=$(record_field "$LEASE/owner" pid) || return 1
  LEASE_START=$(record_field "$LEASE/owner" start) || return 1
  [ "$LEASE_VERSION" = 1 ] || return 1
  token_is_valid "$LEASE_TOKEN" || return 1
}

write_lease() {
  local token=$1 owner=$2 start=$3
  [ ! -e "$LEASE" ] && [ ! -L "$LEASE" ] || return 1
  mkdir "$LEASE" 2>/dev/null || return 1
  chmod 700 "$LEASE" || { rmdir "$LEASE"; return 1; }
  write_record "$LEASE/version" version 1 || { rm -rf "$LEASE"; return 1; }
  write_record "$LEASE/token" token "$token" || { rm -rf "$LEASE"; return 1; }
  write_record "$LEASE/owner" pid "$owner" start "$start" || { rm -rf "$LEASE"; return 1; }
}

remove_token_lease() {
  local token=$1
  load_lease || return 1
  [ "$LEASE_TOKEN" = "$token" ] || return 1
  rm -rf "$LEASE"
}

load_custody() {
  local canonical
  private_dir_is_canonical || return 1
  C_VERSION=$(record_field "$CUSTODY" version) || return 1
  C_HOME=$(record_field "$CUSTODY" home) || return 1
  C_HERDR_SESSION=$(record_field "$CUSTODY" herdr_session) || return 1
  C_HERDR_SOCKET=$(record_field "$CUSTODY" herdr_socket) || return 1
  C_HERDR_WORKSPACE=$(record_field "$CUSTODY" herdr_workspace_id) || return 1
  C_HERDR_TAB=$(record_field "$CUSTODY" herdr_tab_id) || return 1
  C_HERDR_PANE=$(record_field "$CUSTODY" herdr_pane_id) || return 1
  C_PI_HARNESS=$(record_field "$CUSTODY" pi_harness) || return 1
  C_SESSION_ID=$(record_field "$CUSTODY" pi_session_id) || return 1
  C_SESSION_FILE=$(record_field "$CUSTODY" pi_session_file) || return 1
  C_SESSION_DIR=$(record_field "$CUSTODY" pi_session_dir) || return 1
  C_CWD=$(record_field "$CUSTODY" pi_cwd) || return 1
  C_INTEGRITY=$(record_field "$CUSTODY" session_integrity) || return 1
  C_LEASE_TOKEN=$(record_field "$CUSTODY" lease_token) || return 1
  C_LEASE_PID=$(record_field "$CUSTODY" lease_owner_pid) || return 1
  C_LEASE_START=$(record_field "$CUSTODY" lease_owner_start) || return 1
  C_UPDATED=$(record_field "$CUSTODY" updated_epoch) || return 1
  [ "$C_VERSION" = 1 ] || return 1
  case "$C_PI_HARNESS" in pi|pi-signed) ;; *) return 1 ;; esac
  case "$C_INTEGRITY" in ok|pending) ;; *) return 1 ;; esac
  case "$C_LEASE_PID" in ''|*[!0-9]*|1) return 1 ;; esac
  case "$C_UPDATED" in ''|*[!0-9]*) return 1 ;; esac
  token_is_valid "$C_LEASE_TOKEN" || return 1
  session_id_is_valid "$C_SESSION_ID" || return 1
  canonical=$(canonical_dir "$C_HOME") || return 1
  [ "$canonical" = "$C_HOME" ] || return 1
  canonical=$(canonical_dir "$C_SESSION_DIR") || return 1
  [ "$canonical" = "$C_SESSION_DIR" ] || return 1
  canonical=$(canonical_dir "$C_CWD") || return 1
  [ "$canonical" = "$C_CWD" ] || return 1
  canonical=$(canonical_intended_file_path "$C_SESSION_FILE") || return 1
  [ "$canonical" = "$C_SESSION_FILE" ] && [ "${C_SESSION_FILE%/*}" = "$C_SESSION_DIR" ] || return 1
  canonical=$(canonical_intended_file_path "$C_HERDR_SOCKET") || return 1
  [ "$canonical" = "$C_HERDR_SOCKET" ] || return 1
}

herdr_cli() {
  HERDR_SESSION="$1" "$HERDR_BIN" "${@:2}" --session "$1"
}

herdr_status() {
  herdr_cli "$1" status --json
}

status_running_and_socket() {
  local session=$1 expected_socket=$2 out
  out=$(herdr_status "$session" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e --arg session "$session" --arg socket "$expected_socket" '
    .server.running == true and .server.session == $session and .server.socket == $socket
  ' >/dev/null 2>&1
}

wait_server() {
  local session=$1 socket=$2 attempts=$3 i=0
  while [ "$i" -lt "$attempts" ]; do
    status_running_and_socket "$session" "$socket" && return 0
    i=$((i + 1))
    [ "$i" -lt "$attempts" ] && sleep "$SERVER_DELAY"
  done
  return 1
}

start_named_server() {
  local session=$1
  (herdr_cli "$session" server >/dev/null 2>&1 &)
}

pane_json_exact() {
  local session=$1 pane=$2 workspace=$3 tab=$4 out
  out=$(herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e --arg p "$pane" --arg w "$workspace" --arg t "$tab" '
    .result.pane.pane_id == $p and .result.pane.workspace_id == $w and .result.pane.tab_id == $t
  ' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

agent_shape() {
  local session=$1 pane=$2 out code agent
  out=$(herdr_cli "$session" agent get "$pane" 2>&1)
  agent=$(printf '%s' "$out" | jq -r '.result.agent.agent // empty' 2>/dev/null)
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
  if [ "$agent" = pi ]; then
    printf 'pi'
  elif [ "$code" = agent_not_found ]; then
    printf 'none'
  else
    printf 'unknown'
  fi
}

process_json() {
  herdr_cli "$1" pane process-info --pane "$2" 2>/dev/null
}

process_is_pi() {
  printf '%s' "$1" | jq -e '
    (.result.process_info.foreground_processes | type) == "array" and
    (.result.process_info.foreground_processes | length) >= 1 and
    ([.result.process_info.foreground_processes[] |
      select(((.argv0 // .name // .argv[0] // "") | split("/")[-1]) |
        test("^(pi|pi-signed|pi-launcher)$"))] | length) >= 1
  ' >/dev/null 2>&1
}

process_is_bare_shell() {
  printf '%s' "$1" | jq -e '
    .result.process_info as $p |
    ($p.shell_pid | type) == "number" and
    ($p.foreground_processes | type) == "array" and
    ($p.foreground_processes | length) == 1 and
    ($p.foreground_processes[0].pid == $p.shell_pid) and
    (($p.foreground_processes[0].argv0 // $p.foreground_processes[0].name // "") |
      sub("^-"; "") | test("^(ba|da|fi|k|mk|pdk|tc|z)?sh$|^fish$"))
  ' >/dev/null 2>&1
}

strict_session() {
  local file=$1 session_dir=$2 session_id=$3 cwd=$4 canonical_file canonical_session_dir canonical_cwd first header_id header_cwd header_version f fid count=0
  session_id_is_valid "$session_id" || return 1
  canonical_file=$(canonical_file_path "$file") || return 1
  canonical_session_dir=$(canonical_dir "$session_dir") || return 1
  canonical_cwd=$(canonical_dir "$cwd") || return 1
  [ "$session_dir" = "$canonical_session_dir" ] || return 1
  [ "$cwd" = "$canonical_cwd" ] || return 1
  [ "${canonical_file%/*}" = "$canonical_session_dir" ] || return 1
  jq -e . "$canonical_file" >/dev/null 2>&1 || return 1
  first=$(awk 'NF { print; exit }' "$canonical_file")
  [ -n "$first" ] || return 1
  header_id=$(printf '%s' "$first" | jq -r 'select(.type == "session") | .id // empty' 2>/dev/null)
  header_cwd=$(printf '%s' "$first" | jq -r 'select(.type == "session") | .cwd // empty' 2>/dev/null)
  header_version=$(printf '%s' "$first" | jq -r 'select(.type == "session") | .version // 1' 2>/dev/null)
  [ "$header_id" = "$session_id" ] || return 1
  case "$header_version" in 1|2|3) ;; *) return 1 ;; esac
  [ "$header_cwd" = "$canonical_cwd" ] || return 1
  for f in "$canonical_session_dir"/*.jsonl; do
    [ -e "$f" ] || continue
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    first=$(awk 'NF { print; exit }' "$f")
    fid=$(printf '%s' "$first" | jq -r 'select(.type == "session") | .id // empty' 2>/dev/null)
    [ "$fid" = "$session_id" ] && count=$((count + 1))
  done
  [ "$count" = 1 ] || return 1
  S_FILE=$canonical_file
  return 0
}

write_attestation() {
  local token=$1 result=$2 session_id=$3 session_file=$4 session_dir=$5 cwd=$6 pi_pid=$7 pi_start=$8 reason=$9
  write_record "$ATTESTATION" \
    version 1 token "$token" result "$result" pi_session_id "$session_id" \
    pi_session_file "$session_file" pi_session_dir "$session_dir" pi_cwd "$cwd" \
    pi_pid "$pi_pid" pi_start "$pi_start" reason "$reason" updated_epoch "$(date +%s)"
}

attestation_result_for_token() {
  local token=$1 file_token result
  file_token=$(record_field "$ATTESTATION" token) || return 1
  [ "$file_token" = "$token" ] || return 1
  result=$(record_field "$ATTESTATION" result) || return 1
  printf '%s' "$result"
}

write_custody() {
  local home=$1 session=$2 socket=$3 workspace=$4 tab=$5 pane=$6 harness=$7 session_id=$8 session_file=$9
  shift 9
  local session_dir=$1 cwd=$2 integrity=$3 token=$4 owner=$5 owner_start=$6
  write_record "$CUSTODY" \
    version 1 home "$home" herdr_session "$session" herdr_socket "$socket" \
    herdr_workspace_id "$workspace" herdr_tab_id "$tab" herdr_pane_id "$pane" \
    pi_harness "$harness" pi_session_id "$session_id" pi_session_file "$session_file" \
    pi_session_dir "$session_dir" pi_cwd "$cwd" session_integrity "$integrity" \
    lease_token "$token" lease_owner_pid "$owner" lease_owner_start "$owner_start" \
    updated_epoch "$(date +%s)"
}

current_env_identity() {
  validate_value HERDR_SESSION "${HERDR_SESSION:-}"
  validate_value HERDR_SOCKET_PATH "${HERDR_SOCKET_PATH:-}"
  validate_value HERDR_WORKSPACE_ID "${HERDR_WORKSPACE_ID:-}"
  validate_value HERDR_TAB_ID "${HERDR_TAB_ID:-}"
  validate_value HERDR_PANE_ID "${HERDR_PANE_ID:-}"
  [ "${HERDR_ENV:-}" = 1 ] || die "launch/resume requires a native Herdr pane"
  status_running_and_socket "$HERDR_SESSION" "$HERDR_SOCKET_PATH" || die "injected Herdr session/socket is not the exact running server"
  pane_json_exact "$HERDR_SESSION" "$HERDR_PANE_ID" "$HERDR_WORKSPACE_ID" "$HERDR_TAB_ID" >/dev/null \
    || die "injected Herdr pane identity is absent or contradictory"
}

acquire_recovery_lock() {
  local start stale_pid stale_start canonical
  ensure_private_dir || return 1
  start=$(process_start "$$")
  [ -n "$start" ] || return 1
  if mkdir "$RECOVERY_LOCK" 2>/dev/null; then
    write_record "$RECOVERY_LOCK/owner" pid "$$" start "$start" || { rm -rf "$RECOVERY_LOCK"; return 1; }
    return 0
  fi
  canonical=$(canonical_dir "$RECOVERY_LOCK") || return 1
  [ "$canonical" = "$RECOVERY_LOCK" ] || return 1
  stale_pid=$(record_field "$RECOVERY_LOCK/owner" pid) || return 1
  stale_start=$(record_field "$RECOVERY_LOCK/owner" start) || return 1
  pid_matches "$stale_pid" "$stale_start" && return 1
  if ! mkdir "$PRIVATE_DIR/.recovery-steal" 2>/dev/null; then return 1; fi
  stale_pid=$(record_field "$RECOVERY_LOCK/owner" pid 2>/dev/null || true)
  stale_start=$(record_field "$RECOVERY_LOCK/owner" start 2>/dev/null || true)
  if [ -n "$stale_pid" ] && ! pid_matches "$stale_pid" "$stale_start"; then
    rm -rf "$RECOVERY_LOCK"
  fi
  rm -rf "$PRIVATE_DIR/.recovery-steal"
  mkdir "$RECOVERY_LOCK" 2>/dev/null || return 1
  write_record "$RECOVERY_LOCK/owner" pid "$$" start "$start" || { rm -rf "$RECOVERY_LOCK"; return 1; }
}

release_recovery_lock() {
  local pid start
  pid=$(record_field "$RECOVERY_LOCK/owner" pid 2>/dev/null || true)
  start=$(record_field "$RECOVERY_LOCK/owner" start 2>/dev/null || true)
  [ "$pid" = "$$" ] && [ "$start" = "$(process_start "$$")" ] && rm -rf "$RECOVERY_LOCK"
}

lease_is_live() {
  load_lease || return 1
  pid_matches "$LEASE_PID" "$LEASE_START"
}

replace_stale_lease() {
  local old_token=$1 new=$2 start old=''
  if mkdir "$LEASE_STEAL" 2>/dev/null; then :; else return 1; fi
  if [ -e "$LEASE" ] || [ -L "$LEASE" ]; then
    load_lease || { rmdir "$LEASE_STEAL"; return 1; }
    old=$LEASE_TOKEN
    [ "$old" = "$old_token" ] || { rmdir "$LEASE_STEAL"; return 1; }
    pid_matches "$LEASE_PID" "$LEASE_START" && { rmdir "$LEASE_STEAL"; return 1; }
    rm -rf "$LEASE" || { rmdir "$LEASE_STEAL"; return 1; }
  else
    [ "$old_token" = absent ] || { rmdir "$LEASE_STEAL"; return 1; }
  fi
  start=$(process_start "$$")
  if ! write_lease "$new" "$$" "$start"; then
    rmdir "$LEASE_STEAL"
    return 1
  fi
  rmdir "$LEASE_STEAL"
}

validate_launch_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -c|--continue|-r|--resume|--session|--session=*|--session-id|--session-id=*|--fork|--fork=*|--no-session)
        die "launch forbids Pi session-selection flag '$arg'; use recover for exact resumption"
        ;;
    esac
  done
}

run_pi_owner() {
  local token=$1 harness=$2 recovery=$3 expected_id=$4 expected_file=$5 expected_dir=$6 expected_cwd=$7
  shift 7
  local pi_bin child=0 rc=0 owner_start
  case "$harness" in pi|pi-signed) ;; *) die "--pi must be pi or pi-signed" ;; esac
  pi_bin=$(command -v "$harness" 2>/dev/null || true)
  [ -n "$pi_bin" ] && [ -x "$pi_bin" ] || die "$harness is not available"
  owner_start=$(process_start "$$")
  export FM_PRIMARY_PI_TOKEN="$token"
  export FM_PRIMARY_PI_RECOVERY="$recovery"
  export FM_PRIMARY_EXPECTED_SESSION_ID="$expected_id"
  export FM_PRIMARY_EXPECTED_SESSION_FILE="$expected_file"
  export FM_PRIMARY_EXPECTED_SESSION_DIR="$expected_dir"
  export FM_PRIMARY_EXPECTED_CWD="$expected_cwd"
  export FM_PRIMARY_PI_HARNESS="$harness"
  export FM_PI_HARNESS="$harness"
  export FM_HOME FM_ROOT_OVERRIDE="$FM_ROOT"
  if [ "$recovery" = 1 ]; then
    cd "$expected_cwd" || die "cannot enter the exact recorded Pi cwd before recovery launch"
    [ "$(pwd -P)" = "$expected_cwd" ] || die "recovery launch cwd is not the exact recorded Pi cwd"
  fi
  trap 'if [ "$child" -gt 1 ] 2>/dev/null; then kill -TERM "$child" 2>/dev/null || true; fi' TERM INT HUP
  "$pi_bin" \
    -e "$FM_ROOT/.pi/extensions/fm-primary-custody.ts" \
    -e "$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts" \
    -e "$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts" \
    "$@" &
  child=$!
  wait "$child" || rc=$?
  child=0
  trap - TERM INT HUP
  remove_token_lease "$token" >/dev/null 2>&1 || true
  return "$rc"
}

command_launch() {
  local harness=${FM_PI_HARNESS:-pi} token start stale_token='' shape proc shape2 proc2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pi) shift; harness=${1:-}; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  validate_launch_args "$@"
  current_env_identity
  ensure_private_dir || die "cannot create or validate private custody directory"
  acquire_recovery_lock || die "another launch or recovery owns or ambiguously left the recovery lock"
  trap release_recovery_lock EXIT
  if [ -e "$LEASE" ] || [ -L "$LEASE" ]; then
    load_lease || die "existing custody lease is malformed; refusing duplicate launch"
    if pid_matches "$LEASE_PID" "$LEASE_START"; then
      die "a primary custody lease is already live (pid $LEASE_PID)"
    fi
    if [ -e "$CUSTODY" ] || [ -L "$CUSTODY" ]; then
      die "a stale custody lease with recorded identity requires recover; launch will not reclaim it"
    fi
    stale_token=$LEASE_TOKEN
  elif [ -e "$CUSTODY" ] || [ -L "$CUSTODY" ]; then
    die "existing primary custody requires recover; launch will not create a second authority"
  fi
  token=$(new_token)
  start=$(process_start "$$")
  if [ -n "$stale_token" ]; then
    shape=$(agent_shape "$HERDR_SESSION" "$HERDR_PANE_ID")
    proc=$(process_json "$HERDR_SESSION" "$HERDR_PANE_ID") || die "stale pre-attestation launch pane process state is unreadable"
    if [ "$shape" = pi ]; then
      process_is_pi "$proc" || die "stale pre-attestation lease has contradictory registered-Pi process state"
      die "stale pre-attestation lease still has a live Pi; manual attach is required"
    fi
    [ "$shape" = none ] || die "stale pre-attestation lease has unknown agent state; refusing duplicate launch"
    process_is_bare_shell "$proc" || die "stale pre-attestation lease does not resolve to a proven bare shell"
    sleep "$SERVER_DELAY"
    shape2=$(agent_shape "$HERDR_SESSION" "$HERDR_PANE_ID")
    proc2=$(process_json "$HERDR_SESSION" "$HERDR_PANE_ID") || die "stale pre-attestation pane changed unreadably during revalidation"
    if [ "$shape2" != none ] || ! process_is_bare_shell "$proc2"; then
      die "stale pre-attestation pane stopped being a stable agent-free bare shell"
    fi
    replace_stale_lease "$stale_token" "$token" || die "could not atomically replace the stale pre-attestation lease"
  else
    write_lease "$token" "$$" "$start" || die "could not acquire the primary custody lease"
  fi
  release_recovery_lock
  trap - EXIT
  run_pi_owner "$token" "$harness" 0 '' '' '' '' "$@"
}

command_resume_internal() {
  local from='' token='' harness='' session_id='' session_file='' session_dir='' cwd=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from-token) shift; from=${1:-} ;;
      --token) shift; token=${1:-} ;;
      --pi) shift; harness=${1:-} ;;
      --expected-id) shift; session_id=${1:-} ;;
      --session-file) shift; session_file=${1:-} ;;
      --session-dir) shift; session_dir=${1:-} ;;
      --cwd) shift; cwd=${1:-} ;;
      *) die "unknown internal resume option: $1" ;;
    esac
    shift
  done
  validate_token "$token"
  validate_session_id "$session_id"
  current_env_identity
  load_custody || die "custody record is missing or malformed"
  [ "$C_SESSION_ID" = "$session_id" ] && [ "$C_SESSION_FILE" = "$session_file" ] \
    && [ "$C_SESSION_DIR" = "$session_dir" ] && [ "$C_CWD" = "$cwd" ] \
    || die "internal resume identity differs from custody"
  strict_session "$session_file" "$session_dir" "$session_id" "$cwd" \
    || die "session changed or failed strict validation before resume"
  replace_stale_lease "$from" "$token" || die "could not atomically replace the stale custody lease"
  run_pi_owner "$token" "$harness" 1 "$session_id" "$session_file" "$session_dir" "$cwd" \
    --session-dir "$session_dir" --session "$session_id"
}

command_attest() {
  local token='' session_id='' session_file='' session_dir='' cwd='' pi_pid='' pi_start='' reason='' recovery=0
  local home owner owner_start result=ok actual_file actual_dir actual_cwd status socket
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --token) shift; token=${1:-} ;;
      --actual-id) shift; session_id=${1:-} ;;
      --session-file) shift; session_file=${1:-} ;;
      --session-dir) shift; session_dir=${1:-} ;;
      --cwd) shift; cwd=${1:-} ;;
      --pi-pid) shift; pi_pid=${1:-} ;;
      --pi-start) shift; pi_start=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --recovery) recovery=1 ;;
      *) die "unknown attest option: $1" ;;
    esac
    shift
  done
  validate_token "$token"
  validate_session_id "$session_id"
  validate_value session-file "$session_file"
  validate_value session-dir "$session_dir"
  validate_value cwd "$cwd"
  validate_value pi-pid "$pi_pid"
  validate_value pi-start "$pi_start"
  validate_value reason "$reason"
  ensure_private_dir || die "cannot create or validate private custody directory"
  load_lease || { write_attestation "$token" failed "$session_id" "$session_file" "$session_dir" "$cwd" "$pi_pid" "$pi_start" lease; die "lifetime lease is missing or malformed"; }
  [ "$LEASE_TOKEN" = "$token" ] || { write_attestation "$token" failed "$session_id" "$session_file" "$session_dir" "$cwd" "$pi_pid" "$pi_start" token; die "attestation token does not own the lifetime lease"; }
  pid_matches "$LEASE_PID" "$LEASE_START" || { write_attestation "$token" failed "$session_id" "$session_file" "$session_dir" "$cwd" "$pi_pid" "$pi_start" owner; die "lifetime lease owner is not live"; }
  if [ "$pi_start" != "$(process_start "$pi_pid")" ] || ! pid_descends_from "$pi_pid" "$LEASE_PID"; then
    write_attestation "$token" failed "$session_id" "$session_file" "$session_dir" "$cwd" "$pi_pid" "$pi_start" ancestry
    die "Pi process is not a live descendant of the lease owner"
  fi
  current_env_identity
  home=$(canonical_home)
  actual_dir=$(canonical_dir "$session_dir") || { write_attestation "$token" failed "$session_id" "$session_file" "$session_dir" "$cwd" "$pi_pid" "$pi_start" directory; die "session directory is not canonical"; }
  actual_cwd=$(canonical_dir "$cwd") || { write_attestation "$token" failed "$session_id" "$session_file" "$session_dir" "$cwd" "$pi_pid" "$pi_start" cwd; die "session cwd is not canonical"; }
  [ "$actual_dir" = "$session_dir" ] && [ "$actual_cwd" = "$cwd" ] \
    || { write_attestation "$token" failed "$session_id" "$session_file" "$session_dir" "$cwd" "$pi_pid" "$pi_start" canonical; die "session identity uses noncanonical paths"; }
  if [ -f "$session_file" ]; then
    strict_session "$session_file" "$session_dir" "$session_id" "$cwd" \
      || { write_attestation "$token" failed "$session_id" "$session_file" "$session_dir" "$cwd" "$pi_pid" "$pi_start" integrity; die "session file failed strict validation"; }
    actual_file=$S_FILE
  else
    [ "$recovery" = 0 ] || { write_attestation "$token" failed "$session_id" "$session_file" "$session_dir" "$cwd" "$pi_pid" "$pi_start" missing; die "recovery session file is missing"; }
    actual_file=$(canonical_intended_file_path "$session_file") \
      || { write_attestation "$token" failed "$session_id" "$session_file" "$session_dir" "$cwd" "$pi_pid" "$pi_start" path; die "new session path is not canonical"; }
    [ "${actual_file%/*}" = "$actual_dir" ] \
      || { write_attestation "$token" failed "$session_id" "$session_file" "$session_dir" "$cwd" "$pi_pid" "$pi_start" path; die "new session path is outside its session directory"; }
    result=pending
  fi
  if [ "$recovery" = 1 ]; then
    [ "$session_id" = "${FM_PRIMARY_EXPECTED_SESSION_ID:-}" ] \
      && [ "$actual_file" = "${FM_PRIMARY_EXPECTED_SESSION_FILE:-}" ] \
      && [ "$actual_dir" = "${FM_PRIMARY_EXPECTED_SESSION_DIR:-}" ] \
      && [ "$actual_cwd" = "${FM_PRIMARY_EXPECTED_CWD:-}" ] \
      || { write_attestation "$token" failed "$session_id" "$actual_file" "$actual_dir" "$actual_cwd" "$pi_pid" "$pi_start" expected; die "post-launch Pi session differs from the expected recovery session"; }
  fi
  status=$(herdr_status "$HERDR_SESSION" 2>/dev/null) || die "cannot inspect exact Herdr server during attestation"
  socket=$(printf '%s' "$status" | jq -r '.server.socket // empty' 2>/dev/null)
  [ "$socket" = "$HERDR_SOCKET_PATH" ] || die "Herdr socket changed during attestation"
  socket=$(canonical_intended_file_path "$socket") || die "Herdr socket path is not canonical"
  owner=$LEASE_PID; owner_start=$LEASE_START
  write_custody "$home" "$HERDR_SESSION" "$socket" "$HERDR_WORKSPACE_ID" "$HERDR_TAB_ID" "$HERDR_PANE_ID" \
    "${FM_PRIMARY_PI_HARNESS:-pi}" "$session_id" "$actual_file" "$actual_dir" "$actual_cwd" "$result" \
    "$token" "$owner" "$owner_start" || die "cannot publish custody record"
  write_attestation "$token" "$result" "$session_id" "$actual_file" "$actual_dir" "$actual_cwd" "$pi_pid" "$pi_start" "$reason" \
    || die "cannot publish attestation"
  printf '%s\n' "$result"
}

ensure_recorded_server() {
  local start_server=$1
  if wait_server "$C_HERDR_SESSION" "$C_HERDR_SOCKET" "$SERVER_ATTEMPTS"; then return 0; fi
  [ "$start_server" = 1 ] || return 1
  start_named_server "$C_HERDR_SESSION" || return 1
  wait_server "$C_HERDR_SESSION" "$C_HERDR_SOCKET" "$SERVER_ATTEMPTS"
}

attach_exact() {
  local no_attach=$1
  release_recovery_lock
  if [ "$no_attach" = 1 ] || [ "${FM_PRIMARY_NO_ATTACH:-0}" = 1 ]; then
    printf 'primary live: session=%s pane=%s pi_session=%s\n' "$C_HERDR_SESSION" "$C_HERDR_PANE" "$C_SESSION_ID"
    return 0
  fi
  exec env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    "$HERDR_BIN" agent attach "$C_HERDR_PANE" --session "$C_HERDR_SESSION"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\''/g"
  printf "'"
}

cleanup_new_token() {
  local token=$1 result pid start
  result=$(attestation_result_for_token "$token" 2>/dev/null || true)
  [ "$result" != ok ] || return 0
  load_lease || return 0
  [ "$LEASE_TOKEN" = "$token" ] || return 0
  pid=$LEASE_PID; start=$LEASE_START
  pid_matches "$pid" "$start" || return 0
  kill -TERM "$pid" 2>/dev/null || true
}

command_recover() {
  local no_attach=0 start_server=1 home shape proc shape2 proc2 from token cmd result i=0 pane_after agent_after
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-attach) no_attach=1 ;;
      --no-server-start) start_server=0 ;;
      *) die "unknown recover option: $1" ;;
    esac
    shift
  done
  load_custody || die "custody record is missing or malformed; automatic recovery is unavailable"
  home=$(canonical_home)
  [ "$C_HOME" = "$home" ] || die "custody belongs to a different canonical Firstmate home"
  [ "$C_INTEGRITY" = ok ] || die "the recorded Pi session is not yet durably persisted; attach-only/manual recovery is required"
  acquire_recovery_lock || die "another recovery owns or ambiguously left the recovery lock"
  trap release_recovery_lock EXIT
  ensure_recorded_server "$start_server" || die "recorded named Herdr server is unavailable after the bounded retry"
  pane_json_exact "$C_HERDR_SESSION" "$C_HERDR_PANE" "$C_HERDR_WORKSPACE" "$C_HERDR_TAB" >/dev/null \
    || die "recorded Herdr pane identity is absent or contradictory"
  shape=$(agent_shape "$C_HERDR_SESSION" "$C_HERDR_PANE")
  proc=$(process_json "$C_HERDR_SESSION" "$C_HERDR_PANE") || die "recorded pane process state is unreadable"
  if [ "$shape" = pi ]; then
    process_is_pi "$proc" || die "registered Pi has contradictory foreground process identity"
    attach_exact "$no_attach"
    trap - EXIT
    return 0
  fi
  [ "$shape" = none ] || die "recorded primary agent state is unknown; refusing duplicate launch"
  process_is_bare_shell "$proc" || die "agent-free pane is not a proven bare restored shell"
  if [ -e "$LEASE" ] || [ -L "$LEASE" ]; then
    load_lease || die "custody lease is malformed; refusing duplicate launch"
    pid_matches "$LEASE_PID" "$LEASE_START" && die "custody lease owner is still live; refusing duplicate launch"
    from=$LEASE_TOKEN
  else
    from=absent
  fi
  sleep "$SERVER_DELAY"
  pane_json_exact "$C_HERDR_SESSION" "$C_HERDR_PANE" "$C_HERDR_WORKSPACE" "$C_HERDR_TAB" >/dev/null \
    || die "recorded pane changed during recovery revalidation"
  shape2=$(agent_shape "$C_HERDR_SESSION" "$C_HERDR_PANE")
  proc2=$(process_json "$C_HERDR_SESSION" "$C_HERDR_PANE") || die "pane process state changed unreadably during recovery"
  if [ "$shape2" != none ] || ! process_is_bare_shell "$proc2"; then
    die "pane stopped being a stable agent-free restored shell"
  fi
  strict_session "$C_SESSION_FILE" "$C_SESSION_DIR" "$C_SESSION_ID" "$C_CWD" \
    || die "recorded Pi session failed strict integrity or uniqueness validation"
  token=$(new_token)
  cmd="exec env FM_HOME=$(shell_quote "$FM_HOME") FM_ROOT_OVERRIDE=$(shell_quote "$FM_ROOT") "
  cmd="$cmd HERDR_ENV=1 HERDR_SESSION=$(shell_quote "$C_HERDR_SESSION") HERDR_SOCKET_PATH=$(shell_quote "$C_HERDR_SOCKET")"
  cmd="$cmd HERDR_WORKSPACE_ID=$(shell_quote "$C_HERDR_WORKSPACE") HERDR_TAB_ID=$(shell_quote "$C_HERDR_TAB") HERDR_PANE_ID=$(shell_quote "$C_HERDR_PANE")"
  cmd="$cmd $(shell_quote "$0") resume --from-token $(shell_quote "$from") --token $(shell_quote "$token") --pi $(shell_quote "$C_PI_HARNESS")"
  cmd="$cmd --expected-id $(shell_quote "$C_SESSION_ID") --session-file $(shell_quote "$C_SESSION_FILE") --session-dir $(shell_quote "$C_SESSION_DIR") --cwd $(shell_quote "$C_CWD")"
  herdr_cli "$C_HERDR_SESSION" pane run "$C_HERDR_PANE" "$cmd" >/dev/null 2>&1 \
    || die "could not launch the token-bound exact-session wrapper in the restored pane"
  while [ "$i" -lt "$ATTEST_ATTEMPTS" ]; do
    result=$(attestation_result_for_token "$token" 2>/dev/null || true)
    case "$result" in
      ok) break ;;
      failed) cleanup_new_token "$token"; die "post-launch exact-session attestation failed; token-matched process was asked to stop" ;;
    esac
    sleep "$ATTEST_DELAY"
    i=$((i + 1))
  done
  [ "$result" = ok ] || { cleanup_new_token "$token"; die "post-launch exact-session attestation timed out; token-matched process was asked to stop"; }
  pane_after=$(pane_json_exact "$C_HERDR_SESSION" "$C_HERDR_PANE" "$C_HERDR_WORKSPACE" "$C_HERDR_TAB") \
    || { cleanup_new_token "$token"; die "pane identity changed after attestation"; }
  : "$pane_after"
  agent_after=$(agent_shape "$C_HERDR_SESSION" "$C_HERDR_PANE")
  [ "$agent_after" = pi ] || { cleanup_new_token "$token"; die "attested process did not register as Pi"; }
  load_custody || { cleanup_new_token "$token"; die "attested custody record became unreadable"; }
  [ "$C_LEASE_TOKEN" = "$token" ] || { cleanup_new_token "$token"; die "attested custody token changed unexpectedly"; }
  attach_exact "$no_attach"
  trap - EXIT
}

command_status() {
  local live=absent server=unknown pane=unknown agent=unknown integrity=unknown
  if load_custody; then
    integrity=$C_INTEGRITY
    status_running_and_socket "$C_HERDR_SESSION" "$C_HERDR_SOCKET" && server=running || server=unavailable
    pane_json_exact "$C_HERDR_SESSION" "$C_HERDR_PANE" "$C_HERDR_WORKSPACE" "$C_HERDR_TAB" >/dev/null 2>&1 && pane=exact || pane=unavailable
    [ "$pane" = exact ] && agent=$(agent_shape "$C_HERDR_SESSION" "$C_HERDR_PANE")
  fi
  if [ -e "$LEASE" ] || [ -L "$LEASE" ]; then
    if load_lease; then
      if [ "${C_LEASE_TOKEN:-}" != "$LEASE_TOKEN" ] || [ "${C_LEASE_PID:-}" != "$LEASE_PID" ] \
        || [ "${C_LEASE_START:-}" != "$LEASE_START" ]; then
        live=contradictory
      elif pid_matches "$LEASE_PID" "$LEASE_START"; then
        live=live
      else
        live=stale
      fi
    else
      live=malformed
    fi
  fi
  printf 'custody=%s lease=%s server=%s pane=%s agent=%s\n' "$integrity" "$live" "$server" "$pane" "$agent"
}

command_server_ensure() {
  local home
  load_custody || die "custody record is missing or malformed"
  home=$(canonical_home)
  [ "$C_HOME" = "$home" ] || die "custody belongs to a different canonical Firstmate home"
  if ensure_recorded_server 1; then
    printf 'server ready: session=%s\n' "$C_HERDR_SESSION"
  else
    die "recorded named Herdr server did not become available within the bounded retry"
  fi
}

validate_count FM_PRIMARY_SERVER_ATTEMPTS "$SERVER_ATTEMPTS"
validate_count FM_PRIMARY_ATTEST_ATTEMPTS "$ATTEST_ATTEMPTS"
validate_delay FM_PRIMARY_SERVER_DELAY "$SERVER_DELAY"
validate_delay FM_PRIMARY_ATTEST_DELAY "$ATTEST_DELAY"

case "${1:-}" in
  -h|--help|help) usage ;;
  launch) shift; fm_refuse_if_gate_agent "$FM_ROOT"; command_launch "$@" ;;
  recover) shift; fm_refuse_if_gate_agent "$FM_ROOT"; command_recover "$@" ;;
  resume) shift; fm_refuse_if_gate_agent "$FM_ROOT"; command_resume_internal "$@" ;;
  attest) shift; fm_refuse_if_gate_agent "$FM_ROOT"; command_attest "$@" ;;
  status) shift; [ "$#" -eq 0 ] || die "status takes no options"; command_status ;;
  server-ensure) shift; fm_refuse_if_gate_agent "$FM_ROOT"; [ "$#" -eq 0 ] || die "server-ensure takes no options"; command_server_ensure ;;
  *) usage >&2; exit 2 ;;
esac
