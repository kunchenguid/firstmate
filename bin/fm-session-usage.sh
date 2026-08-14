#!/usr/bin/env bash
# fm-session-usage.sh - read-only JSON report for an observed-stable Pi session.
#
# Usage:
#   fm-session-usage.sh [--run-label <label>] [--role <role>]
#     [--task <task>] [--attempt <number>] [--settle-ms <number>] <session.jsonl>
#
# The input must be a regular Pi JSONL session file. The report is final only
# when the file has a session header, every non-blank line is valid JSON, and
# the file identity and size stay unchanged while it is read and during the
# settle check. A growing or replaced file is reported as non-final.
#
# Only top-level usage-bearing entries are measured. Compaction retained tails,
# details, prompts, tool output, credentials, authenticated content, and source
# paths are never emitted. Caller-supplied metadata is content-free only when it
# uses the accepted tag syntax; primary versus worker identity is never guessed.
# This phase does not create a correlation sidecar or add runtime instrumentation.
# Provider usage and model-rate cost estimates are separate and neither is
# subscription or quota consumption.
set -euo pipefail

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-session-usage: %s\n' "$*" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || die 'jq is required'

RUN_LABEL=
ROLE=
TASK=
ATTEMPT=
SETTLE_MS=10
RUN_LABEL_SET=0
ROLE_SET=0
TASK_SET=0
ATTEMPT_SET=0

validate_tag() {
  local name=$1 value=$2
  [ -n "$value" ] || die "$name must not be empty"
  [ "${#value}" -le 128 ] || die "$name is too long"
  case "$value" in
    *[!A-Za-z0-9._:+,@-]*) die "$name must be a content-free tag" ;;
  esac
}

validate_milliseconds() {
  case "$1" in
    ''|*[!0-9]*) die 'settle milliseconds must be a non-negative integer' ;;
  esac
  [ "$1" -le 60000 ] || die 'settle milliseconds must be at most 60000'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-label)
      [ "$#" -ge 2 ] || die '--run-label requires a value'
      RUN_LABEL=$2
      validate_tag run-label "$RUN_LABEL"
      RUN_LABEL_SET=1
      shift 2
      ;;
    --role)
      [ "$#" -ge 2 ] || die '--role requires a value'
      ROLE=$2
      validate_tag role "$ROLE"
      ROLE_SET=1
      shift 2
      ;;
    --task)
      [ "$#" -ge 2 ] || die '--task requires a value'
      TASK=$2
      validate_tag task "$TASK"
      TASK_SET=1
      shift 2
      ;;
    --attempt)
      [ "$#" -ge 2 ] || die '--attempt requires a value'
      case "$2" in
        ''|*[!0-9]*) die 'attempt must be a non-negative integer' ;;
      esac
      ATTEMPT=$2
      ATTEMPT_SET=1
      shift 2
      ;;
    --settle-ms)
      [ "$#" -ge 2 ] || die '--settle-ms requires a value'
      SETTLE_MS=$2
      validate_milliseconds "$SETTLE_MS"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

[ "$#" -eq 1 ] || die 'one session JSONL path is required'
SESSION_FILE=$1
case "$SESSION_FILE" in
  -*) die 'session path must not start with a dash' ;;
esac
[ -f "$SESSION_FILE" ] || die 'session path is not a readable regular file'
[ -r "$SESSION_FILE" ] || die 'session path is not a readable regular file'

stat_signature() {
  local path=$1 result
  if result=$(stat -c '%d:%i:%s:%Y:%Z' "$path" 2>/dev/null); then
    printf '%s\n' "$result"
    return 0
  fi
  stat -f '%d:%i:%z:%m' "$path" 2>/dev/null
}

sleep_milliseconds() {
  local milliseconds=$1 seconds fraction
  [ "$milliseconds" -gt 0 ] || return 0
  seconds=$((milliseconds / 1000))
  fraction=$((milliseconds % 1000))
  if [ "$seconds" -gt 0 ]; then
    sleep "${seconds}.$(printf '%03d' "$fraction")"
  else
    sleep "0.$(printf '%03d' "$fraction")"
  fi
}

