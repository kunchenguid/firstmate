#!/usr/bin/env bash
# fm-project-cockpit-snapshot.sh - project the canonical fleet snapshot for Project Cockpit.
#
# Usage:
#   fm-project-cockpit-snapshot.sh [--from-snapshot <file|->] [--observed-at <UTC>] [--stale-after <seconds>]
#
# With no fixture input, the command invokes fm-fleet-snapshot.sh --json exactly
# once.
# It validates schema fm-fleet-snapshot.v1 and emits the bounded, allowlisted
# fm-project-cockpit.v1 presentation model.
# It never follows paths carried by the snapshot, reparses mutable fleet files,
# queries the network, or derives state from prose.
#
# --from-snapshot reads a deterministic fixture instead of collecting live
# state.
# --observed-at fixes the projection clock for deterministic age calculations.
# --stale-after changes the positive stale threshold from its 300-second
# default.
#
# If live collection fails, the command emits a valid unavailable cockpit model
# without retaining possibly misattributed task identity.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT="$SCRIPT_DIR/fm-fleet-snapshot.sh"
FROM_SNAPSHOT=
OBSERVED_AT=${FM_COCKPIT_NOW:-}
STALE_AFTER=${FM_COCKPIT_STALE_AFTER:-300}
MAX_BYTES=${FM_COCKPIT_SNAPSHOT_MAX_BYTES:-2097152}

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  printf 'fm-project-cockpit-snapshot: %s\n' "$*" >&2
  exit 1
}

valid_positive_integer() {
  case "$1" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --from-snapshot)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      FROM_SNAPSHOT=$2
      shift 2
      ;;
    --observed-at)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      OBSERVED_AT=$2
      shift 2
      ;;
    --stale-after)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      STALE_AFTER=$2
      shift 2
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
valid_positive_integer "$STALE_AFTER" || fail "--stale-after must be a positive integer"
valid_positive_integer "$MAX_BYTES" || fail "FM_COCKPIT_SNAPSHOT_MAX_BYTES must be a positive integer"

[ -n "$OBSERVED_AT" ] || OBSERVED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\n' "$OBSERVED_AT" | jq -R -e 'fromdateiso8601' >/dev/null 2>&1 \
  || fail "--observed-at must be a UTC timestamp such as 2026-09-15T12:00:00Z"

tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-project-cockpit-snapshot.XXXXXX") \
  || fail "cannot stage the fleet snapshot"
cleanup() { rm -f -- "$tmp"; }
trap cleanup EXIT HUP INT TERM

collection_failed=0
if [ -z "$FROM_SNAPSHOT" ]; then
  if ! "$SNAPSHOT" --json > "$tmp"; then
    collection_failed=1
  fi
elif [ "$FROM_SNAPSHOT" = - ]; then
  head -c "$((MAX_BYTES + 1))" > "$tmp"
else
  [ -f "$FROM_SNAPSHOT" ] && [ ! -L "$FROM_SNAPSHOT" ] \
    || fail "snapshot fixture must be a regular non-symlink file: $FROM_SNAPSHOT"
  cp -- "$FROM_SNAPSHOT" "$tmp" || fail "cannot read snapshot fixture: $FROM_SNAPSHOT"
fi

if [ "$collection_failed" -eq 1 ]; then
  jq -n \
    --arg generated "$OBSERVED_AT" \
    --argjson stale_after "$STALE_AFTER" '
    {
      schema:"fm-project-cockpit.v1",
      generated:$generated,
      observed_at:$generated,
      age_seconds:0,
      stale_after_seconds:$stale_after,
      freshness:"unavailable",
      inventory:{status:"unavailable",reason:"fleet snapshot unavailable",partial_reasons:[],truncated:false},
      counts:{running:0,waiting:0,blocked:0,attention:0},
      projects:[],
      terminal:{status:"unavailable",reason:"Terminal observation is omitted in version 1 because exact task attribution is not yet guaranteed."},
      limits:{projects:80,tasks_per_project:160,total_tasks:500,strings:500}
    }'
  exit 0
fi

bytes=$(wc -c < "$tmp" | tr -d '[:space:]')
[ "$bytes" -le "$MAX_BYTES" ] || fail "fleet snapshot exceeds the $MAX_BYTES-byte input bound"
jq empty "$tmp" >/dev/null 2>&1 || fail "fleet snapshot is not valid JSON"

