#!/usr/bin/env bash
# fm-intake-status.sh - compact tmux status text for the intake snapshot.
#
# Example overlay hook:
#   set -g status-right "#(FIRSTMATE_HOME=/path/to/firstmate /path/to/firstmate/bin/fm-intake-status.sh) | ..."
#
# Read-only. It never polls Linear/GitHub/Slack; it only reads the already
# written state/intake/snapshot.json and degrades to "intake:no-data".
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SNAPSHOT="${FM_INTAKE_SNAPSHOT:-$STATE/intake/snapshot.json}"
NOW_EPOCH="${FM_INTAKE_TUI_NOW_EPOCH:-$(date +%s 2>/dev/null || printf '0')}"

case "$NOW_EPOCH" in
  ''|*[!0-9]*) NOW_EPOCH=0 ;;
esac

if ! command -v jq >/dev/null 2>&1 || [ ! -s "$SNAPSHOT" ]; then
  printf 'intake:no-data\n'
  exit 0
fi

jq -er --argjson now "$NOW_EPOCH" '
  def epoch($v): if $v == null then null else try ($v | fromdateiso8601) catch null end;
  (.items // []) as $items
  | ($items | map(select(.lane == "oncall")) | length) as $oncall
  | ($items | map(select((epoch(.sla_breach_at) as $b | $b != null and $now >= $b))) | length) as $breach
  | "intake: \($oncall) oncall / \($breach) breach"
' "$SNAPSHOT" 2>/dev/null || printf 'intake:no-data\n'
