#!/usr/bin/env bash
# fm-captain-ask.sh - file firstmate's own direct captain asks on the shared
# captain board, so the request survives this session's memory.
#
# Usage:
#   fm-captain-ask.sh "<title>" [--tldr <one-line-detail>]
#   fm-captain-ask.sh --answer <ask-id> "<answer-text>"
#
# `fm-captain-ask.sh "<title>"` creates one `captain`-label bead on the board
# this home names in `config/beads-board` (contract: bin/fm-bead-board-lib.sh),
# with `fm-requester: firstmate` in its body, and records the bead id under
# `state/captain-asks/<seq>.rec` as `v1 <bead-id> <title>`. The ask id is that
# record's <seq>, printed on stdout.
#
# `--answer <ask-id> "<text>"` closes the recorded bead with the text as its
# close reason and removes the record. `--answer` works in a home without the
# config only when the record still exists from an earlier configured run -
# but with no board to close it against, it refuses loudly instead of losing
# the answer.
#
# Notification of the requester (firstmate) rides bin/fm-bead-board-lib.sh's
# consumers: bin/fm-captain-beads-check.sh wakes this home when the bead
# closes, whoever closed it, so the loop does not depend on this script being
# re-run. A delivery failure exits nonzero and the record stays for retry.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"
# shellcheck source=bin/fm-bead-board-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-bead-board-lib.sh"

ASK_DIR="$FM_HOME/state/captain-asks"

fail() {
  printf 'fm-captain-ask: %s\n' "$*" >&2
  exit 1
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

validate_one_line() {  # <label> <value>
  [ -n "$2" ] || fail "$1 must not be empty"
  case "$2" in
    *$'\n'*|*$'\r'*) fail "$1 must be one line" ;;
  esac
}

command_answer() {  # <ask-id> <answer-text>
  local id=$1 answer=$2 record line bead title rc=0
  case "$id" in
    ''|*[!0-9]*) fail "ask id must be the numeric id printed when the ask was filed: $id" ;;
  esac
  [ -n "$answer" ] || fail "the answer text must not be empty"
  record="$ASK_DIR/$id.rec"
  [ -f "$record" ] || fail "no recorded captain ask $id in this home"
  IFS= read -r line < "$record" || fail "ask record $id is unreadable"
  case "$line" in
    'v1 '[A-Za-z0-9._-]*' '*) : ;;
    *) fail "ask record $id is unrecognized: $line" ;;
  esac
  line=${line#v1 }
  bead=${line%% *}
  title=${line#* }
  fm_bead_board_ready || rc=$?
  [ "$rc" -ne 2 ] || fail "the configured captain board is unavailable; the answer for ask $id ($title) is NOT recorded - resend when it is back"
  [ "$rc" -ne 1 ] || fail "this home has no config/beads-board; the answer for ask $id ($title) is NOT recorded"
  fm_bead_close "$bead" "Captain answered: $answer" \
    || fail "closing ask $id against the board failed; the answer is NOT recorded - retry"
  rm -f -- "$record"
  printf 'answered: %s (%s)\n' "$id" "$bead"
}

command_create() {  # <title> [--tldr <text>]
  local title=$1 tldr='' seq bead record rc=0
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tldr) shift; tldr=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_one_line title "$title"
  [ -z "$tldr" ] || validate_one_line tldr "$tldr"
  fm_bead_board_ready || rc=$?
  [ "$rc" -ne 2 ] || fail "the configured captain board is unavailable"
  [ "$rc" -ne 1 ] || fail "this home has no config/beads-board; file captain asks as board beads requires it"
  bead=$(fm_bead_headline_create "$title" firstmate \
    "${tldr:-Captain ask from firstmate ($FM_HOME).}") \
    || fail "bd create against the configured board failed"
  umask 077
  mkdir -p "$ASK_DIR" || fail "cannot create $ASK_DIR"
  seq=1
  while [ -e "$ASK_DIR/$seq.rec" ] || [ -L "$ASK_DIR/$seq.rec" ]; do
    seq=$((seq + 1))
  done
  record="$ASK_DIR/$seq.rec"
  printf 'v1 %s %s\n' "$bead" "$title" > "$record" \
    || fail "the bead $bead is filed but its record could not be written; close it by hand with bd close $bead"
  printf '%s : %s (%s)\n' "$seq" "$title" "$bead"
}

case "${1:-}" in
  --answer)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    command_answer "$2" "$3"
    ;;
  -h|--help|'')
    usage
    ;;
  -*)
    usage >&2
    exit 2
    ;;
  *)
    command_create "$@"
    ;;
esac
