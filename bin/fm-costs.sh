#!/usr/bin/env bash
# fm-costs.sh - local, read-only Pi AI usage and list-price cost report.
#
# Usage:
#   fm-costs.sh [--json] [--home <dir>] [--session-dir <dir>]
#               [--models-store <file>] [--now <iso8601>]
#
# The default scans only $HOME/.pi/agent/sessions. FM_COSTS_HOME,
# FM_COSTS_SESSION_DIR, FM_COSTS_MODELS_STORE, and FM_COSTS_NOW are hermetic
# overrides for the report home, Pi stores, and clock. The corresponding flags
# take precedence. The command reads JSONL line by line, writes nothing, makes no
# network calls, and emits no transcript content.
#
# Output contract: fm-costs.v1. Default output is compact TOON-like text;
# --json emits the equivalent structured model. Pi's stored direct cost.total
# and subagent flat cost are authoritative. Dollar values are list-price
# valuations, not invoices.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FORMAT=toon
REPORT_HOME=${FM_COSTS_HOME:-${FM_HOME:-$ROOT}}
SESSION_DIR=${FM_COSTS_SESSION_DIR:-$HOME/.pi/agent/sessions}
MODELS_STORE=${FM_COSTS_MODELS_STORE:-$HOME/.pi/agent/models-store.json}
NOW=${FM_COSTS_NOW:-}

usage() {
  cat <<'EOF'
usage: fm-costs.sh [--json] [--home <dir>] [--session-dir <dir>]
                   [--models-store <file>] [--now <iso8601>]

Local, read-only Pi usage report. The default scans only
$HOME/.pi/agent/sessions, writes nothing, makes no network calls, and emits no
transcript content. FM_COSTS_HOME, FM_COSTS_SESSION_DIR,
FM_COSTS_MODELS_STORE, and FM_COSTS_NOW provide hermetic overrides.

The output contract is fm-costs.v1. Default output is compact TOON-like text;
--json emits the equivalent structured model.
Dollar values are list-price valuations, not invoices.
EOF
}

die_usage() {
  printf 'fm-costs: %s\n' "$*" >&2
  usage >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      FORMAT=json
      shift
      ;;
    --home)
      [ "$#" -ge 2 ] || die_usage '--home requires a directory'
      REPORT_HOME=$2
      shift 2
      ;;
    --home=*)
      REPORT_HOME=${1#*=}
      shift
      ;;
    --session-dir|--sessions-dir)
      [ "$#" -ge 2 ] || die_usage "$1 requires a directory"
      SESSION_DIR=$2
      shift 2
      ;;
    --session-dir=*|--sessions-dir=*)
      SESSION_DIR=${1#*=}
      shift
      ;;
    --models-store)
      [ "$#" -ge 2 ] || die_usage '--models-store requires a file'
      MODELS_STORE=$2
      shift 2
      ;;
    --models-store=*)
      MODELS_STORE=${1#*=}
      shift
      ;;
    --now)
      [ "$#" -ge 2 ] || die_usage '--now requires a value'
      NOW=$2
      shift 2
      ;;
    --now=*)
      NOW=${1#*=}
      shift
      ;;
    -h|--help)
      [ "$#" -eq 1 ] || die_usage '--help takes no other arguments'
      usage
      exit 0
      ;;
    *)
      die_usage "unknown argument '$1'"
      ;;
  esac
done

[ -n "$REPORT_HOME" ] || die_usage 'home must not be empty'
[ -n "$SESSION_DIR" ] || die_usage 'session directory must not be empty'
[ -n "$MODELS_STORE" ] || die_usage 'models store must not be empty'
case "$REPORT_HOME" in
  /) ;;
  */) REPORT_HOME=${REPORT_HOME%/} ;;
esac
command -v jq >/dev/null 2>&1 || { printf 'fm-costs: jq not found\n' >&2; exit 1; }
[ -n "$NOW" ] || NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

