#!/usr/bin/env bash
# fm-project-status.sh - bounded project projection over fm-fleet-snapshot.v1.
#
# `--json <project>` runs the no-write, conversation-free project-status source
# mode of bin/fm-fleet-snapshot.sh under an eight-second subprocess bound and a
# 4 MiB source cap, then emits exactly one
# fm-project-status.v1 object no larger than 64 KiB. It never collects fleet
# state independently.
# Project lookup is exact, ASCII case-insensitive, and unique across the main
# project registry and secondmate_projects.
# Parent status events and terminal or conversation text are never current-state
# authority. A secondmate-owned project uses only its secondmate_current record
# and filters every collection by project identity. Unidentifiable rows are
# omitted and disclosed; partial or truncated current surfaces remain unknown.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_BYTES=65536
SOURCE_MAX_BYTES=4194304
TIMEOUT_SECONDS=8

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-project-status.sh --json <project>

Print fm-project-status.v1 as a bounded read-only projection of
fm-fleet-snapshot.v1. Project matching is exact and case-insensitive; fuzzy
matching is never attempted. Unknown, ambiguous, unreadable, incompatible,
timed-out, and oversized sources remain explicit in the JSON result.
EOF
}

if [ "$#" -ne 2 ] || [ "$1" != --json ] || [ -z "$2" ] || [ "${#2}" -gt 128 ]; then
  usage >&2
  exit 2
fi
QUERY=$2

TMP_STATUS=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-project-status.XXXXXX") \
  || { echo "fm-project-status: temporary directory creation failed" >&2; exit 1; }
cleanup() { rm -rf -- "$TMP_STATUS"; }
trap cleanup EXIT
SOURCE_JSON="$TMP_STATUS/fleet.json"

unavailable_json() {  # <reason-code> <warning>
  jq -n --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg query "$QUERY" --arg reason_code "$1" --arg warning "$2" '
    {schema:"fm-project-status.v1",generated:$generated,query:$query,
     match:{status:"unavailable",project:null,candidates:[]},owner:null,
     current:{state:"unavailable",reason_code:$reason_code,reason_ids:[]},
     underway:[],captain_calls:[],queued:[],recently_landed:[],
     counts:{underway:0,captain_calls:0,queued:0,landed:0},
     provenance:{source:"fm-fleet-snapshot.v1",trust:"unavailable",freshness:"unavailable",observed_at:null,age_seconds:null},
     warnings:[$warning],omitted:[]}'
}

limit=$((SOURCE_MAX_BYTES + 1))
# shellcheck disable=SC2016  # Positional parameters expand in the child bash.
capture_script='set -o pipefail; "$1" --json --project-status-source | LC_ALL=C head -c "$2"'
if fm_run_timed "$TIMEOUT_SECONDS" bash -c "$capture_script" fm-project-status \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" "$limit" > "$SOURCE_JSON" 2>/dev/null; then
  snapshot_rc=0
else
  snapshot_rc=$?
fi
source_bytes=$(LC_ALL=C wc -c < "$SOURCE_JSON" | tr -d ' ')
case "$source_bytes" in ''|*[!0-9]*) source_bytes=0 ;; esac
if [ "$source_bytes" -gt "$SOURCE_MAX_BYTES" ]; then
  unavailable_json source_too_large "fleet snapshot exceeded the 4 MiB source bound"
  exit 0
fi
if [ "$snapshot_rc" -eq 124 ]; then
  unavailable_json source_timeout "fleet snapshot exceeded the 8 second subprocess bound"
  exit 0
fi
if [ "$snapshot_rc" -ne 0 ]; then
  unavailable_json source_unreadable "fleet snapshot could not be read"
  exit 0
fi
if ! jq -e -s '
  length == 1 and (.[0] | type) == "object"
  and .[0].schema == "fm-fleet-snapshot.v1"
  and (.[0].project_registry.records | type) == "array"
  and (.[0].project_registry.available | type) == "boolean"
  and (.[0].backlog.records | type) == "array"
  and (.[0].tasks | type) == "array"
  and (.[0].secondmate_current.records | type) == "array"
