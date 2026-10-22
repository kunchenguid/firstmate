#!/usr/bin/env bash
# fm-rex-side.sh - labeled side panes in a Rex worker's own tab.
#
# docs/rex-backend.md "Side panes" owns the public contract. This header owns
# the mechanics.
#
# A worker running in its own Rex pane opens side panes beside itself for a
# test run, a dev server, or validation progress, so the captain sees them in
# the worker's tab. Every pane opens with `--focus=false`, so neither the
# worker's nor the captain's focus moves, and with `--keep-open`, so its last
# output stays readable after its command exits.
#
# Each side pane is labeled `<worker block label>/<name>`, for example
# `fm-firstmate-42de5bad-t1/tests`. That label is the only link between a
# side pane and its worker, because Rex records no creating client on a block;
# task cleanup (bin/backends/rex.sh fm_backend_rex_kill) closes exactly the
# blocks carrying it in the task's current and recorded tabs and leaves every
# other pane alone.
#
# The helper acts only for a proven worker pane: REX_BLOCK must be live on the
# selected server, inside REX_SESSION, with that block's child process an
# ancestor of this process (fm_backend_rex_launcher_identity), and its label
# must be a Firstmate task label (`fm-...`, no `/`). An inherited REX_* that
# names someone else's pane, such as the captain's, refuses with nothing
# changed. Every rex call passes `-S <server> --autostart=false` and full ids
# through the adapter (bin/backends/rex.sh fm_backend_rex_cli).
#
# Usage:
#   fm-rex-side.sh open <name> -- <command...>
#   fm-rex-side.sh list
#   fm-rex-side.sh close <name>
#
# open splits the worker's pane below it (35 percent of the split) and runs
# <command...> there through the login shell's environment, not the caller's:
# pass anything the command needs on its own command line, for example
# `env PORT=3000 npm run dev`. The working directory is the caller's. A pane
# with the same name already in the tab refuses; close it first. It prints
# "<name>\t<block-id>".
# list prints "<name>\t<running|exited N|unknown>\t<block-id>" for each side pane of
# this worker in its current tab. close closes one named pane and proves it
# gone (exit 3).
#
# A Rex window holds at most 64 panes by default (`rex server start --help`,
# --max-panes); a split beyond it fails with Rex's own error.
#
# Exit status: 0 on success, 2 on a usage error, 1 on a refusal or a Rex
# failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FM_REX_SIDE_RATIO=35

usage() {
  echo "usage: fm-rex-side.sh open <name> -- <command...> | list | close <name>" >&2
  exit 2
}

die() {
  echo "fm-rex-side: $*" >&2
  exit 1
}

name_ok() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]]
}

