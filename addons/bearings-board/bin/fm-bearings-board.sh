#!/usr/bin/env bash
# fm-bearings-board.sh - runs the Bearings board from the Firstmate checkout, unchanged.
#
# Commands:
#   build <data.json> [args...]   run the checkout's build with every argument
#   path [args...]                run the checkout's path with every argument
#
# FM_CODE_ROOT names the Firstmate checkout (defaults to FM_HOME). Nothing is copied
# from the checkout: its own bin/fm-bearings-board.sh does the work and receives every
# argument. The exec sets FM_BEARINGS_BOARD_WRAPPER so a checkout wired back to this
# wrapper fails instead of recursing. install.sh wires this wrapper into a home;
# uninstall.sh removes it.
set -eu

fail() { printf 'fm-bearings-board: %s\n' "$*" >&2; exit 1; }

usage() {
  printf 'usage: fm-bearings-board.sh build <data.json> [args...] | path\n' >&2
  exit 2
}

checkout_board() {
  local root="${FM_CODE_ROOT:-${FM_HOME:-}}"
  [ -z "${FM_BEARINGS_BOARD_WRAPPER:-}" ] || fail "the checkout's bin/fm-bearings-board.sh is this wrapper: refusing to recurse"
  [ -n "$root" ] || fail "set FM_CODE_ROOT to the Firstmate checkout"
  [ -x "$root/bin/fm-bearings-board.sh" ] || fail "no bin/fm-bearings-board.sh under $root"
  printf '%s/bin/fm-bearings-board.sh\n' "$root"
}

build() {
  local upstream
  [ "$#" -ge 1 ] || usage
  upstream=$(checkout_board)
  exec env FM_BEARINGS_BOARD_WRAPPER=1 "$upstream" build "$@"
}

case "${1-}" in
  build) shift; build "$@" ;;
  path) shift; upstream=$(checkout_board); exec env FM_BEARINGS_BOARD_WRAPPER=1 "$upstream" path "$@" ;;
  *) usage ;;
esac
