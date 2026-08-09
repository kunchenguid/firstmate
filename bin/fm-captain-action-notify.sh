#!/usr/bin/env bash
# Notify once when the fleet snapshot gains a captain-actionable decision or a
# review/merge-ready PR. The state file is only the immediately prior snapshot's
# identity set: an absent file establishes a silent baseline, and every later
# successful snapshot replaces it atomically before best-effort notification.
#
# This deliberately reuses fm-supervise-daemon.sh's wedge-alarm delivery owner,
# including its bounded notifier, argv-safe AppleScript, channel grammar, and
# FM_WEDGE_ALARM_EXEC recorder seam. It uses a sibling config because silencing
# rare away-mode wedge alarms must not also silence ordinary captain prompts.
#
# Usage: fm-captain-action-notify.sh
# Environment: FM_FLEET_SNAPSHOT_BIN test seam; FM_CAPTAIN_ACTION_NOTIFICATION_
# CHANNEL and _EXEC respectively override this notifier's sibling-config channel
# and wedge-alarm execution seam. Errors are logged best-effort and return zero.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SNAPSHOT_BIN="${FM_FLEET_SNAPSHOT_BIN:-$SCRIPT_DIR/fm-fleet-snapshot.sh}"
SET_FILE="$STATE/.captain-action-notification-set"
LOG="$STATE/.watch-triage.log"

mkdir -p "$STATE" 2>/dev/null || exit 0

# The daemon returns before its main loop when sourced. Its library-mode guard
# deliberately sets the wedge seam to discard, which this executable replaces
# below with its own explicit production/test choice.
# shellcheck source=bin/fm-supervise-daemon.sh
. "$SCRIPT_DIR/fm-supervise-daemon.sh"
# shellcheck source=bin/fm-push-transition-lib.sh
. "$SCRIPT_DIR/fm-push-transition-lib.sh"

captain_action_log() {
  triage_log "captain action notification: $*"
}

write_set() {  # <keys-file>
  local keys=$1 tmp
  tmp=$(umask 077; mktemp "$STATE/.captain-action-notification-set.XXXXXX") || return 1
  if ! cat "$keys" > "$tmp" || ! mv -f "$tmp" "$SET_FILE"; then
    rm -f "$tmp"
    return 1
  fi
}

snapshot=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" "$SNAPSHOT_BIN" --json 2>/dev/null) || {
  captain_action_log "snapshot unavailable; notification check skipped"
  exit 0
}

if ! printf '%s' "$snapshot" | jq -e '
  .schema == "fm-fleet-snapshot.v1"
  and (.backlog.records | type == "array")
  and (.tasks | type == "array")
  and (.secondmate_current.records | type == "array")
  and all(.secondmate_current.records[]; (.decisions_open | type == "array"))
' >/dev/null 2>&1; then
  captain_action_log "snapshot was malformed; notification check skipped"
  exit 0
fi

items=$(printf '%s' "$snapshot" | jq -r '
  def clean:
    tostring | gsub("[\\t\\r\\n]+"; " ") | gsub("\\s+"; " ") | .[:120];
  def action($scope; $id; $title):
    {key:("decision/" + $scope + "/" + ($id | tostring)),
     label:("Decision: " + (($title // $id) | clean))};
  [
    (.backlog.records[]?
      | select(.captain_actionable == true)
      | action("main"; .id; .title)),
    (.secondmate_current.records[]? as $home
      | $home.decisions_open[]?
      | action(("secondmate/" + ($home.id | tostring)); (.key // .id); (.summary // .title // .id))),
    (.tasks[]?
      | select(.kind != "secondmate" and ((.pr.url // "") | type == "string") and (.pr.url != ""))
      | {key:("pr/main/" + (.id | tostring) + "/" + .pr.url),
         label:("PR: " + ((.backlog.title // .id) | clean))})
  ]
  | unique_by(.key) | sort_by(.key) | .[] | [.key, .label] | @tsv
' 2>/dev/null) || {
  captain_action_log "snapshot was malformed; notification check skipped"
  exit 0
}

keys=$(umask 077; mktemp "$STATE/.captain-action-notification-keys.XXXXXX") || exit 0
items_file=$(umask 077; mktemp "$STATE/.captain-action-notification-items.XXXXXX") || {
  rm -f "$keys"
  exit 0
}
trap 'rm -f "$keys" "$items_file"' EXIT
printf '%s\n' "$items" > "$items_file" || exit 0
awk -F '\t' 'NF == 2 && $1 ~ /^(decision|pr)\// { print $1 }' "$items_file" > "$keys" || exit 0

# The set was created only by this script. Anything else is a corruption signal:
# preserve it and skip rather than treating all live work as newly actionable.
if [ -e "$SET_FILE" ] && ! awk '
  /^(decision|pr)\// { next }
  { exit 1 }
' "$SET_FILE"; then
  captain_action_log "prior set was malformed; notification check skipped"
  exit 0
fi

if [ ! -e "$SET_FILE" ]; then
  write_set "$keys" || captain_action_log "could not establish initial notification baseline"
  exit 0
fi

new_items=$(awk -F '\t' '
  FILENAME == ARGV[1] { previous[$1] = 1; next }
  !previous[$1] { print }
' "$SET_FILE" "$items_file")

# Advance the immediate-prior snapshot even while notifications are disabled or
# a notifier fails. This prevents a later enable/recovery from replaying history.
if ! write_set "$keys"; then
  captain_action_log "could not record current action set; notification skipped"
  exit 0
fi

[ -n "$new_items" ] || exit 0

count=$(printf '%s\n' "$new_items" | awk 'NF { n += 1 } END { print n + 0 }')
labels=$(printf '%s\n' "$new_items" | awk -F '\t' 'NF == 2 { print $2 }' | head -3 | paste -sd ';' -)
case "$count" in
  1) summary="New captain action: $labels" ;;
  2|3) summary="$count new captain actions: $labels" ;;
  *) summary="$count new captain actions: $labels; +$((count - 3)) more" ;;
esac

# Keep notification policy separate from the wedge-only preference, but route
# every delivery call through the exact established wedge notifier machinery.
unset FM_WEDGE_ALARM_CHANNEL FM_WEDGE_ALARM_EXEC FM_WEDGE_ALARM_CONFIG FM_WEDGE_ALARM_TITLE
export FM_WEDGE_ALARM_CONFIG="$FM_HOME/config/captain-action-notifications"
export FM_WEDGE_ALARM_TITLE="firstmate: captain action needed"
if [ -n "${FM_CAPTAIN_ACTION_NOTIFICATION_CHANNEL:-}" ]; then
  export FM_WEDGE_ALARM_CHANNEL="$FM_CAPTAIN_ACTION_NOTIFICATION_CHANNEL"
fi
if [ -n "${FM_CAPTAIN_ACTION_NOTIFICATION_EXEC:-}" ]; then
  export FM_WEDGE_ALARM_EXEC="$FM_CAPTAIN_ACTION_NOTIFICATION_EXEC"
fi
wedge_alarm_notify "$summary" "$SET_FILE" || true
exit 0
