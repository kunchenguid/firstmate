#!/usr/bin/env bash
# bin/fm-herdr-orphan-reaper.sh - find and optionally close orphaned Herdr panes.
#
# An orphaned Herdr pane is one that:
#   1. Lives in THIS HOME's own workspace (identified by label).
#   2. Has a tab label matching the fm-<id> convention (evidence it was once
#      a firstmate-spawned crewmate pane).
#   3. Is NOT claimed by any state/<id>.meta in this home.
#   4. Does NOT have a live agent (working or blocked).
#
# The fm-<id> tab label requirement is the critical safety boundary that
# separates "a crewmate's pane whose agent exited" from "the captain's own
# shell".  Firstmate always labels its task tabs fm-<id> at spawn time
# (fm_backend_herdr_list_live documents this convention), and the captain's
# own terminals never carry that label.  A pane without an fm- label is
# therefore never an orphan candidate, regardless of its agent status.
#
# Safety refusals (each returns a skip with a reason):
#   - Pane is claimed by a state/<id>.meta in this home.
#   - Pane has a live agent (agent_status is working or blocked).
#   - Pane is outside this home's workspace.
#   - Pane's tab label does not match fm-<id>.
#   - Backend is not herdr.
#
# Usage:
#   bin/fm-herdr-orphan-reaper.sh [--report|--close]
#
#   --report  (default) List orphaned panes without closing them.
#   --close   Close orphaned panes after listing them.
#
# Environment:
#   FM_HOME       The firstmate home directory (defaults to repo root).
#   FM_ROOT       The firstmate repo root (defaults to this script's parent).
#
# Exit codes:
#   0  Success (report printed or panes closed).
#   1  Error (backend not herdr, tools missing, workspace not found).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

MODE=report
case "${1:-}" in
  --close) MODE=close ;;
  --report|'') MODE=report ;;
  *)
    echo "usage: fm-herdr-orphan-reaper.sh [--report|--close]" >&2
    exit 1
    ;;
esac

# Gate: only herdr backend.
BACKEND=$(fm_backend_name 2>/dev/null) || BACKEND=
if [ "$BACKEND" != herdr ]; then
  exit 0
fi

# Source the herdr adapter.
fm_backend_source herdr || {
  echo "HERDR_ORPHAN_REAPER: error sourcing herdr adapter" >&2
  exit 1
}

fm_backend_herdr_tool_check || {
  echo "HERDR_ORPHAN_REAPER: herdr or jq not available" >&2
  exit 1
}

SESSION=$(fm_backend_herdr_session)

# Find this home's workspace by label.
HOME_WORKSPACE_ID=$(fm_backend_herdr_workspace_find "$SESSION") || HOME_WORKSPACE_ID=
if [ -z "$HOME_WORKSPACE_ID" ]; then
  exit 0
fi

HOME_WORKSPACE_LABEL=$(fm_backend_herdr_workspace_label)

# Collect the set of pane IDs claimed by this home's meta files.
# Each meta file may contain herdr_pane_id=<pane_id>.
claimed_panes=""
if [ -d "$STATE" ]; then
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    pane_id=$(grep '^herdr_pane_id=' "$meta" 2>/dev/null | cut -d= -f2-)
    if [ -n "$pane_id" ]; then
      claimed_panes="${claimed_panes}${pane_id}"$'\n'
    fi
  done
fi

is_claimed() {
  local pane_id=$1
  case "$claimed_panes" in
    *"$pane_id"$'\n'*) return 0 ;;
  esac
  return 1
}

fm_herdr_orphan_process_age() {
  local pid=$1 lstart now start_time
  lstart=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}')
  [ -n "$lstart" ] || return 1
  now=$(date "+%s")
  if date --version >/dev/null 2>&1; then
    start_time=$(date -d "$lstart" "+%s" 2>/dev/null) || return 1
  else
    start_time=$(date -j -f "%a %b %d %T %Y" "$lstart" "+%s" 2>/dev/null) || return 1
  fi
  echo "$((now - start_time))"
}

OUR_OWN_LABEL=""
if [ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ]; then
  my_id=$(cat "$FM_HOME/.fm-secondmate-home" 2>/dev/null || true)
  if [ -n "$my_id" ]; then
    OUR_OWN_LABEL="fm-$my_id"
  fi
fi

