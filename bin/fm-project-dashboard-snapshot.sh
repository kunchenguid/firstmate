#!/usr/bin/env bash
# fm-project-dashboard-snapshot.sh - aggregate the canonical fleet snapshot by registered project.
#
# Usage:
#   fm-project-dashboard-snapshot.sh --json [--select <project>]
#
# The output is `fm-project-dashboard.v1` JSON.
# Every data/projects.md row appears exactly once, even when it has no task.
# Current state comes only from fm-fleet-snapshot.sh and its structured
# secondmate-home summaries.
# Secondmate owners come from secondmate_current.records, which carry registered
# project ownership; a task-only secondmate the bounded read omitted is kept as
# an explicit unavailable owner instead of disappearing.
# Secondmate state whose repo names a registered project attributes to that
# project even when the project is absent from the mate's clone list, which is
# non-exclusive; secondmates[].in_clone_list records that without judging it.
# Secondmate state that carries no repo and whose owner covers several projects
# is not guessed at: it is disclosed per owned project in unattributed[] and
# raises that project to needs_attention when it could have changed the status.
# A main-home task whose crew state reads back as unknown is disclosed in
# unreadable[] and raises the project to needs_attention rather than letting the
# card read idle.
# A done task whose backlog row is not yet done is finished work awaiting
# teardown, disclosed in awaiting_teardown[]. Nothing local distinguishes a
# merged PR from one awaiting review, so the board never claims either.
# A captain hold and a status fold collapse to one decision only when the
# pairing is unambiguous: one live hold and exactly one open needs-decision
# fold on the same task. A deferred hold never suppresses a live fold, and a
# task with several keyed folds keeps every one of them.
# An empty-string detail is treated as an absent value everywhere, so no card
# renders a blank next step.
# Only needs-decision folds and non-deferred captain holds count as decisions;
# deferred or superseded holds are disclosed in deferred_decisions[] instead of
# painting the card red, matching the canonical bearings default view.
# Bounded-read drops in the canonical snapshot surface board-wide in
# disclosures[] rather than silently shrinking a project card.
# PR links that are not https stay in prs[] with linkable=false so one odd link
# discloses itself instead of failing the whole board.
# This script reads task metadata/status mtimes only as activity timestamps;
# it never parses status-log text as current state.
#
# Project status precedence is needs_attention, active, waiting, idle_queued.
# Stale risk is an overlay, not a status.
# It applies only when the project is neither active nor needs_attention and
# the latest known activity is strictly older than the threshold.
#
# FM_PROJECT_DASHBOARD_STALE_DAYS sets the threshold (default 8).
# FM_PROJECT_DASHBOARD_NOW and FM_PROJECT_DASHBOARD_NOW_EPOCH pin time in tests.
# FM_PROJECT_DASHBOARD_FLEET_SNAPSHOT overrides the canonical reader in tests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REGISTRY="$DATA/projects.md"
FLEET_SNAPSHOT="${FM_PROJECT_DASHBOARD_FLEET_SNAPSHOT:-$SCRIPT_DIR/fm-fleet-snapshot.sh}"
STALE_DAYS="${FM_PROJECT_DASHBOARD_STALE_DAYS:-8}"
NOW="${FM_PROJECT_DASHBOARD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
SELECTED=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-project-dashboard-snapshot: %s\n' "$*" >&2
  exit 1
}

case "${1-}" in
  --json) shift ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --select)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      SELECTED=$2
      shift 2
      ;;
    *) usage >&2; exit 2 ;;
  esac
done

case "$STALE_DAYS" in
  ''|*[!0-9]*) fail "FM_PROJECT_DASHBOARD_STALE_DAYS must be a non-negative integer" ;;
esac
command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -x "$FLEET_SNAPSHOT" ] || fail "fleet snapshot reader is not executable: $FLEET_SNAPSHOT"

if [ -n "${FM_PROJECT_DASHBOARD_NOW_EPOCH:-}" ]; then
  NOW_EPOCH=$FM_PROJECT_DASHBOARD_NOW_EPOCH
else
  NOW_EPOCH=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$NOW" +%s 2>/dev/null \
    || date -u -d "$NOW" +%s 2>/dev/null \
    || true)