# side_identity: prove this process runs in a Firstmate worker's own pane and
# set SIDE_SESSION, SIDE_WINDOW, SIDE_PREFIX, and the pinned server.
side_identity() {
  local out rc label
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" || die "could not load the backend library"
  fm_backend_source rex || die "could not load the Rex adapter"
  fm_backend_rex_tool_check || exit 1
  FM_BACKEND_REX_SERVER=$(fm_backend_rex_server) || die "no Rex server could be named; run this from your own Rex pane"
  export FM_BACKEND_REX_SERVER
  fm_backend_rex_launcher_identity
  rc=$?
  case "$rc" in
    0) ;;
    2) die "could not read the Rex server at $FM_BACKEND_REX_SERVER; nothing changed" ;;
    *) die "this process is not running in its own Rex pane (REX_BLOCK and REX_SESSION must name the pane this process runs in); nothing changed" ;;
  esac
  out=$(fm_backend_rex_cli_json block inspect "$REX_BLOCK" --json) || die "could not inspect this pane"
  label=$(printf '%s' "$out" | jq -r '.block.label // empty' 2>/dev/null)
  SIDE_WINDOW=$(printf '%s' "$out" | jq -r '.block.window_id // empty' 2>/dev/null)
  case "$label" in
    */*) die "this pane ('$label') is itself a side pane; open side panes from the worker's own pane" ;;
    fm-?*) ;;
    *) die "this pane's label '$label' is not a Firstmate task label; side panes belong to Firstmate workers only" ;;
  esac
  case "$SIDE_WINDOW" in window:?*) ;; *) die "this pane is not placed in a tab" ;; esac
  SIDE_SESSION=$REX_SESSION
  SIDE_PREFIX="$label/"
}

# side_panes: "<block-id>\t<name>" for each side pane of this worker in its
# current tab.
side_panes() {
  local out
  out=$(fm_backend_rex_cli_json block ls -s "$SIDE_SESSION" --json) || die "could not list this session's panes"
  printf '%s' "$out" | jq -r --arg w "$SIDE_WINDOW" --arg p "$SIDE_PREFIX" '
    .blocks[]? | select(.window_id == $w and ((.label // "") | startswith($p)))
    | "\(.block_id)\t\(.label[($p | length):])"' 2>/dev/null
}

# side_state: `running`, `exited <code>`, or `unknown` for <block-id>.
side_state() { # <block-id>
  local out state
  out=$(fm_backend_rex_cli block call -s "$SIDE_SESSION" -b "$1" process 2>/dev/null) || { printf 'unknown'; return 0; }
  state=$(printf '%s' "$out" | jq -r 'if .last_exit == null then "running" else "exited \(.last_exit.exit_code)" end' 2>/dev/null)
  printf '%s' "${state:-unknown}"
}

side_close_block() { # <block-id>
  fm_backend_rex_block_close "${SIDE_SESSION#session:}:${1#block:}"
}

cmd_open() {
  local name=${1:-} panes bid pane_name out
  name_ok "$name" || { echo "fm-rex-side: a side pane name is 1-32 letters, digits, dots, underscores, or dashes, starting with a letter or digit" >&2; usage; }
  shift
  [ "${1:-}" = -- ] || usage
  shift
  [ "$#" -gt 0 ] || { echo "fm-rex-side: open needs a command after --" >&2; usage; }
  side_identity
  panes=$(side_panes) || exit 1
  while IFS=$'\t' read -r bid pane_name; do
    [ -n "$bid" ] && [ "$pane_name" = "$name" ] || continue
    die "side pane '$name' is already open in this tab; close it first (fm-rex-side.sh close $name)"
  done <<<"$panes"
  out=$(fm_backend_rex_cli_json split -s "$SIDE_SESSION" -b "$REX_BLOCK" --split below --ratio "$FM_REX_SIDE_RATIO" \
    --focus=false --keep-open --label "$SIDE_PREFIX$name" -c "$PWD" --json -- "$@") || die "rex could not open side pane '$name'"
  bid=$(printf '%s' "$out" | jq -r '.block_ids[0] // empty' 2>/dev/null)
  case "$bid" in block:?*) ;; *) die "could not read the new side pane's id from: $out" ;; esac
  printf '%s\t%s\n' "$name" "$bid"
}

cmd_list() {
  local panes bid pane_name
  [ "$#" -eq 0 ] || usage
  side_identity
  panes=$(side_panes) || exit 1
  while IFS=$'\t' read -r bid pane_name; do
    [ -n "$bid" ] || continue
    printf '%s\t%s\t%s\n' "$pane_name" "$(side_state "$bid")" "$bid"
  done <<<"$panes"
}

cmd_close() {
  local target=${1:-} panes bid pane_name found=0 failed=0
  [ "$#" -eq 1 ] || usage
  name_ok "$target" || usage
  side_identity
  panes=$(side_panes) || exit 1
  while IFS=$'\t' read -r bid pane_name; do
    [ -n "$bid" ] || continue
    [ "$pane_name" = "$target" ] || continue
    found=1
    if side_close_block "$bid"; then
      printf 'closed\t%s\t%s\n' "$pane_name" "$bid"
    else
      echo "fm-rex-side: side pane '$pane_name' ($bid) is still present after close" >&2
      failed=1
    fi
  done <<<"$panes"
  [ "$found" -eq 1 ] || die "no side pane named '$target' in this tab"
  [ "$failed" -eq 0 ]
}

case "${1:-}" in
  open) shift; cmd_open "$@" ;;
  list) shift; cmd_list "$@" ;;
  close) shift; cmd_close "$@" ;;
  -h | --help | help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" ;;
  *) usage ;;
esac
