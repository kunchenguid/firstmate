#!/usr/bin/env bash
# Sourced by the sign-off adapter and merge-card: tell the owner how far an
# answer they sent on a sign-off card got, with `sign-off-axi feedback` (sign-off
# 0.6.1+). A plain argv call against the board.json the card lives on.
#
# fm_signoff_feedback <card-key> <board.json> <flags...>
#   0: marked, or sign-off answered NOT_FOUND (nothing was sent on that card yet).
#   3: this sign-off-axi has no feedback command (older than 0.6.1).
#   1: any other failure, with sign-off's own output on one stderr line.

fm_signoff_feedback() {
  local out rc=0
  out=$(sign-off-axi feedback "$@" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || return 0
  case $out in *'Unknown command: feedback'*) return 3 ;; esac
  if [ "$rc" -eq 1 ] && [[ $out == *NOT_FOUND* ]]; then return 0; fi
  printf 'sign-off-axi feedback %s failed (exit %s): %s\n' "$1" "$rc" "${out//$'\n'/ }" >&2
  return 1
}
