#!/usr/bin/env bash
# fm-backlog-next.sh - deterministically pick the next SAFE, dependency-free
# backlog item to auto-dispatch, so queue advance never depends on agent memory.
#
# When a ship/scout reaches a terminal outcome or a no-decision external wait
# (CI running, review pending, awaiting merge authority), firstmate advances the
# queue autonomously instead of idling for a captain message. This script is the
# single owner of "which item is next": it scans `data/backlog.md`'s Queued
# section in order and prints the id of the first item that is:
#   - unchecked (`- [ ]`, i.e. not already done/in-flight),
#   - not held - no `(hold:` or `(hold-kind:` marker, so a parked item and any
#     captain- or decision-gated thread is never auto-dispatched, and
#   - dependency-free - it has no `blocked-by: <id>` link, or every such blocker
#     is already in the Done section.
#
# It prints exactly one id and exits 0 when a safe item exists, or prints nothing
# and exits 1 when none does. It never dispatches: the caller still applies the
# coarse-overlap and delivery-path checks in AGENTS.md sections 7 and 4 before
# spawning, and decisions, merges, and destructive/security actions still stop
# and escalate rather than ride this path.
#
# Usage:
#   fm-backlog-next.sh [<backlog-file>]   default: $FM_HOME/data/backlog.md
#
# FM_DATA_OVERRIDE overrides the data dir; an explicit file argument wins.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

case "${1:-}" in
  -h|--help)
    awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0" >&2
    exit 0 ;;
esac

BACKLOG=${1:-$DATA/backlog.md}
[ -f "$BACKLOG" ] || { exit 1; }

# item_id <line> -> the task id after the "- [ ] " / "- [x] " checkbox.
item_id() {
  local rest=${1#*] }
  printf '%s' "${rest%% *}"
}

# Pass 1: collect Done ids (a blocker in Done counts as cleared).
done_ids=""
section=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "## Done"*) section="done"; continue ;;
    "## "*) section="other"; continue ;;
  esac
  [ "$section" = "done" ] || continue
  case "$line" in
    "- ["*"] "*) done_ids="$done_ids $(item_id "$line")" ;;
  esac
done < "$BACKLOG"

is_done() {  # <id>
  case " $done_ids " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Pass 2: first safe, dependency-free Queued item wins.
section=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "## Queued"*) section="queued"; continue ;;
    "## "*) section="other"; continue ;;
  esac
  [ "$section" = "queued" ] || continue
  # Only unchecked items are dispatchable.
  case "$line" in
    "- [ ] "*) : ;;
    *) continue ;;
  esac
  # Held / parked / captain- or decision-gated: never auto-dispatched.
  case "$line" in
    *"(hold:"*|*"(hold-kind:"*) continue ;;
  esac
  # Dependency check: every blocked-by link must already be Done.
  if case "$line" in *"blocked-by:"*) true ;; *) false ;; esac; then
    blocker_rest=${line#*blocked-by: }
    blocker=${blocker_rest%% *}
    is_done "$blocker" || continue
  fi
  printf '%s\n' "$(item_id "$line")"
  exit 0
done < "$BACKLOG"

exit 1
