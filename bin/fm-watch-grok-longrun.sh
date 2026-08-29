#!/usr/bin/env bash
# Keep Grok's one tracked supervision task open across routine declared-wait
# rechecks. The task completes only for an actionable watcher result or a
# failure, so Grok does not inject billed task_completed prompts for quiet
# cycles.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARM="$SCRIPT_DIR/fm-watch-arm.sh"
STATE="${FM_STATE_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}/state}"
mkdir -p "$STATE"
out=

cleanup() {
  [ -n "$out" ] && rm -f "$out" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 143' TERM
trap 'exit 130' INT

routine_declared_wait() {
  local out=$1 count reason
  count=$(grep -Ec '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  reason=$(grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null | head -1 || true)
  case "$reason" in
    stale:*'declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)') return 0 ;;
    stale:*'verified hold transfer, rechecked on a long cadence not a wedge; answer the held decision or release the hold)') return 0 ;;
    *) return 1 ;;
  esac
}

while :; do
  out=$(mktemp "$STATE/.grok-watch-longrun.XXXXXX") || {
    echo "watcher: FAILED - Grok long-runner could not allocate cycle output"
    exit 1
  }
  status=0
  "$ARM" >"$out" 2>&1 || status=$?
  if [ "$status" -ne 0 ]; then
    cat "$out"
    rm -f "$out"
    out=
    exit "$status"
  fi
  if routine_declared_wait "$out"; then
    rm -f "$out"
    out=
    continue
  fi
  cat "$out"
  rm -f "$out"
  out=
  exit 0
done
