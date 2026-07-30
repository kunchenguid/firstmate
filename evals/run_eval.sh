#!/bin/bash
# Run any eval against any deliverable, headless.
# Usage: ./run_eval.sh <eval-name> <file-to-grade>
#   e.g. ./run_eval.sh tov draft_post.md
# The grader is Claude in -p (print) mode; the eval file IS the grading spec.

set -euo pipefail
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
EVAL_FILE="$EVAL_DIR/${1%.md}-eval.md"
[ -f "$EVAL_FILE" ] || EVAL_FILE="$EVAL_DIR/$1.md"
TARGET="$2"

[ -f "$EVAL_FILE" ] || { echo "no such eval: $1 (looked for $EVAL_FILE)"; exit 1; }
[ -f "$TARGET" ] || { echo "no such file: $TARGET"; exit 1; }

claude -p "You are an eval grader. Grade the DELIVERABLE strictly against the EVAL SPEC below. Follow the spec's output contract exactly. Be harsh; a borderline case fails.

=== EVAL SPEC ===
$(cat "$EVAL_FILE")

=== DELIVERABLE ===
$(cat "$TARGET")"
