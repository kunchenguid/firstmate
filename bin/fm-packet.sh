#!/usr/bin/env bash
# fm-packet.sh - record and check bounded packet-scoped merge authority.
#
# AGENTS.md section 7 describes the bounded, already-proven-operationally
# model this mechanizes: an explicitly authorized execution packet may grant
# packet-scoped merge authority, under which a conforming internal PR may
# merge without another per-PR captain word only while that packet remains
# open, granted, and the PR's repo is inside the packet's declared scope. The
# grant expires the instant the packet closes, never enables yolo, and is
# never standing global autonomous-merge authority.
#
# This script is the smallest local mechanism that lets that lifecycle be
# recorded and checked mechanically instead of re-derived from memory each
# time: open a packet naming its authorized repos and objective, grant it
# merge authority as a separate explicit step, check a PR's repo against an
# open, granted packet's scope, and close the packet to expire the grant. It
# records and checks the packet only - it does not itself drive or authorize a
# merge; a merge helper (e.g. bin/fm-pr-merge.sh) may consult `check` before
# treating a captain merge word as already satisfied for an in-scope PR, but
# no such wiring is added by this script.
#
# Records live one per packet at data/packets/<slug>.record as plain
# key=value lines: status (open|closed), repos (comma-separated owner/repo
# list), objective (one line), merge_authority (yes|no), opened, granted, and
# closed (UTC timestamps, empty until set).
#
# Usage:
#   fm-packet.sh open <slug> --repo <owner/repo> [--repo <owner/repo>...] --objective <text>
#   fm-packet.sh grant <slug>
#   fm-packet.sh check <slug> --repo <owner/repo>
#   fm-packet.sh close <slug>
#   fm-packet.sh show <slug>
#
# Every mutation (open, grant, close) serializes on a per-slug lock so a
# concurrent grant and close cannot race each other's read-modify-write and
# silently resurrect a closed packet's merge authority (a grant that reads the
# old, still-open record after a concurrent close writes last would otherwise
# restore status=open with merge_authority=yes already set).
#
# Environment:
#   FM_HOME               operational home
#   FM_PACKET_NOW         UTC timestamp override YYYY-MM-DDTHH:MM:SSZ (tests)
#   FM_PACKET_TEST_DELAY  seconds to hold the per-slug lock before grant/close
#                         writes (tests only; default 0, no delay)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PACKETS_DIR="$DATA/packets"

# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

PACKET_LOCK=
PACKET_LOCK_HELD=0
packet_lock_release() {
  [ "$PACKET_LOCK_HELD" = 1 ] || return 0
  fm_lock_release "$PACKET_LOCK"
  PACKET_LOCK_HELD=0
}
trap packet_lock_release EXIT

