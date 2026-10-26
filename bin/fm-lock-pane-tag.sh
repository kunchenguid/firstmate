#!/usr/bin/env bash
# Tag this session's own Herdr pane so the fleet-lock holder is visible at a glance.
#
# Usage:
#   fm-lock-pane-tag.sh holder     # this session holds the lock
#   fm-lock-pane-tag.sh readonly   # lock refused: read-only session
#   fm-lock-pane-tag.sh clear      # drop every tag this script set
#
# Tags are display-only, reported under --source fm-lock on $HERDR_PANE_ID in
# the herdr session named by $HERDR_SESSION (default "default"), through the
# same fm_backend_herdr_cli path as the rest of firstmate:
#   holder   token fm_lock='LOCK HOLDER',   display agent 'firstmate (lock)'
#   readonly token fm_readonly='READ-ONLY', display agent 'firstmate (read-only)'
# Each state clears the other state's token, so a later acquire or refusal in
# the same pane flips the tag instead of leaving a stale one. A pane that dies
# takes its tags with it.
# Herdr renders a token only where its sidebar config names it; the suggested
# rows are in docs/herdr-backend.md.
#
# Best effort by design: outside a herdr pane, without a herdr client, or on any
# Herdr failure this exits 0 silently, so tagging can never block session start.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_LOCK_PANE_TAG_SOURCE=${FM_LOCK_PANE_TAG_SOURCE:-fm-lock}

mode=${1:-}
case "$mode" in
  holder|readonly|clear) ;;
  *) echo "usage: fm-lock-pane-tag.sh holder|readonly|clear" >&2; exit 2 ;;
esac

[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v herdr >/dev/null 2>&1 || exit 0

# shellcheck source=bin/backends/herdr.sh
. "$SCRIPT_DIR/backends/herdr.sh" >/dev/null 2>&1 || exit 0
declare -F fm_backend_herdr_cli >/dev/null 2>&1 || exit 0

session=$(fm_backend_herdr_session)
args=(pane report-metadata "$HERDR_PANE_ID" --source "$FM_LOCK_PANE_TAG_SOURCE")
case "$mode" in
  holder)
    args+=(--token 'fm_lock=LOCK HOLDER' --clear-token fm_readonly --display-agent 'firstmate (lock)') ;;
  readonly)
    args+=(--token 'fm_readonly=READ-ONLY' --clear-token fm_lock --display-agent 'firstmate (read-only)') ;;
  clear)
    args+=(--clear-token fm_lock --clear-token fm_readonly --clear-display-agent) ;;
esac

fm_backend_herdr_cli "$session" "${args[@]}" >/dev/null 2>&1 || true
exit 0
