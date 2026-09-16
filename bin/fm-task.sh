#!/usr/bin/env bash
# Render one deterministic current-or-closed task detail record.
#
# Usage: fm-task.sh [--json|--card] <canonical-id|active-reference|human-name>
#
# Current lookup uses fm-callsigns-lib.sh, so canonical ids, active t1-t99
# references, and unambiguous active names follow the same owner as /tasks.
# Canonical ids and unambiguous names that are no longer current fall through to
# finalized data/closed-tasks records through fm-history.sh. Retired short
# references never resolve from history because they may be recycled.
#
# Current detail composes the canonical fleet snapshot, current-state
# reconciliation, task instructions, metadata, and recorded artifacts. It does
# not persist another task summary. Dates are emitted only from explicit backlog,
# metadata, or closure fields; absent dates stay null/unknown and file mtimes are
# never treated as lifecycle dates.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
FORMAT=card
SELECTOR=

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

fail() { printf 'fm-task: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json; shift ;;
    --card) FORMAT=card; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) printf 'fm-task: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *)
      [ -z "$SELECTOR" ] || { usage >&2; exit 2; }
      SELECTOR=$1
      shift
      ;;
  esac
done
[ -n "$SELECTOR" ] || { usage >&2; exit 2; }
command -v jq >/dev/null 2>&1 || fail "jq is required"

