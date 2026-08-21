#!/usr/bin/env bash
# fm-decision-hold.sh - transitional compatibility shim over bin/fm-captain-hold.sh.
#
# The separate "decision" concept collapsed into the one primitive the captain
# cares about: a task held for the captain. bin/fm-captain-hold.sh owns every
# surviving behavior; this shim only maps the retired command surface onto it so
# in-flight work briefed before the collapse keeps working for one release, and
# it will be removed in the release after the collapse lands.
#
# Mapping (old -> new):
#   id <origin> <key>                      -> prints the legacy <origin>-decision-<key> identity
#   hold <origin> <key> --title --reason [--repo]
#                                          -> hold <origin>-decision-<key> --origin <origin> ...
#   complete <origin> (--none | <key>...)  -> complete <origin> (--none | <origin>-decision-<key>...)
#   verify <origin>                        -> verify <origin>
#   resolve <origin> <key> --decision-file <f> --routed-to <id>...
#                                          -> answer <origin>-decision-<key> with the routed ids
#                                             appended to the decision text, then the recorded
#                                             blocked-by edges cleared through tasks-axi
#   answer|decline|repair <origin> <key> --decision-file <f>
#                                          -> answer <origin>-decision-<key> --decision-file <f>
#   answers (<origin> | --any-origin) --source <p>
#                                          -> answers with the same positional (the intake resolves
#                                             task ids first and legacy identities second)
#   bind <source> (<origin> | --any-origin) -> bind <source> [<origin>]
#   unbind | binding <source>              -> unchanged
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CAPTAIN_HOLD="$SCRIPT_DIR/fm-captain-hold.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  case "$2" in
    ''|*[!A-Za-z0-9._-]*) fail "$1 must be a non-empty privacy-safe slug: $2" ;;
  esac
}

compose() {  # <origin> <key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s' "$1" "$2"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' routed='' id dep tmp
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  id=$(compose "$origin" "$key")
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  [ -n "$routed" ] || fail "at least one --routed-to task is required; use answer when the captain's answer routes no work"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  # The routed identities become part of the recorded decision text, so the
  # record still says what work the answer released; the same inputs always
  # rebuild the same text, keeping an exact retry idempotent.
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-decision-hold-resolve.XXXXXX") \
    || fail "cannot stage the captain decision"
  if ! { cat "$decision_file" && printf '\n\nRouted work:\n' \
    && printf '%s\n' "$routed" | tr ' ' '\n' | sed 's/^/- /'; } > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the captain decision for $id"
  fi
  if ! "$CAPTAIN_HOLD" answer "$id" --decision-file "$tmp"; then
    rm -f -- "$tmp"
    exit 1
  fi
  rm -f -- "$tmp"
  # Clear the recorded dependency edges the old resolve path owned. A closed
  # blocker already reads as resolved, so a failure here is loud but not fatal
  # to the recorded close.
  for dep in $routed; do
    (cd "$FM_HOME" && tasks-axi unblock "$dep" --by "$id" >/dev/null 2>&1) || true
  done
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

command_complete() {
  local origin=${1:-} mapped=''
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    exec "$CAPTAIN_HOLD" complete "$origin" --none
  fi
  for key in "$@"; do
    [ "$key" != --none ] || fail "--none cannot be combined with decision keys"
    mapped="${mapped}${mapped:+ }$(compose "$origin" "$key")"
  done
  # shellcheck disable=SC2086  # mapped is a validated space-separated slug list.
  exec "$CAPTAIN_HOLD" complete "$origin" $mapped
}

command_close() {  # <origin> <key> <flag-args...>
  local origin=${1:-} key=${2:-} id
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  id=$(compose "$origin" "$key")
  shift 2
  local decision_file=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  exec "$CAPTAIN_HOLD" answer "$id" --decision-file "$decision_file"
}

command_hold() {
  local origin=${1:-} key=${2:-} id
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  id=$(compose "$origin" "$key")
  shift 2
  exec "$CAPTAIN_HOLD" hold "$id" --origin "$origin" "$@"
}

case "${1:-}" in
  id) shift; [ "$#" -eq 2 ] || { usage >&2; exit 2; }; compose "$1" "$2"; printf '\n' ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; exec "$CAPTAIN_HOLD" verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  answer|decline|repair) shift; command_close "$@" ;;
  answers) shift; exec "$CAPTAIN_HOLD" answers "$@" ;;
  bind) shift; exec "$CAPTAIN_HOLD" bind "$@" ;;
  unbind) shift; exec "$CAPTAIN_HOLD" unbind "$@" ;;
  binding) shift; exec "$CAPTAIN_HOLD" binding "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
