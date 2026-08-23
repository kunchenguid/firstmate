#!/usr/bin/env bash
# bin/fm-wait.sh - declare, refresh, clear, or show a task's machine wait
# field. The field's byte format, damping semantics, and single-fire expiry
# contract are owned by bin/fm-wait-lib.sh; this CLI is its only writer.
#
# Usage:
#   fm-wait.sh declare <id> --reason <text> --until <when>
#   fm-wait.sh clear <id> [--note <text>]
#   fm-wait.sh show <id>
#
# <when> accepts +<seconds> (relative from now), a bare unix epoch, or a
# date string handed to the platform parser (GNU `date -d`, else BSD
# `date -j -f` against common ISO shapes); an unparseable deadline or one not
# in the future is refused loudly. A re-declare simply replaces the field
# (that refresh is the intended way to extend a wait).
#
# declare writes the field AND appends the matching status event
# ("<paused-verb> ...: <reason> (until <ISO>)") to state/<id>.status in the
# same command, so the wake channel and the machine field cannot drift; clear
# removes the field and appends a resume event. Both refuse an id that has no
# state/<id>.meta, so a typo cannot create an orphan wait. FM_HOME selects
# the home, exactly as for fm-send.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wait-lib.sh
. "$SCRIPT_DIR/fm-wait-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

iso_of() {  # <epoch>
  if date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; then
    return 0
  fi
  date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null
}

parse_when() {  # <when> -> epoch on stdout, or failure
  local when=$1 now epoch fmt
  now=$(date +%s)
  case "$when" in
    +*)
      case "${when#+}" in ''|*[!0-9]*) return 1 ;; esac
      printf '%s' $(( now + ${when#+} ))
      return 0
      ;;
  esac
  case "$when" in
    ''|*[!0-9]*) ;;
    *) printf '%s' "$when"; return 0 ;;
  esac
  if epoch=$(date -d "$when" +%s 2>/dev/null); then
    printf '%s' "$epoch"
    return 0
  fi
  for fmt in '%Y-%m-%dT%H:%M:%S' '%Y-%m-%d %H:%M' '%Y-%m-%d'; do
    if epoch=$(date -j -f "$fmt" "$when" +%s 2>/dev/null); then
      printf '%s' "$epoch"
      return 0
    fi
  done
  return 1
}

CMD=${1:-}
ID=${2:-}
[ -n "$CMD" ] && [ -n "$ID" ] || usage
shift 2

[ -f "$STATE/$ID.meta" ] || {
  echo "error: no task metadata at $STATE/$ID.meta - refusing to touch a wait field for an unknown id" >&2
  exit 1
}
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}

case "$CMD" in
  declare)
    REASON='' WHEN=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --reason) REASON=${2:-}; shift 2 ;;
        --until)  WHEN=${2:-};  shift 2 ;;
        *) echo "error: unknown argument $1" >&2; usage ;;
      esac
    done
    [ -n "$REASON" ] || { echo "error: --reason is required" >&2; exit 1; }
    case "$REASON" in
      *$'\n'*) echo "error: --reason must be a single line" >&2; exit 1 ;;
    esac
    [ -n "$WHEN" ] || { echo "error: --until is required" >&2; exit 1; }
    UNTIL=$(parse_when "$WHEN") || {
      echo "error: cannot parse --until '$WHEN' (use +<seconds>, a unix epoch, or an ISO date)" >&2
      exit 1
    }
    NOW=$(date +%s)
    [ "$UNTIL" -gt "$NOW" ] || {
      echo "error: --until '$WHEN' is not in the future - a wait needs a real deadline" >&2
      exit 1
    }
    fm_wait_write "$STATE" "$ID" "$UNTIL" "$NOW" "$REASON" || exit 1
    ISO=$(iso_of "$UNTIL") || ISO="epoch $UNTIL"
    printf '%s: %s (until %s)\n' "$PAUSED_VERB" "$REASON" "$ISO" >> "$STATE/$ID.status"
    echo "declared: $ID waits until $ISO - $REASON"
    ;;
  clear)
    NOTE=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --note) NOTE=${2:-}; shift 2 ;;
        *) echo "error: unknown argument $1" >&2; usage ;;
      esac
    done
    if fm_wait_read "$STATE" "$ID"; then
      [ -n "$NOTE" ] || NOTE="wait cleared ($FM_WAIT_REASON)"
    else
      [ -n "$NOTE" ] || NOTE="wait cleared"
    fi
    case "$NOTE" in
      *$'\n'*) echo "error: --note must be a single line" >&2; exit 1 ;;
    esac
    fm_wait_clear_file "$STATE" "$ID"
    printf 'working: %s\n' "$NOTE" >> "$STATE/$ID.status"
    echo "cleared: $ID"
    ;;
  show)
    fm_wait_read "$STATE" "$ID"
    case $? in
      0)
        ISO=$(iso_of "$FM_WAIT_UNTIL") || ISO="epoch $FM_WAIT_UNTIL"
        echo "$FM_WAIT_STATE until=$ISO reason=$FM_WAIT_REASON"
        ;;
      1) echo "none" ;;
      *) echo "malformed (treated as undeclared - it silences nothing)"; exit 1 ;;
    esac
    ;;
  *)
    usage
    ;;
esac
