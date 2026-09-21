#!/usr/bin/env bash
# Codex Stop-hook adapter for the shared primary turn-end guard.
#
# The shared guard's exit 2 remains the cross-harness signal that supervision
# is missing. Codex would turn that status into a continuation prompt and hide
# the assistant's completed answer, so this adapter translates only that result
# into an exit-0 systemMessage warning. Other outcomes retain their status and
# output, and the shared predicate remains unchanged for blocking or bounded-
# follow-up harnesses.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-codex.XXXXXX") || exit 0
trap 'rm -f "$ERR"' EXIT

printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
if [ "$RC" -eq 2 ]; then
  jq -n --rawfile systemMessage "$ERR" '{systemMessage: $systemMessage}' 2>/dev/null || true
  exit 0
fi

cat "$ERR" >&2 2>/dev/null || true
exit "$RC"