emit_file_events() {
  jq -Rrc '
    def number_or_zero($v): if ($v | type) == "number" then $v else 0 end;
    def stored_cost($v): if ($v | type) == "number" then $v else null end;
    def message_text:
      if (.message.content? | type) == "string" then .message.content
      elif (.message.content? | type) == "array" then
        [.message.content[]? |
          if type == "string" then .
          elif type == "object" and .type == "text" then (.text // "")
          else ""
          end] | join("\n")
      else ""
      end;
    def direct_model:
      (.message.provider // .provider // "unknown") as $provider |
      (.message.responseModel // .message.model // "unknown") as $model |
      if ($model | contains("/")) then
        {provider:($model | split("/")[0]), model:$model}
      else
        {provider:$provider, model:($provider + "/" + $model)}
      end;
    def subagent_model($result):
      ($result.provider // "unknown") as $provider |
      ($result.model // "unknown") as $model |
      if ($model | contains("/")) then
        {provider:($model | split("/")[0]), model:$model}
      else
        {provider:$provider, model:($provider + "/" + $model)}
      end;
    def usage_event($record; $usage; $origin; $index; $model; $turns; $cost):
      ($record.timestamp // $record.message.timestamp // "") as $timestamp |
      {
        kind:"usage",
        line:input_line_number,
        identity:[($record.id // ""), $timestamp, $origin, $index],
        entry_id:($record.id // ""),
        entry_timestamp:$timestamp,
        origin:$origin,
        result_index:$index,
        provider:$model.provider,
        model:$model.model,
        calls:1,
        turns:$turns,
        tokens:{
          input:number_or_zero($usage.input),
          output:number_or_zero($usage.output),
          cacheRead:number_or_zero($usage.cacheRead),
          cacheWrite:number_or_zero($usage.cacheWrite),
          reasoning:number_or_zero($usage.reasoning),
          cacheWrite1h:number_or_zero($usage.cacheWrite1h)
        },
        cost:stored_cost($cost),
        cost_known:(($cost | type) == "number")
      };
    if test("^[[:space:]]*$") then {kind:"parse_error",line:input_line_number}
    else
      (try fromjson catch {__fm_parse_error:true}) as $record |
      if (($record | type) == "object" and ($record.__fm_parse_error // false)) then
        {kind:"parse_error",line:input_line_number}
      elif ($record | type) != "object" then
        {kind:"parse_error",line:input_line_number}
      elif $record.type == "session" then
        {kind:"session",line:input_line_number,id:($record.id // ""),
         timestamp:($record.timestamp // ""),cwd:($record.cwd // ""),
         version:($record.version // null)}
      elif $record.type == "message" and $record.message.role == "user" then
        ($record | message_text) as $text |
        {kind:"user",line:input_line_number,
         refs:([$text |
           scan("(/[^[:space:]]+)/state/([A-Za-z0-9._-]+)\\.status") |
           {home:.[0],task:.[1],path:(.[0] + "/state/" + .[1] + ".status")}
         ] | unique_by(.path))}
      elif $record.type == "message" and $record.message.role == "assistant"
           and (($record.message.usage? | type) == "object") then
        ($record | direct_model) as $model |
        usage_event($record; $record.message.usage; "direct"; -1; $model; 1;
          $record.message.usage.cost.total)
      elif $record.type == "message" and $record.message.role == "toolResult"
           and $record.message.toolName == "subagent" then
        ($record.message.details.results // []) as $results |
        range(0; ($results | length)) as $index |
        $results[$index] as $result |
        select(($result.usage? | type) == "object") |
        (subagent_model($result)) as $model |
        usage_event($record; $result.usage; "subagent"; $index; $model;
          number_or_zero($result.usage.turns); $result.usage.cost)
      else empty
      end
    end
  ' -- "$1"
}

json_array_from_lines() {
  if [ "$#" -eq 0 ]; then
    printf '[]\n'
  else
    printf '%s\n' "$@" | jq -sc '.'
  fi
}

append_gap() {
  local count=${4:-0}
  GAPS+=("$(jq -cn --arg kind "$1" --arg path "$2" --arg reason "$3" \
    --argjson count "$count" '{kind:$kind,path:$path,reason:$reason,count:$count}')")
}

declare -a EVENTS=()
declare -a SESSIONS=()
declare -a GAPS=()
SCAN_FILES=0
SCAN_BYTES=0
PARSE_ERRORS=0
VALID_SESSIONS=0

if [ -d "$SESSION_DIR" ]; then
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    SCAN_FILES=$((SCAN_FILES + 1))
    if bytes=$(wc -c < "$file" 2>/dev/null); then
      SCAN_BYTES=$((SCAN_BYTES + bytes))
    else
      append_gap unreadable-session "$file" 'could not read session file size'
      continue
    fi
    if ! raw=$(emit_file_events "$file" 2>/dev/null); then
      append_gap unreadable-session "$file" 'could not read session file'
      continue
    fi

    header_seen=0
    session_id=
    session_timestamp=
    session_cwd=
    first_user_seen=0
    refs_json='[]'
    file_parse_errors=0
    declare -a FILE_USAGE=()

    while IFS= read -r event; do
      [ -n "$event" ] || continue
      kind=$(printf '%s\n' "$event" | jq -r '.kind')
      case "$kind" in
        session)
          line=$(printf '%s\n' "$event" | jq -r '.line')
          if [ "$line" -eq 1 ] && [ "$header_seen" -eq 0 ]; then
            header_seen=1
            session_id=$(printf '%s\n' "$event" | jq -r '.id')
            session_timestamp=$(printf '%s\n' "$event" | jq -r '.timestamp')
            session_cwd=$(printf '%s\n' "$event" | jq -r '.cwd')
          fi
          ;;
        user)
          if [ "$first_user_seen" -eq 0 ]; then
            first_user_seen=1
            refs_json=$(printf '%s\n' "$event" | jq -c '.refs')
          fi
          ;;
        usage)
          FILE_USAGE+=("$event")
          ;;
        parse_error)
          file_parse_errors=$((file_parse_errors + 1))
          ;;
      esac
    done <<EOF
$raw
EOF

    PARSE_ERRORS=$((PARSE_ERRORS + file_parse_errors))
    if [ "$file_parse_errors" -gt 0 ]; then
      append_gap malformed-lines "$file" 'malformed JSONL lines were skipped' "$file_parse_errors"
    fi
    if [ "$header_seen" -eq 0 ]; then
      append_gap no-session-header "$file" 'line 1 is not a valid session header'
      continue
    fi
    VALID_SESSIONS=$((VALID_SESSIONS + 1))

    refs_count=$(printf '%s\n' "$refs_json" | jq 'length')
    scope=unattributed
    task=unattributed
    other_home=
    attribution=unattributed
    reason='no unique current-home status path in the first user message'
    if [ "$refs_count" -eq 1 ]; then
      ref_home=$(printf '%s\n' "$refs_json" | jq -r '.[0].home')
      ref_task=$(printf '%s\n' "$refs_json" | jq -r '.[0].task')
      if [ "$ref_home" = "$REPORT_HOME" ]; then
        scope=task
        task=$ref_task
        attribution=first-user-status-path
        reason=
      else
        scope=other-home
        task=$ref_task
        other_home=$ref_home
        attribution=other-home-status-path
        reason='the first user message points to another Firstmate home'
      fi
    elif [ "$refs_count" -eq 0 ] && [ "$session_cwd" = "$REPORT_HOME" ]; then
      scope=primary
      task=primary
      attribution=current-home-cwd
      reason=
    elif [ "$refs_count" -gt 1 ]; then
      reason='multiple absolute Firstmate status paths occur in the first user message'
    elif [ "$first_user_seen" -eq 0 ]; then
      reason='no user message was found'
    fi

    SESSIONS+=("$(jq -cn \
      --arg scope "$scope" --arg task "$task" --arg other_home "$other_home" \
      --arg attribution "$attribution" --arg reason "$reason" \
      --arg id "$session_id" --arg timestamp "$session_timestamp" \
      --arg cwd "$session_cwd" --arg file "$file" \
      '{scope:$scope,task:$task,other_home:$other_home,attribution:$attribution,
        reason:$reason,id:$id,timestamp:$timestamp,cwd:$cwd,file:$file}')")
    for event in "${FILE_USAGE[@]+"${FILE_USAGE[@]}"}"; do
      EVENTS+=("$(printf '%s\n' "$event" | jq -c \
        --arg scope "$scope" --arg task "$task" --arg other_home "$other_home" \
        --arg session_id "$session_id" --arg file "$file" \
        '. + {scope:$scope,task:$task,other_home:$other_home,
              session_id:$session_id,file:$file}')")
    done
  done < <(find "$SESSION_DIR" -type f -name '*.jsonl' -print | LC_ALL=C sort)
else
  append_gap missing-session-dir "$SESSION_DIR" 'session directory does not exist'
fi
if [ "$SCAN_FILES" -eq 0 ] && [ -d "$SESSION_DIR" ]; then
  append_gap no-sessions "$SESSION_DIR" 'no Pi session files were found'
fi

EVENTS_JSON=$(json_array_from_lines "${EVENTS[@]+"${EVENTS[@]}"}")
SESSIONS_JSON=$(json_array_from_lines "${SESSIONS[@]+"${SESSIONS[@]}"}")

MODELS_STORE_STATE=ok
if [ ! -e "$MODELS_STORE" ]; then
  MODELS_STORE_STATE=missing
  KNOWN_MODELS_JSON='[]'
elif [ ! -r "$MODELS_STORE" ]; then
  MODELS_STORE_STATE=unreadable
  KNOWN_MODELS_JSON='[]'
elif KNOWN_MODELS_JSON=$(jq -ce '
  if type != "object" then error("models store is not an object") else
    [to_entries[] as $provider |
      ($provider.value.models // [])[]? |
      select((.id? | type) == "string") |
      ($provider.key + "/" + .id)
    ] | unique
  end
' -- "$MODELS_STORE" 2>/dev/null); then
  :
else
  MODELS_STORE_STATE=corrupt
  KNOWN_MODELS_JSON='[]'
fi
case "$MODELS_STORE_STATE" in
  missing) append_gap models-store-missing "$MODELS_STORE" 'models store does not exist' ;;
  unreadable) append_gap models-store-unreadable "$MODELS_STORE" 'models store is unreadable' ;;
  corrupt) append_gap models-store-corrupt "$MODELS_STORE" 'models store is not valid supported JSON' ;;
esac
GAPS_JSON=$(json_array_from_lines "${GAPS[@]+"${GAPS[@]}"}")

RESULT=$(jq -n \
  --arg home "$REPORT_HOME" \
  --arg generated_at "$NOW" \
  --arg models_store_state "$MODELS_STORE_STATE" \
  --argjson events "$EVENTS_JSON" \
  --argjson sessions "$SESSIONS_JSON" \
  --argjson initial_gaps "$GAPS_JSON" \
  --argjson known_models "$KNOWN_MODELS_JSON" \
  --argjson scan_files "$SCAN_FILES" \
  --argjson scan_bytes "$SCAN_BYTES" \
  --argjson parse_errors "$PARSE_ERRORS" \
  --argjson valid_sessions "$VALID_SESSIONS" '
  def sum_field($rows; $path):
    ([$rows[] | getpath($path) | select(type == "number")] | add // 0);
  def billing_basis($provider):
    if $provider == "github-copilot" or $provider == "openai-codex" then "subscription"
    else "unknown"
    end;
  def costs($rows):
    ([$rows[] | select(.cost_known != true)] | length) as $unknown |
    (sum_field($rows; ["cost"])) as $known |
    {
      est_cost_usd:(if $unknown == 0 then $known else null end),
      known_cost_usd:$known,
      unknown_cost_events:$unknown
    };
  def token_totals($rows):
    {
      input:sum_field($rows; ["tokens","input"]),
      output:sum_field($rows; ["tokens","output"]),
      cacheRead:sum_field($rows; ["tokens","cacheRead"]),
      cacheWrite:sum_field($rows; ["tokens","cacheWrite"]),
      reasoning:sum_field($rows; ["tokens","reasoning"]),
      cacheWrite1h:sum_field($rows; ["tokens","cacheWrite1h"])
    };
  def aggregate($rows):
    ({
      calls:sum_field($rows; ["calls"]),
      turns:sum_field($rows; ["turns"]),
      tokens:token_totals($rows),
      cost_source:"pi-stored"
    } + costs($rows));
  def origin_split($rows):
    {
      direct:aggregate([$rows[] | select(.origin == "direct")]),
      subagent:aggregate([$rows[] | select(.origin == "subagent")])
    };
  def billing_split($rows):
    {
      subscription:costs([$rows[] | select(billing_basis(.provider) == "subscription")]),
      metered:costs([$rows[] | select(billing_basis(.provider) == "metered")]),
      unknown:costs([$rows[] | select(billing_basis(.provider) == "unknown")])
    };
  def model_rows($rows):
    [$rows | sort_by([.model,.origin]) | group_by([.model,.origin])[] |
      . as $group |
      ({
        model:$group[0].model,
        origin:$group[0].origin,
        calls:sum_field($group; ["calls"]),
        turns:sum_field($group; ["turns"]),
        tokens:token_totals($group),
        billing_basis:billing_basis($group[0].provider),
        cost_source:"pi-stored"
      } + costs($group))
    ];
  def bucket($rows; $bucket_sessions):
    ({
      sessions:($bucket_sessions | length),
      calls:sum_field($rows; ["calls"]),
      turns:sum_field($rows; ["turns"]),
      tokens:token_totals($rows),
      models:model_rows($rows),
      by_origin:origin_split($rows),
      by_billing_basis:billing_split($rows),
      cost_source:"pi-stored"
    } + costs($rows));
  ($events | sort_by([.identity,
      (if .scope == "other-home" then 2 elif .scope == "unattributed" then 1 else 0 end),
      .file,.line]) | group_by(.identity)) as $identity_groups |
  ([$identity_groups[] | .[0]]) as $deduped |
  ([$identity_groups[] | .[1:][]]) as $suppressed |
  ([$deduped[] | select(.scope != "other-home")]) as $included |
  ([$sessions[] | select(.scope != "other-home")]) as $included_sessions |
  ([$deduped[] | select(.scope == "primary")]) as $primary_events |
  ([$sessions[] | select(.scope == "primary")]) as $primary_sessions |
  ([$deduped[] | select(.scope == "unattributed")]) as $unattributed_events |
  ([$sessions[] | select(.scope == "unattributed")]) as $unattributed_sessions |
  ([$sessions[] | select(.scope == "task") | .task] | unique) as $task_names |
  ([$task_names[] as $task |
    ([$deduped[] | select(.scope == "task" and .task == $task)]) as $rows |
    ([$sessions[] | select(.scope == "task" and .task == $task)]) as $task_sessions |
    ({task:$task,attribution:"first-user-status-path"} + bucket($rows; $task_sessions))
  ]) as $tasks |
  ([$sessions[] | select(.scope == "other-home") | .other_home] | unique) as $other_names |
  ([$other_names[] as $other_home |
    ([$deduped[] | select(.scope == "other-home" and .other_home == $other_home)]) as $rows |
    ([$sessions[] | select(.scope == "other-home" and .other_home == $other_home)]) as $home_sessions |
    ({home:$other_home,omitted:true,sessions:($home_sessions | length)} + costs($rows))
  ]) as $other_homes |
  ([$deduped[] |
    . as $event |
    select(($known_models | index($event.model)) == null) |
    {kind:"missing-model-metadata",model:$event.model}
  ] | group_by(.model) | map(.[0] + {count:length})) as $model_gaps |
  ([$deduped[] | select(.cost_known != true) |
    {kind:"unknown-cost",model:.model,origin:.origin}
  ] | group_by([.model,.origin]) | map(.[0] + {count:length})) as $cost_gaps |
  (if ($unattributed_sessions | length) > 0 then
     [({kind:"unattributed",reason:"sessions could not be tied to one current-home task"}
       + costs($unattributed_events)
       + {sessions:($unattributed_sessions | length)})]
   else [] end) as $unattributed_gaps |
  ([$other_homes[] |
    {kind:"other-home-omitted",home:.home,reason:"full all-home rollup is deferred",
     sessions:.sessions,est_cost_usd:.est_cost_usd,
     known_cost_usd:.known_cost_usd,unknown_cost_events:.unknown_cost_events}
  ]) as $other_gaps |
  {
    contract:"fm-costs.v1",
    caveat:"Dollar values are list-price valuations, not invoices.",
    home:$home,
    generated_at:$generated_at,
    counting_rule:"executed-calls-global-structured-identity-dedup",
    cost_source:"Pi stored per-call cost",
    inputs:{models_store_state:$models_store_state},
    scan:{
      files:$scan_files,
      bytes:$scan_bytes,
      sessions:$valid_sessions,
      included_sessions:($included_sessions | length),
      parse_errors:$parse_errors,
      deduplicated_entries:($suppressed | length),
      deduplicated_known_cost_usd:sum_field($suppressed; ["cost"]),
      deduplicated_unknown_cost_events:([$suppressed[] | select(.cost_known != true)] | length)
    },
    primary:({task:"primary",attribution:"current-home-cwd"} + bucket($primary_events; $primary_sessions)),
    tasks:$tasks,
    unattributed:(bucket($unattributed_events; $unattributed_sessions)
      + {files:($unattributed_sessions | map(.file) | unique)}),
    other_homes:$other_homes,
    totals:({
      calls:sum_field($included; ["calls"]),
      turns:sum_field($included; ["turns"]),
      tokens:token_totals($included),
      by_origin:origin_split($included),
      subagent:aggregate([$included[] | select(.origin == "subagent")]),
      by_billing_basis:billing_split($included),
      cost_source:"pi-stored"
    } + costs($included)),
    gaps:($initial_gaps + $model_gaps + $cost_gaps + $unattributed_gaps + $other_gaps)
  }
') || { printf 'fm-costs: report aggregation failed\n' >&2; exit 1; }

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$RESULT"
  exit 0
fi

printf '%s\n' "$RESULT" | jq -r '
  def money: if . == null then "null" else tostring end;
  def model_line:
    "    " + .origin + " " + .model
    + ": calls=" + (.calls|tostring)
    + " turns=" + (.turns|tostring)
    + " input=" + (.tokens.input|tostring)
    + " output=" + (.tokens.output|tostring)
    + " cacheRead=" + (.tokens.cacheRead|tostring)
    + " cacheWrite=" + (.tokens.cacheWrite|tostring)
    + " reasoning=" + (.tokens.reasoning|tostring)
    + " cacheWrite1h=" + (.tokens.cacheWrite1h|tostring)
    + " est_cost_usd=" + (.est_cost_usd|money)
    + " known_cost_usd=" + (.known_cost_usd|money)
    + " unknown_cost_events=" + (.unknown_cost_events|tostring)
    + " billing_basis=" + .billing_basis
    + " cost_source=" + .cost_source;
  def bucket_lines($name; $bucket):
    ($name + ": sessions=" + ($bucket.sessions|tostring)
      + " est_cost_usd=" + ($bucket.est_cost_usd|money)
      + " known_cost_usd=" + ($bucket.known_cost_usd|money)
      + " unknown_cost_events=" + ($bucket.unknown_cost_events|tostring)),
    ($bucket.models[]? | model_line);
  "contract: " + .contract,
  "caveat: " + .caveat,
  "home: " + .home,
  "generated_at: " + .generated_at,
  "counting_rule: " + .counting_rule,
  "cost_source: " + .cost_source,
  "scan: files=" + (.scan.files|tostring)
    + " bytes=" + (.scan.bytes|tostring)
    + " sessions=" + (.scan.sessions|tostring)
    + " included_sessions=" + (.scan.included_sessions|tostring)
    + " parse_errors=" + (.scan.parse_errors|tostring)
    + " deduplicated_entries=" + (.scan.deduplicated_entries|tostring)
    + " deduplicated_known_cost_usd=" + (.scan.deduplicated_known_cost_usd|money)
    + " deduplicated_unknown_cost_events=" + (.scan.deduplicated_unknown_cost_events|tostring),
  bucket_lines("primary"; .primary),
  "tasks[" + (.tasks|length|tostring) + "]:",
  (.tasks[] | bucket_lines("  " + .task; .)),
  bucket_lines("unattributed"; .unattributed),
  "other_homes[" + (.other_homes|length|tostring) + "]:",
  (.other_homes[] | "  " + .home + ": omitted=true sessions=" + (.sessions|tostring)
    + " est_cost_usd=" + (.est_cost_usd|money)
    + " known_cost_usd=" + (.known_cost_usd|money)
    + " unknown_cost_events=" + (.unknown_cost_events|tostring)),
  "totals: est_cost_usd=" + (.totals.est_cost_usd|money)
    + " known_cost_usd=" + (.totals.known_cost_usd|money)
    + " unknown_cost_events=" + (.totals.unknown_cost_events|tostring)
    + " subagent_est_cost_usd=" + (.totals.subagent.est_cost_usd|money)
    + " subagent_known_cost_usd=" + (.totals.subagent.known_cost_usd|money),
  "billing_basis: subscription=" + (.totals.by_billing_basis.subscription.est_cost_usd|money)
    + " metered=" + (.totals.by_billing_basis.metered.est_cost_usd|money)
    + " unknown=" + (.totals.by_billing_basis.unknown.est_cost_usd|money),
  "gaps[" + (.gaps|length|tostring) + "]:",
  (.gaps[]? | "  " + .kind
    + (if .home then " home=" + .home else "" end)
    + (if .model then " model=" + .model else "" end)
    + (if .origin then " origin=" + .origin else "" end)
    + (if .sessions then " sessions=" + (.sessions|tostring) else "" end)
    + (if .count and .count != 0 then " count=" + (.count|tostring) else "" end)
    + (if has("known_cost_usd") then " known_cost_usd=" + (.known_cost_usd|money) else "" end)
    + (if .reason then " reason=" + .reason else "" end)),
  "caveat: " + .caveat
'
