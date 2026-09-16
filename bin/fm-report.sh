#!/usr/bin/env bash
# Render the durable Markdown fleet report written into normal conversation history.
#
# Usage: fm-report.sh [--command <report|bearings>] [--include-prs]
#        fm-report.sh [--command <report|bearings>] --snapshot <fm-bearings.v1.json> --lifecycle <rows.json> --history <rows.json>
#
# The live path composes the existing bearings projection, captain-facing task
# lifecycle projection, and closed-task history. It does not parse backlog,
# status, endpoint, or lifecycle files itself. Fixture inputs make formatting and
# recommendation behavior deterministic without creating a second inventory.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_PATH=
LIFECYCLE_PATH=
HISTORY_PATH=
INCLUDE_PRS=0
COMMAND=report

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      case "$2" in report|bearings) COMMAND=$2 ;; *) usage >&2; exit 2 ;; esac
      shift 2
      ;;
    --include-prs) INCLUDE_PRS=1; shift ;;
    --snapshot) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; SNAPSHOT_PATH=$2; shift 2 ;;
    --lifecycle) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; LIFECYCLE_PATH=$2; shift 2 ;;
    --history) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; HISTORY_PATH=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "fm-report: jq not found" >&2; exit 1; }
# The validated command name is intentionally presentation-inert: /bearings is
# a compatibility route into this exact formatter, never a second contract.
: "$COMMAND"

if [ -n "$SNAPSHOT_PATH" ] || [ -n "$LIFECYCLE_PATH" ] || [ -n "$HISTORY_PATH" ]; then
  [ -n "$SNAPSHOT_PATH" ] && [ -n "$LIFECYCLE_PATH" ] && [ -n "$HISTORY_PATH" ] \
    || { echo "fm-report: fixture mode requires --snapshot, --lifecycle, and --history" >&2; exit 2; }
  [ -f "$SNAPSHOT_PATH" ] && [ -f "$LIFECYCLE_PATH" ] && [ -f "$HISTORY_PATH" ] \
    || { echo "fm-report: fixture input not found" >&2; exit 2; }
  SNAPSHOT=$(cat "$SNAPSHOT_PATH") || exit 1
  LIFECYCLE=$(cat "$LIFECYCLE_PATH") || exit 1
  HISTORY=$(cat "$HISTORY_PATH") || exit 1
else
  SNAPSHOT_ARGS=(--json)
  [ "$INCLUDE_PRS" -eq 0 ] || SNAPSHOT_ARGS+=(--include-prs)
  SNAPSHOT=$("$SCRIPT_DIR/fm-bearings-snapshot.sh" "${SNAPSHOT_ARGS[@]}") || exit $?
  LIFECYCLE=$("$SCRIPT_DIR/fm-tasks.sh" --json) || exit $?
  HISTORY=$("$SCRIPT_DIR/fm-history.sh" --json --limit "${FM_REPORT_HISTORY_LIMIT:-5}") || exit $?
fi

printf '%s\n' "$SNAPSHOT" | jq -e '.schema == "fm-bearings.v1"' >/dev/null 2>&1 \
  || { echo "fm-report: snapshot must be fm-bearings.v1" >&2; exit 1; }
printf '%s\n' "$LIFECYCLE" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || { echo "fm-report: lifecycle rows must be an array" >&2; exit 1; }
printf '%s\n' "$HISTORY" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || { echo "fm-report: history rows must be an array" >&2; exit 1; }

