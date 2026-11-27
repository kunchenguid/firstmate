#!/usr/bin/env bash
# Usage: fm-goal-pace.sh [--help]
# Sample ON goals and print one PACE line each. FM_HOME, FM_STATE_OVERRIDE,
# FM_DATA_OVERRIDE and FM_CONFIG_OVERRIDE resolve as in fm-goal.sh. A local
# mate samples its own items in the parent's goals, writing only to its state.
# A remote parent has no local goal projection; no network fetch is attempted.
#
# state/goal-pace.json is the current fm-goal-pace.v1 snapshot; goal-pace.jsonl
# retains the last 2048 snapshots in emission order. In goals[], running_by_home
# maps owner ids to counts; startable_idle, merge_after_ready and behind_after
# carry item ids (the first two also record their observed idle start epoch).
# idle_minutes is the longest continuous observed actionable idle, zero if
# none. The first observation starts the clock; a drive switch resets it even
# if no OFF sample was taken. Waiting groups carry counts and oldest ages in
# seconds. Null host fields mean unknown, not zero. Capacity is for this home.
# merge_after_ready counts work ready to START, not permission to merge a PR.
# It consumes optional goal-export items[].merge_after (ids); typed waits use
# items[].wait_on.kind. Never infer either field from an item's title or note.
set -euo pipefail
export LC_ALL=C

case "${1-}:$#" in
  --help:1|-h:1) awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
  :0) ;;
  *) echo 'usage: fm-goal-pace.sh [--help]' >&2; exit 2 ;;