acquire_packet_lock() {  # <slug>
  mkdir -p "$PACKETS_DIR" || fail "could not create $PACKETS_DIR"
  PACKET_LOCK="$PACKETS_DIR/.lock-$1"
  fm_lock_acquire_wait "$PACKET_LOCK"
  PACKET_LOCK_HELD=1
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-packet: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'fm-packet: %s\n' "$*" >&2
  usage >&2
  exit 2
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2 LC_ALL=C
  case "$value" in
    ''|.*|*/*|*[!A-Za-z0-9._-]*) fail "$label must be a path-safe slug: $value" ;;
  esac
}

validate_repo() {  # <value>
  local value=$1 LC_ALL=C
  case "$value" in
    */*/*|*/) fail "repo must be OWNER/REPO: $value" ;;
    *[!A-Za-z0-9._/-]*) fail "repo must be OWNER/REPO: $value" ;;
    */*) : ;;
    *) fail "repo must be OWNER/REPO: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

now_stamp() {
  local now=${FM_PACKET_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  case "$now" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) fail "FM_PACKET_NOW must be a UTC YYYY-MM-DDTHH:MM:SSZ timestamp" ;;
  esac
  printf '%s' "$now"
}

record_path() {  # <slug>
  printf '%s/%s.record' "$PACKETS_DIR" "$1"
}

record_field() {  # <record-text> <field>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

read_record() {  # <slug> -> record text, or non-zero if absent
  local file
  file=$(record_path "$1")
  [ -f "$file" ] && [ -r "$file" ] && [ ! -L "$file" ] || return 1
  cat "$file"
}

write_record_atomic() {  # <slug> <record-text>
  local slug=$1 text=$2 file tmp
  file=$(record_path "$slug")
  mkdir -p "$PACKETS_DIR" || fail "could not create $PACKETS_DIR"
  tmp=$(mktemp "$PACKETS_DIR/.fm-packet.XXXXXX") || fail "could not stage the packet record"
  printf '%s\n' "$text" > "$tmp" || { rm -f -- "$tmp"; fail "could not write the staged packet record"; }
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; fail "could not replace $file"; }
}

command_open() {
  local slug=${1:-} objective='' repos='' repo
  [ -n "$slug" ] || usage_error "open requires <slug>"
  validate_slug slug "$slug"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)
        shift
        repo=${1:-}
        validate_repo "$repo"
        case ",$repos," in
          *",$repo,"*) : ;;
          *) repos="${repos:+$repos,}$repo" ;;
        esac
        ;;
      --objective) shift; objective=${1:-} ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "unknown open argument: $1" ;;
    esac
    shift
  done
  [ -n "$repos" ] || usage_error "open requires at least one --repo"
  validate_one_line objective "$objective"
  acquire_packet_lock "$slug"
  read_record "$slug" >/dev/null 2>&1 && fail "packet $slug already exists"
  write_record_atomic "$slug" "$(printf 'status=open\nrepos=%s\nobjective=%s\nmerge_authority=no\nopened=%s\ngranted=\nclosed=\n' \
    "$repos" "$objective" "$(now_stamp)")"
  printf '%s\n' "$slug"
}

command_grant() {
  local slug=${1:-} record status
  [ -n "$slug" ] || usage_error "grant requires <slug>"
  acquire_packet_lock "$slug"
  record=$(read_record "$slug") || fail "packet $slug does not exist"
  status=$(record_field "$record" status)
  [ "$status" = open ] || fail "packet $slug is not open (status=$status)"
  # Test-only seam: hold the lock across a deliberate delay so a concurrency
  # test can prove a competing close blocks until this write completes,
  # instead of racing it the way the unlocked implementation once did.
  [ "${FM_PACKET_TEST_DELAY:-0}" = 0 ] || sleep "$FM_PACKET_TEST_DELAY"
  record=$(printf '%s\n' "$record" | sed \
    -e "s/^merge_authority=.*/merge_authority=yes/" \
    -e "s/^granted=.*/granted=$(now_stamp)/")
  write_record_atomic "$slug" "$record"
  printf '%s\n' "$slug"
}

command_check() {
  local slug=${1:-} repo='' record status authority repos
  [ -n "$slug" ] || usage_error "check requires <slug>"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) shift; repo=${1:-} ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "unknown check argument: $1" ;;
    esac
    shift
  done
  [ -n "$repo" ] || usage_error "check requires --repo"
  validate_repo "$repo"
  record=$(read_record "$slug") || fail "packet $slug does not exist"
  status=$(record_field "$record" status)
  authority=$(record_field "$record" merge_authority)
  repos=$(record_field "$record" repos)
  [ "$status" = open ] || fail "packet $slug is closed; its merge authority has expired"
  [ "$authority" = yes ] || fail "packet $slug has not been granted merge authority"
  case ",$repos," in
    *",$repo,"*) : ;;
    *) fail "repo $repo is outside packet $slug's scope ($repos)" ;;
  esac
  printf 'authorized: %s is in scope for packet %s\n' "$repo" "$slug"
}

command_close() {
  local slug=${1:-} record status
  [ -n "$slug" ] || usage_error "close requires <slug>"
  acquire_packet_lock "$slug"
  record=$(read_record "$slug") || fail "packet $slug does not exist"
  status=$(record_field "$record" status)
  [ "$status" = open ] || fail "packet $slug is already closed"
  [ "${FM_PACKET_TEST_DELAY:-0}" = 0 ] || sleep "$FM_PACKET_TEST_DELAY"
  record=$(printf '%s\n' "$record" | sed \
    -e "s/^status=.*/status=closed/" \
    -e "s/^closed=.*/closed=$(now_stamp)/")
  write_record_atomic "$slug" "$record"
  printf '%s\n' "$slug"
}

command_show() {
  local slug=${1:-} record
  [ -n "$slug" ] || usage_error "show requires <slug>"
  record=$(read_record "$slug") || fail "packet $slug does not exist"
  printf '%s\n' "$record"
}

case "${1:-}" in
  open) shift; command_open "$@" ;;
  grant) shift; command_grant "$@" ;;
  check) shift; command_check "$@" ;;
  close) shift; command_close "$@" ;;
  show) shift; command_show "$@" ;;
  -h|--help) usage ;;
  *) usage_error "expected open, grant, check, close, or show" ;;
esac
