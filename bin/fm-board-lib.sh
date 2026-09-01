#!/usr/bin/env bash
# fm-board-lib.sh - shared mechanics for captain-facing Lavish board builders.
#
# One owner for the build sequence every board script shares, so a second board
# never re-implements injection or the bind-before-arm ordering rule:
#   1. inject a validated JSON payload into a fresh copy of a shipped template
#      at a stable board path (fm_board_publish),
#   2. establish or resume the board's Lavish session, then bind its answer
#      source to the keyed-answer intake ALWAYS before arming the polling
#      source (fm_board_serve_bind_arm), enforcing captain-hold-lifecycle's
#      ordering rule structurally rather than leaving it to agent memory.
#
# Each board script keeps ownership of what is board-specific: its payload
# schema and fail-closed validation, its template asset and stable path, and
# its CLI. This library owns only the shared mechanics.
#
# Contract:
#   FM_BOARD_FAIL_PREFIX  set by the sourcing script before any call; names it
#                         in every error line (e.g. "fm-bearings-board").
#   fm_board_fail <msg>   print "<prefix>: <msg>" to stderr and exit 1.
#   fm_board_publish <data.json> <template> <placeholder> <schema> <board> <script-id>
#                         validate JSON syntax was already checked by the
#                         caller; this performs the template checks, compacts
#                         the payload, escapes every "<" as < so a string
#                         containing "</script>" cannot terminate the data
#                         block, injects into a fresh template copy, round-trips
#                         the payload back out of the built page, publishes at
#                         <board>, and prints "board: <board>".
#   fm_board_serve_bind_arm <board>
#                         establish/resume the Lavish session, bind the board's
#                         canonical source id to bin/fm-captain-hold.sh intake,
#                         then arm the source only if not already registered.
#                         Prints served:/bound:/armed:/already-armed: lines.
#
# Sibling scripts (fm-procevent-lavish.sh, fm-captain-hold.sh, fm-procevent.sh)
# are resolved from this library's own directory.

FM_BOARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_board_fail() {
  printf '%s: %s\n' "${FM_BOARD_FAIL_PREFIX:-fm-board}" "$*" >&2
  exit 1
}

fm_board_publish() {  # <data.json> <template> <placeholder> <schema> <board> <script-id>
  local data=$1 template=$2 placeholder=$3 schema=$4 board=$5 script_id=$6
  local json tmp extracted
  [ -f "$template" ] && [ ! -L "$template" ] || fm_board_fail "board template is missing: $template"
  [ "$(grep -cxF "$placeholder" "$template")" -eq 1 ] \
    || fm_board_fail "board template does not carry exactly one data slot: $template"

  json=$(jq -c . "$data") || fm_board_fail "cannot compact the board data"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  (umask 077; mkdir -p "${board%/*}") || fm_board_fail "cannot create ${board%/*}"
  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") || fm_board_fail "cannot stage the board"
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$placeholder\\E\$/\$ENV{BOARD_JSON}/" "$template" > "$tmp"; then
    rm -f -- "$tmp"
    fm_board_fail "cannot inject the board data"
  fi
  if grep -qxF "$placeholder" "$tmp"; then
    rm -f -- "$tmp"
    fm_board_fail "the board data slot survived injection"
  fi
  # Round-trip the injected payload back out of the built page, so a board that
  # would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="'"$script_id"'" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$schema" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fm_board_fail "the built board does not carry a readable $schema payload"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"
    fm_board_fail "cannot publish the board"
  fi
  printf 'board: %s\n' "$board"
}

fm_board_serve_bind_arm() {  # <board>
  local board=$1 sid
  command -v lavish-axi >/dev/null 2>&1 || fm_board_fail "lavish-axi is not installed"
  lavish-axi "$board" || fm_board_fail "cannot establish the board Lavish session"
  printf 'served: %s\n' "$board"

  sid=$("$FM_BOARD_LIB_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fm_board_fail "cannot derive the board source id"
  "$FM_BOARD_LIB_DIR/fm-captain-hold.sh" bind "$sid" >/dev/null \
    || fm_board_fail "cannot bind the board source to the keyed-answer intake"
  printf 'bound: %s\n' "$sid"

  if "$FM_BOARD_LIB_DIR/fm-procevent.sh" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid"; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$FM_BOARD_LIB_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fm_board_fail "cannot arm the board as a process-event source"
    printf 'armed: %s\n' "$sid"
  fi
}