jq -nr --argjson snapshot "$SNAPSHOT" --argjson lifecycle "$LIFECYCLE" --argjson history "$HISTORY" '
  def text:
    tostring | gsub("[\\r\\n\\t]+"; " ") | gsub("  +"; " ")
    | gsub("\\|"; "\\\\|") | if . == "" then "-" else . end;
  def ref($r): (($r.refs // $r.ref // $r.id // "-") | text);
  def command_ref($r): ($r.ref // $r.id // "-");
  def accepted_evidence($r):
    ($r.lifecycle.acceptance // null) as $a
    | $a != null and (($a.actor // "") != "") and (($a.at // "") != "")
      and (($a.evidence // "") != "")
      and (($a.route // "") == "close" or ($a.route // "") == "deliver" or ($a.route // "") == "deliver-monitor");
  def consolidated:
    $lifecycle as $all
    | [$all[] | select((.superseded_by // "") == "")
       | . as $row
       | . + {refs: ([.ref] + [$all[] | select((.superseded_by // "") == $row.id) | .ref]
                    | map(select(. != null and . != ""))
                    | reduce .[] as $ref ([]; if index($ref) == null then . + [$ref] else . end)
                    | join(", "))}];
  def table($headers; $rows; $empty):
    "| " + ($headers | join(" | ")) + " |\n"
    + "| " + ($headers | map("---") | join(" | ")) + " |\n"
    + (if ($rows | length) == 0
       then "| " + $empty + " | " + (($headers[1:] | map("-")) | join(" | ")) + " |\n"
       else ($rows | map("| " + (map(text) | join(" | ")) + " |") | join("\n")) + "\n"
       end);
  consolidated as $rows
  | [$rows[] | select(.status == "needs-you")] as $captain_life
  | ($captain_life | map(.id)) as $captain_ids
  | ([$snapshot.decisions_open[]? as $decision
      | select(($captain_ids | index($decision.id)) == null)
      | $decision
      | {id,ref:.id,name:(.summary // .id),outcome:(.summary // "Captain decision required"),
         next_action:"Open the task and answer the recorded call"}]) as $extra_decisions
  | ([$snapshot.contributions.captain[]?
      | {id:(.id // .task // .url // "contribution"),ref:(.id // .task // "-"),
         name:(.title // .repo // "Owned contribution"),
         outcome:(.reason // .verdict // "Captain action required"),
         next_action:(.url // "Inspect the contribution")}]) as $contribution_calls
  | ($captain_life + $extra_decisions + $contribution_calls | unique_by(.id)) as $captain
  | ([$rows[] | select(.status == "working" or .status == "waiting" or .status == "blocked" or .status == "failed" or .status == "reviewing")]
     + [$snapshot.in_flight[]? as $flight
        | select(([$rows[].id] | index($flight.id)) == null)
        | {id:$flight.id,ref:$flight.id,name:($flight.name // $flight.id),status:$flight.state,
           outcome:($flight.doing // "Current work recorded by its owning home")}]
     | unique_by(.id)) as $underway
  | [$rows[] | select(.status == "done")] as $done
  | [$rows[] | select((.status == "accepted" or .status == "delivering" or .status == "monitoring") and accepted_evidence(.))] as $delivery
  | [$history[]? | select(.disposition == "closed")] as $closed
  | ([$rows[] | select(.status == "queued")]
     + [$snapshot.gates[]? as $gate
        | select(([$rows[].id] | index($gate.id)) == null)
        | {id:$gate.id,ref:$gate.id,name:($gate.title // $gate.id),outcome:($gate.reason // $gate.blocked_by // "Queued"),
           next_action:"Wait for or clear the recorded gate"}]
     | unique_by(.id)) as $charted
  | [$captain[] | [ref(.), (.name // .id), (.outcome // .summary // "Action required"),
       (if (.ref // .id // "-") == "-" then (.next_action // "Act on the recorded call")
        else "`/t \(command_ref(.))` - \(.next_action // "answer the recorded call")" end)]] as $captain_table
  | [$underway[] | [ref(.), (.name // .id), .status, (.outcome // "Work in progress")]] as $underway_table
  | [$done[] | [ref(.), (.name // .id), .outcome, "`/t \(command_ref(.))`, then `/task-lifecycle review-start \(command_ref(.))`"]] as $done_table
  | [$delivery[] | [ref(.), (.name // .id), .status, .route, .next_action]] as $delivery_table
  | [$closed[] | [(.ref // .id), (.name // .id), (.dates.closed // "unknown"), .result,
       (if .lifecycle == null then "acceptance not recorded" else .lifecycle.acceptance.route end)]] as $closed_table
  | [$charted[] | [ref(.), (.name // .id), (.outcome // .reason // "Authorized; not started"),
       (if (.ref // .id // "-") == "-" then (.next_action // "Inspect the gate") else "`/t \(command_ref(.))`" end)]] as $charted_table
  | ([$captain[] | {
       tier:1,ref:command_ref(.),name:(.name // .id),
       why:(.outcome // .summary // "A recorded captain call is stopping progress."),
       consequence:"Resolving it can unblock active work.",
       action:"Run `/t \(command_ref(.))`, then answer the recorded call."}]
     + [$done[] | {
       tier:2,ref:command_ref(.),name:(.name // .id),
       why:"A candidate result is ready but has no recorded review.",
       consequence:"It cannot be accepted, delivered, or closed until review starts.",
       action:"Run `/t \(command_ref(.))`, review the result, then `/task-lifecycle review-start \(command_ref(.))`."}]
     + [$underway[] | select(.status == "reviewing") | {
       tier:2,ref:command_ref(.),name:(.name // .id),
       why:"Review is already in progress.",
       consequence:"The result stays unaccepted until review records acceptance or one correction.",
       action:"Run `/t \(command_ref(.))`, then accept a route or return one concrete correction."}]
     + [$delivery[] | select(.close_ready != true) | . as $r | {
       tier:3,ref:command_ref(.),name:(.name // .id),
       why:(if .status == "accepted" then "Review accepted this result, but its selected route has not started."
            elif .status == "delivering" then "The accepted delivery route is incomplete."
            else "The accepted monitoring route is incomplete." end),
       consequence:"The accepted scope cannot be closed until the selected route finishes.",
       action:(if .status == "accepted" then "Run `/task-lifecycle delivery-start \(command_ref(.))`."
               elif .status == "delivering" and ((.lifecycle.delivery.completedAt // "") != "") then "Run `/task-lifecycle monitoring-start \(command_ref(.))`."
               elif .status == "delivering" then "Complete delivery, then run `/task-lifecycle delivery-complete \(command_ref(.)) --evidence <delivery evidence>`."
               else "Complete monitoring, then run `/task-lifecycle monitoring-complete \(command_ref(.)) --evidence <monitoring evidence>`." end)}]) as $forward_recommendations
  | ([$delivery[] | select(.close_ready == true) | {
       tier:4,ref:command_ref(.),name:(.name // .id),
       why:"Acceptance and every selected delivery or monitoring phase are recorded complete.",
       consequence:"Closing archives finished scope without inventing follow-up work.",
       action:"Run `/t \(command_ref(.))`, then `/close \(command_ref(.))`."}]) as $closure_recommendations
  | (($underway | map(select(.status != "reviewing")) | length) > 0 or ($charted | length) > 0) as $other_forward
  | ($forward_recommendations
     + (if ($forward_recommendations | length) == 0 and ($other_forward | not)
        then $closure_recommendations else [] end)
     | sort_by([.tier,.ref])) as $recommendations
  | "# Fleet report\n\n"
    + "## Captain decisions and actions\n\n"
    + table(["Ref","Work","Why","Action"]; $captain_table; "No captain action is needed right now") + "\n"
    + "## Work under way\n\n"
    + table(["Ref","Work","Status","Current outcome"]; $underway_table; "Nothing is under way") + "\n"
    + "## Done and ready for review\n\n"
    + table(["Ref","Work","Candidate result","Next action"]; $done_table; "No candidate result is waiting for review") + "\n"
    + "## Accepted work in delivery or monitoring\n\n"
    + table(["Ref","Work","Status","Route","Next action"]; $delivery_table; "No accepted work is in delivery or monitoring") + "\n"
    + "## Recently completed and closed\n\n"
    + table(["Ref","Work","Closed","Result","Route"]; $closed_table; "No recent closed work is recorded") + "\n"
    + "## Charted next\n\n"
    + table(["Ref","Work","Why it is next or gated","Action"]; $charted_table; "Nothing is charted next") + "\n"
    + "## Recommendations\n\n"
    + (if ($recommendations | length) == 0 then
         "No captain action is needed right now."
       else
         ($recommendations | to_entries | map(
           "\(.key + 1). **\(.value.name | text)** - Why: \(.value.why | text) Consequence: \(.value.consequence | text) Action: \(.value.action)") | join("\n"))
       end)
'
