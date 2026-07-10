#!/usr/bin/env bash
# fm-context.sh [<id> ...]
#
# Read-only monitor of crewmate context size. Prints one line per task:
#   <id>  <tokens>/<window>  <pct>%  [FLAG >=<threshold>%]
# and exits non-zero if ANY listed task is at or over the handoff threshold, so a
# caller can branch on `if ! fm-context.sh; then ...` to trigger context-handoff.
#
# Source of truth is state/<id>.context, written every turn by the claude Stop
# hook (fm-ctx-hook.sh) - harness-truth, not a model self-report. A task with no
# .context file (non-claude harness, or no turn completed yet) prints "no-data"
# and is not flagged.
#
# With no args, scans every task that has a state/<id>.context file.
#
# Env:
#   FM_CTX_THRESHOLD   handoff threshold percent (default 60)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

THRESHOLD=${FM_CTX_THRESHOLD:-60}
case "$THRESHOLD" in ''|*[!0-9]*) THRESHOLD=60 ;; esac

# Context window implied by the crewmate's model. Opus/Sonnet (and the "default"
# placeholder meta writes when no --model was given) are 1M; the small-context
# models (haiku) are 200k. Keep this list in step with the harness model catalog.
window_for_model() {
  case "$1" in
    *haiku*) echo 200000 ;;
    *)       echo 1000000 ;;
  esac
}

meta_field() {  # <meta-file> <key>
  grep "^$2=" "$1" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

ids=("$@")
if [ "${#ids[@]}" -eq 0 ]; then
  for c in "$STATE"/*.context; do
    [ -e "$c" ] || continue
    b=${c##*/}
    ids+=("${b%.context}")
  done
fi

[ "${#ids[@]}" -gt 0 ] || { echo "no tasks with context data"; exit 0; }

over=0
for id in "${ids[@]}"; do
  ctx="$STATE/$id.context"
  meta="$STATE/$id.meta"
  if [ ! -f "$ctx" ]; then
    printf '%s\tno-data\n' "$id"
    continue
  fi
  tokens=$(cat "$ctx" 2>/dev/null || echo 0)
  case "$tokens" in ''|*[!0-9]*) tokens=0 ;; esac
  model=$(meta_field "$meta" model)
  [ -n "$model" ] || model=default
  window=$(window_for_model "$model")
  pct=$(( tokens * 100 / window ))
  flag=""
  if [ "$pct" -ge "$THRESHOLD" ]; then flag="  FLAG >=${THRESHOLD}%"; over=1; fi
  printf '%s\t%s/%s\t%s%%%s\n' "$id" "$tokens" "$window" "$pct" "$flag"
done

[ "$over" -eq 0 ]