meta_value() {  # <file> <key>
  local file=$1 key=$2
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

captain_intent() {  # <brief-path>
  local brief=$1
  [ -f "$brief" ] && [ ! -L "$brief" ] || return 0
  awk '
    /^## Captain.s intent[[:space:]]*$/ {inside=1; next}
    inside && /^##[[:space:]]+/ {exit}
    inside {print}
  ' "$brief" | jq -Rrs 'gsub("[[:space:]]+"; " ") | gsub("^ | $"; "")'
}

archive_task_field() {  # <task.txt> <field>
  local file=$1 field=$2
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  sed -n "s/^  $field: *//p" "$file" | head -1
}

render_model() {  # <json>
  if [ "$FORMAT" = json ]; then
    printf '%s\n' "$1"
    return 0
  fi
  printf '%s\n' "$1" | jq -r '
    def shown($value): if $value == null or $value == "" then "unknown" else ($value | tostring) end;
    def list($items): if ($items | length) == 0 then "none recorded" else ($items | join(", ")) end;
    "Task \(.ref): \(.name)",
    "Ref: \(.ref)",
    "Name: \(.name)",
    "Canonical ID: \(.id)",
    "Project: \(.project | shown(.))",
    "Kind: \(.kind | shown(.))",
    "Status: \(.status)",
    "Created: \(.dates.created | shown(.))",
    "Started: \(.dates.started | shown(.))",
    "Finished: \(.dates.finished | shown(.))",
    "Delivered: \(.dates.delivered | shown(.))",
    (if .source == "closed" then "Closed: \(.dates.closed | shown(.))" else empty end),
    "Purpose: \(.purpose | shown(.))",
    "Details: \(.details | if . == null or . == "" then "none recorded" else . end)",
    "Current outcome: \(.outcome | shown(.))",
    "Delivery / landing: \(.delivery | shown(.))",
    "Artifacts: \(.artifacts | list(.))",
    (if .source == "closed" then "Retained knowledge: \(.retainedKnowledge | list(.))" else empty end),
    (if .source == "closed" then "Follow-ups: \(.followUps | list(.))" else empty end),
    "Blocker / captain decision: \(.attention // "none")",
    "Next action: \(.nextAction)"
  '
}

current_model() {  # <compact-task-json>
  local summary=$1 id snapshot row task ref name status outcome meta brief intent details
  local created started finished delivered
  id=$(printf '%s\n' "$summary" | jq -r '.id')
  ref=$(printf '%s\n' "$summary" | jq -r '.ref')
  name=$(printf '%s\n' "$summary" | jq -r '.name')
  status=$(printf '%s\n' "$summary" | jq -r '.status')
  outcome=$(printf '%s\n' "$summary" | jq -r '.outcome')
  snapshot=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) \
    || fail "could not read the current fleet snapshot"
  row=$(printf '%s\n' "$snapshot" | jq -c --arg id "$id" \
    '[.backlog.records[]? | select(.structured == true and .id == $id)] | if length == 1 then .[0] else {} end')
  task=$(printf '%s\n' "$snapshot" | jq -c --arg id "$id" \
    '[.tasks[]? | select(.id == $id)] | if length == 1 then .[0] else {} end')
  if [ "$(printf '%s\n' "$row" | jq 'length')" -eq 0 ] \
     && [ "$(printf '%s\n' "$task" | jq 'length')" -eq 0 ]; then
    fail "current task $id disappeared during detail lookup; retry"
  fi
  meta="$STATE/$id.meta"
  brief="$DATA/$id/brief.md"
  [ -f "$brief" ] && [ ! -L "$brief" ] || brief="$DATA/$id/launch-brief.md"
  intent=$(captain_intent "$brief")
  details=$(printf '%s\n' "$row" | jq -r '.body_excerpt // empty')
  created=$(printf '%s\n' "$row" | jq -r '.since // empty')
  started=$(meta_value "$meta" started_at)
  finished=$(printf '%s\n' "$row" | jq -r '.done // .completion.date // empty')
  delivered=$(printf '%s\n' "$row" | jq -r '.merged // .reported // empty')

  jq -n \
    --argjson row "$row" --argjson task "$task" \
    --arg id "$id" --arg ref "$ref" --arg name "$name" \
    --arg status "$status" --arg outcome "$outcome" \
    --arg intent "$intent" --arg details "$details" \
    --arg created "$created" --arg started "$started" \
    --arg finished "$finished" --arg delivered "$delivered" '
    def value($x): if $x == "" then null else $x end;
    def blockers: ($row.unresolved_blocker_ids // $row.blocked_by_ids // []);
    def decision_text:
      if ($row.hold_kind // "") == "captain" then ($row.hold_reason // "needs a captain decision")
      elif (($task.hints.open_decisions // []) | length) > 0
        then ($task.hints.open_decisions | map(.summary) | join("; "))
      else "" end;
    def current_outcome:
      if $status == "done" then ($row.local_note // $row.body_excerpt // $outcome) else $outcome end;
    def attention:
      if decision_text != "" then "Captain decision: " + decision_text
      elif $status == "blocked" and (blockers | length) > 0 then "Blocked by: " + (blockers | join(", "))
      elif $status == "blocked" then ($row.blocked_reason // $outcome // "Blocked")
      else null end;
    def artifact_list:
      ([
        $task.pr.url,
        $row.pr_url,
        $row.report_path,
        ($row.links[]?),
        (if ($task.paths.report.present // false) then "data/" + $id + "/report.md" else null end)
      ] | map(select(. != null and . != "")) | unique);
    def delivery($status):
      if ($row.state // "") == "done" then current_outcome
      elif ($task.mode // "") == "local-only" and $status == "ready" then "Local branch awaiting landing approval"
      elif ($task.pr.url // "") != "" and $status == "ready" then "PR awaiting landing approval: " + $task.pr.url
      elif ($task.pr.url // "") != "" then "PR open: " + $task.pr.url
      elif ($task.kind // $row.kind // "") == "scout" and ($task.paths.report.present // false) then "Report available"
      elif ($task.mode // "") == "local-only" then "Local branch in progress"
      elif ($task.mode // "") != "" then $task.mode
      else "Not recorded" end;
    def next_action($status; $outcome):
      if $status == "done" then "Ready to close"
      elif $status == "ready" then "Awaiting landing approval"
      elif $status == "needs-you" then "Answer the captain decision"
      elif $status == "blocked" then "Resolve the blocker"
      elif $status == "queued" then "Ready to start"
      elif $status == "working" then $outcome
      elif $status == "waiting" then "Wait for the recorded external condition"
      elif $status == "failed" then "Investigate the failure"
      else "Reconcile current state" end;
    (artifact_list) as $artifacts
    | {
        schema:"fm-task-detail.v1", source:"current",
        ref:$ref, name:$name, id:$id,
        project:($row.repo // (($task.project // "") | if . == "" then null else (split("/") | last) end)),
        kind:($row.kind // $task.kind // null), status:$status,
        dates:{created:value($created), started:value($started), finished:value($finished), delivered:value($delivered), closed:null},
        purpose:(if $intent != "" then $intent elif ($row.title // "") != "" then $row.title elif $details != "" then $details else null end),
        details:value($details), outcome:current_outcome,
        delivery:delivery($status), artifacts:$artifacts,
        retainedKnowledge:[], followUps:[], attention:attention,
        nextAction:next_action($status; $outcome)
      }
  '
}

closed_model() {  # <selector>
  local selector=$1 history record id archive brief intent task_file purpose details
  if ! history=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-history.sh" --json --limit 500 "$selector" 2>&1); then
    case "$history" in
      *ambiguous*) fail "ambiguous closed-task name '$selector'; use a canonical id" ;;
      *"no closed task"*) fail "unknown task selector '$selector'" ;;
      *) fail "$history" ;;
    esac
  fi
  record=$(printf '%s\n' "$history" | jq -c '.[0]')
  id=$(printf '%s\n' "$record" | jq -r '.id')
  archive="$DATA/closed-tasks/$id"
  brief="$archive/brief.md"
  [ -f "$brief" ] && [ ! -L "$brief" ] || brief="$archive/launch-brief.md"
  intent=$(captain_intent "$brief")
  task_file="$archive/task.txt"
  purpose=$(archive_task_field "$task_file" title)
  details=$(archive_task_field "$task_file" body)
  [ "$details" != "-" ] || details=

  jq -n --argjson record "$record" --arg intent "$intent" --arg purpose "$purpose" --arg details "$details" '
    def value($x): if $x == "" then null else $x end;
    $record as $r
    | {
        schema:"fm-task-detail.v1", source:"closed",
        ref:(($r.ref // "-") + " (retired)"), name:$r.name, id:$r.id,
        project:($r.project // null), kind:($r.kind // null), status:"closed",
        dates:{created:($r.dates.created // null), started:($r.dates.started // null),
          finished:($r.dates.completed // null), delivered:null, closed:($r.dates.closed // null)},
        purpose:(if $intent != "" then $intent elif $purpose != "" then $purpose else ($r.result // null) end),
        details:value($details), outcome:($r.result // "Closed"),
        delivery:("Closed and archived at " + ($r.archive // ("data/closed-tasks/" + $r.id))),
        artifacts:($r.artifacts // []), retainedKnowledge:($r.retainedKnowledge // []),
        followUps:($r.followUps // []), attention:null,
        nextAction:(if (($r.followUps // []) | length) > 0 then "Continue recorded follow-up work" else "No action - closed" end)
      }
  '
}

if current=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-tasks.sh" --json "$SELECTOR" 2>&1); then
  [ "$(printf '%s\n' "$current" | jq 'length')" -eq 1 ] \
    || fail "current selector '$SELECTOR' did not identify exactly one task"
  summary=$(printf '%s\n' "$current" | jq -c '.[0]')
  MODEL=$(current_model "$summary") || exit $?
else
  case "$current" in
    *ambiguous*) fail "ambiguous task selector '$SELECTOR'" ;;
    *"unknown task selector"*) : ;;
    *) fail "$current" ;;
  esac
  case "$SELECTOR" in
    t[1-9]|t[1-9][0-9]) fail "retired or unknown short reference '$SELECTOR'; use a canonical id or human name" ;;
  esac
  MODEL=$(closed_model "$SELECTOR") || exit $?
fi
render_model "$MODEL"