esac
command -v jq >/dev/null || { echo 'fm-goal-pace: jq is required' >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

current=$STATE/goal-pace.json history=$STATE/goal-pace.jsonl
[ -d "$STATE" ] || exit 0

# Serialize the observation as well as publication: an older ON sample must
# never overwrite a newer OFF sample just because its host probes finish late.
lock=$STATE/.goal-pace.lock
fm_lock_acquire_wait_bounded "$lock" 2 || { echo 'fm-goal-pace: could not lock snapshot' >&2; exit 1; }
staged_current='' staged_history=''
cleanup() {
  [ -z "$staged_current" ] || rm -f -- "$staged_current"
  [ -z "$staged_history" ] || rm -f -- "$staged_history"
  fm_lock_release "$lock"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

goals=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-goal.sh" export --driven | jq -ec '
  select(.schema == "fm-goal-export.v1") | .goals')
# No initial files (or host probes) for a home that has never had ON work.
if [ "$goals" = '[]' ] && [ ! -e "$current" ] && [ ! -L "$current" ] && [ ! -e "$history" ] && [ ! -L "$history" ]; then
  exit 0
fi

at=${FM_GOAL_PACE_NOW_EPOCH:-$(date +%s)}
case "$at" in ''|*[!0-9]*|0[0-9]*) echo 'fm-goal-pace: invalid clock' >&2; exit 1 ;; esac

capacity=null workers=null
if [ "$goals" != '[]' ]; then
  # These are optional observations and must not wedge a wake presentation.
  capacity=$(fm_run_timed 8 "$SCRIPT_DIR/fm-capacity.sh" --json 2>/dev/null | jq -ec '
    select(.schema == "fm-lane-capacity.v1")
    | {load1:.pressure.load1, cores:.pressure.cores, avail_gb:.pressure.avail_gb,
       free_lanes:.verdict.free_lanes, lane_target:.cap.target}') || capacity=null
  workers=$(FM_CREW_STATE_NO_FORGE=1 fm_run_timed 5 "$SCRIPT_DIR/fm-worker-table.sh" --json 2>/dev/null | jq -ec '
    select(.schema == "fm-worker-table.v1")
    | [.homes[] | select(.status == "local" or (.status == "cached" and (.cache_age_s // 601) <= 600))] as $fresh
    | {homes:[$fresh[] | {id, observed_at_epoch, workers:[.workers[] | {id, state_class,
           wait_since:((.last_progress | select(.verb == "blocked" or .verb == "paused" or .verb == "needs-decision") | .emitted_at_epoch) // null)}]}],
       fleet_working:(if ($fresh | length) == (.homes | length) then .totals.working else null end)}') || workers=null
fi
for path in "$current" "$history"; do
  if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
    echo "fm-goal-pace: refusing unsafe snapshot path: ${path##*/}" >&2
    exit 1
  fi
done
previous=/dev/null
[ ! -f "$current" ] || previous=$current

# The worker key is owner + task, never task alone. Owner-home orphan verdicts
# are authoritative; the worker table refines liveness into working or parked.
staged_current=$(mktemp "$STATE/.goal-pace.json.XXXXXX")
printf '%s\n' "$goals" | jq -ec --argjson now "$at" \
  --argjson capacity "$capacity" --argjson workers "$workers" --rawfile previous "$previous" '
  def worker($item):
    first($workers.homes[]? | select(.id == $item.owner and (.observed_at_epoch // $now) >= ($item.since // 0))
          | .workers[] | select(.id == $item.task)) // {};
  def bucket($w):
    if .state == "done" or .state == "dropped" then "closed"
      elif .state == "waiting" then "wait:" + (.wait_on.kind // (if .class == "captain" then "captain" else "unspecified" end))
      elif .state == "blocked" then (if .class == "captain" then "wait:captain" else "wait:blocked" end)
      elif .class == "captain" then
        if (.waiting_on | length) == 0 and (.until // $now) >= $now then "wait:captain" else "other" end
      elif (.orphaned_running | not) and $w.state_class == "working" then "running"
      elif (.orphaned_running | not) and $w.state_class == "parked" then "wait:fleet"
      elif .state == "running" and (.orphaned_running | not) then "running"
      elif .startable then (if (.merge_after // [] | length) > 0 then "merge" else "start" end)
      else "other" end;
  def idle($items; $old):
    [$items[] | . as $item
     | {id, owner, task, mark_epoch:.since,
        idle_since_epoch:(first($old[]? | select(.id == $item.id and .owner == $item.owner
          and .task == $item.task and .mark_epoch == $item.since) | .idle_since_epoch) // $now)}];
  ((try ($previous | fromjson | select(.schema == "fm-goal-pace.v1" and .generated_epoch <= $now)) catch empty) // {}) as $prior
  | {schema:"fm-goal-pace.v1", generated_epoch:$now,
   host:(({load1:null, cores:null, avail_gb:null, free_lanes:null, lane_target:null} + $capacity) + {fleet_working:$workers.fleet_working}),
   goals:[.[] | . as $goal
     | (first($prior.goals[]? | select(.id == $goal.id and .started_epoch == $goal.started_epoch
        and .drive_revision == $goal.drive_revision)) // {}) as $old
     | [.items[] | worker(.) as $w | bucket($w) as $kind | . + {bucket:$kind,
          wait_since:(if $kind == "wait:fleet" then $w.wait_since else .since // $goal.started_epoch end)}] as $items
     | idle([$items[] | select(.bucket == "start")]; $old.startable_idle) as $start
     | idle([$items[] | select(.bucket == "merge")]; $old.merge_after_ready) as $merge
     | {id, started_epoch, drive_revision,
        running_by_home: ([$items[] | select(.bucket == "running")] | group_by(.owner)
          | map({key:.[0].owner, value:length}) | from_entries),
        startable_idle:$start, merge_after_ready:$merge,
        behind_after: [$items[] | select(.bucket != "closed" and (.waiting_on | length) > 0) | .id],
        waiting_by_kind: ([$items[] | select(.bucket | startswith("wait:"))] | group_by(.bucket)
          | map({key:(.[0].bucket | ltrimstr("wait:")),
                 value:{count:length, oldest_age_seconds:([.[] | .wait_since | numbers | [$now - ., 0] | max] | max)}})
          | from_entries),
        idle_minutes: ([$start[], $merge[] | [($now - .idle_since_epoch) / 60 | floor, 0] | max] | max // 0)}
     ]}' > "$staged_current"

staged_history=$(mktemp "$STATE/.goal-pace.jsonl.XXXXXX")
{
  if [ -f "$history" ]; then tail -n 2047 "$history"; fi
  jq -c . "$staged_current"
} > "$staged_history"
mv -f -- "$staged_history" "$history"
mv -f -- "$staged_current" "$current"

jq -r '
  def val: if . == null then "?" else tostring end;
  def age: if . == null then "unknown" elif . < 3600 then "\(. / 60 | floor)m" else "\(. / 3600 | floor)h" end;
  .host as $host | .goals[]
  | (.running_by_home | to_entries | map("\(.key) \(.value)") | join(", ")) as $homes
  | (.waiting_by_kind | to_entries) as $wait
  | "PACE \(.id): running \([.running_by_home[]] | add // 0)\(if $homes == "" then "" else " (" + $homes + ")" end)"
    + " · startable idle \(.startable_idle | length) · merge-after ready \(.merge_after_ready | length)"
    + " · waiting \([$wait[].value.count] | add // 0)"
    + (if ($wait | length) == 0 then "" else
        " (\($wait | map("\(.key) \(.value.count)") | join(", ")); oldest \([$wait[].value.oldest_age_seconds] | max | age))" end)
    + " · behind \(.behind_after | length) · idle \(.idle_minutes)m"
    + " | host load \($host.load1 | val)/\($host.cores | val) · \($host.avail_gb | val) GB free · lanes \($host.free_lanes | val)/\($host.lane_target | val)"
' "$current"
