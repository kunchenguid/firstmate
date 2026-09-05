#!/usr/bin/env bash
# fm-ticket-board-consume.sh - turn a captured ticket-board poll result into
# durable ticket records, then rebuild and rearm the board.
#
# Usage:
#   fm-ticket-board-consume.sh <result-file> [<store.json>]
#
# <result-file> is the durable captured result named by a
# `procevent lavish <source-id> <sequence>` wake for the ticket board's
# source (state/procevent-inbox/<source-id>.<sequence>.result; see the
# process-event-sources skill). This is the receiving side of ticket
# creation: the captain types a plain-language ticket description into the
# board's own Lavish conversation panel and sends it, and Lavish captures
# that as an ordinary freeform message (tag=message) inside the result's
# `prompts[N]` block - there is no custom form on the board page itself. This
# script reads every such row's full sent text, turns each into one ticket
# record (a slug id, a title taken from the first line, and the full text as
# the body), appends it to the durable store (default: the path
# `bin/fm-ticket-board.sh store` prints) in the "backlog" status, then
# rebuilds and rearms the board through `bin/fm-ticket-board.sh build` so the
# new ticket is visible immediately.
#
# A row not tagged `message` is ignored only when it sits beside at least one
# message row: this board carries no decision forms, so a `choice` row (if one
# ever appeared) is not ticket-board input on its own. A result whose queued
# content is entirely non-message rows is a distinct case, covered below, and
# fails loudly rather than silently vanishing.
# A result that provably carries no queued content at all prints `captured: 0`
# and exits 0 without touching the store or rebuilding - firstmate need not
# treat "captain closed the board without typing anything" as an error. A
# result that DOES carry queued content but yields zero parsed ticket rows -
# a feedback-framed result, or a parse the reader could not complete - is a
# distinct case and fails loudly instead, per bin/fm-procevent-lavish.sh's
# `has-content` (see that script's header for the full contract): a ticket
# the captain actually typed must never silently vanish as if he said nothing.
#
# The captured-result parsing itself is not implemented here: it delegates to
# bin/fm-procevent-lavish.sh's `messages` and `has-content` subcommands, which
# own the `prompts[N]{...}` wire format contract (see that script's header).
#
# DEDUPLICATED AGAINST REPLAY. A captured result stays eligible for bounded
# re-announcement until firstmate durably acknowledges it (see the
# process-event-sources skill), so this script can run more than once against
# the exact same result file - a crash between a prior run's success and that
# acknowledgement is exactly this. Each new ticket therefore records the
# resolved path of the result file it came from plus its row index as a
# `source` field, and a row whose `source` already exists in the store is
# skipped rather than appended again, so a replayed wake can never mint a
# second ticket for the same captain message.
#
# Fail-closed: a missing or unreadable result file, or an updated store that
# would not satisfy fm-ticket-board.v1 (checked via `bin/fm-ticket-board.sh
# validate`), refuses before the existing durable store is touched - new
# tickets are appended to a private staged copy first, which is validated and
# only then published. The staged store is published BEFORE the board is
# rebuilt from it, not after: a rebuild failure after publish leaves the
# board stale but the ticket durably recorded, which is the safer failure
# mode than the reverse - the store is the durable record, the board is a
# rebuildable view of it, and the captain must never be told a ticket exists
# only for the record of it to have been silently dropped.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  printf 'fm-ticket-board-consume: %s\n' "$*" >&2
  exit 1
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

RESULT=${1-}
[ -n "$RESULT" ] || { usage >&2; exit 2; }
[ "$#" -le 2 ] || { usage >&2; exit 2; }
[ -f "$RESULT" ] && [ ! -L "$RESULT" ] || fail "result file does not exist: $RESULT"
command -v jq >/dev/null 2>&1 || fail "jq is required"

STORE=${2:-$("$SCRIPT_DIR/fm-ticket-board.sh" store)}

new_id() {
  # tkt-<UTC compact timestamp>-<4 hex>: unique enough for a captain-paced
  # single-operator feed; a collision is refused rather than silently merged.
  printf 'tkt-%s-%04x\n' "$(date -u +%Y%m%dT%H%M%S)" "$(((RANDOM << 1 | RANDOM & 1) % 65536))"
}

CAPTURED=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-ticket-consume.XXXXXX") || fail "cannot stage captured messages"
trap 'rm -f -- "$CAPTURED"' EXIT
messages_rc=0
"$SCRIPT_DIR/fm-procevent-lavish.sh" messages "$RESULT" > "$CAPTURED" || messages_rc=$?
[ "$messages_rc" -eq 0 ] || fail "could not read the captured result to look for ticket messages: $RESULT"
COUNT=$(wc -l < "$CAPTURED" | tr -d ' ')
printf 'captured: %s\n' "$COUNT"
if [ "$COUNT" -eq 0 ]; then
  content_rc=0
  "$SCRIPT_DIR/fm-procevent-lavish.sh" has-content "$RESULT" || content_rc=$?
  case "$content_rc" in
    1) exit 0 ;;
    0) fail "the result carries queued content but no ticket rows were captured from it - format drift or an unrecognized content block, not a silent captain" ;;
    *) fail "could not determine whether the result carries queued content - refusing to treat this as silence" ;;
  esac
fi

[ -f "$STORE" ] || "$SCRIPT_DIR/fm-ticket-board.sh" init "$STORE" >/dev/null
jq empty "$STORE" 2>/dev/null || fail "ticket store is not valid JSON: $STORE"

# Every row's dedupe key is anchored to the exact result file it was read
# from, not its text, so a captain legitimately typing the same words twice
# on two different occasions is never mistaken for a replay.
RESULT_REAL=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$RESULT") \
  || fail "cannot resolve the result file path: $RESULT"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STAGED=$(umask 077; mktemp "${STORE%/*}/.tickets.XXXXXX") || fail "cannot stage the store"
trap 'rm -f -- "$CAPTURED" "$STAGED" "$STAGED.next"' EXIT
cp -p "$STORE" "$STAGED" || fail "cannot stage the store"

ROW=0
SKIPPED=0
while IFS=$'\t' read -r title body; do
  source_key="$RESULT_REAL#$ROW"
  ROW=$((ROW + 1))
  if jq -e --arg source "$source_key" 'any(.tickets[]; .source == $source)' "$STAGED" >/dev/null; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  id=$(new_id)
  jq -e --arg id "$id" 'any(.tickets[]; .id == $id) | not' "$STAGED" >/dev/null \
    || fail "generated a colliding ticket id: $id"
  jq --arg id "$id" --arg title "$title" --arg created "$NOW" --arg body "$body" --arg source "$source_key" \
    '.tickets += [{id: $id, title: $title, status: "backlog", created: $created, body: $body, source: $source}]' \
    "$STAGED" > "$STAGED.next" || fail "cannot append ticket: $id"
  mv -f -- "$STAGED.next" "$STAGED"
  printf 'ticket: %s %s\n' "$id" "$title"
done < "$CAPTURED"
[ "$SKIPPED" -eq 0 ] || printf 'skipped: %s already-recorded row(s) (replayed result)\n' "$SKIPPED"

"$SCRIPT_DIR/fm-ticket-board.sh" validate "$STAGED" >/dev/null \
  || fail "the updated store does not satisfy fm-ticket-board.v1"
if ! { chmod 0600 "$STAGED" && mv -f -- "$STAGED" "$STORE"; }; then
  fail "cannot publish the updated store"
fi
"$SCRIPT_DIR/fm-ticket-board.sh" build "$STORE" \
  || fail "the store was published but the board rebuild failed - rerun: $SCRIPT_DIR/fm-ticket-board.sh build"