jq -e '
  type == "object"
  and .schema == "fm-fleet-snapshot.v1"
  and (.generated | type == "string" and (try fromdateiso8601 catch null) != null)
  and (.backlog | type == "object")
  and (.backlog.records | type == "array")
  and (.tasks | type == "array")
  and (.main_inventory | type == "object")
  and (.main_inventory.valid | type == "boolean")
  and (.secondmate_current == null or (.secondmate_current | type == "object"))
  and (.secondmate_landed == null or (.secondmate_landed | type == "object"))
' "$tmp" >/dev/null || fail "fleet snapshot does not satisfy fm-fleet-snapshot.v1"

jq \
  --arg observed_at "$OBSERVED_AT" \
  --argjson stale_after "$STALE_AFTER" '
  def text($n):
    if type != "string" then null
    else gsub("[[:cntrl:]]"; " ") | gsub("[[:space:]]+"; " ")
      | if length > $n then .[:($n - 1)] + "…" else . end
    end;
  def ident:
    if type == "string" and test("^[A-Za-z0-9._:-]{1,128}$") then . else null end;
  def time:
    if type == "string" and (try fromdateiso8601 catch null) != null then . else null end;
  def date_or_time:
    if type != "string" then null
    elif test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then .
    elif (try fromdateiso8601 catch null) != null then .
    else null end;
  def https:
    if type == "string"
       and length <= 500
       and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]<>]*)?$")
    then . else null end;
  def arr: if type == "array" then . else [] end;
  def project_id:
    ((.backlog.repo // null) | text(128)) as $repo
    | ((.project // null) | text(500)) as $project
    | if $repo != null and $repo != "" then $repo
      elif $project != null and $project != "" then ($project | split("/") | map(select(length > 0)) | last) // "unassigned"
      else "unassigned" end
    | text(128);
  def backlog_project_id:
    ((.repo // null) | text(128)) as $repo
    | if $repo == null or $repo == "" then "unassigned" else $repo end;
  def task_state:
    (.current_state.state // "unknown") as $state
    | if ["working","parked","done","blocked","paused","failed","unknown","stopped"] | index($state)
      then $state else "unknown" end;
  def endpoint_status:
    (.endpoint.status // "unknown") as $status
    | if ["alive","absent","dead","unknown"] | index($status)
      then $status else "unknown" end;
  def lane_for($state; $backlog_state; $hold):
    if $backlog_state == "done" or $state == "done" then "recently_completed"
    elif $hold != null or (["parked","blocked","paused","failed"] | index($state)) != null then "waiting"
    else "running" end;
  def attention_for($state; $actionable):
    ($actionable == true or $state == "blocked" or $state == "failed");
  def task_projection($now):
    . as $task
    | (task_state) as $state
    | (.backlog // {}) as $work
    | (($work.hold_bucket // null) as $bucket
       | if ["live","blocked","dated","aged","superseded","resolved"] | index($bucket)
         then $bucket else null end) as $hold_bucket
    | (lane_for($state; ($work.state // null); $hold_bucket)) as $lane
    | (attention_for($state; ($work.captain_actionable // false))) as $attention
    | (($task.started_at // null) | time) as $started_at
    | (($task.current_state.observed_at // null) | time) as $observed
    | (($task.paths.report.path // null) | text(500)) as $report_path
    | {
        id:(($task.id | ident) // "invalid-task"),
        spawn_gen:(($task.spawn_gen // null) | if . == null then null else ident end),
        name:((($work.title // null) | text(160)) // (($task.id // "Unnamed task") | text(128))),
        project_id:project_id,
        lane:$lane,
        state:$state,
        state_source:((($task.current_state.source // "none") | text(40)) // "none"),
        state_detail:null,
        state_detail_status:"unavailable",
        observed_at:$observed,
        started_at:$started_at,
        elapsed_seconds:(if $started_at == null then null else (($now - ($started_at | fromdateiso8601)) | floor | if . < 0 then 0 else . end) end),
        crew:{
          liveness:endpoint_status,
          summary:(if $state == "working" and endpoint_status == "alive" then "1 LIVE"
                   elif $state == "parked" then "QUIET"
                   elif $state == "done" then "COMPLETE"
                   elif endpoint_status == "dead" then "DEAD"
                   elif endpoint_status == "absent" then "UNAVAILABLE"
                   else "UNKNOWN" end),
          kind:(($task.kind // "worker") | text(40)),
          harness:(($task.harness // null) | text(40)),
          backend:(($task.backend // null) | text(40))
        },
        attention:$attention,
        attention_rank:(if ($work.captain_actionable // false) == true then 0 elif $attention then 1 else 2 end),
        hold:(if $hold_bucket == null then null else {
          classification:$hold_bucket,
          actionable:($work.captain_actionable // false),
          question:(($work.hold_reason // null) | text(240)),
          age_days:($work.hold_age_days // null),
          until:(($work.hold_until // null) | date_or_time),
          evidence:"structured backlog hold"
        } end),
        blockers:(($work.unresolved_blocker_ids // []) | arr | map(ident) | map(select(. != null)) | .[:20]),
        gate:(if (($work.unresolved_blocker_ids // []) | arr | length) > 0 then
                 {status:"blocked",label:(((($work.unresolved_blocker_ids // []) | arr | map(text(80)) | join(", ")) | text(240)))}
              elif $hold_bucket != null then {status:$hold_bucket,label:(($work.hold_reason // "Captain hold") | text(240))}
              else {status:"unavailable",label:"Unavailable"} end),
        artifacts:{
          pr_url:(($task.pr.url // $work.pr_url // null) | https),
          report:{status:(if ($task.paths.report.present // false) == true then "available" else "missing" end),path:$report_path}
        },
        runtime_evidence:{
          endpoint_status:endpoint_status,
          target:(($task.endpoint.target // null) | text(240)),
          worktree:(($task.paths.worktree.path // null) | text(500)),
          home:(($task.paths.home.path // null) | text(500))
        },
        events:{status:"unavailable",items:[],reason:"Structured event chronology is not available in fm-fleet-snapshot.v1."},
        terminal:{status:"unavailable",reason:"Terminal observation is omitted in version 1 because exact task attribution is not yet guaranteed."}
      };
  def queued_projection:
    {
      id:((.id | ident) // "invalid-queued"),spawn_gen:null,
      name:((.title | text(160)) // ((.id // "Unnamed queued item") | text(128))),
      project_id:backlog_project_id,lane:"queued",state:"queued",state_source:"backlog",
      state_detail:null,state_detail_status:"unavailable",observed_at:null,started_at:null,elapsed_seconds:null,
      crew:{liveness:"not_started",summary:"NOT STARTED",kind:((.kind // "work") | text(40)),harness:null,backend:null},
      attention:((.captain_actionable // false) == true),
      attention_rank:(if (.captain_actionable // false) == true then 0 else 2 end),
      hold:(if .hold_bucket == null then null else {classification:.hold_bucket,actionable:(.captain_actionable // false),question:(.hold_reason | text(240)),age_days:(.hold_age_days // null),until:(.hold_until | date_or_time),evidence:"structured backlog hold"} end),
      blockers:((.unresolved_blocker_ids // []) | arr | map(ident) | map(select(. != null)) | .[:20]),
      gate:(if ((.unresolved_blocker_ids // []) | arr | length) > 0 then {status:"blocked",label:(((.unresolved_blocker_ids | map(text(80)) | join(", ")) | text(240)))} else {status:"unavailable",label:"Unavailable"} end),
      artifacts:{pr_url:(.pr_url | https),report:{status:(if .report_path == null then "missing" else "available" end),path:(.report_path | text(500))}},
      runtime_evidence:{endpoint_status:"not_started",target:null,worktree:null,home:null},
      events:{status:"unavailable",items:[],reason:"No structured event chronology is available for queued work."},
      terminal:{status:"unavailable",reason:"Terminal observation is unavailable for queued work."}
    };
  def completed_projection:
    {
      id:((.id | ident) // "invalid-completed"),spawn_gen:null,
      name:((.title | text(160)) // ((.id // "Unnamed completed item") | text(128))),
      project_id:backlog_project_id,lane:"recently_completed",state:"done",state_source:"backlog",
      state_detail:null,state_detail_status:"unavailable",observed_at:null,completed_at:(.completion.date | date_or_time),started_at:null,elapsed_seconds:null,
      crew:{liveness:"complete",summary:"COMPLETE",kind:((.kind // "work") | text(40)),harness:null,backend:null},
      attention:false,attention_rank:2,hold:null,blockers:[],gate:{status:"complete",label:"Complete"},
      artifacts:{pr_url:(.pr_url | https),report:{status:(if .report_path == null then "missing" else "available" end),path:(.report_path | text(500))}},
      runtime_evidence:{endpoint_status:"complete",target:null,worktree:null,home:null},
      events:{status:"unavailable",items:[],reason:"No structured event chronology is available for completed work."},
      terminal:{status:"unavailable",reason:"Terminal observation is omitted in version 1."}
    };
  . as $snapshot
  | ($observed_at | fromdateiso8601) as $now
  | ($snapshot.generated | fromdateiso8601) as $generated_epoch
  | (($now - $generated_epoch) | floor | if . < 0 then 0 else . end) as $age
  | ([ $snapshot.tasks[:500][] | task_projection($now) ]) as $live_tasks
  | ([ $snapshot.backlog.records[]?
       | select(.structured == true and .state == "queued")
       | select(.id as $id | [$snapshot.tasks[].id] | index($id) | not)
       | queued_projection ][0:500]) as $queued
  | ([ $snapshot.backlog.records[]?
       | select(.structured == true and .state == "done")
       | completed_projection ][0:160]) as $completed
  | (($live_tasks + $queued + $completed) | unique_by([.id,.spawn_gen,.lane]) | .[:500]) as $all_tasks
  | ([ $all_tasks[].project_id ] | unique | sort) as $project_ids
  | ([
      if $snapshot.main_inventory.valid != true then ($snapshot.main_inventory.reason // "invalid main inventory") | text(240) else empty end,
      if ($snapshot.secondmate_current.truncated // false) == true then "secondmate inventory truncated" else empty end,
      (($snapshot.secondmate_landed.unreadable // [])[]? | "secondmate inventory unavailable"),
      (($snapshot.secondmate_landed.partial // [])[]? | "secondmate inventory partial"),
      (($snapshot.secondmate_landed.truncated // [])[]? | "secondmate landed inventory truncated")
    ] | unique) as $partial_reasons
  | ([ $project_ids[:80][] as $pid
       | ([ $all_tasks[] | select(.project_id == $pid) ]
          | sort_by([.attention_rank,(if .lane == "running" then 0 elif .lane == "waiting" then 1 elif .lane == "queued" then 2 else 3 end),.id,(.spawn_gen // "")])) as $tasks
       | {
           id:$pid,label:$pid,
           attention_count:([$tasks[] | select(.attention)] | length),
           active_count:([$tasks[] | select(.lane == "running" or .lane == "waiting")] | length),
           blocker_count:([$tasks[] | select(.state == "blocked" or .state == "failed")] | length),
           latest_phase:(([ $tasks[] | select(.lane == "running" or .lane == "waiting") ][0].state) // "quiet"),
           last_observed_at:([ $tasks[].observed_at | select(. != null and test("T")) ] | sort | last // null),
           oldest_active_seconds:([ $tasks[] | select(.lane == "running" or .lane == "waiting") | .elapsed_seconds | select(. != null) ] | max // null),
           rank:(if any($tasks[]; .attention) then 0 elif any($tasks[]; .lane == "running" or .lane == "waiting") then 1 else 2 end),
           total_task_count:($tasks | length),
           truncated:(($tasks | length) > 160),
           tasks:$tasks[:160]
         }
     ] | sort_by([.rank,.id])) as $projects
  | ([ $all_tasks[] | select(.lane == "running") ] | length) as $running
  | ([ $all_tasks[] | select(.lane == "waiting") ] | length) as $waiting
  | ([ $all_tasks[] | select(.state == "blocked" or .state == "failed") ] | length) as $blocked
  | ([ $all_tasks[] | select(.attention) ] | length) as $attention
  | (if $snapshot.main_inventory.valid != true then "invalid"
     elif ($partial_reasons | length) > 0 then "partial"
     elif ($all_tasks | length) == 0 then "empty"
     else "valid" end) as $inventory_status
  | {
      schema:"fm-project-cockpit.v1",
      generated:$snapshot.generated,
      observed_at:$observed_at,
      age_seconds:$age,
      stale_after_seconds:$stale_after,
      freshness:(if $age > $stale_after then "stale" else "fresh" end),
      inventory:{status:$inventory_status,reason:(if $snapshot.main_inventory.valid != true then (($snapshot.main_inventory.reason // "invalid main inventory") | text(240)) else null end),partial_reasons:$partial_reasons,truncated:(($snapshot.tasks | length) > 500 or ($project_ids | length) > 80 or any($projects[]; .truncated))},
      counts:{running:$running,waiting:$waiting,blocked:$blocked,attention:$attention},
      projects:$projects,
      terminal:{status:"unavailable",reason:"Terminal observation is omitted in version 1 because exact task attribution is not yet guaranteed."},
      limits:{projects:80,tasks_per_project:160,total_tasks:500,strings:500}
    }
' "$tmp"
