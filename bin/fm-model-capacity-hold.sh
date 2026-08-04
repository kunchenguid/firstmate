#!/usr/bin/env bash
# Register, inspect, or release the home-wide hold that blocks Firstmate-owned
# model-consuming execution paths while leaving interrupts and cleanup available.
#
# Usage:
#   fm-model-capacity-hold.sh register <hold-id> --reason <one-line> --dispatch-ref <one-line>
#   fm-model-capacity-hold.sh status
#   fm-model-capacity-hold.sh release <hold-id> --authority-file <path>
#
# Registration and release receipts live under data/model-capacity-holds/. A
# release requires a regular authority object and records its SHA-256 before the
# active marker is retired. The current primary turn and native same-session
# continuations, direct TUI input, provider CLIs, lower-level backend sends,
# already-running agents, and direct no-mistakes commands are outside this
# command's control; docs/architecture.md owns the complete boundary inventory.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
MARKER="$STATE/.model-capacity-hold"
RECEIPTS="$DATA/model-capacity-holds"
LIFECYCLE_LOCK="$STATE/.model-capacity-hold.lock"

# shellcheck source=bin/fm-custody-lib.sh
. "$SCRIPT_DIR/fm-custody-lib.sh"
# shellcheck source=bin/fm-model-capacity-hold-lib.sh
. "$SCRIPT_DIR/fm-model-capacity-hold-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fail() {
  printf 'fm-model-capacity-hold: %s\n' "$*" >&2
  exit 1
}

validate_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) fail "hold id must be a privacy-safe slug" ;; esac
}

validate_line() {
  [ -n "$2" ] || fail "$1 is required"
  case "$2" in *$'\n'*|*$'\r'*) fail "$1 must be one line" ;; esac
}