# List all tabs in this home's workspace that have fm-<id> labels.
TABS_JSON=$(fm_backend_herdr_cli "$SESSION" tab list --workspace "$HOME_WORKSPACE_ID" 2>/dev/null) || {
  echo "HERDR_ORPHAN_REAPER: could not list tabs in workspace $HOME_WORKSPACE_ID"
  exit 0
}

# Extract tab_id and label for fm-* tabs.
orphan_count=0
closed_count=0
refused_count=0

while IFS=$'\t' read -r tab_id label; do
  [ -n "$tab_id" ] || continue
  [ -n "$label" ] || continue

  # Get the pane for this tab.
  pane_id=$(fm_backend_herdr_pane_for_tab "$SESSION" "$HOME_WORKSPACE_ID" "$tab_id") || continue
  [ -n "$pane_id" ] || continue

  # Safety check 1: is this pane claimed by a meta file?
  if is_claimed "$pane_id"; then
    echo "HERDR_ORPHAN_REAPER: SKIP $pane_id (tab $label) - claimed by meta"
    refused_count=$((refused_count + 1))
    continue
  fi

  # Safety check 1.5: is this pane THIS home's own supervisor pane?
  if [ -n "$OUR_OWN_LABEL" ] && [ "$label" = "$OUR_OWN_LABEL" ]; then
    echo "HERDR_ORPHAN_REAPER: SKIP $pane_id (tab $label) - this home's own supervisor pane"
    refused_count=$((refused_count + 1))
    continue
  fi

  # Safety check 2: does this pane have a live agent?
  agent_status=$(fm_backend_herdr_agent_status_raw "$SESSION" "$pane_id")
  case "$agent_status" in
    working|blocked)
      echo "HERDR_ORPHAN_REAPER: SKIP $pane_id (tab $label) - live agent (status: $agent_status)"
      refused_count=$((refused_count + 1))
      continue
      ;;
  esac

  # Safety check 3: is this pane too young?
  # The live-agent guard loses a startup race: between a pane being created and its agent
  # registering, the pane looks abandoned. We add a 15-second age floor to provide generous
  # headroom over the typical 1-3 seconds pane creation and startup actually costs.
  # We fail closed: if we cannot determine the process age, we refuse to close the pane.
  info=$(fm_backend_herdr_cli "$SESSION" pane process-info --pane "$pane_id" 2>/dev/null || true)
  shell_pid=$(printf '%s' "$info" | jq -er \
    '.result.process_info.shell_pid | select(type == "number" and . > 1) | floor' 2>/dev/null || true)
  age_sec=
  if [ -n "$shell_pid" ]; then
    age_sec=$(fm_herdr_orphan_process_age "$shell_pid") || age_sec=
  fi
  if [ -z "$age_sec" ] || [ "$age_sec" -lt 15 ]; then
    echo "HERDR_ORPHAN_REAPER: SKIP $pane_id (tab $label) - pane is too young (${age_sec:-unknown}s < 15s)"
    refused_count=$((refused_count + 1))
    continue
  fi

  # This pane is an orphan: fm-<id> label, unclaimed, no live agent.
  orphan_count=$((orphan_count + 1))
  echo "HERDR_ORPHAN_REAPER: ORPHAN $pane_id (tab $label, workspace $HOME_WORKSPACE_ID, agent_status: ${agent_status:-none})"

  if [ "$MODE" = close ]; then
    if fm_backend_herdr_kill "$SESSION:$pane_id" 2>/dev/null; then
      echo "HERDR_ORPHAN_REAPER: CLOSED $pane_id (tab $label)"
      closed_count=$((closed_count + 1))
    else
      echo "HERDR_ORPHAN_REAPER: FAILED to close $pane_id (tab $label)"
    fi
  fi
done < <(printf '%s' "$TABS_JSON" | jq -r '.result.tabs[]? | select(.label | startswith("fm-")) | "\(.tab_id)\t\(.label)"' 2>/dev/null)

if [ "$orphan_count" -gt 0 ]; then
  if [ "$MODE" = report ]; then
    echo "HERDR_ORPHAN_REAPER: found $orphan_count orphaned pane(s) in workspace $HOME_WORKSPACE_LABEL ($HOME_WORKSPACE_ID) (report mode, use --close to remove)"
  else
    echo "HERDR_ORPHAN_REAPER: closed $closed_count of $orphan_count orphaned pane(s) in workspace $HOME_WORKSPACE_LABEL ($HOME_WORKSPACE_ID)"
  fi
fi

exit 0
