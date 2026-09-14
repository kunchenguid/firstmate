#!/usr/bin/env bash
# fm-agy-spend-gate.sh - the PostInvocation point-of-spend verdict for one agy worker.
#
# Usage: fm-agy-spend-gate.sh <state-dir> <id> <spend-gate> [<now>]
#
# Prints exactly one JSON object line: a terminate verdict when the worker's
# own rung is proven exhausted, {} on every other path including every
# failure. Always exits 0, because agy treats a hook's non-zero exit as hook
# failure rather than a semantic signal, and the failure direction here must
# be allow - the captain's no-stall ruling applied inside the worker's loop.
#
# WHY THIS EXISTS. The per-poll evaluation in bin/fm-agy-descent-lib.sh
# detects a crossed floor within about a minute but can only act on a
# provably idle worker, so a worker inside one long turn spends the reserve
# with nothing in its path. This runs synchronously in that worker's own
# execution loop, after every tool batch, and ends the turn the moment the
# floor is proven crossed. bin/fm-agy-descent-lib.sh owns the policy, the
# evidence rules, and what this does not cover; this file is the executable a
# hook can name.
#
# IT IS AN ADJUNCT, NOT A DAEMON. It decides once and exits. The fast path is
# file reads only; a stale reading pays for one bounded quota poll that runs
# no turn, so deciding costs latency and never quota.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${1:-}"
TASK_ID="${2:-}"
SPEND_GATE="${3:-}"
NOW="${4:-}"

# Every exit path prints one verdict line: the caller (a hook with a JSON
# contract) must never receive an empty answer, and a failure anywhere below
# fails open to allow rather than stranding a live worker on a broken gate.
verdict='{}'
if [ -n "$STATE_DIR" ] && [ -d "$STATE_DIR" ] && [ -n "$TASK_ID" ]; then
  # The same libraries bin/fm-watch.sh loads before the evaluation, in the
  # same order. Source analysis stops at each of them: every one is a
  # canonical lint root already, so following them from here adds no uncovered
  # line and only duplicates the largest source graphs this repo has inside
  # one more root.
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/fm-backend.sh"
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/fm-busy-lib.sh"
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/fm-agy-quota-lib.sh"
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/fm-agy-descent-lib.sh"
  verdict=$(fm_agy_spend_gate_verdict "$STATE_DIR" "$TASK_ID" "$SPEND_GATE" "$NOW" 2>/dev/null) || verdict='{}'
  [ -n "$verdict" ] || verdict='{}'
fi
printf '%s\n' "$verdict"
exit 0
