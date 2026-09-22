#!/usr/bin/env bash
# fm-jev-wake-triage.sh - classify one stale-escalation candidate with Jev.
#
# Usage:
#   fm-jev-wake-triage.sh --class <kind> --age <secs> --escalation-count <n>
#                         [--task <id>] [--status-file <path>] [--last-status <line>]
#
# Hook: bin/fm-watch.sh calls this from the at-threshold wedge path after the
#   wait, worktree-write, and dead-record probes, and before it increments the
#   escalation counter or wakes. docs/configuration.md "Jev stale-escalation
#   triage" owns the operator contract; this header owns flags, output, the
#   request, telemetry, and the calibration log.
#
# API: the typesafe-sdk system_one contract (Choice + Noul in one POST) over
#   the same REST client as bin/fm-dispatch-resolve.sh. The watcher is bash and
#   does not add a Python toolchain; pip install typesafe-sdk is the documented
#   SDK shape, not a runtime dependency. Endpoint https://api.typesafe.ai,
#   model jev-latest, timeout 5 seconds.
#
# Key: TYPESAFE_API_KEY from this process environment only, vault-injected at
#   runtime. Never read from .env (unlike typed dispatch resolution). The key
#   is copied into a non-exported variable and unset before children run, then
#   sent to curl as a header from a file descriptor, never on argv. Nothing
#   logs or writes it.
#
# Fail-open: any missing key, missing curl/jq, HTTP/transport error, timeout,
#   or malformed answer prints action=unavailable and exits 0 so the watcher
#   escalates exactly as it did before this gate. Exit 2 only for usage.
#
# Decision: escalate only when the Choice is true_wedge. pipeline_wait and
#   healthy_idle print action=suppress. The Noul wedge_probability is recorded
#   for calibration and is not a second escalate gate.
#
# Telemetry: appends one `jev_triage.<action>\t<class>` line to
#   state/.jev-triage-telemetry. <class> is ship, scout, secondmate, or
#   unknown. No task id, no status text, no PHI.
#
# Calibration: the first 20 decisions (override with
#   FM_JEV_WAKE_TRIAGE_CALIBRATION_LIMIT) append one JSON object to
#   state/.jev-triage-calibration.jsonl with the input summary, Jev answer,
#   action, and outcome. A later escalate after a suppress for the same task
#   appends a follow-up line with outcome=later_escalated.
#
# Output (stdout, one key=value per line):
#   action=escalate|suppress|unavailable
#   class=<kind>
#   choice=<pipeline_wait|true_wedge|healthy_idle>   (omitted when unavailable)
#   noul=<0..1>                                      (omitted when unavailable)
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

TS_MODEL=jev-latest
TS_BASE=https://api.typesafe.ai
TS_TIMEOUT=${FM_JEV_WAKE_TRIAGE_TIMEOUT:-5}
CALIBRATION_LIMIT=${FM_JEV_WAKE_TRIAGE_CALIBRATION_LIMIT:-20}
case "$TS_TIMEOUT" in ''|*[!0-9]*|0) TS_TIMEOUT=5 ;; esac
case "$CALIBRATION_LIMIT" in ''|*[!0-9]*) CALIBRATION_LIMIT=20 ;; esac

CLASS='' AGE='' COUNT='' TASK='' STATUS_FILE='' LAST_STATUS=''

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --class) [ $# -ge 2 ] || die "--class needs a value"; CLASS=$2; shift 2 ;;
    --age) [ $# -ge 2 ] || die "--age needs a value"; AGE=$2; shift 2 ;;
    --escalation-count) [ $# -ge 2 ] || die "--escalation-count needs a value"; COUNT=$2; shift 2 ;;
    --task) [ $# -ge 2 ] || die "--task needs a value"; TASK=$2; shift 2 ;;
    --status-file) [ $# -ge 2 ] || die "--status-file needs a value"; STATUS_FILE=$2; shift 2 ;;
    --last-status) [ $# -ge 2 ] || die "--last-status needs a value"; LAST_STATUS=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) die "unexpected argument $1" ;;
  esac
done

[ -n "$CLASS" ] || die "--class is required"
[ -n "$AGE" ] || die "--age is required"
[ -n "$COUNT" ] || die "--escalation-count is required"
case "$AGE" in *[!0-9]*) die "--age must be a non-negative integer" ;; esac
case "$COUNT" in *[!0-9]*) die "--escalation-count must be a non-negative integer" ;; esac
case "$CLASS" in
  ship|scout|secondmate) ;;
  *) CLASS=unknown ;;
