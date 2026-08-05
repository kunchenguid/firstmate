#!/usr/bin/env bash
# fm-dashboard-snapshot.sh - read-only dashboard projection.
#
# Output contract: `--json` prints one object with schema
# `fm-dashboard-snapshot.v1`.
# The command reads the existing Bearings projection and supervision health.
# It never acquires the session lock, drains `.wake-queue`, or changes fleet
# state.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}
INCLUDE_PRS=${FM_DASHBOARD_INCLUDE_PRS:-1}
NOW=${FM_DASHBOARD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

usage() {
  cat <<'EOF'
usage: fm-dashboard-snapshot.sh --json

Print the read-only structured snapshot used by the local dashboard.
Live PR and CI enrichment is enabled by default and can be disabled for a
local-only read with FM_DASHBOARD_INCLUDE_PRS=0.
The watcher health uses FM_GUARD_GRACE, defaulting to 300 seconds.
EOF
}

case "${1:---json}" in
  --json) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-dashboard-snapshot: jq not found" >&2; exit 1; }

# shellcheck source=bin/fm-supervision-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

case "$INCLUDE_PRS" in
  0|1) ;;
  *) echo "fm-dashboard-snapshot: FM_DASHBOARD_INCLUDE_PRS must be 0 or 1" >&2; exit 2 ;;
esac

fleet_args=(--json --fields paths,endpoints --all-in-flight --all-decisions --all-landed --all-unhealthy --all-recorded-prs)
[ "$INCLUDE_PRS" -eq 1 ] && fleet_args+=(--include-prs --all-pr-repos)

fleet=$(FM_HOME="$FM_HOME" \
  FM_ROOT_OVERRIDE="$FM_ROOT" \
  FM_STATE_OVERRIDE="$STATE" \
  FM_BEARINGS_NOW="$NOW" \
  "$SCRIPT_DIR/fm-bearings-snapshot.sh" "${fleet_args[@]}" 2>/dev/null) \
  || { echo "fm-dashboard-snapshot: Bearings projection failed" >&2; exit 1; }
printf '%s' "$fleet" | jq -e '.schema == "fm-bearings.v1"' >/dev/null \
  || { echo "fm-dashboard-snapshot: Bearings projection was malformed" >&2; exit 1; }

fm_supervision_status "$STATE" "$GRACE"
watcher_active=false
if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
  watcher_active=true
fi

lock_present=false
heartbeat_present=false
heartbeat_age=null
if [ -d "$STATE/.watch.lock" ]; then lock_present=true; fi
if [ -e "$STATE/.last-watcher-beat" ]; then
  heartbeat_present=true
  heartbeat_age=$(fm_path_age "$STATE/.last-watcher-beat")
  case "$heartbeat_age" in ''|*[!0-9]*) heartbeat_age=null ;; esac
fi

supervision_state=not_needed
if [ "$FM_SUP_NEEDED" = true ]; then
  if [ "$watcher_active" = true ]; then
    supervision_state=healthy
  elif [ "$lock_present" = true ]; then
    supervision_state=stale-watcher
  else
    supervision_state=no-watcher-active
  fi
fi

jq -n \
  --arg schema "fm-dashboard-snapshot.v1" \
  --arg generated "$NOW" \
  --arg home "$FM_HOME" \
  --arg state "$supervision_state" \
  --arg beacon "$FM_SUP_BEACON_DESC" \
  --argjson fleet "$fleet" \
  --argjson needed "$FM_SUP_NEEDED" \
  --argjson watcher_active "$watcher_active" \
  --argjson lock_present "$lock_present" \
  --argjson heartbeat_present "$heartbeat_present" \
  --argjson heartbeat_age "$heartbeat_age" \
  --argjson in_flight "$FM_SUP_IN_FLIGHT" \
  --argjson sources "$FM_SUP_SOURCES" \
  --argjson queue_pending "$FM_SUP_QUEUE_PENDING" \
  '{schema:$schema,generated:$generated,home:$home,fleet:$fleet,
    supervision:{state:$state,needed:$needed,watcher_active:$watcher_active,
      lock_present:$lock_present,heartbeat_present:$heartbeat_present,
      heartbeat_age_seconds:$heartbeat_age,beacon:$beacon,
      in_flight:$in_flight,process_event_sources:$sources,
      wake_queue_pending:$queue_pending}}'
