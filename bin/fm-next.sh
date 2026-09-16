#!/usr/bin/env bash
# Select and render the single highest-value captain-facing lifecycle action.
#
# Usage: fm-next.sh [--json] [--snapshot <path>|-]
#
# docs/task-lifecycle.md owns status and route semantics. The command composes
# fm-task-lifecycle.sh's projection rather than inferring acceptance from backlog
# Done, worker completion, tests, or delivery. Ranking is deterministic:
# concrete captain actions that restart work, review/acceptance/delivery work,
# then closure only when no forward action remains. Within one tier: priority,
# downstream tasks released, active before inactive, oldest action, callsign,
# then canonical id. The command never mutates a task.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_COMMAND="$SCRIPT_DIR/fm-fleet-snapshot.sh"
FORMAT=text
SNAPSHOT_PATH=

usage() {
  awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --snapshot)
      shift
      [ "$#" -gt 0 ] || { echo "fm-next: --snapshot requires a path or -" >&2; exit 2; }
      SNAPSHOT_PATH=$1
      ;;
    --snapshot=*) SNAPSHOT_PATH=${1#--snapshot=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-next: jq not found" >&2; exit 1; }

CALLSIGNS=${FM_NEXT_CALLSIGNS_JSON:-[]}
if [ -z "${FM_NEXT_CALLSIGNS_JSON+x}" ] && [ -z "$SNAPSHOT_PATH" ] && [ -f "$SCRIPT_DIR/fm-callsigns-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/fm-callsigns-lib.sh"
  CALLSIGNS=$(fm_callsigns_json) || { echo "fm-next: could not read private task references" >&2; exit 1; }
fi
printf '%s\n' "$CALLSIGNS" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || { echo "fm-next: invalid task reference JSON" >&2; exit 2; }

if [ -z "$SNAPSHOT_PATH" ]; then
  SNAPSHOT=$($SNAPSHOT_COMMAND --json) || exit $?
elif [ "$SNAPSHOT_PATH" = - ]; then
  SNAPSHOT=$(cat) || exit $?
else
  [ -f "$SNAPSHOT_PATH" ] || { echo "fm-next: snapshot not found: $SNAPSHOT_PATH" >&2; exit 2; }
  SNAPSHOT=$(cat "$SNAPSHOT_PATH") || exit $?
fi

LIFECYCLE_ROWS=$(printf '%s\n' "$SNAPSHOT" | \
  "$SCRIPT_DIR/fm-task-lifecycle.sh" project --snapshot - --callsigns-json "$CALLSIGNS") \
  || { echo "fm-next: could not derive task lifecycle" >&2; exit 1; }

RESULT=$(printf '%s\n' "$SNAPSHOT" | jq -e \
  --argjson callsigns "$CALLSIGNS" --argjson lifecycleRows "$LIFECYCLE_ROWS" '
  if .schema != "fm-fleet-snapshot.v1" then error("fm-next requires fm-fleet-snapshot.v1") else . end
  | . as $snapshot
  | ($snapshot.backlog.records // []) as $records
  | ($snapshot.tasks // []) as $tasks
  | def clean($value; $fallback):
      ($value // "") as $v
      | if ($v | type) != "string" or ($v | length) == 0 then $fallback
        else ($v | gsub("[\\r\\n\\t]+"; " ") | gsub("  +"; " ")) end;
  def task_for($id): first($tasks[]? | select(.id == $id)) // null;
  def life_for($id): first($lifecycleRows[]? | select(.id == $id)) // null;
  def callsign_for($owner; $id):
      if $owner == "main" then (first($callsigns[]? | select(.id == $id)) // null) else null end;
  def priority_rank($priority): if $priority == null or $priority == "" then 5 else (($priority | tonumber?) // 5) end;
  def wait_key($record; $fallback):
      ($record.hold_set // $record.since // $record.completion.date // $record.done // $record.merged // $record.reported // $fallback // "9999-12-31");
  def downstream_count($id):
      [$records[]? | select(.structured == true and .state != "done")
       | select(((.unresolved_blocker_ids // .blocked_by_ids // []) | index($id)) != null)] | length;
  def artifact_for($record; $task):
      ($task.pr.url // $record.pr_url // $record.report_path // $record.local_note // ($record.links // [])[0] // null);
  def canonical_ref($owner; $id):
      if $owner == "main" or ($id | startswith($owner + "/")) then $id else ($owner + "/" + $id) end;
  def base($tier; $kind; $owner; $record; $task; $row; $id; $title; $reason; $active):
      (callsign_for($owner; $id)) as $call
      | (canonical_ref($owner; $id)) as $canonical
      | {tier:$tier,kind:$kind,owner:$owner,
         ref:($call.ref // $canonical),canonical_id:$canonical,id:$id,
         name:clean(($call.name // $title); $id),
         sort_callsign:(($call.ref // "") | ltrimstr("t") | tonumber? // 1000),
         priority:($record.priority // null),priority_rank:priority_rank($record.priority // null),
         downstream_released:downstream_count($id),active:$active,active_rank:(if $active then 0 else 1 end),
         actionable_since:wait_key($record; $snapshot.generated),
         reason:clean($reason; "One task lifecycle action remains."),
         current_state:($task.current_state.state // null),current_detail:($row.outcome // $task.current_state.detail // null),
         status:($row.status // null),next_action:($row.next_action // null),route:($row.route // null),
         close_ready:($row.close_ready // false),lifecycle:($row.lifecycle // null),
         repo:($record.repo // $task.project // null),
         delivery:{mode:($task.mode // null),standing_landing_authority:(($task.yolo // "off") == "on")},
         artifact:artifact_for($record; $task),durable_context:($record.body_excerpt // null)};
  def lifecycle_kind($row):
      if $row.status == "done" then "review"
      elif $row.status == "reviewing" then "acceptance"
      elif $row.status == "accepted" or $row.status == "delivering" then
        (if $row.route == "deliver-monitor" and ($row.lifecycle.delivery.completedAt // "") != "" then "monitoring" else "delivery" end)
      elif $row.status == "monitoring" then "monitoring"
      else "lifecycle" end;
  ([ $records[]?
       | select(.structured == true)
       | . as $record | task_for(.id) as $task | life_for(.id) as $row
       | select($row != null and $row.status == "needs-you")
       | base((if .state == "in_flight" then 1 else 2 end);
           (if .state == "in_flight" then "active_intervention" else "blocked_captain_action" end);
           "main"; $record; $task; $row; .id; .title; $row.outcome; (.state == "in_flight")) ]
   + [ $records[]?
       | select(.structured == true and .state == "queued" and .kind == "captain")
       | . as $record | task_for(.id) as $task | life_for(.id) as $row
       | select($row != null and $row.status == "queued")
       | base(3; "queued_judgment"; "main"; $record; $task; $row; .id; .title;
           "This authorized item needs an ordering or scope judgment before it starts."; false) ]
   + [ $records[]?
       | select(.structured == true)
       | . as $record | task_for(.id) as $task | life_for(.id) as $row
       | select($row != null and ($row.status == "done" or $row.status == "reviewing" or $row.status == "accepted" or $row.status == "delivering" or $row.status == "monitoring"))
       | select($row.close_ready != true)
       | base(4; lifecycle_kind($row); "main"; $record; $task; $row; .id; .title; $row.outcome; (.state == "in_flight")) ]
   + [ ($snapshot.secondmate_current.records // [])[]?
       | select(.provenance.selected == "structured-home") | . as $mate
       | ($mate.decisions_open // [])[]? | . as $decision
       | first(($mate.queued // [])[]? | select(.id == $decision.id)) as $found
       | (($found // {id:$decision.id,title:$decision.summary,priority:null,since:null,repo:null}) + {id:$decision.id}) as $record
       | (any(($mate.active_children // [])[]?; .id == $decision.id)) as $active
       | base((if $active then 1 else 2 end); (if $active then "active_intervention" else "blocked_captain_action" end);
           $mate.id; $record; null; null; $decision.id; ($record.title // $decision.summary); $decision.summary; $active) ]
   + [ ($snapshot.secondmate_current.records // [])[]?
       | select(.provenance.selected == "structured-home") | . as $mate
       | ($mate.queued // [])[]?
       | select((.unresolved_blocker_ids // []) | length == 0)
       | select(.captain_actionable != true and .hold_reason == null and .kind == "captain")
       | . as $record
       | base(3; "queued_judgment"; $mate.id; $record; null; null; .id; .title;
           "This authorized item needs an ordering or scope judgment before it starts."; false) ]) as $forward
  | (any($lifecycleRows[]?; .status == "working" or .status == "queued")
     or any(($snapshot.secondmate_current.records // [])[]?; ((.active_children // []) | length) > 0)) as $autonomous_forward
  | ([ $records[]?
       | select(.structured == true) | . as $record | task_for(.id) as $task | life_for(.id) as $row
       | select($row != null and $row.close_ready == true)
       | base(5; "closure"; "main"; $record; $task; $row; .id; .title;
           "Every selected lifecycle phase is complete; only archival closure remains."; false) ]) as $closures
  | (if ($forward | length) > 0 then $forward elif $autonomous_forward then [] else $closures end
     | sort_by([.tier,.priority_rank,(-.downstream_released),.active_rank,.actionable_since,.sort_callsign,.canonical_id])) as $ranked
  | ($ranked[0] // null) as $selected
  | def consequence($c):
      if $c.kind == "active_intervention" or $c.kind == "blocked_captain_action" then
        "Resolving this restarts stopped work" + (if $c.downstream_released > 0 then " and releases \($c.downstream_released) dependent task(s)." else "." end)
      elif $c.kind == "queued_judgment" then "A clear choice lets authorized work start without guessing."
      elif $c.kind == "review" then "The candidate cannot be accepted, delivered, or closed until review starts."
      elif $c.kind == "acceptance" then "The active review must either accept the result with a route or return it for correction."
      elif $c.kind == "delivery" then "The accepted result has not completed its selected delivery route."
      elif $c.kind == "monitoring" then "The selected post-delivery observation is not complete."
      else "The accepted lifecycle is complete; only archival closure remains." end;
  def recommendation($c):
      if $c.kind == "active_intervention" or $c.kind == "blocked_captain_action" then "Provide the exact recorded action now."
      elif $c.kind == "queued_judgment" then "Choose whether this should start next."
      elif $c.kind == "review" then "Review the candidate now; acceptance is a separate recorded result."
      elif $c.kind == "acceptance" then "Finish review by accepting one route or returning the task with a concrete correction."
      elif $c.kind == "delivery" then "Complete the selected delivery phase before considering closure."
      elif $c.kind == "monitoring" then "Complete the selected monitoring phase before considering closure."
      else "Close this task rather than inventing follow-up work." end;
  def alternatives($c):
      if $c.kind == "review" or $c.kind == "acceptance" then "Return the candidate to working with one specific correction."
      elif $c.kind == "delivery" or $c.kind == "monitoring" then "Return it to working if the phase exposed a problem."
      elif $c.kind == "closure" then "Keep it open only if the detail reveals unfinished accepted scope or a separate authorized follow-up."
      else "Defer it explicitly, accepting that the affected work remains stopped." end;
  def actions($c):
      if $c.kind == "closure" then ["/task \($c.ref)", "/close \($c.ref)", "/history \($c.ref)"]
      elif $c.kind == "review" then ["/task \($c.ref)", "Review the candidate artifact", "Record review start or return one correction"]
      elif $c.kind == "acceptance" then ["/task \($c.ref)", "Accept with route close, deliver, or deliver-monitor; or return one correction"]
      elif $c.kind == "delivery" then ["/task \($c.ref)", $c.next_action]
      elif $c.kind == "monitoring" then ["/task \($c.ref)", $c.next_action]
      elif $c.kind == "queued_judgment" then ["/task \($c.ref)", "Say: start \($c.ref), or name what should precede it"]
      else ["/task \($c.ref)", "Answer the recorded captain call in chat"] end;
  def closure_context($c):
      if $c.kind != "closure" then null else
        {accepted_scope_ended:true,acceptance:$c.lifecycle.acceptance,route:$c.route,
         durable_outcome:($c.artifact // $c.name),
         open_defect_or_authorized_follow_up:
           (if $c.durable_context == null then "No separate structured follow-up is recorded; verify the task detail before closing."
            else "Durable task notes remain available for the closure review: \($c.durable_context)" end),
         knowledge_retained:(if $c.artifact != null then "The durable outcome is retained at \($c.artifact)." else "The closure archive retains the task record." end)} end;
  if $selected == null then
    {schema:"fm-next.v2",generated:$snapshot.generated,selection:null,
     ranking:{eligible:0,forward_eligible:($forward|length),closure_eligible:($closures|length),autonomous_forward_present:$autonomous_forward},
     card:"Fleet needs no captain action."}
  else
    ($selected + {consequence:consequence($selected),recommendation:recommendation($selected),
                  alternatives:alternatives($selected),actions:actions($selected),closure_context:closure_context($selected)}) as $card
    | {schema:"fm-next.v2",generated:$snapshot.generated,selection:$card,
       ranking:{eligible:($ranked|length),forward_eligible:($forward|length),closure_eligible:($closures|length),autonomous_forward_present:$autonomous_forward,
                order:["tier","priority","downstream_released","active","oldest_actionable_wait","callsign","canonical_id"]},
       card:((if $card.kind == "closure" then
                "Ref: \($card.ref) - \($card.name)\nWhat completed: \($card.closure_context.durable_outcome)\nAcceptance: \($card.closure_context.acceptance.actor) at \($card.closure_context.acceptance.at)\nRoute: \($card.route)\nWhat remains: \($card.consequence)"
              else
                "Ref: \($card.ref) - \($card.name)\nSituation: \($card.current_detail // $card.reason)\nNext lifecycle action: \($card.next_action // $card.reason)\nConsequence: \($card.consequence)" end)
             + "\nRecommendation: \($card.recommendation)"
             + "\nAlternatives: \($card.alternatives)"
             + "\nActions:\n" + ($card.actions | map("- " + .) | join("\n")))}
  end
' 2>&1) || { printf 'fm-next: %s\n' "$RESULT" >&2; exit 1; }

# Live output composes the detail and closure owners after deterministic ranking.
if [ -z "$SNAPSHOT_PATH" ] && [ "$(printf '%s\n' "$RESULT" | jq -r '.selection != null')" = true ]; then
  SELECTED_ID=$(printf '%s\n' "$RESULT" | jq -r '.selection.canonical_id')
  DETAIL=$(FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}" \
    FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}" \
    "$SCRIPT_DIR/fm-task.sh" --json "$SELECTED_ID") \
    || { echo "fm-next: selected task detail became unavailable; retry" >&2; exit 1; }
  CLOSURE_REVIEW='null'
  if [ "$(printf '%s\n' "$RESULT" | jq -r '.selection.kind')" = closure ]; then
    REVIEW_TEXT=$(FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}" \
      FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}" \
      "$SCRIPT_DIR/fm-close.sh" --review "$SELECTED_ID") \
      || { echo "fm-next: closure review refused for the selected task" >&2; exit 1; }
    CLOSURE_REVIEW=$(printf '%s\n' "$REVIEW_TEXT" | jq -R -s '
      reduce (split("\n")[]) as $line
        ({mode:null,result:"Completed",retained:[],follow_ups:[],cleanup:"Cleanup state unavailable."};
         if ($line | startswith("Result: ")) then .result = ($line | ltrimstr("Result: "))
         elif $line == "Retained knowledge and task material:" then .mode = "retained"
         elif ($line | startswith("Next-work recommendations:")) then .mode = "follow-ups"
         elif (($line | startswith("Cleanup:")) or ($line | startswith("Cleanup blocker:"))) then .cleanup = $line | .mode = null
         elif ($line | startswith("Review only:")) then .mode = null
         elif ($line | startswith("- ")) and .mode == "retained" then .retained += [($line | ltrimstr("- "))]
         elif ($line | startswith("- Continue existing task ")) and .mode == "follow-ups" then .follow_ups += [($line | ltrimstr("- Continue existing task "))]
         else . end) | del(.mode)')
  fi
  RESULT=$(printf '%s\n' "$RESULT" | jq --argjson detail "$DETAIL" --argjson review "$CLOSURE_REVIEW" '
    .selection.task_detail=$detail
    | .selection.artifact=(.selection.artifact // $detail.artifacts[0] // null)
    | if .selection.kind == "closure" then
        .selection.closure_review=$review
        | .selection.closure_context.durable_outcome=($review.result // $detail.outcome // .selection.name)
        | .selection.closure_context.open_defect_or_authorized_follow_up=
            (if (($review.follow_ups // []) | length) > 0 then "Authorized follow-up already exists: " + ($review.follow_ups | join(", "))
             else "The closure owner found no existing follow-up and will not create one automatically." end)
        | .selection.closure_context.knowledge_retained=
            (if (($review.retained // []) | length) > 0 then "Knowledge and task material will be retained at " + ($review.retained | join(", ")) + "."
             else "No retained material is recorded." end)
        | .selection.recommendation=
            (if (($review.follow_ups // []) | length) > 0 then "Close this completed scope and continue the already-authorized follow-up separately."
             else "Close this task rather than inventing follow-up work." end)
        | .card=("Ref: \(.selection.ref) - \(.selection.name)"
          + "\nWhat completed: \(.selection.closure_context.durable_outcome)"
          + "\nAcceptance: \(.selection.closure_context.acceptance.actor) at \(.selection.closure_context.acceptance.at)"
          + "\nRoute: \(.selection.route)"
          + "\nClosure check: \(.selection.closure_context.open_defect_or_authorized_follow_up) \(.selection.closure_context.knowledge_retained) \($review.cleanup)"
          + "\nRecommendation: \(.selection.recommendation)"
          + "\nAlternatives: \(.selection.alternatives)"
          + "\nActions:\n" + (.selection.actions | map("- " + .) | join("\n")))
      else
        .card=("Ref: \(.selection.ref) - \(.selection.name)"
          + "\nSituation: " + (($detail.outcome // .selection.reason) | tostring)
          + "\nNext lifecycle action: " + (($detail.nextAction // .selection.next_action) | tostring)
          + "\nConsequence: \(.selection.consequence)"
          + "\nRecommendation: \(.selection.recommendation)"
          + "\nAlternatives: \(.selection.alternatives)"
          + "\nActions:\n" + (.selection.actions | map("- " + .) | join("\n")))
      end') || { echo "fm-next: could not compose selected task context" >&2; exit 1; }
fi

if [ "$FORMAT" = json ]; then printf '%s\n' "$RESULT"; else printf '%s\n' "$RESULT" | jq -r '.card'; fi
