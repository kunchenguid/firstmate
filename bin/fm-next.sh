#!/usr/bin/env bash
# Choose the highest-value captain action and compose its preparation packet.
#
# Usage: fm-next.sh [--json] [--why|--debug] [--snapshot <path>|-]
#
# docs/task-lifecycle.md owns the boundary between deterministic fleet ranking,
# bounded read-only preparation, and the final captain handoff. This command is
# the deterministic CHOOSE owner: it composes fm-task-lifecycle.sh, excludes work
# Firstmate can continue autonomously, and ranks every eligible action without
# mutation. Schema fm-next.v4 keeps the selected task's PREPARE inputs separate
# from diagnostics. Normal text is a terse deterministic handoff seed; --why
# adds a concise selection explanation, while --debug emits structured ranking,
# candidate, and lifecycle diagnostics. Neither flag changes selection or state.
#
# Ranking, in order:
#   1. one concrete captain action that restarts work already under way;
#   2. one bounded action that can close a high-value open loop;
#   3. one unresolved decision that releases dependent work;
#   4. other captain attention that meaningfully advances authorized work;
#   5. archival closure, only when no forward work can move.
# Within one class: explicit priority, downstream work released, active before
# inactive, oldest wait, callsign, then canonical id.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_COMMAND="$SCRIPT_DIR/fm-fleet-snapshot.sh"
FORMAT=text
MODE=normal
SNAPSHOT_PATH=