BEFORE_SIGNATURE=$(stat_signature "$SESSION_FILE") || die 'could not inspect session file'
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-session-usage.XXXXXX") || die 'could not create a private temporary directory'
RECORDS_FILE=$TMP_DIR/records.jsonl
WARNINGS_FILE=$TMP_DIR/warnings.jsonl
: >"$RECORDS_FILE"
: >"$WARNINGS_FILE"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

append_warning() {
  printf '%s\n' "$1" >>"$WARNINGS_FILE"
}

exec 3<"$SESSION_FILE" || die 'could not open session file'
LINE_NUMBER=0
MALFORMED_COUNT=0
while IFS= read -r line <&3 || [ -n "$line" ]; do
  LINE_NUMBER=$((LINE_NUMBER + 1))
  [ -n "$line" ] || continue

  if ! json=$(printf '%s\n' "$line" | jq -c . 2>/dev/null); then
    append_warning "{\"code\":\"malformed_json\",\"line\":$LINE_NUMBER}"
    MALFORMED_COUNT=$((MALFORMED_COUNT + 1))
    continue
  fi
  if ! printf '%s\n' "$json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    append_warning "{\"code\":\"record_not_object\",\"line\":$LINE_NUMBER}"
    MALFORMED_COUNT=$((MALFORMED_COUNT + 1))
    continue
  fi
  if ! printf '%s\n' "$json" | jq -c --argjson line "$LINE_NUMBER" '. + {"_fm_line": $line}' \
    >>"$RECORDS_FILE" 2>/dev/null; then
    append_warning "{\"code\":\"record_unreadable\",\"line\":$LINE_NUMBER}"
    MALFORMED_COUNT=$((MALFORMED_COUNT + 1))
  fi
done
exec 3<&-

AFTER_READ_SIGNATURE=$(stat_signature "$SESSION_FILE" 2>/dev/null || true)
sleep_milliseconds "$SETTLE_MS"
AFTER_SETTLE_SIGNATURE=$(stat_signature "$SESSION_FILE" 2>/dev/null || true)

STABILITY=stable
STABLE_BOOL=true
if [ -z "$AFTER_READ_SIGNATURE" ] || [ -z "$AFTER_SETTLE_SIGNATURE" ] || \
  [ "$BEFORE_SIGNATURE" != "$AFTER_READ_SIGNATURE" ] || \
  [ "$BEFORE_SIGNATURE" != "$AFTER_SETTLE_SIGNATURE" ]; then
  STABILITY=unstable
  STABLE_BOOL=false
fi

jq -s \
  --slurpfile input_warnings "$WARNINGS_FILE" \
  --arg stability "$STABILITY" \
  --argjson stable "$STABLE_BOOL" \
  --argjson malformed "$MALFORMED_COUNT" \
  --arg run_label "$RUN_LABEL" \
  --arg role "$ROLE" \
  --arg task "$TASK" \
  --arg attempt "$ATTEMPT" \
  --argjson run_label_set "$RUN_LABEL_SET" \
  --argjson role_set "$ROLE_SET" \
  --argjson task_set "$TASK_SET" \
  --argjson attempt_set "$ATTEMPT_SET" \
  '
  def string_or_null($value):
    if ($value | type) == "string" and ($value | length) > 0 then $value else null end;

  def session_id_or_null($value):
    if ($value | type) == "string" and ($value | test("^[A-Za-z0-9._:-]{1,128}$")) then $value else null end;

  def nonnegative_number($value):
    if ($value | type) == "number" and $value >= 0 then $value else null end;

  def usage_object($value):
    if ($value | type) == "object" then $value else null end;

  def token_value($usage; $key):
    nonnegative_number(($usage[$key] // null));

  def cost_value($usage; $key):
    nonnegative_number(($usage.cost[$key] // null));

  def provider_usage($usage):
    (usage_object($usage)) as $u |
    if $u == null then null
    else {
      input: token_value($u; "input"),
      cache_read: token_value($u; "cacheRead"),
      cache_write: token_value($u; "cacheWrite"),
      output: token_value($u; "output"),
      reasoning: token_value($u; "reasoning"),
      provider_total: token_value($u; "totalTokens")
    }
    end;

  def model_rate_cost($usage):
    (usage_object($usage)) as $u |
    if $u == null or (($u.cost | type) != "object") then null
    else {
      input: cost_value($u; "input"),
      cache_read: cost_value($u; "cacheRead"),
      cache_write: cost_value($u; "cacheWrite"),
      output: cost_value($u; "output"),
      total: cost_value($u; "total")
    }
    end;

  def usage_state($parent):
    if ($parent | type) != "object" or ($parent | has("usage") | not) then "missing"
    elif (($parent.usage | type) != "object") then "invalid"
    else "present"
    end;

  def measurement($entry; $entry_class; $parent; $provider; $model):
    {
      entry_class: $entry_class,
      line: ($entry._fm_line // null),
      provider: string_or_null($provider),
      model: string_or_null($model),
      usage_state: usage_state($parent),
      has_usage: (usage_state($parent) == "present"),
      provider_usage: provider_usage($parent.usage?),
      model_rate_cost_estimate: model_rate_cost($parent.usage?)
    };

  def measurements($entries):
    [
      $entries[] as $entry |
      if $entry.type == "message" and ($entry.message | type) == "object" and $entry.message.role == "assistant" then
        measurement($entry; "assistant"; $entry.message; $entry.message.provider?; $entry.message.model?)
      elif $entry.type == "message" and ($entry.message | type) == "object" and $entry.message.role == "toolResult" then
        measurement($entry; "tool_result"; $entry.message; null; null)
      elif $entry.type == "compaction" then
        measurement($entry; "compaction"; $entry; null; null)
      elif $entry.type == "branch_summary" then
        measurement($entry; "branch_summary"; $entry; null; null)
      else empty
      end
    ];

  def usage_warnings($measurement):
    if $measurement.usage_state == "missing" then
      [{code: "missing_usage", entry_class: $measurement.entry_class, line: $measurement.line}]
    elif $measurement.usage_state == "invalid" then
      [{code: "invalid_usage", entry_class: $measurement.entry_class, line: $measurement.line}]
    else
      (
        [
          {key: "input", field: "input"},
          {key: "cache_read", field: "cacheRead"},
          {key: "cache_write", field: "cacheWrite"},
          {key: "output", field: "output"},
          {key: "provider_total", field: "totalTokens"}
        ]
        | map(select($measurement.provider_usage[.key] == null) |
          {code: "unknown_usage_field", entry_class: $measurement.entry_class,
           field: .field, line: $measurement.line})
      ) +
      if $measurement.model_rate_cost_estimate == null then
        [{code: "unknown_model_rate_cost", entry_class: $measurement.entry_class, line: $measurement.line}]
      else []
      end
    end;

  def aggregate($measurements; $section; $key; $zero_if_empty):
    if ($measurements | length) == 0 then
      if $zero_if_empty then 0 else null end
    elif any($measurements[]; .has_usage == false) then null
    else
      ($measurements | map(.[$section][$key])) as $values |
      if any($values[]; . == null) then null
      else reduce $values[] as $value (0; . + $value)
      end
    end;

  def aggregate_section($measurements; $section; $zero_if_empty):
    {
      input: aggregate($measurements; $section; "input"; $zero_if_empty),
      cache_read: aggregate($measurements; $section; "cache_read"; $zero_if_empty),
      cache_write: aggregate($measurements; $section; "cache_write"; $zero_if_empty),
      output: aggregate($measurements; $section; "output"; $zero_if_empty),
      reasoning: aggregate($measurements; $section; "reasoning"; false),
      provider_total: aggregate($measurements; $section; "provider_total"; false)
    };

  . as $entries |
  (measurements($entries)) as $measurements |
  ($entries | map(select(.type == "session"))) as $headers |
  ($headers[0] // {}) as $header |
  (
    $input_warnings +
    ([$measurements[] | usage_warnings(.)[]]) +
    (if ($headers | length) == 0 then [{code: "missing_session_header"}]
     elif ($headers | length) > 1 then [{code: "multiple_session_headers"}]
     else [] end) +
    ([$entries[] | select(.type == "compaction" and (.retainedTail | type) == "array") |
      {code: "embedded_history_ignored", entry_class: "compaction", line: ._fm_line}]) +
    (if $stable then [] else [{code: "unstable_file"}] end)
  ) as $warnings |
  {
    schema: 1,
    artifact: {
      format: "pi-session-jsonl",
      stability: $stability,
      final: ($stable and ($malformed == 0) and (($headers | length) == 1))
    },
    session: {
      id: session_id_or_null($header.id?),
      version: if ($header.version | type) == "number" then $header.version else null end
    },
    metadata: {
      run_label: if $run_label_set == 1 then $run_label else null end,
      role: if $role_set == 1 then $role else null end,
      task: if $task_set == 1 then $task else null end,
      attempt: if $attempt_set == 1 then ($attempt | tonumber) else null end
    },
    entry_counts: {
      parsed: ($entries | length),
      malformed: $malformed,
      session: ($entries | map(select(.type == "session")) | length),
      message: ($entries | map(select(.type == "message")) | length),
      user_message: ($entries | map(select(.type == "message" and (.message.role? // null) == "user")) | length),
      assistant_message: ($entries | map(select(.type == "message" and (.message.role? // null) == "assistant")) | length),
      tool_result_message: ($entries | map(select(.type == "message" and (.message.role? // null) == "toolResult")) | length),
      compaction: ($entries | map(select(.type == "compaction")) | length),
      branch_summary: ($entries | map(select(.type == "branch_summary")) | length),
      other: ($entries | map(select(.type != "session" and .type != "message" and .type != "compaction" and .type != "branch_summary")) | length)
    },
    calls: {
      assistant: ($entries | map(select(.type == "message" and (.message.role? // null) == "assistant")) | length),
      tool: ([$entries[] | select(.type == "message") | .message.content? // [] | .[]? | select(type == "object" and .type == "toolCall")] | length),
      tool_result: ($entries | map(select(.type == "message" and (.message.role? // null) == "toolResult")) | length),
      compaction: ($entries | map(select(.type == "compaction")) | length),
      branch_summary: ($entries | map(select(.type == "branch_summary")) | length),
      measured: ($measurements | map(select(.has_usage)) | length)
    },
    records: $measurements,
    totals: {
      provider_usage: aggregate_section($measurements; "provider_usage"; true),
      model_rate_cost_estimate: {
        input: aggregate($measurements; "model_rate_cost_estimate"; "input"; true),
        cache_read: aggregate($measurements; "model_rate_cost_estimate"; "cache_read"; true),
        cache_write: aggregate($measurements; "model_rate_cost_estimate"; "cache_write"; true),
        output: aggregate($measurements; "model_rate_cost_estimate"; "output"; true),
        total: aggregate($measurements; "model_rate_cost_estimate"; "total"; true)
      }
    },
    warnings: $warnings,
    limitations: [
      "final means the regular file stayed unchanged during this read and settle check; Pi JSONL has no closed marker.",
      "Provider usage is not subscription or quota consumption, and model-rate cost is an estimate rather than a billing record.",
      "Worker identity and run correlation are caller-supplied only; this parser does not infer primary versus worker or create a sidecar."
    ]
  }
' "$RECORDS_FILE"
