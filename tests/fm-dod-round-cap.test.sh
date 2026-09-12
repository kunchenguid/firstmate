#!/usr/bin/env bash
# The no-mistakes Definition of done must carry the settled round cap: a soft
# cap at 3 for ordinary findings, no cap at all for warning/error/ask-user.
set -u
FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

BLOCK=$(fm_dod_block no-mistakes demo-task)

want() {  # <needle> <label>
  case "$BLOCK" in
    *"$1"*) echo "ok - $2" ;;
    *) echo "FAIL - $2 (missing: $1)"; FAIL=1 ;;
  esac
}

reject() {  # <needle> <label>
  case "$BLOCK" in
    *"$1"*) echo "FAIL - $2 (still present: $1)"; FAIL=1 ;;
    *) echo "ok - $2" ;;
  esac
}

reject "after the second review round" "the old two-round convergence line is gone"
want "after round 3" "the cap is stated at round 3"
want "never deferred" "the severity escape is stated"
want "warning" "warning severity is named"
want "error" "error severity is named"
want "ask-user" "ask-user is named"
want "Deferred pipeline findings" "the deferral destination is named"
want "run id" "each deferred entry carries its run id"
want "file:line" "each deferred entry carries file:line"
want "verbatim" "the finding text is pasted verbatim, not summarized"
want "Severity alone decides" "severity, not category, governs the round-3 cap"
want "regardless of category" "warning/error/ask-user is fixed regardless of category"
want "only \`info\`-severity findings" "only info severity defers, no other severity"
want "still fixed, never deferred" "a style/naming finding at warning or error severity is not deferred"

exit "$FAIL"
