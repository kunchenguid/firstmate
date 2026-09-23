#!/usr/bin/env bash
# vessel-record-run.sh - append one run record to data/vessel/runs.jsonl.
#
# The vessel-workflows skill calls this right after bin/fm-spawn.sh succeeds, so
# the vessel TUI can tie a firstmate task to the Jira ticket and/or pull request
# it worked on. Task lifecycle (status, merge, teardown) is NOT recorded here:
# the TUI joins these records with firstmate's own state/fleet-ledger.jsonl.
#
# Records are append-only JSON Lines, schema v1. Readers ignore unknown fields.
#
# Usage:
#   vessel-record-run.sh --task <id> --workflow <workflow> [options]
# Options:
#   --agent <name> --harness <name> --model <name> --effort <level>
#   --project <name> --title <text>
#   --ticket <KEY> --repo <owner/repo> --pr <number> --pr-url <url> --pr-head <sha>
#   --plan-task <task-id> --request-id <id>
# Workflows: implement plan review address conflicts description ticket free
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
RUNS="${VESSEL_RUNS_FILE:-$FM_HOME/data/vessel/runs.jsonl}"

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//' >&2; }

task="" workflow="" agent="" harness="" model="" effort="" project="" title=""
ticket="" repo="" pr="" pr_url="" pr_head="" plan_task="" request_id=""

while [ $# -gt 0 ]; do
  case "$1" in
    --task) task="$2"; shift 2 ;;
    --workflow) workflow="$2"; shift 2 ;;
    --agent) agent="$2"; shift 2 ;;
    --harness) harness="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --effort) effort="$2"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    --ticket) ticket="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --pr) pr="$2"; shift 2 ;;
    --pr-url) pr_url="$2"; shift 2 ;;
    --pr-head) pr_head="$2"; shift 2 ;;
    --plan-task) plan_task="$2"; shift 2 ;;
    --request-id) request_id="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "vessel-record-run: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$task" ] || [ -z "$workflow" ]; then
  echo "vessel-record-run: --task and --workflow are required" >&2
  exit 2
fi
case "$workflow" in
  implement|plan|review|address|conflicts|description|ticket|free) ;;
  *) echo "vessel-record-run: unknown workflow: $workflow" >&2; exit 2 ;;
esac
if [ -n "$pr" ] && ! [ "$pr" -eq "$pr" ] 2>/dev/null; then
  echo "vessel-record-run: --pr must be a number" >&2
  exit 2
fi
command -v jq >/dev/null || { echo "vessel-record-run: jq is required" >&2; exit 1; }

mkdir -p "$(dirname "$RUNS")"
jq -nc \
  --arg task "$task" --arg workflow "$workflow" --arg agent "$agent" \
  --arg harness "$harness" --arg model "$model" --arg effort "$effort" \
  --arg project "$project" --arg title "$title" --arg ticket "$ticket" \
  --arg repo "$repo" --arg pr "$pr" --arg pr_url "$pr_url" --arg pr_head "$pr_head" \
  --arg plan_task "$plan_task" --arg request_id "$request_id" \
  --argjson ts "$(date +%s)" '
  def opt: if . == "" then null else . end;
  {v: 1, ts: $ts, task: $task, workflow: $workflow,
   agent: ($agent|opt), harness: ($harness|opt), model: ($model|opt), effort: ($effort|opt),
   project: ($project|opt), title: ($title|opt), ticket_key: ($ticket|opt), repo: ($repo|opt),
   pr_number: (if $pr == "" then null else ($pr|tonumber) end),
   pr_url: ($pr_url|opt), pr_head: ($pr_head|opt),
   plan_task: ($plan_task|opt), request_id: ($request_id|opt)}' >> "$RUNS"
echo "recorded $task ($workflow) in $RUNS"