' "$SOURCE_JSON" >/dev/null 2>&1; then
  unavailable_json incompatible_source "fleet snapshot schema is missing, unsupported, or malformed"
  exit 0
fi

OUTPUT_JSON="$TMP_STATUS/status.json"
jq -n --arg query "$QUERY" --slurpfile snapshot "$SOURCE_JSON" '
  ($snapshot[0]) as $s
  | def lower: ascii_downcase;
  def belongs($project): (.project | type) == "string" and (.project | lower) == ($project | lower);
  def text($n):
      if . == null then null
      else (tostring | gsub("[[:space:]]+"; " ") | if length > $n then .[:$n] + "…" else . end)
      end;
  def task_row:
      {id:(.id | text(120)),title:((.backlog.title // .id) | text(160)),
       kind:((.kind // null) | text(40)),state:((.current_state.state // "unknown") | text(40)),
       source:((.current_state.source // null) | text(80)),doing:((.current_state.detail // null) | text(240)),
       pr_url:((.pr.url // null) | text(500)),report_path:((.paths.report.path // null) | text(500))};
  def active_row:
      {id:((.id // null) | text(120)),title:((.title // .id // null) | text(160)),
       kind:((.kind // null) | text(40)),state:((.state // "unknown") | text(40)),
       source:((.source // null) | text(80)),doing:((.doing // null) | text(240)),
       pr_url:null,report_path:null};
  def decision_row:
      {id:((.id // null) | text(120)),key:((.key // .id // null) | text(120)),
       summary:((.summary // .title // null) | text(240)),reason:((.reason // .hold_reason // null) | text(240)),
       source:((.source // null) | text(80)),hold_until:(.hold_until // null),
       hold_bucket:(.hold_bucket // null)};
  def queued_row:
      {id:((.id // null) | text(120)),title:((.title // null) | text(180)),
       kind:((.kind // null) | text(40)),repo:((.repo // null) | text(120)),
       blocked_by_ids:((.unresolved_blocker_ids // .blocked_by_ids // []) | map(text(120))[:10]),
       reason:((.blocked_reason // .hold_reason // .reason // null) | text(240)),
       hold_kind:((.hold_kind // null) | text(40)),hold_until:(.hold_until // null),
       hold_bucket:(.hold_bucket // null),captain_actionable:(.captain_actionable // false)};
  def landed_row:
      {id:((.id // null) | text(120)),title:((.title // null) | text(180)),
       kind:((.kind // null) | text(40)),pr_url:((.pr_url // null) | text(500)),
       report_path:((.report_path // null) | text(500)),local_note:((.local_note // null) | text(180)),
       completion:(.completion // {verb:null,date:null})};
  def finish($warnings; $omitted):
      ($warnings[:10]) as $kept_warnings
      | .warnings = $kept_warnings
      | .omitted = $omitted[:(10 - ($kept_warnings | length))];
  ([ $s.project_registry.records[]? | select((.name | type) == "string" and .name != "")
       | {name:.name,source:"main-registry",owner:{kind:"main",id:null}}
     ]
   + [ $s.tasks[]? | select(.kind == "secondmate") as $mate
       | $mate.secondmate_projects[]?
       | select(type == "string" and . != "")
       | {name:.,source:"secondmate-projects",owner:{kind:"secondmate",id:$mate.id}}
     ]) as $all_candidates
  | ([ $all_candidates[] | select((.name | lower) == ($query | lower)) ]) as $matches
  | ([ $matches[] | select(.owner.kind == "secondmate") | .owner.id ] | unique) as $mate_ids
  | ([ $matches[].owner | [.kind,(.id // "")] | join(":") ] | unique) as $owners
  | ([ $matches[] | .name ] | unique) as $exact_names
  | if ($matches | length) == 0 and $s.project_registry.available != true then
      {schema:"fm-project-status.v1",generated:$s.generated,query:$query,
       match:{status:"unavailable",project:null,candidates:[]},owner:null,
       current:{state:"unavailable",reason_code:"project_registry_unavailable",reason_ids:[]},
       underway:[],captain_calls:[],queued:[],recently_landed:[],
       counts:{underway:0,captain_calls:0,queued:0,landed:0},
       provenance:{source:"fm-fleet-snapshot.v1/project_registry",trust:"unavailable",freshness:"unknown",observed_at:$s.generated,age_seconds:null},
       warnings:[($s.project_registry.reason // "project registry is unavailable")],omitted:[]}
    elif ($matches | length) == 0 then
      {schema:"fm-project-status.v1",generated:$s.generated,query:$query,
       match:{status:"unknown",project:null,candidates:[]},owner:null,
       current:{state:"unknown",reason_code:"project_not_found",reason_ids:[]},
       underway:[],captain_calls:[],queued:[],recently_landed:[],
       counts:{underway:0,captain_calls:0,queued:0,landed:0},
       provenance:{source:"fm-fleet-snapshot.v1",trust:"none",freshness:"unknown",observed_at:$s.generated,age_seconds:null},
       warnings:["no exact case-insensitive project match"],omitted:[]}
    elif ($owners | length) > 1 then
      {schema:"fm-project-status.v1",generated:$s.generated,query:$query,
       match:{status:"ambiguous",project:null,candidates:($exact_names[:5])},owner:null,
       current:{state:"unknown",reason_code:"ambiguous_project_owner",reason_ids:$owners[:5]},
       underway:[],captain_calls:[],queued:[],recently_landed:[],
       counts:{underway:0,captain_calls:0,queued:0,landed:0},
       provenance:{source:"fm-fleet-snapshot.v1",trust:"none",freshness:"unknown",observed_at:$s.generated,age_seconds:null},
       warnings:["more than one owner declares the exact project name"],omitted:[]}
    elif ($mate_ids | length) == 1 then
      ($mate_ids[0]) as $owner_id
      | ([ $matches[] | select(.owner.kind == "secondmate" and .owner.id == $owner_id) | .name ][0]) as $project
      | ([ $s.secondmate_current.records[]? | select(.id == $owner_id) ][0] // null) as $record
      | if $record == null or $record.provenance.selected != "structured-home" then
          {schema:"fm-project-status.v1",generated:$s.generated,query:$query,
           match:{status:"exact",project:$project,candidates:[]},owner:{kind:"secondmate",id:$owner_id},
           current:{state:"unknown",reason_code:"structured_home_unavailable",reason_ids:[]},
           underway:[],captain_calls:[],queued:[],recently_landed:[],
           counts:{underway:0,captain_calls:0,queued:0,landed:0},
           provenance:{source:"fm-fleet-snapshot.v1/secondmate_current",trust:"unavailable",freshness:($record.freshness.status // "unavailable"),observed_at:($record.freshness.observed_at // null),age_seconds:($record.freshness.age_seconds // null)},
           warnings:["the owning secondmate has no authoritative structured-home record"],omitted:[]}
        else
          ([ $record.active_children[]? | select(belongs($project)) ]) as $active
          | ([ $record.decisions_open[]? | select(belongs($project)) ]) as $decisions
          | ([ $record.holds[]? | select(belongs($project)) ]) as $holds
          | ([ $record.queued[]? | select(belongs($project)) ]) as $queued
          | ([ $record.landed[]? | select(belongs($project)) ]) as $landed
          | ($record.invalidities // [($record.invalidity + {project:null})]) as $invalidities
          | ([ $invalidities[]? | select(belongs($project)) ]) as $project_invalidities
          | ([ $invalidities[]? | select((.project | type) != "string" or .project == "") ]) as $unknown_invalidities
          | ([{surface:"underway",rows:[$record.active_children[]?]},
              {surface:"captain_calls",rows:[$record.decisions_open[]?]},
              {surface:"current_holds",rows:[$record.holds[]?]},
              {surface:"queued",rows:[$record.queued[]?]},
              {surface:"recently_landed",rows:[$record.landed[]?]}]
             | map({surface,count:([.rows[] | select((.project | type) != "string" or .project == "")] | length)})
             | map(select(.count > 0) | . + {reason:"project identity unavailable"})) as $unidentified
          | ([ $record.omitted[]?
               | select(.surface == "active_children" or .surface == "decisions_open" or
                        .surface == "holds" or .surface == "queued" or .surface == "landed") ]) as $source_omitted
          | (($source_omitted | any(.surface == "active_children" or .surface == "decisions_open" or .surface == "holds"))) as $current_incomplete
          | ([if ($project_invalidities + $unknown_invalidities | length) > 0 then "current state is incomplete; independently reliable structured fields were retained" else empty end,
              if $current_incomplete then "project current state may be incomplete because the structured home was truncated" else empty end,
              if ($unidentified | length) > 0 then "structured rows without project identity were omitted" else empty end,
              if $record.contradiction == true then "historical parent evidence contradicts the structured home and was not used as current state" else empty end,
              if $record.freshness.status == "cached" then "the structured home was read from an existing cache" else empty end]) as $warnings
          | ($unidentified + ($source_omitted | map({surface:(if .surface == "active_children" then "underway" elif .surface == "decisions_open" then "captain_calls" elif .surface == "landed" then "recently_landed" else .surface end),count,reason:"structured home truncation"}))
              + [if ($active | length) > 5 then {surface:"underway",count:(($active | length) - 5)} else empty end,
                 if ($decisions | length) > 5 then {surface:"captain_calls",count:(($decisions | length) - 5)} else empty end,
                 if ($queued | length) > 5 then {surface:"queued",count:(($queued | length) - 5)} else empty end,
                 if ($landed | length) > 3 then {surface:"recently_landed",count:(($landed | length) - 3)} else empty end]) as $omitted
          | (($project_invalidities + $unknown_invalidities | length) > 0 or $current_incomplete or
             any($unidentified[]; .surface == "underway" or .surface == "captain_calls" or .surface == "current_holds")) as $unknown_current
          | {schema:"fm-project-status.v1",generated:$s.generated,query:$query,
             match:{status:"exact",project:$project,candidates:[]},owner:{kind:"secondmate",id:$owner_id},
             current:(if $unknown_current then
                 {state:"unknown",
                  reason_code:(if $current_incomplete or any($unidentified[]; .surface == "underway" or .surface == "captain_calls" or .surface == "current_holds") then "project_projection_incomplete" else (($project_invalidities + $unknown_invalidities)[0].kind // "structured_home_unknown") end),
                  reason_ids:([$project_invalidities[].ids[]?, $unknown_invalidities[].ids[]?] | unique)[:10]}
               elif ($decisions | length) > 0 then {state:"captain_decision",reason_code:null,reason_ids:[]}
               elif ($active | length) > 0 then {state:"active_child_work",reason_code:null,reason_ids:[]}
               elif ($holds | length) > 0 then {state:"externally_held",reason_code:null,reason_ids:[]}
               else {state:"no_active_work",reason_code:null,reason_ids:[]} end),
             underway:([$active[] | active_row][:5]),
             captain_calls:([$decisions[] | decision_row][:5]),
             queued:([$queued[] | queued_row][:5]),
             recently_landed:([$landed[] | landed_row][:3]),
             counts:{underway:($active | length),captain_calls:($decisions | length),
               queued:($queued | length),landed:($landed | length)},
             provenance:{source:"fm-fleet-snapshot.v1/secondmate_current",trust:$record.provenance.trust,
               freshness:$record.freshness.status,observed_at:$record.freshness.observed_at,age_seconds:($record.freshness.age_seconds // null)}}
            | finish($warnings; $omitted)
        end
    else
      ([ $matches[] | select(.source == "main-registry") | .name ][0]
        // [ $matches[] | .name ][0]) as $project
      | ([ $s.backlog.records[]? | select(.structured == true and (.repo | type) == "string" and (.repo | lower) == ($project | lower)) ]) as $backlog
      | ([ $s.tasks[]? | select(.kind != "secondmate" and (.backlog.structured == true) and
             ((.backlog.repo | type) == "string" and (.backlog.repo | lower) == ($project | lower))) ]) as $tasks
      | ([ $s.tasks[]? | select(.kind != "secondmate" and
             ((.backlog.structured != true) or ((.backlog.repo | type) != "string") or .backlog.repo == "")) | .id ]) as $unidentified_task_ids
      | ([ $backlog[] | select(.state == "in_flight" and .requires_child_metadata == true) as $work
             | select(any($s.tasks[]?; .id == $work.id) | not) | .id ]) as $project_orphan_ids
      | ([ $s.backlog.records[]? | select(.structured != true and (.state == "in_flight" or .state == "queued") and
             (.repo | type) == "string" and (.repo | lower) == ($project | lower)) | .id ]) as $project_unstructured_ids
      | ([ $s.backlog.records[]? | select(.structured != true and (.state == "in_flight" or .state == "queued") and
             ((.repo | type) != "string" or .repo == "")) | .id ]) as $unidentified_backlog_ids
      | (($project_orphan_ids + $project_unstructured_ids + $unidentified_task_ids + $unidentified_backlog_ids) | unique) as $inventory_ids
      | ([ $tasks[] | select((.current_state.state // "unknown") == "unknown") | .id ]) as $unknown_ids
      | ([ $tasks[].current_state.state // "unknown" ] | unique) as $states
      | ([ $backlog[] | select(.captain_actionable == true) | decision_row ]
         + [ $tasks[] as $task | $task.hints.open_decisions[]? | . + {id:$task.id} | decision_row ] | unique_by([.id,.key])) as $calls
      | ([ $backlog[] | select(.state == "queued") | queued_row ]) as $queued
      | ([ $backlog[] | select(.state == "done") | landed_row ] | sort_by([(.completion.date // ""),.id]) | reverse) as $landed
      | ([if ($inventory_ids | length) > 0 then "main project inventory is incomplete or contains project-unidentifiable current rows" else empty end]) as $warnings
      | ([if ($tasks | length) > 5 then {surface:"underway",count:(($tasks | length) - 5)} else empty end,
          if ($calls | length) > 5 then {surface:"captain_calls",count:(($calls | length) - 5)} else empty end,
          if ($queued | length) > 5 then {surface:"queued",count:(($queued | length) - 5)} else empty end,
          if ($landed | length) > 3 then {surface:"recently_landed",count:(($landed | length) - 3)} else empty end]) as $omitted
      | {schema:"fm-project-status.v1",generated:$s.generated,query:$query,
         match:{status:"exact",project:$project,candidates:[]},owner:{kind:"main",id:null},
         current:(if ($inventory_ids | length) > 0 then {state:"unknown",reason_code:"main_inventory_incomplete",reason_ids:$inventory_ids[:10]}
                  elif ($unknown_ids | length) > 0 then {state:"unknown",reason_code:"task_current_unavailable",reason_ids:$unknown_ids[:10]}
                  elif ($tasks | length) == 0 then {state:"no_active_work",reason_code:null,reason_ids:[]}
                  elif ($states | length) == 1 then {state:$states[0],reason_code:null,reason_ids:[]}
                  else {state:"mixed",reason_code:null,reason_ids:[]} end),
         underway:([$tasks[] | task_row][:5]),captain_calls:$calls[:5],queued:$queued[:5],recently_landed:$landed[:3],
         counts:{underway:($tasks | length),captain_calls:($calls | length),queued:($queued | length),landed:($landed | length)},
         provenance:{source:"fm-fleet-snapshot.v1/main",trust:(if ($inventory_ids | length) == 0 then "complete" else "partial-structured" end),
           freshness:"fresh",observed_at:$s.generated,age_seconds:0}}
        | finish($warnings; $omitted)
    end
' > "$OUTPUT_JSON" || {
  unavailable_json projection_failed "fleet snapshot could not be projected"
  exit 0
}

output_bytes=$(LC_ALL=C wc -c < "$OUTPUT_JSON" | tr -d ' ')
case "$output_bytes" in ''|*[!0-9]*) output_bytes=0 ;; esac
if [ "$output_bytes" -gt "$MAX_BYTES" ]; then
  unavailable_json projection_too_large "project status exceeded the 64 KiB output bound"
  exit 0
fi
cat "$OUTPUT_JSON"