usage() {
  awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --why)
      [ "$MODE" = normal ] || { echo "fm-next: --why and --debug are mutually exclusive" >&2; exit 2; }
      MODE=why
      ;;
    --debug)
      [ "$MODE" = normal ] || { echo "fm-next: --why and --debug are mutually exclusive" >&2; exit 2; }
      MODE=debug
      ;;
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
         repository_state:{projectLabel:($record.repo // null),projectPath:($task.project // null),
           worktreePath:($task.paths.worktree.path // null),worktreePresent:($task.paths.worktree.present // false),git:($record.repository_state.git // null)},
         existing_result:{summary:($record.completion_evidence.summary // $row.outcome // $task.current_state.detail // null),
           report:($task.paths.report // (if ($record.report_path // "") == "" then null else {path:$record.report_path,present:null} end)),
           contentExcerpt:($record.existing_result.contentExcerpt // null)},
         closure_review:($record.closure_review // null),
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
  | {schema:"fm-next.v4",generated:$snapshot.generated,selection:($ranked[0] // null),
     _candidates:$ranked,
     _diagnostics:{ranking:{eligible:($ranked|length),forwardEligible:($forward|length),closureEligible:($closures|length),
       autonomousForwardPresent:$autonomous_forward,
       order:["captain_value_class","priority","downstream_released","active","oldest_actionable_wait","callsign","canonical_id"]}}}
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
  REPORT_EXCERPT=null
  REPORT_FILE="${FM_DATA_OVERRIDE:-${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}/data}/$SELECTED_ID/report.md"
  if [ -f "$REPORT_FILE" ] && [ ! -L "$REPORT_FILE" ]; then
    REPORT_EXCERPT=$(head -c 16384 "$REPORT_FILE" | jq -R -s '.') \
      || { echo "fm-next: could not read the selected result" >&2; exit 1; }
  fi
  REPOSITORY_GIT=null
  WORKTREE=$(printf '%s\n' "$RESULT" | jq -r '.selection.repository_state.worktreePath // empty')
  if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] \
     && git -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BRANCH=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    TRACKED_CHANGES=true
    if git -C "$WORKTREE" --no-pager diff --quiet --no-ext-diff -- \
       && git -C "$WORKTREE" --no-pager diff --cached --quiet --no-ext-diff --; then
      TRACKED_CHANGES=false
    fi
    REPOSITORY_GIT=$(jq -n --arg branch "$BRANCH" --argjson trackedChanges "$TRACKED_CHANGES" \
      '{branch:(if $branch == "" then null else $branch end),trackedChanges:$trackedChanges}')
  fi
  RESULT=$(printf '%s\n' "$RESULT" | jq --argjson detail "$DETAIL" --argjson closureReview "$CLOSURE_REVIEW" \
    --argjson reportExcerpt "$REPORT_EXCERPT" --argjson repositoryGit "$REPOSITORY_GIT" '
    .selection.task_detail=$detail
    | .selection.artifact=(.selection.artifact // $detail.artifacts[0] // null)
    | .selection.artifact_type=($detail.completionEvidence.artifactType // .selection.artifact_type)
    | .selection.review_plan=(.selection.review_plan // $detail.reviewPlan)
    | .selection.completion_evidence=(.selection.completion_evidence // $detail.completionEvidence)
    | .selection.requirements=(.selection.requirements * ($detail.requirements // {}))
    | .selection.repository_state.git=$repositoryGit
    | .selection.existing_result=(.selection.existing_result * {summary:$detail.completionEvidence.summary,
        report:(if ($detail.artifacts | map(select(test("/report\\.md$"))) | length) > 0
          then {path:($detail.artifacts | map(select(test("/report\\.md$")))[0]),present:true}
          else .selection.existing_result.report end),contentExcerpt:$reportExcerpt})
    | if .selection.kind == "closure" then .selection.closure_review=$closureReview else . end
    | ._candidates[0]=.selection
  ') || { echo "fm-next: could not compose selected task evidence" >&2; exit 1; }
fi

RESULT=$(printf '%s\n' "$RESULT" | jq -e --arg mode "$MODE" '
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
  def evidence($c):
    ($c.completion_evidence // {}) as $e
    | text($e.summary; text($c.existing_result.summary; text($c.current_detail; $c.reason)));
  def intent($c): text($c.requirements.captainIntent; text($c.durable_context; $c.name));
  def artifact_locations($c):
    ([$c.artifact, $c.existing_result.report.path]
      + ($c.completion_evidence.artifacts // []) + ($c.task_detail.artifacts // []))
    | map(select(. != null and . != "")) | unique;
  def location($c):
    (artifact_locations($c)) as $locations
    | if ($locations | length) > 0 then $locations[0]
      elif ($c.repository_state.worktreePath // "") != "" then $c.repository_state.worktreePath
      else null end;
  def credential($c):
    (text($c.reason; "") | test("credential|token|log[ -]?in|authentication|api[ -]?key|secret"; "i"));
  def approval($c):
    (text($c.reason; "") | test("approve|approval|authorize|permission|consent"; "i"));
  def approval_action($c):
    if (text($c.reason; "") | test("^approve[[:space:]]+"; "i")) then
      "Approve or decline " + (text($c.reason; "") | sub("^[Aa]pprove[[:space:]]+"; ""))
    elif (text($c.reason; "") | test("^authorize[[:space:]]+"; "i")) then
      "Authorize or decline " + (text($c.reason; "") | sub("^[Aa]uthorize[[:space:]]+"; ""))
    else "Approve or decline " + $c.name end;
  def action($c):
    (phase_plan($c)) as $plan
    | if $c.kind == "captain_action" then
        if credential($c) then "Complete the login for " + $c.name
        elif approval($c) then approval_action($c)
        else text($c.reason; "Answer the open question for " + $c.name) end
      elif $c.kind == "queued_choice" then "Choose whether to start " + $c.name
      elif $c.kind == "review" or $c.kind == "acceptance" then
        text($plan.action; if location($c) == null then "Locate the result for " + $c.name else "Check " + $c.name end)
      elif $c.kind == "delivery" then text($plan.action; "Approve or decline delivery of " + $c.name)
      elif $c.kind == "monitoring" then text($plan.action; "Check " + $c.name)
      else "Authorize closing " + $c.name end;
  def context($c):
    (phase_plan($c)) as $plan
    | if ($plan.context // "") != "" then text($plan.context; evidence($c))
      elif $c.kind == "captain_action" then
        if ($c.completion_evidence.summary // "") != "" then text($c.completion_evidence.summary; "")
        else "I checked the task context; this input is the only remaining step before work can resume." end
      elif $c.kind == "queued_choice" then "I checked the ready work; only the start choice remains."
      elif $c.kind == "review" or $c.kind == "acceptance" then
        if location($c) == null then "I found no readable result or task-specific review evidence, so I could not reduce the check further."
        else "I gathered the available result and verification evidence; the remaining uncertainty is below." end
      elif $c.kind == "delivery" then "I checked the accepted result and delivery evidence; only explicit approval remains."
      elif $c.kind == "monitoring" then "I gathered the available post-delivery evidence; the remaining physical check is below."
      else
        "I preflighted retention and cleanup: "
        + text($c.closure_review.result; evidence($c))
        + (if ($c.closure_review.cleanup // "") == "" then "." else "; " + text($c.closure_review.cleanup; "") + "." end)
      end;
  def instruction($c):
    (phase_plan($c)) as $plan
    | if (($plan.checks // []) | length) > 0 then ($plan.checks | map(text(.; "")) | join(" "))
      elif $c.kind == "captain_action" and credential($c) then
        text($c.reason; "Complete the named login.") + " Do not paste a secret into chat."
      elif $c.kind == "captain_action" then text($c.reason; "Provide the exact choice needed to resume work.")
      elif $c.kind == "queued_choice" then "Choose `start " + $c.ref + "` or name the work that should come first."
      elif $c.kind == "review" or $c.kind == "acceptance" then
        if location($c) == null then "Send the result location or result needed to check: " + intent($c)
        else "At " + location($c) + ", check only this remaining uncertainty: " + intent($c) end
      elif $c.kind == "delivery" then
        if location($c) == null then "Approve or decline delivery of the accepted result."
        else "At " + location($c) + ", approve or decline delivery of the accepted result." end
      elif $c.kind == "monitoring" then "Check the delivered behavior against the recorded health target."
      else "Authorize closing and cleanup for " + $c.name + "." end;
  def response($c):
    (action($c) + " " + instruction($c)) as $surface
    | if $c.kind == "captain_action" and credential($c) then "Reply `ready` when access works, or send the non-secret error."
      elif $c.kind == "captain_action" and approval($c) then "Reply `approve` or `decline: <reason>`."
      elif $c.kind == "captain_action" or $c.kind == "queued_choice" then "Reply with the choice."
      elif ($c.kind == "review" or $c.kind == "acceptance") and ($surface | test("visual|browser|screen|layout|dashboard|lavish"; "i")) then
        "Reply `looks good`, or name the first visible mismatch."
      elif $c.kind == "review" or $c.kind == "acceptance" then "Reply `works`, or send the observed failure."
      elif $c.kind == "delivery" then "Reply `approve` or `decline: <reason>`."
      elif $c.kind == "monitoring" then "Reply `healthy`, or send the observed failure."
      else "Reply `close` to authorize cleanup, or name what must stay open." end;
  def why($c; $other_count):
    (if $c.class == "restart" then "This is the smallest action that restarts work already under way."
     elif $c.class == "close_loop" then "This bounded check can close the highest-value open loop."
     elif $c.class == "dependency_release" then "This decision releases dependent work."
     elif $c.class == "advance" then "This is the highest-value captain action that advances authorized work."
     else "No forward work can move, so closing completed work is the most useful remaining action." end)
    + (if $c.downstream_released > 0 then " It unlocks \($c.downstream_released) dependent task(s)." else "" end)
    + (if $other_count > 0 then " It ranked ahead of \($other_count) other eligible action(s)."
       else " No other captain action is eligible now." end);
  def preparation($c):
    (phase_plan($c)) as $plan
    | (artifact_locations($c)) as $artifacts
    | {schema:"fm-next-prepare.v1",
       intent:$c.requirements,
       plan:$plan,
       lifecycle:{status:$c.status,currentState:$c.current_state,currentDetail:$c.current_detail,
         route:$c.route,closeReady:$c.close_ready,evidence:$c.lifecycle},
       artifacts:{type:$c.artifact_type,locations:$artifacts},
       repository:$c.repository_state,
       existingResult:(($c.existing_result // {}) + {summary:evidence($c),closurePreflight:$c.closure_review}),
       missingEvidence:([
         if ($c.requirements.captainIntent // "") == "" then "captain intent" else empty end,
         if (($c.kind == "review" or $c.kind == "acceptance") and $plan == null) then "task-specific review plan" else empty end,
         if (($c.kind == "review" or $c.kind == "acceptance") and ($artifacts | length) == 0) then "readable result location" else empty end
       ])};
  def compact_alternative($c): {ref:$c.ref,name:$c.name,action:action($c)};
  def diagnostic_candidate($c):
    {ref:$c.ref,name:$c.name,canonicalId:$c.canonical_id,owner:$c.owner,kind:$c.kind,
     rank:{class:$c.rank_class,valueClass:$c.class,priority:$c.priority,priorityRank:$c.priority_rank,
       downstreamReleased:$c.downstream_released,active:$c.active,actionableSince:$c.actionable_since,
       callsign:$c.sort_callsign,canonicalId:$c.canonical_id},
     lifecycle:{status:$c.status,currentState:$c.current_state,currentDetail:$c.current_detail,
       route:$c.route,closeReady:$c.close_ready,evidence:$c.lifecycle},reason:$c.reason};
  . as $root
  | if $root.selection == null then
      .mode=$mode
      | .selection=null
      | .presentation={title:"Nothing needs your attention right now.",identity:null,context:[],instruction:null,response:null}
      | .card="Nothing needs your attention right now."
      | if $mode == "why" then
          .explanation={summary:"No captain action is eligible now.",alternatives:[]}
          | .card += "\n\nWhy this\nNo captain action is eligible now."
        else . end
      | if $mode == "debug" then
          .diagnostics=(._diagnostics + {candidates:(._candidates | map(diagnostic_candidate(.)))})
        else . end
      | del(._candidates,._diagnostics)
    else
      ($root.selection) as $selected
      | (action($selected)) as $title
      | (context($selected)) as $context
      | (instruction($selected)) as $instruction
      | (response($selected)) as $response
      | (preparation($selected)) as $preparation
      | .mode=$mode
      | .selection={ref:$selected.ref,name:$selected.name,canonicalId:$selected.canonical_id,
          owner:$selected.owner,kind:$selected.kind,actionTitle:$title,preparation:$preparation}
      | .presentation={title:$title,identity:($selected.ref + " · " + $selected.name),
          context:[$context],instruction:$instruction,response:$response}
      | .card=($title + "\n" + $selected.ref + " · " + $selected.name
          + "\n\n" + $context + "\n\n" + $instruction + "\n\n" + $response)
      | if $mode == "why" then
          why($selected; (($root._diagnostics.ranking.eligible // 1) - 1)) as $reason
          | ($root._candidates[1:3] | map(compact_alternative(.))) as $alternatives
          | .explanation={summary:$reason,alternatives:$alternatives}
          | .card += "\n\nWhy this\n" + $reason
              + (if ($alternatives | length) == 0 then "" else
                  "\nConsidered next: " + ($alternatives | map(.ref + " · " + .name) | join("; ")) end)
        else . end
      | if $mode == "debug" then
          .diagnostics=($root._diagnostics + {candidates:($root._candidates | map(diagnostic_candidate(.)))})
          | .selection |= del(.preparation)
        else . end
      | del(._candidates,._diagnostics)
    end
' 2>&1) || { printf 'fm-next: %s\n' "$RESULT" >&2; exit 1; }

if [ "$FORMAT" = json ] || [ "$MODE" = debug ]; then
  printf '%s\n' "$RESULT"
else
  printf '%s\n' "$RESULT" | jq -r '.card'
fi
