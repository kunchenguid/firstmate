#!/usr/bin/env bash
# fm-next.sh - select and render the single highest-value captain action.
#
# Usage: fm-next.sh [--json] [--snapshot <path>|-]
#
# The command composes bin/fm-fleet-snapshot.sh rather than reading task state
# itself. Its ranking is deterministic and does not mutate backlog or work state;
# the snapshot may refresh observational caches and the identity owner may sync
# private callsign assignments.
# Default output is the stable plain-text card stored in the JSON `card` field;
# --json prints the complete `fm-next.v1` object used by tests and other views.
# --snapshot accepts an already captured canonical snapshot, with `-` meaning
# stdin. This is primarily a deterministic composition/test seam.
#
# Ranking, in order:
#   1. active work with a live captain call;
#   2. finished delivery that lacks standing landing authority;
#   3. inactive blocked work with a live captain call;
#   4. ready queued captain-kind work whose ordering needs judgment;
#   5. one Done item to close, but only when neither captain nor autonomous
#      forward work exists.
# Within one tier: explicit priority, number of downstream tasks released,
# active before inactive, oldest actionable wait, then callsign and canonical id.
# Ordinary autonomous recovery, landing with standing authority, and ordinary
# ready queued work are deliberately ineligible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_COMMAND="$SCRIPT_DIR/fm-fleet-snapshot.sh"
FORMAT=text
SNAPSHOT_PATH=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --snapshot)
      shift
      [ $# -gt 0 ] || { echo "fm-next: --snapshot requires a path or -" >&2; exit 2; }
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

RESULT=$(printf '%s\n' "$SNAPSHOT" | jq -e --argjson callsigns "$CALLSIGNS" '
  if .schema != "fm-fleet-snapshot.v1" then
    error("fm-next requires fm-fleet-snapshot.v1")
  else . end
  | . as $snapshot
  | ($snapshot.backlog.records // []) as $records
  | ($snapshot.tasks // []) as $tasks
  | def clean($value; $fallback):
      ($value // "") as $v
      | if ($v | type) != "string" or ($v | length) == 0 then $fallback
        else ($v | gsub("[\\r\\n\\t]+"; " ") | gsub("  +"; " ")) end;
  def task_for($id): first($tasks[]? | select(.id == $id)) // null;
  def callsign_for($owner; $id):
      if $owner == "main" then (first($callsigns[]? | select(.id == $id)) // null) else null end;
  def priority_rank($priority):
      if $priority == null or $priority == "" then 5
      else (($priority | tonumber?) // 5) end;
  def wait_key($record; $fallback):
      ($record.hold_set // $record.since // $record.completion.date // $record.done // $record.merged // $record.reported // $fallback // "9999-12-31");
  def downstream_count($id):
      [$records[]?
       | select(.structured == true and .state != "done")
       | select(((.unresolved_blocker_ids // .blocked_by_ids // []) | index($id)) != null)]
      | length;
  def artifact_for($record; $task):
      ($task.pr.url // $record.pr_url // $record.report_path // $record.local_note // ($record.links // [])[0] // null);
  def canonical_ref($owner; $id):
      if $owner == "main" or ($id | startswith($owner + "/")) then $id else ($owner + "/" + $id) end;
  def base_candidate($tier; $kind; $owner; $record; $task; $id; $title; $reason; $active):
      (callsign_for($owner; $id)) as $call
      | (canonical_ref($owner; $id)) as $canonical
      | {tier:$tier,kind:$kind,owner:$owner,
       ref:($call.ref // $canonical),canonical_id:$canonical,id:$id,
       name:clean(($call.name // $title); $id),
       sort_callsign:(($call.ref // "") | ltrimstr("t") | tonumber? // 1000),
       priority:($record.priority // null),
       priority_rank:priority_rank($record.priority // null),
       downstream_released:downstream_count($id),
       active:$active,
       active_rank:(if $active then 0 else 1 end),
       actionable_since:wait_key($record; $snapshot.generated),
       reason:clean($reason; "Captain input is required before this work can continue."),
       current_state:($task.current_state.state // null),
       current_detail:($task.current_state.detail // null),
       repo:($record.repo // $task.project // null),
       delivery:{mode:($task.mode // null),standing_landing_authority:(($task.yolo // "off") == "on")},
       artifact:artifact_for($record; $task),
       durable_context:($record.body_excerpt // null)};
  ([ $records[]?
       | select(.structured == true and .state == "in_flight")
       | . as $record
       | task_for(.id) as $task
       | [($task.hints.open_decisions // [])[]?
          | select(.verb == "needs-decision" or .verb == "captain-hold")] as $calls
       | select(.captain_actionable == true or ($calls | length) > 0)
       | (($calls | map(.summary) | join("; ")) // "") as $call_reason
       | base_candidate(1; "active_intervention"; "main"; $record; $task; .id; .title;
           (if $call_reason != "" then $call_reason else .hold_reason end); true) ]
     +
     [ $records[]?
       | select(.structured == true and .state == "in_flight")
       | . as $record
       | task_for(.id) as $task
       | select($task != null and $task.current_state.state == "done")
       | select(($task.yolo // "off") != "on")
       | base_candidate(2; "delivery_review"; "main"; $record; $task; .id; .title;
           ($task.current_state.detail // "The delivery is finished and awaits review or landing approval."); true) ]
     +
     [ $records[]?
       | select(.structured == true and .state != "in_flight" and .state != "done")
       | select(.captain_actionable == true)
       | . as $record
       | task_for(.id) as $task
       | base_candidate(3; "blocked_captain_action"; "main"; $record; $task; .id; .title;
           (.hold_reason // .blocked_reason); false) ]
     +
     [ $records[]?
       | select(.structured == true and .state == "queued")
       | select((.unresolved_blocker_ids // []) | length == 0)
       | select(.hold_reason == null and .kind == "captain")
       | . as $record
       | task_for(.id) as $task
       | base_candidate(4; "queued_judgment"; "main"; $record; $task; .id; .title;
           "This queued captain-owned item needs an ordering or scope judgment before dispatch."; false) ]
     +
     [ ($snapshot.secondmate_current.records // [])[]?
       | select(.provenance.selected == "structured-home")
       | . as $mate
       | ($mate.decisions_open // [])[]?
       | . as $decision
       | first(($mate.queued // [])[]? | select(.id == $decision.id)) as $record
       | (($record // {id:$decision.id,title:$decision.summary,priority:null,since:null,repo:null}) + {id:$decision.id}) as $record
       | (any(($mate.active_children // [])[]?; .id == $decision.id)) as $active
       | base_candidate((if $active then 1 else 3 end);
           (if $active then "active_intervention" else "blocked_captain_action" end);
           $mate.id; $record; null; $decision.id; ($record.title // $decision.summary);
           $decision.summary; $active) ]
     +
     [ ($snapshot.secondmate_current.records // [])[]?
       | select(.provenance.selected == "structured-home")
       | . as $mate
       | ($mate.queued // [])[]?
       | select((.unresolved_blocker_ids // []) | length == 0)
       | select(.captain_actionable != true and .hold_reason == null and .kind == "captain")
       | . as $record
       | base_candidate(4; "queued_judgment"; $mate.id; $record; null; .id; .title;
           "This queued captain-owned item needs an ordering or scope judgment before dispatch."; false) ]) as $forward
  | (([ $records[]?
         | select(.structured == true and .state == "queued")
         | select((.unresolved_blocker_ids // []) | length == 0)
         | select(.hold_reason == null and .kind != "captain") ]
       + [ $records[]?
           | select(.structured == true and .state == "in_flight")
           | . as $record
           | task_for(.id) as $task
           | select(($task.current_state.state // "unknown") != "paused")
           | select((($task.current_state.state // "unknown") == "done" and ($task.yolo // "off") != "on") | not) ]
       + [ ($snapshot.secondmate_current.records // [])[]?
           | select(.provenance.selected == "structured-home")
           | (.active_children // [])[]? ]) | length > 0) as $autonomous_forward
  | ([ $records[]?
       | select(.structured == true and .state == "done")
       | . as $record
       | task_for(.id) as $task
       | base_candidate(5; "closure"; "main"; $record; $task; .id; .title;
           "The accepted task is recorded Done, so it is no longer an execution item."; false) ]
    ) as $closures
  | (if ($forward | length) > 0 then $forward
     elif $autonomous_forward then []
     else $closures end
     | sort_by([.tier,.priority_rank,(-.downstream_released),.active_rank,.actionable_since,.sort_callsign,.canonical_id])) as $ranked
  | ($ranked[0] // null) as $selected
  | def consequence($c):
      if $c.kind == "active_intervention" then
        "Resolving this unlocks active work immediately" +
        (if $c.downstream_released > 0 then " and releases \($c.downstream_released) downstream task(s)." else "." end)
      elif $c.kind == "delivery_review" then
        "The completed delivery remains unlanded and cannot produce its intended outcome."
      elif $c.kind == "blocked_captain_action" then
        "Answering this releases the blocked work" +
        (if $c.downstream_released > 0 then " and \($c.downstream_released) dependent task(s)." else "." end)
      elif $c.kind == "queued_judgment" then
        "A clear choice lets Firstmate dispatch the right work without guessing about order, scope, cost, or risk."
      else
        "Execution is complete; only explicit closure into history remains."
      end;
  def recommendation($c):
      if $c.kind == "active_intervention" then
        "Decide this now. It is the fastest way to restart work already in motion."
      elif $c.kind == "delivery_review" then
        "Review and approve this delivery now. Finished value should land before new discretionary work starts."
      elif $c.kind == "blocked_captain_action" then
        "Clear this blocker now. It is the highest-ranked available captain action."
      elif $c.kind == "queued_judgment" then
        "Choose whether this should start next. The fleet should not guess where explicit judgment is required."
      else
        "Close this task rather than inventing follow-up work. Its accepted scope ended, and any new work requires separate authorization."
      end;
  def alternatives($c):
      if $c.kind == "active_intervention" or $c.kind == "blocked_captain_action" then
        "Defer it explicitly, accepting that this work and its dependents remain stopped."
      elif $c.kind == "delivery_review" then
        "Request a specific correction instead of landing it, or defer review and leave the completed value unshipped."
      elif $c.kind == "queued_judgment" then
        "Leave it queued and choose another item through /tasks."
      else
        "Authorize a concrete follow-up only if the durable task detail shows unfinished accepted scope or an open defect."
      end;
  def actions($c):
      if $c.kind == "closure" then
        ["/task \($c.ref)", "/close \($c.ref)", "/history \($c.ref)"]
      elif $c.kind == "delivery_review" then
        ["/task \($c.ref)"]
        + (if $c.artifact != null then ["Review \($c.artifact)"] else [] end)
        + [(if ($c.artifact // "" | test("/pull/[0-9]+")) then
              "Say: merge \($c.artifact), or request a specific correction"
            else "Say: land \($c.ref), or request a specific correction" end), "/next"]
      elif $c.kind == "queued_judgment" then
        ["/task \($c.ref)", "Say: start \($c.ref), or name the item that should precede it", "/next"]
      else
        ["/task \($c.ref)", "Answer the recorded captain call in chat", "/next"]
      end;
  def closure_context($c):
      if $c.kind != "closure" then null else
        {accepted_scope_ended:true,
         open_defect_or_authorized_follow_up:
           (if $c.durable_context == null then
              "No separate structured follow-up is recorded; verify the task detail before closing."
            else
              "Durable task notes were checked and still require human interpretation before closure: \($c.durable_context)"
            end),
         durable_outcome:($c.artifact // $c.name),
         knowledge_retained:
           (if $c.artifact != null then "The durable outcome is retained at \($c.artifact)."
            elif $c.durable_context != null then "The durable completion note remains in the task record."
            else "The completion remains in backlog history." end)}
      end;
  if $selected == null then
      {schema:"fm-next.v1",generated:$snapshot.generated,selection:null,
       ranking:{eligible:0,forward_eligible:($forward|length),closure_eligible:($closures|length),autonomous_forward_present:$autonomous_forward},
       card:"Fleet needs no captain action."}
    else
      ($selected + {consequence:consequence($selected),recommendation:recommendation($selected),
                    alternatives:alternatives($selected),actions:actions($selected),
                    closure_context:closure_context($selected)}) as $card
      | {schema:"fm-next.v1",generated:$snapshot.generated,selection:$card,
         ranking:{eligible:($ranked|length),forward_eligible:($forward|length),closure_eligible:($closures|length),autonomous_forward_present:$autonomous_forward,
                  order:["tier","priority","downstream_released","active","oldest_actionable_wait","callsign","canonical_id"]},
         card:
           ((if $card.kind == "closure" then
               "Ref: \($card.ref) - \($card.name)\nWhat completed: \($card.closure_context.durable_outcome)\nWhy it is not continuing: \($card.reason)\nClosure check: Accepted scope ended. \($card.closure_context.open_defect_or_authorized_follow_up) \($card.closure_context.knowledge_retained)\nWhat remains: \($card.consequence)"
             else
               "Ref: \($card.ref) - \($card.name)\nSituation: \($card.current_detail // $card.reason)\nWhy progress stopped: \($card.reason)\nConsequence: \($card.consequence)"
             end)
            + "\nRecommendation: \($card.recommendation)"
            + "\nAlternatives: \($card.alternatives)"
            + "\nActions:\n" + ($card.actions | map("- " + .) | join("\n")))}
    end
' 2>&1) || { printf 'fm-next: %s\n' "$RESULT" >&2; exit 1; }

# A live invocation composes the existing detail and closure owners after the
# deterministic ranker has selected exactly one current task. The --snapshot
# seam deliberately stays self-contained for repeatable tests and other views.
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
         elif ($line | startswith("- Continue existing task ")) and .mode == "follow-ups" then
           .follow_ups += [($line | ltrimstr("- Continue existing task "))]
         else . end)
      | del(.mode)
    ')
  fi
  RESULT=$(printf '%s\n' "$RESULT" | jq --argjson detail "$DETAIL" --argjson review "$CLOSURE_REVIEW" '
    .selection.task_detail = $detail
    | .selection.artifact = (.selection.artifact // $detail.artifacts[0] // null)
    | if .selection.kind == "closure" then
        .selection.closure_review = $review
        | .selection.closure_context.durable_outcome = ($review.result // $detail.outcome // .selection.name)
        | .selection.closure_context.open_defect_or_authorized_follow_up =
            (if (($review.follow_ups // []) | length) > 0 then
               "Authorized follow-up already exists: " + ($review.follow_ups | join(", "))
             else
               "The closure owner found no existing follow-up and will not create one automatically."
             end)
        | .selection.closure_context.knowledge_retained =
            (if (($review.retained // []) | length) > 0 then
               "Knowledge and task material will be retained at " + ($review.retained | join(", ")) + "."
             else "No retained material is recorded." end)
        | .selection.recommendation =
            (if (($review.follow_ups // []) | length) > 0 then
               "Close this completed scope and continue the already-authorized follow-up separately."
             else
               "Close this task rather than inventing follow-up work. Its accepted scope ended, and any new work requires separate authorization."
             end)
        | .selection.alternatives =
            "Do not close only if the task detail reveals unfinished accepted scope or an open defect in this task."
        | .card =
            ("Ref: \(.selection.ref) - \(.selection.name)"
             + "\nWhat completed: \(.selection.closure_context.durable_outcome)"
             + "\nWhy it is not continuing: \(.selection.reason)"
             + "\nClosure check: Accepted scope ended. \(.selection.closure_context.open_defect_or_authorized_follow_up) \(.selection.closure_context.knowledge_retained) \($review.cleanup)"
             + "\nWhat remains: \(.selection.consequence)"
             + "\nRecommendation: \(.selection.recommendation)"
             + "\nAlternatives: \(.selection.alternatives)"
             + "\nActions:\n" + (.selection.actions | map("- " + .) | join("\n")))
      else
        .card =
          ("Ref: \(.selection.ref) - \(.selection.name)"
           + "\nSituation: " + (($detail.outcome // .selection.current_detail // .selection.reason) | tostring)
           + (if ($detail.purpose // "") == "" then "" else " Purpose: " + $detail.purpose end)
           + "\nWhy progress stopped: " + (($detail.attention // .selection.reason) | tostring)
           + "\nConsequence: \(.selection.consequence)"
           + "\nRecommendation: \(.selection.recommendation)"
           + "\nAlternatives: \(.selection.alternatives)"
           + "\nActions:\n" + (.selection.actions | map("- " + .) | join("\n")))
      end
  ') || { echo "fm-next: could not compose selected task context" >&2; exit 1; }
fi

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$RESULT"
else
  printf '%s\n' "$RESULT" | jq -r '.card'
fi
