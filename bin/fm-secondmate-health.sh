#!/usr/bin/env bash
# fm-secondmate-health.sh - one parent-owned startable-goal health sweep.
# Usage: FM_HOME=<parent> fm-secondmate-health.sh [--help]
# The watcher runs this off its hot path every minute, with per-mate liveness
# locks shared with bootstrap/dead-endpoint recovery. No foreign home is read
# or changed. Each mate has an independent job so a persist wait blocks no
# sibling. Existing inbox supervision handles unread steers and unsent own
# doorbells; this sweep supplies the missing goal-idle trigger.
# FM_SECONDMATE_HEALTH_SECS defaults to 1800 per missed interval.
# Restart confirmation and its bounded wait belong to fm-secondmate-restart.sh.
# Local backends delegate proof to existing busy/composer/control adapters;
# remote mates retain their pending-reply/liveness paths, not guessed idleness.
set -u
case "${1:-}" in
  --help|-h) sed -n '2,12s/^# \{0,1\}//p' "$0"; exit 0 ;;
  '') ;;
  *) echo 'usage: FM_HOME=<parent> fm-secondmate-health.sh [--help]' >&2; exit 2 ;;
esac
FM_SM_HEALTH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] || { echo 'error: FM_HOME must name the parent home' >&2; exit 1; }
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 1
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$FM_SM_HEALTH_DIR/fm-secondmate-liveness-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$FM_SM_HEALTH_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$FM_SM_HEALTH_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-secondmate-health-lib.sh
. "$FM_SM_HEALTH_DIR/fm-secondmate-health-lib.sh"
# Fail closed on an unreadable goal projection; do not reset existing episodes.
rows=$(FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$FM_SM_HEALTH_DIR/fm-goal.sh" startable) || exit 1
now=$(date +%s)
pids=()
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  [ "$(fm_meta_get "$meta" kind)" = secondmate ] || continue
  id=${meta##*/}; id=${id%.meta}
  case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
  (
    fm_secondmate_liveness_lock "$id" || exit 0
    trap 'fm_secondmate_liveness_unlock "$id"' EXIT
    fm_secondmate_health_observe "$id" "$rows" "$now"
  ) &
  pids+=("$!")
done
rc=0
for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid" || rc=1; done
exit "$rc"
