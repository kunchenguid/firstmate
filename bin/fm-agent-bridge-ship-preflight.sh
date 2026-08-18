#!/usr/bin/env bash
# Atomically publish one private Agent bridge ship preflight handoff.
#
# Usage:
#   fm-agent-bridge-ship-preflight.sh publish <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-ship-preflight-lib.sh
. "$SCRIPT_DIR/fm-ship-preflight-lib.sh"

usage() { sed -n '2,5p' "$0" | sed 's/^# //'; }
die() { echo "fm-agent-bridge-ship-preflight: $*" >&2; exit 1; }
mode_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi; }
links_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %l "$1"; else stat -c %h "$1"; fi; }
inode_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %i "$1"; else stat -c %i "$1"; fi; }
owner_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %u "$1"; else stat -c %u "$1"; fi; }
valid_private_metadata() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(mode_of "$1" 2>/dev/null || true)" = 600 ]; }
valid_private_file() { valid_private_metadata "$1" && [ "$(links_of "$1" 2>/dev/null || true)" = 1 ]; }
valid_data_dir() {
  local path=$1 mode owner group other
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  owner=$(owner_of "$path" 2>/dev/null || true)
  [ "$owner" = "$(id -u)" ] || return 1
  mode=$(mode_of "$path" 2>/dev/null || true)
  case "$mode" in [0-7][0-7][0-7]) ;; *) return 1 ;; esac
  group=${mode#?}; group=${group%?}
  other=${mode#??}
  case "$group$other" in *[2367]*) return 1 ;; esac
}
valid_private_dir() {
  local path=$1 mode
  valid_data_dir "$path" || return 1
  mode=$(mode_of "$path" 2>/dev/null || true)
  case "$mode" in [0-7]00) ;; *) return 1 ;; esac
}
valid_id() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1;; *) return 0;; esac; }
valid_producer_revision() {
  fm_ship_preflight_within_limit "$1" || return 1
  jq -e '
    .producer_revision | type == "number" and floor == . and . >= 1 and . <= 9007199254740991
  ' "$1" >/dev/null
}
record_producer_revision() {
  fm_ship_preflight_within_limit "$1" || return 1
  jq -er '
    .producer_revision as $revision |
    if ($revision | type == "number" and floor == . and . >= 1 and . <= 9007199254740991) then
      $revision
    else
      error("invalid producer revision")
    end
  ' "$1"
}
same_private_handoff() {
  local first=$1 second=$2 first_inode second_inode
  valid_private_metadata "$first" && valid_private_metadata "$second" || return 1
  [ "$(links_of "$first" 2>/dev/null || true)" = 2 ] || return 1
  [ "$(links_of "$second" 2>/dev/null || true)" = 2 ] || return 1
  first_inode=$(inode_of "$first" 2>/dev/null || true)
  second_inode=$(inode_of "$second" 2>/dev/null || true)
  [ -n "$first_inode" ] && [ "$first_inode" = "$second_inode" ]
}
recover_claim() {
  local claim claim_revision handoff_revision
  local -a claims
  shopt -s nullglob
  claims=("$HANDOFF_DIR/.${ID}.claim."*)
  shopt -u nullglob
  [ "${#claims[@]}" -le 1 ] || die "multiple private bridge handoff claims"
  [ "${#claims[@]}" -eq 1 ] || return 0
  claim=${claims[0]}
  if [ -e "$HANDOFF" ] || [ -L "$HANDOFF" ]; then
    if same_private_handoff "$claim" "$HANDOFF"; then
      rm -f -- "$claim" || die "could not recover private bridge handoff"
      return 0
    fi
    valid_private_file "$claim" && valid_private_file "$HANDOFF" || die "no valid private bridge handoff"
    claim_revision=$(record_producer_revision "$claim") || die "claimed preflight producer revision is malformed"
    handoff_revision=$(record_producer_revision "$HANDOFF") || die "private bridge handoff producer revision is malformed"
    die "competing private bridge handoffs: claimed revision $claim_revision and pending revision $handoff_revision"
  else
    valid_private_file "$claim" || die "invalid private bridge handoff claim"
    if ln "$claim" "$HANDOFF"; then
      rm -f -- "$claim" || die "could not recover private bridge handoff"
      return 0
    fi
    valid_private_file "$HANDOFF" || die "could not recover private bridge handoff"
    claim_revision=$(record_producer_revision "$claim") || die "claimed preflight producer revision is malformed"
    handoff_revision=$(record_producer_revision "$HANDOFF") || die "private bridge handoff producer revision is malformed"
    die "competing private bridge handoffs: claimed revision $claim_revision and pending revision $handoff_revision"
  fi
  rm -f -- "$claim" || die "could not recover private bridge handoff"
}

[ "${1:-}" = publish ] && [ "$#" = 2 ] || { usage >&2; exit 2; }
ID=$2
valid_id "$ID" || die "unsafe task id"
fm_ship_preflight_validate_limit || die "FM_SHIP_PREFLIGHT_MAX_BYTES must be a positive integer no greater than 1048576"