esac

if [ -z "$LAST_STATUS" ] && [ -n "$STATUS_FILE" ] && [ -f "$STATUS_FILE" ]; then
  LAST_STATUS=$(tail -n 1 "$STATUS_FILE" 2>/dev/null || true)
fi

TELEMETRY="$STATE/.jev-triage-telemetry"
CALIBRATION="$STATE/.jev-triage-calibration.jsonl"
PENDING="$STATE/.jev-triage-pending"

sanitize_line() {
  local line=$1
  line=$(printf '%s' "$line" | tr -d '\r')
  if [ "${#line}" -gt 240 ]; then
    line=${line:0:240}
  fi
  printf '%s' "$line"
}

status_tail_json() {
  local f=$1 line
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    printf '[]'
    return 0
  fi
  { tail -n 5 "$f" 2>/dev/null || true; } | while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    sanitize_line "$line"
    printf '\n'
  done | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

stamp_telemetry() {  # <suppress|escalate|unavailable>
  local counter=$1
  case "$counter" in
    suppress) counter=suppressed ;;
    escalate) counter=escalated ;;
  esac
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf 'jev_triage.%s\t%s\n' "$counter" "$CLASS" >> "$TELEMETRY" 2>/dev/null || true
}

calibration_count() {
  local n
  [ -f "$CALIBRATION" ] || { printf '0'; return 0; }
  n=$(grep -c '"summary"' "$CALIBRATION" 2>/dev/null || echo 0)
  n=${n##* }
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

write_calibration() {  # <action> [choice] [noul]
  local action=$1 choice=${2-} noul=${3-} n summary pending_action
  n=$(calibration_count)
  mkdir -p "$STATE" 2>/dev/null || return 0
  if [ -n "$TASK" ] && [ -f "$PENDING" ]; then
    pending_action=$(awk -F '\t' -v t="$TASK" '$1 == t { a=$2 } END { print a }' "$PENDING" 2>/dev/null || true)
    if [ "$pending_action" = suppress ] && [ "$action" = escalate ]; then
      jq -nc --arg class "$CLASS" --arg action "$action" --arg choice "$choice" \
        --arg noul "$noul" --argjson n "$n" \
        '{n:$n,class:$class,action:$action,choice:$choice,noul:(if $noul == "" then null else ($noul|tonumber) end),outcome:"later_escalated"}' \
        >> "$CALIBRATION" 2>/dev/null || true
    fi
  fi
  if [ "$n" -ge "$CALIBRATION_LIMIT" ]; then
    if [ -n "$TASK" ]; then
      printf '%s\t%s\n' "$TASK" "$action" >> "$PENDING" 2>/dev/null || true
    fi
    return 0
  fi
  summary=$(jq -nc --arg class "$CLASS" --argjson age "$AGE" --argjson count "$COUNT" \
    --arg task "$TASK" --arg last "$(sanitize_line "$LAST_STATUS")" --argjson tail "$(status_tail_json "$STATUS_FILE")" \
    '{task_id:$task,kind:$class,idle_seconds:$age,escalation_count:$count,last_status:$last,status_tail:$tail,run_step:$last}')
  jq -nc --argjson summary "$summary" --arg class "$CLASS" --arg action "$action" \
    --arg choice "$choice" --arg noul "$noul" --argjson n "$n" \
    '{n:($n+1),class:$class,action:$action,choice:(if $choice == "" then null else $choice end),noul:(if $noul == "" then null else ($noul|tonumber) end),outcome:(if $action == "suppress" then "pending" else $action end),summary:$summary}' \
    >> "$CALIBRATION" 2>/dev/null || true
  if [ -n "$TASK" ]; then
    printf '%s\t%s\n' "$TASK" "$action" >> "$PENDING" 2>/dev/null || true
  fi
}

emit() {  # <action> [choice] [noul]
  local action=$1 choice=${2-} noul=${3-}
  stamp_telemetry "$action"
  write_calibration "$action" "$choice" "$noul"
  printf 'action=%s\nclass=%s\n' "$action" "$CLASS"
  if [ -n "$choice" ]; then
    printf 'choice=%s\n' "$choice"
  fi
  if [ -n "$noul" ]; then
    printf 'noul=%s\n' "$noul"
  fi
  exit 0
}

emit_unavailable() { emit unavailable; }

if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  emit_unavailable
fi
command -v jq >/dev/null 2>&1 || emit_unavailable
command -v curl >/dev/null 2>&1 || emit_unavailable

TAIL_JSON=$(status_tail_json "$STATUS_FILE")
REQUEST=$(jq -n --arg model "$TS_MODEL" --arg class "$CLASS" --argjson age "$AGE" \
  --argjson count "$COUNT" --arg task "$TASK" --arg last "$(sanitize_line "$LAST_STATUS")" \
  --argjson tail "$TAIL_JSON" '
  {
    model: $model,
    state: {
      task_id: $task,
      kind: $class,
      idle_seconds: $age,
      escalation_count: $count,
      last_status: $last,
      status_tail: $tail,
      run_step: $last
    },
    questions: {
      class: {
        type: "choice",
        instructions: "Which one label describes this quiet pane? Read `kind`, `idle_seconds`, `escalation_count`, `last_status`, `run_step`, and `status_tail`. Pick pipeline_wait when a ship or scout is silent because a pipeline, CI, validation round, or long drive call is still running. Pick healthy_idle when silence is the healthy state: an idle secondmate with an empty queue, or a finished worker whose endpoint is still up. Pick true_wedge when the worker looks stuck in a way that will not clear on its own.",
        criteria: {
          pipeline_wait: "A static pane is expected because in-flight validation, CI, a long tool call, or another pipeline step is still running. Tonight false escalations were this class: ships waiting on no-mistakes or CI while the pane stayed idle.",
          true_wedge: "The worker is actually stuck: looping, confused, repeating the same unchanged display without pipeline evidence, or otherwise not making progress that will resume on its own.",
          healthy_idle: "Silence is healthy: an idle secondmate with nothing to do, or a finished or waiting worker that is not wedged."
        }
      },
      wedge_probability: {
        type: "noul",
        instructions: "Is this quiet pane a true wedge that needs a supervisor now, rather than a pipeline wait or healthy idle? Read `kind`, `idle_seconds`, `escalation_count`, `last_status`, and `status_tail`."
      }
    }
  }') || emit_unavailable

RESP_FILE=$(mktemp) || emit_unavailable
trap 'rm -f "$RESP_FILE"' EXIT
HTTP=$(printf '%s' "$REQUEST" | curl -sS --max-time "$TS_TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
  -X POST "$TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
  -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
  --data-binary @- 2>/dev/null) || HTTP=000
[ "$HTTP" = 200 ] || emit_unavailable

jq -e '
  (.answers.class.choice | type) == "string" and
  (.answers.class.choice == "pipeline_wait" or .answers.class.choice == "true_wedge" or .answers.class.choice == "healthy_idle") and
  (.answers.class.probabilities | type) == "object" and
  ((.answers.class.probabilities | keys | sort) == ["healthy_idle","pipeline_wait","true_wedge"]) and
  all(.answers.class.probabilities[]; type == "number" and . >= 0 and . <= 1) and
  ((.answers.class.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01) and
  (.answers.wedge_probability.noul | type) == "number" and
  .answers.wedge_probability.noul >= 0 and .answers.wedge_probability.noul <= 1
' "$RESP_FILE" >/dev/null 2>&1 || emit_unavailable

CHOICE=$(jq -r '.answers.class.choice' "$RESP_FILE")
NOUL=$(jq -r '.answers.wedge_probability.noul' "$RESP_FILE")
case "$CHOICE" in
  true_wedge) emit escalate "$CHOICE" "$NOUL" ;;
  pipeline_wait|healthy_idle) emit suppress "$CHOICE" "$NOUL" ;;
  *) emit_unavailable ;;
esac