fi
case "$NOW_EPOCH" in
  ''|*[!0-9]*) fail "cannot resolve dashboard observation time: $NOW" ;;
esac

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-project-dashboard.XXXXXX") || fail "cannot create staging directory"
trap 'rm -rf -- "$tmpdir"' EXIT

if [ -f "$REGISTRY" ]; then
  jq -R -s '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    split("\n")
    | map(select(test("^-[[:space:]]+[^[:space:]]")))
    | map(
        capture("^-[[:space:]]+(?<name>[^[:space:]]+)(?<rest>.*)$") as $row
        | (($row.rest | capture("^[[:space:]]+\\[(?<policy>[^]]*)\\](?<after>.*)$")) // {policy:null,after:$row.rest}) as $split
        | (($split.policy // "") | split(" ") | map(select(length > 0))) as $policy
        | ($split.after | sub("^[[:space:]]*-[[:space:]]+"; "") | trim) as $tail
        | {
            name:$row.name,
            description:($tail | sub("[[:space:]]+\\(added [0-9]{4}-[0-9]{2}-[0-9]{2}\\)[[:space:]]*$"; "") | trim),
            added:((($tail | capture("\\(added (?<date>[0-9]{4}-[0-9]{2}-[0-9]{2})\\)[[:space:]]*$")) // {date:null}).date),
            mode:(($policy | map(select(startswith("+") | not)) | .[0]) // "no-mistakes"),
            yolo:($policy | index("+yolo") != null)
          })
  ' "$REGISTRY" > "$tmpdir/registry.json" || fail "cannot parse $REGISTRY"
else
  printf '[]\n' > "$tmpdir/registry.json"
fi

if ! jq -e 'group_by(.name) | all(.[]; length == 1)' "$tmpdir/registry.json" >/dev/null; then
  fail "project registry contains duplicate names: $REGISTRY"
fi
if [ -n "$SELECTED" ] && ! jq -e --arg selected "$SELECTED" 'any(.[]; .name == $selected)' "$tmpdir/registry.json" >/dev/null; then
  fail "selected project is not registered: $SELECTED"
fi

FM_SNAPSHOT_NOW="$NOW" FM_SNAPSHOT_NOW_EPOCH="$NOW_EPOCH" \
  "$FLEET_SNAPSHOT" --json > "$tmpdir/fleet.json" \
  || fail "canonical fleet snapshot failed"
jq -e '.schema == "fm-fleet-snapshot.v1"' "$tmpdir/fleet.json" >/dev/null \
  || fail "canonical fleet snapshot returned an unsupported schema"

file_mtime_epoch() {
  if [ ! -e "$1" ]; then
    return 0
  fi
  if [ "$(uname -s)" = Darwin ]; then
    stat -f '%m' "$1" 2>/dev/null || true
  else
    stat -c '%Y' "$1" 2>/dev/null || true
  fi
}

while IFS=$'\t' read -r id meta_path status_path; do
  [ -n "$id" ] || continue
  meta_epoch=$(file_mtime_epoch "$meta_path")
  status_epoch=$(file_mtime_epoch "$status_path")
  latest=0
  case "$meta_epoch" in ''|*[!0-9]*) : ;; *) latest=$meta_epoch ;; esac
  case "$status_epoch" in
    ''|*[!0-9]*) : ;;
    *) [ "$status_epoch" -gt "$latest" ] && latest=$status_epoch ;;
  esac
  jq -n --arg id "$id" --argjson epoch "$latest" '{key:$id,value:$epoch}'
done < <(jq -r '.tasks[] | [.id, (.paths.meta.path // ""), (.paths.status_log.path // "")] | @tsv' "$tmpdir/fleet.json") \
  | jq -s 'from_entries' > "$tmpdir/activity.json"

jq -n \
  --arg generated "$NOW" \
  --arg home "$FM_HOME" \
  --arg selected "$SELECTED" \
  --argjson now_epoch "$NOW_EPOCH" \
  --argjson stale_days "$STALE_DAYS" \
  --slurpfile registry "$tmpdir/registry.json" \
  --slurpfile fleet "$tmpdir/fleet.json" \
  --slurpfile activity "$tmpdir/activity.json" '
  def date_epoch:
    select(type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) as $date
    | try ($date + "T00:00:00Z" | fromdateiso8601) catch empty;
  def task_repo:
    (.backlog.repo //
      (if (.project // "") == "" then null
       elif (.project | contains("/")) then (.project | split("/") | map(select(length > 0)) | last)
       else .project end));
  def present:
    if . == null then null
    elif (type == "string") and ((gsub("[[:space:]]"; "")) == "") then null
    else . end;
  def owner_items($owner):
    (($owner.record.active_children // []) + ($owner.record.decisions_open // [])
     + ($owner.record.holds // []) + ($owner.record.queued // []) + ($owner.record.landed // []));
  def unattributable($owner):
    ((.repo // "") == "") and (($owner.projects | length) != 1);
  def matches_project($owner; $name):
    (.repo == $name)
    or (((.repo // "") == "") and (($owner.projects | length) == 1) and $owner.projects[0] == $name);
  def dedupe_first(keyf):
    reduce .[] as $item ([];
      ($item | keyf) as $key
      | if any(.[]; keyf == $key) then . else . + [$item] end);
  def https_url:
    (type == "string") and
    test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$");
  def status_label($status):
    if $status == "needs_attention" then "Needs attention"
    elif $status == "active" then "Active"
    elif $status == "waiting" then "Waiting"
    else "Idle / queued" end;
  def concise($value; $fallback):
    ((($value | present) // $fallback) | tostring | gsub("[[:space:]]+"; " ")) as $text
    | if ($text | length) > 150 then $text[:147] + "..." else $text end;

  $registry[0] as $projects_registry
  | $fleet[0] as $fleet_data
  | $activity[0] as $task_activity
  | ([ $fleet_data.secondmate_current.records[]? | .id ]) as $mate_record_ids
  | ([ ($fleet_data.secondmate_current.records[]?
        | . as $record
        | (([ $fleet_data.tasks[]? | select(.id == $record.id) ][0]) // null) as $task
        | {id:$record.id,
           projects:((($record.projects // []) + ($task.secondmate_projects // [])) | unique),
           activity:($task_activity[$record.id] // 0),
           record:$record}),
       ($fleet_data.tasks[]?
        | select(.kind == "secondmate")
        | . as $task
        | select(($mate_record_ids | index($task.id)) == null)
        | {id:$task.id,
           projects:($task.secondmate_projects // []),
           activity:($task_activity[$task.id] // 0),
           record:{
             id:$task.id,home:$task.paths.home.path,remote:($task.remote != null),projects:($task.secondmate_projects // []),
             current:{state:"unknown",reason:"Secondmate state unavailable from the bounded fleet snapshot"},
             active_children:[],decisions_open:[],holds:[],queued:[],landed:[]
           }}) ]) as $mate_owners
  | ($fleet_data.secondmate_current.registry // {}) as $mate_registry
  | ([ (if (($fleet_data.secondmate_current.truncated // 0) > 0) then
          {surface:("registered secondmates omitted by the snapshot bound: "
                    + (($fleet_data.secondmate_current.truncated) | tostring)),
           reveal:"raise FM_SNAPSHOT_SECONDMATES"} else empty end),
       (if $mate_registry.available == false then
          {surface:("secondmate registry unavailable: " + ($mate_registry.reason // "read failed")),
           reveal:"inspect data/secondmates.md"} else empty end),
       (if $mate_registry.records_truncated == true then
          {surface:"secondmate registry records omitted by the bounded read",
           reveal:"raise FM_SNAPSHOT_REGISTRY_RECORDS"} else empty end),
       (if $mate_registry.input_truncated == true then
          {surface:"secondmate registry input truncated by the bounded read",
           reveal:"raise FM_SNAPSHOT_REGISTRY_LINES or FM_SNAPSHOT_REGISTRY_BYTES"} else empty end) ]) as $disclosures
  | [ $projects_registry[] as $registered
      | $registered.name as $name
      | ([ $fleet_data.tasks[]?
           | select(.kind != "secondmate" and task_repo == $name) ]) as $tasks
      | ([ $fleet_data.backlog.records[]?
           | select(.structured == true and .repo == $name) ]) as $backlog
      | ([ $backlog[]
           | select(.captain_actionable == true and .deferred_marker != true)
           | .id ]) as $live_hold_ids
      | ([ $backlog[] | select(.state == "done") | .id ]) as $landed_ids
      | ([ $mate_owners[]
           | select((.projects | index($name) != null)
                    or (owner_items(.) | any(.repo == $name))) ]) as $owners
      | ([ $owners[] | select(.projects | index($name) != null) ]) as $registered_owners
      | ([ $tasks[]
           | select(.current_state.state == "working")
           | {id,title:(.backlog.title // .id),state:.current_state.state,
              detail:((.current_state.detail | present) // ""),owner:"main",pr_url:.pr.url} ]
         + [ $owners[] as $owner
             | $owner.record.active_children[]?
             | select(matches_project($owner; $name))
             | {id,title:(.title // .id),state,detail:((.doing | present) // ""),owner:$owner.id,pr_url:null} ]) as $active
      | ([ $tasks[] as $task
           | ([ ($task.hints.open_decisions // [])[] | select(.verb == "needs-decision") ]) as $folds
           | select((($live_hold_ids | index($task.id)) == null) or (($folds | length) != 1))
           | $folds[]
           | {id:$task.id,key,title:((.summary | present) // "Captain decision"),
              summary:((.summary | present) // ""),
              deferred:false,owner:"main"} ]
         + [ $backlog[]
             | select(.captain_actionable == true)
             | {id,key:.id,title:.title,summary:((.hold_reason | present) // .title),
                deferred:(.deferred_marker == true),owner:"main"} ]
         + [ $owners[] as $owner
             | ([ $owner.record.decisions_open[]?
                  | select(.source == "backlog" and .deferred_marker != true) | .id ]) as $owner_live_hold_ids
             | ([ $owner.record.decisions_open[]?
                  | select(.source == "status" and .verb != "blocked") ]) as $owner_folds
             | $owner.record.decisions_open[]?
             | . as $entry
             | select(.verb != "blocked")
             | select(.source != "status"
                      or (($owner_live_hold_ids | index($entry.id)) == null)
                      or (([ $owner_folds[] | select(.id == $entry.id) ] | length) != 1))
             | select(matches_project($owner; $name))
             | {id,key:(.key // .id),title:((.summary | present) // "Captain decision"),
                summary:((.reason | present) // (.summary | present) // ""),
                deferred:(.deferred_marker == true),owner:$owner.id} ]
        | dedupe_first([.owner,.id,.key])) as $decisions_all
      | ([ $decisions_all[] | select(.deferred | not) ]) as $decisions
      | ([ $decisions_all[] | select(.deferred) ]) as $deferred_decisions
      | ([ $tasks[]
           | select(.current_state.state == "failed" or .current_state.state == "blocked")
           | {id,title:(.backlog.title // .id),state:.current_state.state,
              detail:((.current_state.detail | present) // ""),owner:"main"} ]) as $failures
      | ([ $tasks[] as $task
           | select($task.current_state.state == "done")
           | select(($landed_ids | index($task.id)) == null)
           | {id:$task.id,title:($task.backlog.title // $task.id),url:$task.pr.url,
              detail:(($task.current_state.detail | present) // ""),owner:"main"} ]) as $awaiting_teardown
      | ([ $tasks[]
           | select(.current_state.state == "unknown")
           | {id,title:(.backlog.title // .id),state:.current_state.state,
              reason:((.current_state.detail | present) // "Task state could not be read"),owner:"main"} ]) as $unreadable
      | ([ $tasks[]
           | select(.current_state.state == "parked" or .current_state.state == "paused")
           | {id,title:(.backlog.title // .id),
              reason:((.current_state.detail | present) // .current_state.state),owner:"main"} ]
         + [ $backlog[]
             | select(.state == "queued" and
                 (((.unresolved_blocker_ids // []) | length) > 0 or
                  (.hold_reason != null and .captain_actionable != true)))
             | {id,title,reason:((.hold_reason | present) // (.blocked_reason | present) // "Waiting"),owner:"main"} ]
         + [ $owners[] as $owner
             | $owner.record.holds[]?
             | select(matches_project($owner; $name))
             | {id,title:(.title // .id),reason:((.reason | present) // "Waiting"),owner:$owner.id} ]
        | dedupe_first([.owner,.id])) as $waiting
      | ([ $backlog[]
           | select(.state == "queued")
           | {id,title,reason:(.hold_reason // .blocked_reason // ""),since,owner:"main",
              captain_actionable:(.captain_actionable // false)} ]
         + [ $owners[] as $owner
             | $owner.record.queued[]?
             | select(matches_project($owner; $name))
             | {id,title,reason:(.hold_reason // .blocked_reason // ""),since:(.since // null),owner:$owner.id,
                captain_actionable:(.captain_actionable // false)} ]
        | dedupe_first([.owner,.id])) as $queued
      | ([ $backlog[]
           | select(.state == "done" and .hold_kind != "captain")
           | {id,title,completed:(.completion.date // .merged // .reported // .done),
              pr_url,report_path,owner:"main"} ]
         + [ $owners[] as $owner
             | $owner.record.landed[]?
             | select(matches_project($owner; $name))
             | {id,title,completed:(.completion.date // null),pr_url,report_path,owner:$owner.id} ]
        | dedupe_first([.owner,.id])
        | sort_by([(.completed // ""),.id]) | reverse) as $landed_all
      | ([ $tasks[] | select(.pr.url != null)
           | {id,title:(.backlog.title // .id),url:.pr.url,owner:"main"} ]
         + [ $backlog[] | select(.pr_url != null)
             | {id,title,url:.pr_url,owner:"main"} ]
         + [ $owners[] as $owner
             | $owner.record.landed[]?
             | select(matches_project($owner; $name) and .pr_url != null)
             | {id,title,url:.pr_url,owner:$owner.id} ]
        | dedupe_first(.url)
        | map(. + {linkable:(.url | https_url)})) as $prs
      | ([ $owners[] | select(.record.current.state == "unknown")
           | {id:.id,reason:(.record.current.reason // "Secondmate state unavailable")} ]) as $unavailable_owners
      | ([ $registered_owners[] as $owner
           | ($owner.record.active_children[]? | select(unattributable($owner))
              | {kind:"active_work",id,title:(.title // .id),owner:$owner.id}),
             ($owner.record.decisions_open[]? | select(unattributable($owner))
              | {kind:"decision",id,title:(.summary // .id),owner:$owner.id}),
             ($owner.record.holds[]? | select(unattributable($owner))
              | {kind:"waiting",id,title:(.title // .id),owner:$owner.id}),
             ($owner.record.queued[]? | select(unattributable($owner))
              | {kind:"queued",id,title:(.title // .id),owner:$owner.id}),
             ($owner.record.landed[]? | select(unattributable($owner))
              | {kind:"landed",id,title:(.title // .id),owner:$owner.id}) ]
         | dedupe_first([.owner,.kind,.id])) as $unattributed
      | ([ $unattributed[] | select(.kind != "landed") ]) as $unattributed_live
      | (if ($decisions | length) > 0 or ($failures | length) > 0 or
             ($unreadable | length) > 0 or ($unavailable_owners | length) > 0 or
             ($unattributed_live | length) > 0 then "needs_attention"
         elif ($active | length) > 0 then "active"
         elif ($waiting | length) > 0 then "waiting"
         else "idle_queued" end) as $status
      | ([ $registered.added | date_epoch ]
         + [ $backlog[]
             | (.completion.date // .merged // .reported // .done // .since)
             | date_epoch ]
         + [ $tasks[] | $task_activity[.id] // 0 | select(. > 0) ]
         + [ $owners[] | .activity | select(. > 0) ]
         + [ $owners[] as $owner
             | $owner.record.queued[]?
             | select(matches_project($owner; $name))
             | .since | date_epoch ]
         + [ $owners[] as $owner
             | $owner.record.landed[]?
             | select(matches_project($owner; $name))
             | .completion.date | date_epoch ]) as $activity_candidates
      | (($activity_candidates | max) // null) as $last_epoch
      | (if $last_epoch == null then null else ($now_epoch - $last_epoch | if . < 0 then 0 else . end) end) as $age_seconds
      | (if ($status == "needs_attention") then
           concise((if ($decisions | length) > 0 then
                      ($decisions[0].title as $title
                       | ($decisions[0].summary // "") as $summary
                       | if $summary == "" or $summary == $title then $title
                         else ($title + ": " + $summary) end)
                    elif ($failures | length) > 0 then
                      ($failures[0].state + ": " +
                       (if ($failures[0].detail // "") == "" then $failures[0].title else $failures[0].detail end))
                    elif ($unreadable | length) > 0 then
                      ("Task state could not be read: " + $unreadable[0].id + " - " + $unreadable[0].reason)
                    elif ($unattributed_live | length) > 0 then
                      ("Secondmate work is not attributable to one project: " + $unattributed_live[0].title)
                    else $unavailable_owners[0].reason end); "Review project state")
         elif $status == "active" then
           concise((if ($active[0].detail // "") == "" then $active[0].title else $active[0].detail end); "Work is under way")
         elif $status == "waiting" then
           concise((($waiting[0].reason | present) // $waiting[0].title); "Waiting on an external dependency")
         elif ($queued | length) > 0 then concise($queued[0].title; "Queued work")
         elif ($awaiting_teardown | length) > 0 then
           concise(("Finished; awaiting teardown and completion record: " + $awaiting_teardown[0].title);
                   "Finished work awaiting teardown")
         else "No work queued" end) as $next_step
      | $registered + {
          status:$status,
          status_label:status_label($status),
          stale_risk:(($status != "active" and $status != "needs_attention") and
                      $age_seconds != null and $age_seconds > ($stale_days * 86400)),
          last_activity:(if $last_epoch == null then null else {
            at:($last_epoch | strftime("%Y-%m-%dT%H:%M:%SZ")),
            age_days:($age_seconds / 86400 | floor),
            age_seconds:$age_seconds
          } end),
          next_step:$next_step,
          active_work:$active,
          decisions:$decisions,
          failures:$failures,
          unreadable:$unreadable,
          awaiting_teardown:$awaiting_teardown,
          waiting:$waiting,
          queued:$queued,
          landed:($landed_all[:5]),
          prs:$prs,
          unattributed:$unattributed,
          deferred_decisions:$deferred_decisions,
          secondmates:([ $owners[] | {
            id,home:.record.home,remote:.record.remote,state:.record.current.state,
            unavailable:(.record.current.state == "unknown"),
            in_clone_list:((.projects | index($name)) != null)
          } ]),
          counts:{active:($active | length),decisions:($decisions | length),
            unreadable:($unreadable | length),
            awaiting_teardown:($awaiting_teardown | length),
            waiting:($waiting | length),queued:($queued | length),landed:($landed_all | length),
            prs:($prs | length),unattributed:($unattributed | length),
            deferred_decisions:($deferred_decisions | length)}
        }
    ] as $projects
  | {
      schema:"fm-project-dashboard.v1",
      generated:$generated,
      home:$home,
      stale_after_days:$stale_days,
      selected_project:(if $selected == "" then null else $selected end),
      disclosures:$disclosures,
      projects:$projects,
      summary:{
        total:($projects | length),
        active:([$projects[] | select(.status == "active")] | length),
        needs_attention:([$projects[] | select(.status == "needs_attention")] | length),
        waiting:([$projects[] | select(.status == "waiting")] | length),
        idle_queued:([$projects[] | select(.status == "idle_queued")] | length),
        stale_risk:([$projects[] | select(.stale_risk)] | length),
        unattributed:([$projects[] | select((.unattributed | length) > 0)] | length),
        deferred_decisions:([$projects[].deferred_decisions[]] | length),
        unreadable:([$projects[].unreadable[]] | length),
        awaiting_teardown:([$projects[].awaiting_teardown[]] | length)
      }
    }
' > "$tmpdir/dashboard.json" || fail "project aggregation failed"

jq . "$tmpdir/dashboard.json"
