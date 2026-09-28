#!/usr/bin/env bash
# fm-note.sh - file one notable item as a bead in the federated store.
#
# The recording rule this helper serves: every notable item is a bead. A
# feature built, a PR merged, a fix landed, an investigation finished - each
# gets a durable bead in the appropriate store at creation time, closed with
# a receipt when it lands, so bin/fm-inflight.sh can answer "what got built"
# from records instead of chat memory. Task scaffolding already opens a bead
# for the task itself; this helper covers the notable sub-items born inside
# the work, which is where the record previously went missing.
#
# Usage: fm-note.sh <store> "<title>" [--body <text>] [--label <label>...]
#
#   <store> is a federated store CLI: task, review, robots, projects,
#   workflows, inbox, brain, ideas, ... The store owns the item's meaning;
#   this helper only files it. Fleet-work beads carry the fleet label so the
#   in-flight view can scope the task store to firstmate's own work.
#   Prints the created bead id on stdout.
set -u

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-note: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac
[ "$#" -ge 2 ] || { usage >&2; exit 2; }
STORE=$1
TITLE=$2
shift 2

BODY=""
LABELS=${FM_BEADS_FLEET_LABEL:-fleet:firstmate}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --body) [ "$#" -ge 2 ] || fail "--body needs a value"; BODY=$2; shift 2 ;;
    --label) [ "$#" -ge 2 ] || fail "--label needs a value"; LABELS="$LABELS,$2"; shift 2 ;;
    -h|--help|help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

command -v "$STORE" >/dev/null 2>&1 || fail "store CLI not found: $STORE"
[ -n "$TITLE" ] || fail "title must not be empty"

if [ -n "$BODY" ]; then
  "$STORE" create "$TITLE" --description "$BODY" --labels "$LABELS"
else
  "$STORE" create "$TITLE" --labels "$LABELS"
fi
