#!/usr/bin/env bash
# Run one Droid tracked background supervision cycle, keeping quiet bounded
# checkpoints inside this foreground process until a wake or bounded failure.
# Each pass delegates watcher ownership, home scoping, and away/host behavior
# to fm-watch-checkpoint.sh, requesting quiet rotation for the attended watcher.
# No shell backgrounding is used here.
#
# Usage: fm-watch-droid-background.sh
# FM_DROID_WATCH_CHECKPOINT sets each checkpoint's seconds (default 180).
# FM_DROID_BG_CYCLE_MAX_FAILURES caps consecutive failed passes (default 3).
# Quiet checkpoints reset the failure count and produce no output. Failed
# passes print their output; after the cap the cycle exits with the last code.
# Actionable checkpoints print their output and exit 0 for Droid's native
# background-completion notification to re-invoke the primary agent.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CHECKPOINT_SECONDS=${FM_DROID_WATCH_CHECKPOINT:-180}
MAX_FAILURES=${FM_DROID_BG_CYCLE_MAX_FAILURES:-3}

usage() {
  cat <<'EOF'
Usage: fm-watch-droid-background.sh

Run bounded watcher checkpoints inside one Droid tracked background job.
Quiet checkpoints stay silent and repeat; a wake prints its output and exits 0.
Consecutive failures print their output and terminate at
FM_DROID_BG_CYCLE_MAX_FAILURES (default 3) with the last failure's exit code.
FM_DROID_WATCH_CHECKPOINT sets the checkpoint seconds (default 180).
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac
[ "$#" -eq 0 ] || {
  usage >&2
  exit 2
}
case "$MAX_FAILURES" in
  '' | 0* | *[!0-9]*)
    echo 'error: FM_DROID_BG_CYCLE_MAX_FAILURES must be a positive integer without leading zeros' >&2
    exit 2
    ;;
esac

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-watch-droid-background.out.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-watch-droid-background.err.XXXXXX") || {
  rm -f "$OUT"
  exit 1
}
trap 'rm -f "$OUT" "$ERR"' EXIT

FAILURES=0
while [ "$FAILURES" -lt "$MAX_FAILURES" ]; do
  RC=0
  FM_DROID_BACKGROUND_CYCLE=1 "$SCRIPT_DIR/fm-watch-checkpoint.sh" --seconds "$CHECKPOINT_SECONDS" >"$OUT" 2>"$ERR" || RC=$?
  if [ "$RC" -eq 124 ] && grep -q '^checkpoint:' "$OUT"; then
    FAILURES=0
    continue
  fi
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  [ "$RC" -ne 0 ] || exit 0
  FAILURES=$((FAILURES + 1))
done

printf 'droid-background: checkpoint failed %s consecutive times; exiting with code %s\n' "$FAILURES" "$RC" >&2
exit "$RC"
