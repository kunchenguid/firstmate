#!/usr/bin/env bash
# Select and render the highest-value concrete action for the captain.
#
# Usage: fm-next.sh [--json] [--snapshot <path>|-]
#
# docs/task-lifecycle.md owns the boundary between deterministic fleet ranking
# and human-action translation. This command composes fm-task-lifecycle.sh,
# excludes work Firstmate can continue autonomously, ranks every eligible action
# without mutation, and then renders the selected action from durable task
# intent, review-plan, completion, artifact, and blocker evidence. It never
# treats a possible review outcome as an alternative action.
#
# Ranking, in order:
#   1. one concrete captain action that restarts work already under way;
#   2. one bounded action that can close a high-value open loop;
#   3. one unresolved decision that releases dependent work;
#   4. other captain attention that meaningfully advances authorized work;
#   5. archival closure, only when no forward work can move.
# Within one class: explicit priority, downstream work released, active before
# inactive, oldest wait, callsign, then canonical id. At most two lower-ranked
# candidates are shown as genuine alternative actions from that same set.
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
  def priority_rank($priority):
      if $priority == null or $priority == "" then 5 else (($priority | tonumber?) // 5) end;
  def wait_key($record; $fallback):
      ($record.hold_set // $record.since // $record.completion.date // $record.done // $record.merged // $record.reported // $fallback // "9999-12-31");
  def downstream_count($id):
      [$records[]? | select(.structured == true and .state != "done")
       | select(((.unresolved_blocker_ids // .blocked_by_ids // []) | index($id)) != null)] | length;
  def artifact_for($record; $task):
      ($task.pr.url // $record.pr_url // $record.report_path // $record.local_note // ($record.links // [])[0] // null);
  def artifact_type($record; $task):
      if ($task.pr.url // $record.pr_url // "") != "" then "pull request"
      elif ($record.report_path // "") != "" then "report"
      elif ($task.mode // "") == "local-only" then "local branch"
      elif artifact_for($record; $task) != null then "artifact"
      else "candidate result" end;
  def canonical_ref($owner; $id):
      if $owner == "main" or ($id | startswith($owner + "/")) then $id else ($owner + "/" + $id) end;
  def base($rank_class; $class; $kind; $owner; $record; $task; $row; $id; $title; $reason; $active):
      (callsign_for($owner; $id)) as $call
      | (canonical_ref($owner; $id)) as $canonical
      | {rank_class:$rank_class,class:$class,kind:$kind,owner:$owner,
         ref:($call.ref // $canonical),canonical_id:$canonical,id:$id,
         name:clean(($call.name // $title); $id),
         sort_callsign:(($call.ref // "") | ltrimstr("t") | tonumber? // 1000),
         priority:($record.priority // null),priority_rank:priority_rank($record.priority // null),
         downstream_released:downstream_count($id),active:$active,active_rank:(if $active then 0 else 1 end),
         actionable_since:wait_key($record; $snapshot.generated),
         reason:clean($reason; "The task needs one concrete captain action."),
         current_state:($task.current_state.state // null),current_detail:($row.outcome // $task.current_state.detail // null),
         status:($row.status // null),route:($row.route // null),close_ready:($row.close_ready // false),
         lifecycle:($row.lifecycle // null),repo:($record.repo // $task.project // null),
         standing_landing_authority:(($task.yolo // "off") == "on"),
         artifact:artifact_for($record; $task),artifact_type:artifact_type($record; $task),
         review_plan:($record.review_plan // $row.lifecycle.reviewPlan // null),
         completion_evidence:($record.completion_evidence // $row.lifecycle.completionEvidence // null),
         requirements:{captainIntent:($record.captain_intent // null),firstmateSpec:($record.firstmate_spec // null)},
         durable_context:($record.body_excerpt // null)};
  def phase_kind($row):
      if $row.status == "done" then "review"
      elif $row.status == "reviewing" then "acceptance"
      elif $row.status == "monitoring" then "monitoring"
      elif $row.status == "delivering" and $row.route == "deliver-monitor" and ($row.lifecycle.delivery.completedAt // "") != "" then "monitoring"
      else "delivery" end;
  def meaningful_plan($phase):
      if $phase == null then null
      elif (($phase.action // "") != "" or ($phase.context // "") != "" or (($phase.checks // []) | length) > 0
        or ($phase.success // "") != "" or ($phase.failure // "") != "" or ($phase.continue // "") != "" or ($phase.fix // "") != "") then $phase
      else null end;
  def phase_plan($record; $row; $kind):
      ($record.review_plan // $row.lifecycle.reviewPlan // null) as $plan
      | (if $kind == "review" or $kind == "acceptance" then $plan.review
         elif $kind == "delivery" then $plan.delivery
         elif $kind == "monitoring" then $plan.monitoring
         else null end) | meaningful_plan(.);
  ([ $records[]?
       | select(.structured == true)
       | . as $record | task_for(.id) as $task | life_for(.id) as $row
       | select($row != null and $row.status == "needs-you")
       | (downstream_count(.id)) as $released
       | if .state == "in_flight" then
           base(1;"restart";"captain_action";"main";$record;$task;$row;.id;.title;$row.outcome;true)
         elif $released > 0 then
           base(3;"dependency_release";"captain_action";"main";$record;$task;$row;.id;.title;$row.outcome;false)
         else
           base(4;"advance";"captain_action";"main";$record;$task;$row;.id;.title;$row.outcome;false)
         end ]
   + [ $records[]?
       | select(.structured == true and .state == "queued" and .kind == "captain")
       | . as $record | task_for(.id) as $task | life_for(.id) as $row
       | select($row != null and $row.status == "queued")
       | base(4;"advance";"queued_choice";"main";$record;$task;$row;.id;.title;
           "Authorized work is waiting for an ordering decision.";false) ]
   + [ $records[]?
       | select(.structured == true)
       | . as $record | task_for(.id) as $task | life_for(.id) as $row
       | select($row != null and ($row.status == "done" or $row.status == "reviewing"))
       | base(2;"close_loop";phase_kind($row);"main";$record;$task;$row;.id;.title;$row.outcome;(.state == "in_flight")) ]
   + [ $records[]?
       | select(.structured == true)
       | . as $record | task_for(.id) as $task | life_for(.id) as $row
       | select($row != null and ($row.status == "accepted" or $row.status == "delivering" or $row.status == "monitoring"))
       | select($row.close_ready != true)
       | (phase_kind($row)) as $kind
       | select(phase_plan($record;$row;$kind) != null or ($kind == "delivery" and (($task.yolo // "off") != "on")))
       | base(4;"advance";$kind;"main";$record;$task;$row;.id;.title;$row.outcome;(.state == "in_flight")) ]
   + [ ($snapshot.secondmate_current.records // [])[]?
       | select(.provenance.selected == "structured-home") | . as $mate
       | ($mate.decisions_open // [])[]? | . as $decision
       | first(($mate.queued // [])[]? | select(.id == $decision.id)) as $found
       | (($found // {id:$decision.id,title:$decision.summary,priority:null,since:null,repo:null}) + {id:$decision.id}) as $record
       | (any(($mate.active_children // [])[]?; .id == $decision.id)) as $active
       | if $active then
           base(1;"restart";"captain_action";$mate.id;$record;null;null;$decision.id;($record.title // $decision.summary);$decision.summary;true)
         else
           base(4;"advance";"captain_action";$mate.id;$record;null;null;$decision.id;($record.title // $decision.summary);$decision.summary;false)
         end ]
   + [ ($snapshot.secondmate_current.records // [])[]?
       | select(.provenance.selected == "structured-home") | . as $mate
       | ($mate.queued // [])[]?
       | select((.unresolved_blocker_ids // []) | length == 0)
       | select(.captain_actionable != true and .hold_reason == null and .kind == "captain")
       | . as $record
       | base(4;"advance";"queued_choice";$mate.id;$record;null;null;.id;.title;
           "Authorized work is waiting for an ordering decision.";false) ]) as $forward
  | (any($lifecycleRows[]?;
       .status == "working" or .status == "queued"
       or ((.status == "accepted" or .status == "delivering" or .status == "monitoring") and .close_ready != true))
     or any(($snapshot.secondmate_current.records // [])[]?; ((.active_children // []) | length) > 0)) as $autonomous_forward
  | ([ $records[]?
       | select(.structured == true) | . as $record | task_for(.id) as $task | life_for(.id) as $row
       | select($row != null and $row.close_ready == true)
       | base(5;"closure";"closure";"main";$record;$task;$row;.id;.title;
           "The accepted result is complete and only archival closure remains.";false) ]) as $closures
  | (if ($forward | length) > 0 then $forward elif $autonomous_forward then [] else $closures end
     | sort_by([.rank_class,.priority_rank,(-.downstream_released),.active_rank,.actionable_since,.sort_callsign,.canonical_id])) as $ranked
  | {schema:"fm-next.v3",generated:$snapshot.generated,selection:($ranked[0] // null),
     alternatives:($ranked[1:3] // []),
     ranking:{eligible:($ranked|length),forward_eligible:($forward|length),closure_eligible:($closures|length),
       autonomous_forward_present:$autonomous_forward,
       order:["captain_value_class","priority","downstream_released","active","oldest_actionable_wait","callsign","canonical_id"]}}
' 2>&1) || { printf 'fm-next: %s\n' "$RESULT" >&2; exit 1; }

# Live output enriches only the already-selected main-home task. The ranking is
# complete before this read, so richer prose can never change the winner.
if [ -z "$SNAPSHOT_PATH" ] && [ "$(printf '%s\n' "$RESULT" | jq -r '.selection != null and .selection.owner == "main"')" = true ]; then
  SELECTED_ID=$(printf '%s\n' "$RESULT" | jq -r '.selection.canonical_id')
  DETAIL=$(FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}" \
    FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}" \
    "$SCRIPT_DIR/fm-task.sh" --json "$SELECTED_ID") \
    || { echo "fm-next: selected task detail became unavailable; retry" >&2; exit 1; }
  CLOSURE_REVIEW=null
  if [ "$(printf '%s\n' "$RESULT" | jq -r '.selection.kind')" = closure ]; then
    REVIEW_TEXT=$(FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}" \
      FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}" \
      "$SCRIPT_DIR/fm-close.sh" --review "$SELECTED_ID") \
      || { echo "fm-next: closure review refused for the selected task" >&2; exit 1; }
    CLOSURE_REVIEW=$(printf '%s\n' "$REVIEW_TEXT" | jq -R -s '
      reduce (split("\n")[]) as $line
        ({mode:null,result:null,retained:[],follow_ups:[],cleanup:null};
         if ($line | startswith("Result: ")) then .result = ($line | ltrimstr("Result: "))
         elif $line == "Retained knowledge and task material:" then .mode = "retained"
         elif ($line | startswith("Next-work recommendations:")) then .mode = "follow-ups"
         elif (($line | startswith("Cleanup:")) or ($line | startswith("Cleanup blocker:"))) then .cleanup = $line | .mode = null
         elif ($line | startswith("Review only:")) then .mode = null
         elif ($line | startswith("- ")) and .mode == "retained" then .retained += [($line | ltrimstr("- "))]
         elif ($line | startswith("- Continue existing task ")) and .mode == "follow-ups" then .follow_ups += [($line | ltrimstr("- Continue existing task "))]
         else . end) | del(.mode)')
  fi
  RESULT=$(printf '%s\n' "$RESULT" | jq --argjson detail "$DETAIL" --argjson closureReview "$CLOSURE_REVIEW" '
    .selection.task_detail=$detail
    | .selection.artifact=(.selection.artifact // $detail.artifacts[0] // null)
    | .selection.artifact_type=($detail.completionEvidence.artifactType // .selection.artifact_type)
    | .selection.review_plan=(.selection.review_plan // $detail.reviewPlan)
    | .selection.completion_evidence=(.selection.completion_evidence // $detail.completionEvidence)
    | .selection.requirements=(.selection.requirements * ($detail.requirements // {}))
    | if .selection.kind == "closure" then .selection.closure_review=$closureReview else . end
  ') || { echo "fm-next: could not compose selected task evidence" >&2; exit 1; }
fi

RESULT=$(printf '%s\n' "$RESULT" | jq -e '
  def text($value; $fallback):
    ($value // "") as $v
    | if ($v | type) != "string" or ($v | length) == 0 then $fallback
      else ($v | gsub("[\\r\\n\\t]+"; " ") | gsub("  +"; " ")
        | gsub("\\b[0-9a-fA-F]{7,40}\\b"; "[revision]")
        | gsub("no-mistakes|direct-PR|local-only"; "selected delivery path")) end;
  def meaningful_plan($phase):
    if $phase == null then null
    elif (($phase.action // "") != "" or ($phase.context // "") != "" or (($phase.checks // []) | length) > 0
      or ($phase.success // "") != "" or ($phase.failure // "") != "" or ($phase.continue // "") != "" or ($phase.fix // "") != "") then $phase
    else null end;
  def phase_plan($c):
    (if $c.kind == "review" or $c.kind == "acceptance" then $c.review_plan.review
     elif $c.kind == "delivery" then $c.review_plan.delivery
     elif $c.kind == "monitoring" then $c.review_plan.monitoring
     else null end) | meaningful_plan(.);
  def evidence($c): ($c.completion_evidence // {}) as $e | text($e.summary; text($c.current_detail; $c.reason));
  def intent($c): text($c.requirements.captainIntent; text($c.durable_context; $c.name));
  def location($c):
    if ($c.artifact // "") != "" then $c.artifact
    elif $c.artifact_type == "local branch" then "the ready local branch"
    else "the recorded task result" end;
  def credential($c): ($c.reason | test("credential|token|log[ -]?in|authentication|api[ -]?key|secret"; "i"));
  def approval($c): ($c.reason | test("approve|approval|authorize|permission|consent"; "i"));
  def approval_action($c):
    if ($c.reason | test("^approve[[:space:]]+"; "i")) then
      "Approve or decline " + ($c.reason | sub("^[Aa]pprove[[:space:]]+"; ""))
    elif ($c.reason | test("^authorize[[:space:]]+"; "i")) then
      "Authorize or decline " + ($c.reason | sub("^[Aa]uthorize[[:space:]]+"; ""))
    else "Approve or decline " + $c.name end;
  def action($c):
    (phase_plan($c)) as $plan
    | if $c.kind == "captain_action" then
        if credential($c) then "Provide the credential or login needed for " + $c.name
        elif approval($c) then approval_action($c)
        else text($c.reason; "Answer the open question for " + $c.name) end
      elif $c.kind == "queued_choice" then "Decide whether " + $c.name + " should start now"
      elif $c.kind == "review" then text($plan.action; "Inspect the " + $c.artifact_type + " for " + $c.name)
      elif $c.kind == "acceptance" then text($plan.action; "Finish checking " + $c.name)
      elif $c.kind == "delivery" then text($plan.action; "Approve or decline delivery of " + $c.name)
      elif $c.kind == "monitoring" then text($plan.action; "Check " + $c.name + " after delivery")
      else "Close " + $c.name end;
  def context($c):
    (phase_plan($c)) as $plan
    | if ($plan.context // "") != "" then text($plan.context; evidence($c))
      elif $c.kind == "captain_action" then "Work has stopped because " + text($c.reason; evidence($c)) + "."
      elif $c.kind == "queued_choice" then "The work is authorized but has not started; the remaining question is whether it is the best use of attention now."
      elif $c.kind == "review" then evidence($c) + ". The " + $c.artifact_type + " is ready for the checks below."
      elif $c.kind == "acceptance" then evidence($c) + ". Complete the checks below before choosing an outcome."
      elif $c.kind == "delivery" then evidence($c) + ". The accepted result is waiting on the delivery decision below."
      elif $c.kind == "monitoring" then evidence($c) + ". Use the recorded observation checks below to decide whether it is healthy."
      else text($c.closure_review.result; evidence($c)) + ". The accepted work is complete and ready to archive." end;
  def missing_review_check($c):
    "Open " + location($c) + " and answer one question: does it satisfy this recorded intent - " + intent($c) + "?";
  def checks($c):
    (phase_plan($c)) as $plan
    | if (($plan.checks // []) | length) > 0 then $plan.checks | map(text(.; ""))
      elif $c.kind == "captain_action" and credential($c) then
        [text($c.reason; "Complete the named login or credential step."), "Complete the credential step without pasting a secret into chat."]
      elif $c.kind == "captain_action" and approval($c) then
        [text($c.reason; "Review the approval request."), "Reply with approve or decline and name any constraint that must be preserved."]
      elif $c.kind == "captain_action" then
        [text($c.reason; "Read the open question."), "Reply with the exact choice or information needed to resume the work."]
      elif $c.kind == "queued_choice" then
        ["Compare this task with the work already under way.", "Reply with start " + $c.ref + ", or name the task that should come first."]
      elif $c.kind == "review" or $c.kind == "acceptance" then [missing_review_check($c)]
      elif $c.kind == "delivery" then
        [(if ($c.artifact // "") != "" then "Open " + $c.artifact + " and confirm it is the accepted result." else "Confirm the accepted result matches the recorded task." end),
         "Reply with approve or decline; if declining, name the first concrete correction."]
      elif $c.kind == "monitoring" then
        ["Inspect the recorded post-delivery evidence and answer whether the delivered behavior is healthy."]
      else ["Run /task " + $c.ref + " and confirm the recorded scope is complete.", "Run /close " + $c.ref + "."] end;
  def success($c):
    (phase_plan($c)) as $plan
    | if ($plan.success // "") != "" then text($plan.success; "")
      elif $c.kind == "captain_action" then "The requested answer, approval, or credential step is complete and the stopped work can resume."
      elif $c.kind == "queued_choice" then "The task either has a clear start instruction or a named reason to wait."
      elif $c.kind == "review" or $c.kind == "acceptance" then "Every recorded requirement is visibly satisfied."
      elif $c.kind == "delivery" then "The accepted result has an explicit deliver or do-not-deliver decision."
      elif $c.kind == "monitoring" then "The recorded health checks pass for the required observation window."
      else "The task is archived and its retained result remains available through /history." end;
  def failure($c):
    (phase_plan($c)) as $plan
    | if ($plan.failure // "") != "" then text($plan.failure; "")
      elif $c.kind == "captain_action" then "The requested action cannot be completed; state the missing access or unresolved choice."
      elif $c.kind == "queued_choice" then "A higher-value prerequisite is identified and named instead."
      elif $c.kind == "review" or $c.kind == "acceptance" then "A recorded requirement does not match the result; name the first concrete mismatch."
      elif $c.kind == "delivery" then "Delivery should not proceed; name the first concrete correction."
      elif $c.kind == "monitoring" then "A health check fails; name the observed regression."
      else "The detail reveals unfinished accepted scope; keep it open and name that scope." end;
  def why($c; $other_count):
    (if $c.class == "restart" then "It is the smallest captain action that restarts work already under way."
     elif $c.class == "close_loop" then "It is a bounded check that can close a high-value open loop."
     elif $c.class == "dependency_release" then "It resolves a decision that releases dependent work."
     elif $c.class == "advance" then "It is the highest-value remaining action that moves authorized work forward."
     else "No forward work can move, so closing completed work is the most useful remaining action." end)
    + (if $c.downstream_released > 0 then " It unlocks \($c.downstream_released) dependent task(s)."
       elif $c.class == "restart" then " Completing it lets the stopped work continue."
       elif $c.class == "close_loop" then " Completing it decides whether the finished result can move on or needs one correction."
       elif $c.class == "advance" then " Completing it moves the selected task to its next authorized step."
       else " Completing it clears finished work from active attention." end)
    + (if $other_count > 0 then " It outranks \($other_count) other action(s) available now."
       else " No other captain action is available now." end);
  def outcomes($c):
    (phase_plan($c)) as $plan
    | if $c.kind == "review" or $c.kind == "acceptance" then
        [{label:"ACCEPT",text:(success($c) + " Record acceptance and let the selected follow-through proceed.")},
         {label:"CONTINUE",text:text($plan.continue; "Keep inspecting only if the evidence is inconclusive, and name what is still missing.")},
         {label:"FIX",text:text($plan.fix; failure($c))}]
      elif $c.kind == "captain_action" then
        [{label:"CONTINUE",text:success($c)},
         {label:"DEFER",text:"State the deferral explicitly; the affected work stays stopped."}]
      elif $c.kind == "queued_choice" then
        [{label:"START",text:"Start this task now."},{label:"WAIT",text:"Name the higher-value work that should precede it."}]
      elif $c.kind == "delivery" then
        [{label:"DELIVER",text:success($c)},{label:"FIX",text:text($plan.fix; failure($c))}]
      elif $c.kind == "monitoring" then
        [{label:"HEALTHY",text:success($c)},
         {label:"CONTINUE",text:text($plan.continue; "Continue observing because the evidence is not yet conclusive.")},
         {label:"FIX",text:text($plan.fix; failure($c))}]
      else [{label:"CLOSE",text:success($c)},{label:"KEEP OPEN",text:failure($c)}] end;
  def compact_alternative($c): {ref:$c.ref,name:$c.name,action:action($c)};
  if .selection == null then .card="Fleet needs no captain action."
  else
    . as $root
    | .selection as $selected
    | ($root.ranking.eligible - 1) as $other_count
    | .selection += {action:action($selected),context:context($selected),checks:checks($selected),
        done_when:{success:success($selected),failure:failure($selected)},why:why($selected;$other_count),outcomes:outcomes($selected)}
    | .alternatives |= map(compact_alternative(.))
    | .selection as $card
    | .card=("NEXT — " + $card.action
      + "\nTASK " + $card.ref + " - " + $card.name
      + "\n\n" + $card.context
      + "\n\nDO THIS\n" + ($card.checks | to_entries | map("\(.key + 1). \(.value)") | join("\n"))
      + "\n\nDONE WHEN\n- SUCCESS: " + $card.done_when.success
      + "\n- FAILURE: " + $card.done_when.failure
      + "\n\nWHY THIS\n" + $card.why
      + "\n\nPOSSIBLE OUTCOMES\n" + ($card.outcomes | map("- " + .label + ": " + .text) | join("\n"))
      + (if (.alternatives | length) == 0 then "" else
          "\n\nOTHER WORTHWHILE ACTIONS\n" + (.alternatives | to_entries | map("\(.key + 1). \(.value.ref) - \(.value.action)") | join("\n")) end))
  end
' 2>&1) || { printf 'fm-next: %s\n' "$RESULT" >&2; exit 1; }

if [ "$FORMAT" = json ]; then printf '%s\n' "$RESULT"; else printf '%s\n' "$RESULT" | jq -r '.card'; fi