write_atomic() {  # <path> <exclusive:0|1>, content on stdin
  local path=$1 exclusive=$2 dir tmp
  dir=${path%/*}
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.model-hold.tmp.XXXXXX") || fail "could not allocate receipt temporary"
  chmod 600 "$tmp"
  cat > "$tmp" || { rm -f "$tmp"; fail "could not write temporary"; }
  if [ "$exclusive" = 1 ] && [ -e "$path" ]; then
    rm -f "$tmp"
    fail "refusing to overwrite existing receipt: $path"
  fi
  if [ "$exclusive" = 1 ]; then
    (set -C; : > "$path") 2>/dev/null || { rm -f "$tmp"; fail "receipt appeared concurrently: $path"; }
  fi
  mv "$tmp" "$path" || { rm -f "$tmp"; fail "could not publish $path"; }
}

LOCK_HELD=0
release_lifecycle_lock() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  fm_lock_release "$LIFECYCLE_LOCK"
  LOCK_HELD=0
}

acquire_lifecycle_lock() {
  fm_lock_acquire_wait "$LIFECYCLE_LOCK"
  LOCK_HELD=1
  trap release_lifecycle_lock EXIT
}

registration_matches() {  # <receipt> <id> <reason> <dispatch>
  local receipt=$1 id=$2 reason=$3 dispatch=$4 schema receipt_id receipt_reason receipt_dispatch
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  schema=$(fm_model_capacity_hold_value "$receipt" schema) || return 1
  receipt_id=$(fm_model_capacity_hold_value "$receipt" hold_id) || return 1
  receipt_reason=$(fm_model_capacity_hold_value "$receipt" reason) || return 1
  receipt_dispatch=$(fm_model_capacity_hold_value "$receipt" dispatch_ref) || return 1
  [ "$schema" = fm-model-capacity-hold.v1 ] \
    && [ "$receipt_id" = "$id" ] \
    && [ "$receipt_reason" = "$reason" ] \
    && [ "$receipt_dispatch" = "$dispatch" ]
}

publish_marker() {  # <receipt>
  local receipt=$1 staged="$MARKER.tmp.${BASHPID:-$$}"
  cp "$receipt" "$staged" || fail "could not stage active marker"
  mv "$staged" "$MARKER" || fail "could not publish active marker"
}

command_register() {
  local id reason dispatch timestamp receipt existing_id
  id=${1:-}
  reason=
  dispatch=
  [ "$#" -ge 1 ] || fail "register requires a hold id"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) shift; reason=${1:-} ;;
      --dispatch-ref) shift; dispatch=${1:-} ;;
      *) fail "unknown register argument: $1" ;;
    esac
    shift
  done
  validate_id "$id"
  validate_line reason "$reason"
  validate_line dispatch-ref "$dispatch"
  mkdir -p "$STATE" "$RECEIPTS"
  acquire_lifecycle_lock
  if [ -e "$MARKER" ]; then
    existing_id=$(fm_model_capacity_hold_value "$MARKER" hold_id) || fail "active hold marker is malformed"
    [ "$existing_id" = "$id" ] || fail "another model-capacity hold is active: $existing_id"
    printf 'registered: %s already active\n' "$id"
    return 0
  fi
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  receipt="$RECEIPTS/$id.registered"
  if [ -e "$receipt" ]; then
    [ ! -e "$RECEIPTS/$id.released" ] && [ ! -e "$RECEIPTS/$id.active-marker-retired" ] \
      || fail "hold registration was already released: $id"
    registration_matches "$receipt" "$id" "$reason" "$dispatch" \
      || fail "existing registration receipt does not match retry: $receipt"
  else
    {
      printf 'schema=fm-model-capacity-hold.v1\n'
      printf 'hold_id=%s\n' "$id"
      printf 'reason=%s\n' "$reason"
      printf 'dispatch_ref=%s\n' "$dispatch"
      printf 'registered_at=%s\n' "$timestamp"
    } | write_atomic "$receipt" 1
  fi
  publish_marker "$receipt"
  release_lifecycle_lock
  trap - EXIT
  printf 'registered: %s\n' "$id"
}

command_status() {
  if [ ! -e "$MARKER" ]; then
    printf 'inactive\n'
    return 0
  fi
  cat "$MARKER"
}

command_release() {
  local id authority active_id digest timestamp registered receipt registration_digest
  id=${1:-}
  authority=
  [ "$#" -ge 1 ] || fail "release requires a hold id"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --authority-file) shift; authority=${1:-} ;;
      *) fail "unknown release argument: $1" ;;
    esac
    shift
  done
  validate_id "$id"
  [ -f "$authority" ] && [ ! -L "$authority" ] || fail "authority file must be a regular non-symlink file"
  mkdir -p "$STATE" "$RECEIPTS"
  acquire_lifecycle_lock
  active_id=$(fm_model_capacity_hold_value "$MARKER" hold_id) || fail "no valid active model-capacity hold"
  [ "$active_id" = "$id" ] || fail "active hold is $active_id, not $id"
  registered="$RECEIPTS/$id.registered"
  [ -f "$registered" ] && [ ! -L "$registered" ] || fail "registration receipt is missing"
  digest=$(fm_custody_sha256 "$authority") || fail "could not digest release authority"
  registration_digest=$(fm_custody_sha256 "$registered") || fail "could not digest registration receipt"
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  receipt="$RECEIPTS/$id.released"
  if [ -e "$receipt" ]; then
    [ "$(fm_model_capacity_hold_value "$receipt" schema || true)" = fm-model-capacity-hold-release.v1 ] \
      && [ "$(fm_model_capacity_hold_value "$receipt" hold_id || true)" = "$id" ] \
      && [ "$(fm_model_capacity_hold_value "$receipt" registration_sha256 || true)" = "$registration_digest" ] \
      && [ "$(fm_model_capacity_hold_value "$receipt" authority_path || true)" = "$authority" ] \
      && [ "$(fm_model_capacity_hold_value "$receipt" authority_sha256 || true)" = "$digest" ] \
      || fail "existing release receipt does not match retry: $receipt"
  else
    {
      printf 'schema=fm-model-capacity-hold-release.v1\n'
      printf 'hold_id=%s\n' "$id"
      printf 'registration_sha256=%s\n' "$registration_digest"
      printf 'authority_path=%s\n' "$authority"
      printf 'authority_sha256=%s\n' "$digest"
      printf 'released_at=%s\n' "$timestamp"
    } | write_atomic "$receipt" 1
  fi
  mv "$MARKER" "$RECEIPTS/$id.active-marker-retired" \
    || fail "release receipt exists but active marker could not be retired"
  release_lifecycle_lock
  trap - EXIT
  printf 'released: %s\n' "$id"
}

case "${1:-}" in
  register) shift; command_register "$@" ;;
  status) shift; [ "$#" -eq 0 ] || fail "status takes no arguments"; command_status ;;
  release) shift; command_release "$@" ;;
  -h|--help) sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
  *) fail "usage: fm-model-capacity-hold.sh register|status|release ..." ;;
esac
