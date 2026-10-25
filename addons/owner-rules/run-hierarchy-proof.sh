#!/usr/bin/env bash
# Drive the hierarchy rule through the fork's real fm-brief.sh and record the done-done journey.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
fork=${FM_TEST_FORK:-}
[ -n "$fork" ] && [ -x "$fork/bin/fm-brief.sh" ] \
  || { echo "owner-rules hierarchy proof: set FM_TEST_FORK to a Firstmate checkout with the brief-inherit seam" >&2; exit 1; }
[ -n "${DONE_DONE_EVIDENCE_ROOT:-}" ] && [ -n "${DONE_DONE_RUN_ID:-}" ] \
  || { echo "owner-rules hierarchy proof: run through done-done" >&2; exit 1; }
target=$(git -C "$repo" rev-parse --short HEAD)
jq -n --arg version "$target" \
  '{target:{version:$version},start:"A disposable home has the owner-rules add-on installed and a fixture backlog.",steps:["Brief an owner-linked lane without a parent and confirm it is refused before a brief is written.","Brief items with an existing parent and with parent: upkeep, then inspect their generated briefs.","Run the read-only tree helper and inspect its epic chain, missing-id and cycle reports."],result:"The lane brief enforces backlog hierarchy and the tree helper shows valid and invalid parent chains."}' \
  > "$DONE_DONE_EVIDENCE_ROOT/steps.json"
log="$DONE_DONE_EVIDENCE_ROOT/${DONE_DONE_RUN_ID}.log"
bash "$repo/owner-rules/tests/owner-rules.test.sh" "$fork" > "$log" 2>&1
cat "$log"