BRIDGE_ROOT="$STATE/agent-bridge"
HANDOFF_DIR="$BRIDGE_ROOT/ship-preflight"
if ! valid_private_dir "$BRIDGE_ROOT" || ! valid_private_dir "$HANDOFF_DIR"; then
  die "unsafe bridge handoff directory"
fi
HANDOFF="$HANDOFF_DIR/$ID.json"

valid_data_dir "$DATA" || die "unsafe task record directory"
REC_DIR="$DATA/$ID"
if [ -e "$REC_DIR" ] || [ -L "$REC_DIR" ]; then
  valid_private_dir "$REC_DIR" || die "unsafe task record directory"
else
  (umask 077; mkdir "$REC_DIR") || die "could not create task record directory"
  valid_private_dir "$REC_DIR" || die "unsafe task record directory"
fi

# shellcheck source=bin/fm-wake-lib.sh
STATE="$REC_DIR" FM_STATE_OVERRIDE="$REC_DIR" . "$SCRIPT_DIR/fm-wake-lib.sh"
LOCK="$REC_DIR/.ship-preflight.lock"
fm_lock_acquire_wait "$LOCK" || die "could not lock preflight record"
CLAIM=
TMP=
VALIDATION_DATA=
restore_claim() {
  [ -f "$CLAIM" ] && [ -s "$CLAIM" ] || return 0
  if [ ! -e "$HANDOFF" ] && [ ! -L "$HANDOFF" ]; then
    if ln "$CLAIM" "$HANDOFF" 2>/dev/null; then
      rm -f -- "$CLAIM" || true
      return 0
    fi
  fi
  same_private_handoff "$CLAIM" "$HANDOFF" && rm -f -- "$CLAIM" || true
}
cleanup() {
  local status=$?
  trap - EXIT
  [ "$status" -eq 0 ] || restore_claim
  [ -z "$VALIDATION_DATA" ] || rm -rf -- "$VALIDATION_DATA" || true
  [ -z "$TMP" ] || rm -f -- "$TMP" || true
  [ ! -f "$CLAIM" ] || [ -s "$CLAIM" ] || rm -f -- "$CLAIM" 2>/dev/null || true
  fm_lock_release "$LOCK" || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

recover_claim
valid_private_file "$HANDOFF" || die "no valid private bridge handoff"
fm_ship_preflight_within_limit "$HANDOFF" || die "preflight input exceeds the bounded size"
CLAIM=$(umask 077; mktemp "$HANDOFF_DIR/.${ID}.claim.XXXXXX") || die "could not claim private bridge handoff"
if ! mv -f -- "$HANDOFF" "$CLAIM"; then
  rm -f -- "$CLAIM"
  CLAIM=
  die "could not claim private bridge handoff"
fi
valid_private_file "$CLAIM" || die "invalid private bridge handoff"
fm_ship_preflight_within_limit "$CLAIM" || die "preflight input exceeds the bounded size"

TMP=$(umask 077; mktemp "$REC_DIR/.ship-preflight.XXXXXX") || die "could not prepare preflight record"
if ! fm_ship_preflight_copy_bounded_file "$CLAIM" "$TMP" || ! chmod 600 "$TMP" || ! valid_private_file "$TMP"; then
  rm -f -- "$TMP"
  die "could not prepare private preflight record"
fi
VALIDATION_DATA=$(umask 077; mktemp -d "$REC_DIR/.ship-preflight-validation.XXXXXX") || die "could not validate private preflight record"
mkdir "$VALIDATION_DATA/$ID" || die "could not validate private preflight record"
chmod 700 "$VALIDATION_DATA" "$VALIDATION_DATA/$ID" || die "could not validate private preflight record"
if ! fm_ship_preflight_copy_bounded_file "$TMP" "$VALIDATION_DATA/$ID/ship-preflight.json" || ! chmod 600 "$VALIDATION_DATA/$ID/ship-preflight.json" \
  || ! FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$VALIDATION_DATA" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-ship-end-to-end.sh" validate "$ID" >/dev/null; then
  rm -f -- "$TMP"
  die "invalid typed private bridge handoff"
fi
rm -rf -- "$VALIDATION_DATA"
VALIDATION_DATA=
valid_producer_revision "$TMP" || die "preflight producer revision is malformed"
if [ -e "$REC_DIR/ship-preflight.json" ] || [ -L "$REC_DIR/ship-preflight.json" ]; then
  valid_private_file "$REC_DIR/ship-preflight.json" || die "existing preflight record is unsafe"
  fm_ship_preflight_within_limit "$REC_DIR/ship-preflight.json" || die "existing preflight record exceeds the bounded size"
  current_revision=$(record_producer_revision "$REC_DIR/ship-preflight.json") || die "existing preflight producer revision is malformed"
else
  current_revision=0
fi
jq -e --argjson current_revision "$current_revision" '.producer_revision > $current_revision' "$TMP" >/dev/null \
  || die "preflight producer revision does not advance the current record"
mv -f -- "$TMP" "$REC_DIR/ship-preflight.json"
valid_private_file "$REC_DIR/ship-preflight.json" || die "preflight publication failed validation"
rm -f -- "$CLAIM"
CLAIM=
printf 'published\n'
