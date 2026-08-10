#!/usr/bin/env bash
# fm-daily.sh - summarize one recorded day for a human decision.
# Usage: fm-daily.sh [--full] [YYYY-MM-DD]
#
# This is a manual, read-only report. A compatible tasks-axi backend is required
# to read backlog facts; a configured manual backend is reported as a data gap.
# Legacy ledger rows and undated completed tasks are counted but never guessed
# into a day or outcome. Attempts without explicit terminal outcomes force
# questions 2 and 4 to refuse an answer. Status logs are validated with the
# shared status grammar, but their undated events cannot support day-level claims.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BACKLOG="$DATA/backlog.md"
LEDGER="$DATA/routing-outcomes.jsonl"
TODAY=$(date +%F)

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  printf '%s\n' \
    "Usage: ${0##*/} [--full] [YYYY-MM-DD]" \
    '' \
    'Summarize deliveries, model outcomes, and active blockers for one day.' \
    'Compact output shows at most 3 entries per section; --full shows all entries.' \
    'Requires the configured tasks-axi backend for backlog facts.' \
    'Legacy ledger rows, undated completions, and missing terminal outcomes are named as data gaps.' \
    'Unmatched status lines are skipped and counted; status events remain undated.'
}

valid_date() {
  local value=$1 year month day days
  [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  year=$((10#${value:0:4}))
  month=$((10#${value:5:2}))
  day=$((10#${value:8:2}))
  case "$month" in
    1|3|5|7|8|10|12) days=31 ;;
    4|6|9|11) days=30 ;;
    2)
      days=28
      if ((year % 400 == 0 || (year % 4 == 0 && year % 100 != 0))); then
        days=29
      fi
      ;;
    *) return 1 ;;
  esac
  ((day >= 1 && day <= days))
}

FULL=0
REPORT_DAY=
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --full)
      FULL=1
      ;;
    -*)
      printf 'error: unknown option: %s\n' "$arg" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$REPORT_DAY" ]; then
        usage >&2
        exit 2
      fi
      REPORT_DAY=$arg
      ;;
  esac
done

REPORT_DAY=${REPORT_DAY:-$TODAY}
if ! valid_date "$REPORT_DAY"; then
  printf 'error: invalid date: %s (expected a YYYY-MM-DD calendar date)\n' "$REPORT_DAY" >&2
  exit 2
fi

DISPLAY_LIMIT=3
if [ "$FULL" -eq 1 ]; then
  DISPLAY_LIMIT=1000000
fi

BACKLOG_STATE=ok
BACKLOG_DIAG=
BACKLOG_TOTAL=0
DELIVERIES=
DELIVERY_COUNT=0
DELIVERY_SHOWN=0
UNDATED_DELIVERY_COUNT=0
BLOCKERS=
BLOCKER_COUNT=0
BLOCKER_SHOWN=0

backlog_bad() {
  BACKLOG_STATE=bad
  BACKLOG_DIAG=$1
  DELIVERIES=
  DELIVERY_COUNT=0
  DELIVERY_SHOWN=0
  UNDATED_DELIVERY_COUNT=0
  BLOCKERS=
  BLOCKER_COUNT=0
  BLOCKER_SHOWN=0
}

backlog_gap() {
  backlog_bad "$1"
  BACKLOG_STATE=gap
}

task_rows() {
  sed -n 's/^  \([A-Za-z0-9._-][A-Za-z0-9._-]*,.*\)$/\1/p'
}

task_atom() {
  local value=$1
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"}; value=${value//\"\"/\"} ;;
  esac
  printf '%s' "$value"
}

task_row_last_field() {
  local row=$1
  # tasks-axi quotes comma-containing fields, so split at the field's opening
  # quote instead of treating an internal comma as a column boundary.
  case "$row" in
    *\") printf '%s' "${row##*,\"}" ;;
    *) printf '%s' "${row##*,}" ;;
  esac
}

task_row_without_last_field() {
  local row=$1
  case "$row" in
    *\") printf '%s' "${row%,\"*}" ;;
    *) printf '%s' "${row%,*}" ;;
  esac
}

task_list_count() {
  local value=$1 separators
  case "$value" in
    ''|-) printf '0' ;;
    *)
      separators=${value//[^,]/}
      printf '%s' "$((${#separators} + 1))"
      ;;
  esac
}

tasks_list() {
  tasks-axi list --file "$BACKLOG" --limit 10000 "$@" 2>&1
}

task_row_identity() {
  local row=$1 trailing_fields=$2 id rest kind repo title
  id=${row%%,*}
  rest=${row#*,}
  rest=${rest#*,}
  kind=${rest%%,*}
  rest=${rest#*,}
  repo=${rest%%,*}
  rest=${rest#*,}
  while [ "$trailing_fields" -gt 0 ]; do
    rest=$(task_row_without_last_field "$rest")
    trailing_fields=$((trailing_fields - 1))
  done
  title=$(task_atom "$rest")
  title=${title//\\n/ }
  printf '%s [%s/%s]: %s' "$id" "$repo" "$kind" "$title"
}

load_backlog() {
  local listing rows row rest kind closed held prefix blocked_by identity_row blocker_total blocker_noun
  if [ ! -e "$BACKLOG" ]; then
    BACKLOG_STATE=absent
    BACKLOG_DIAG="backlog source is absent at $BACKLOG"
    return
  fi
  if [ ! -f "$BACKLOG" ] || [ ! -r "$BACKLOG" ]; then
    backlog_bad "backlog source is unreadable or malformed at $BACKLOG"
    return
  fi
  if [ ! -s "$BACKLOG" ]; then
    return
  fi
  if ! fm_tasks_axi_backend_available "$CONFIG"; then
    backlog_gap "tasks-axi backlog backend is disabled or incompatible"
    return
  fi
  if ! listing=$(tasks_list); then
    backlog_bad "backlog source is unreadable or malformed: $(printf '%s\n' "$listing" | sed -n '1p')"
    return
  fi
  BACKLOG_TOTAL=$(printf '%s\n' "$listing" | sed -n 's/^count: \([0-9][0-9]*\).*/\1/p' | sed -n '1p')
  case "$BACKLOG_TOTAL" in
    ''|*[!0-9]*) backlog_bad "backlog source is unreadable or malformed: tasks-axi returned no task count"; return ;;
  esac

  if ! listing=$(tasks_list --state 'done' --fields closed); then
    backlog_bad "backlog source is unreadable or malformed: $(printf '%s\n' "$listing" | sed -n '1p')"
    return
  fi
  rows=$(printf '%s\n' "$listing" | task_rows)
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    rest=${row#*,}
    rest=${rest#*,}
    kind=${rest%%,*}
    [ "$kind" = captain ] && continue
    closed=$(task_atom "${row##*,}")
    if [ "$closed" = - ]; then
      UNDATED_DELIVERY_COUNT=$((UNDATED_DELIVERY_COUNT + 1))
      continue
    fi
    [ "$closed" = "$REPORT_DAY" ] || continue
    DELIVERY_COUNT=$((DELIVERY_COUNT + 1))
    if [ "$DELIVERY_SHOWN" -lt "$DISPLAY_LIMIT" ]; then
      DELIVERIES="${DELIVERIES}- $(task_row_identity "$row" 1)"$'\n'
      DELIVERY_SHOWN=$((DELIVERY_SHOWN + 1))
    fi
  done <<EOF
$rows
EOF

  [ "$REPORT_DAY" = "$TODAY" ] || return
  if ! listing=$(tasks_list --blocked --fields blocked_by,held); then
    backlog_bad "backlog source is unreadable or malformed: $(printf '%s\n' "$listing" | sed -n '1p')"
    return
  fi
  rows=$(printf '%s\n' "$listing" | task_rows)
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    held=$(task_atom "${row##*,}")
    [ "$held" = yes ] && continue
    prefix=${row%,*}
    blocked_by=$(task_atom "$(task_row_last_field "$prefix")")
    identity_row=$(task_row_without_last_field "$prefix")
    blocker_total=$(task_list_count "$blocked_by")
    blocker_noun=tasks
    [ "$blocker_total" -eq 1 ] && blocker_noun=task
    BLOCKER_COUNT=$((BLOCKER_COUNT + 1))
    if [ "$BLOCKER_SHOWN" -lt "$DISPLAY_LIMIT" ]; then
      BLOCKERS="${BLOCKERS}- $(task_row_identity "$identity_row" 0) - blocked by $blocker_total $blocker_noun"$'\n'
      BLOCKER_SHOWN=$((BLOCKER_SHOWN + 1))
    fi
  done <<EOF
$rows
EOF
}

LEDGER_STATE=ok
LEDGER_DIAG=
LEDGER_SUMMARY='{"activity":0,"accepted":[],"failed":[],"unknown":0,"legacy":0}'

load_ledger() {
  local sheet error_file diagnostic
  if [ ! -e "$LEDGER" ]; then
    LEDGER_STATE=absent
    LEDGER_DIAG="model ledger source is absent at $LEDGER"
    return
  fi
  if [ ! -f "$LEDGER" ] || [ ! -r "$LEDGER" ]; then
    LEDGER_STATE=bad
    LEDGER_DIAG="model ledger source is unreadable or malformed at $LEDGER"
    return
  fi
  if ! error_file=$(mktemp "${TMPDIR:-/tmp}/fm-daily.XXXXXX"); then
    LEDGER_STATE=bad
    LEDGER_DIAG="model ledger source is unreadable or malformed: could not create a diagnostic file"
    return
  fi
  if ! sheet=$("$FM_ROOT/bin/fm-model-telemetry.sh" sheet --format json 2>"$error_file"); then
    diagnostic=$(tr '\n' ' ' < "$error_file" | sed 's/[[:space:]][[:space:]]*/ /g; s/[[:space:]]*$//')
    rm -f "$error_file"
    LEDGER_STATE=bad
    LEDGER_DIAG="model ledger source is unreadable or malformed: ${diagnostic:-telemetry projection failed}"
    return
  fi
  rm -f "$error_file"
  if ! LEDGER_SUMMARY=$(printf '%s\n' "$sheet" | jq -ce --arg day "$REPORT_DAY" '
    def local_day:
      if . == null then null
      elif type != "string" then error("timestamp is not a string")
      else fromdateiso8601 | localtime | strftime("%Y-%m-%d")
      end;
    if type != "array" then error("sheet is not an array") else . end |
    . as $rows |
    [$rows[] |
      select(.recordType == "attempt") |
      select((.startedAt | local_day) == $day or (.endedAt | local_day) == $day)
    ] as $relevant |
    [$relevant[] |
      select(.state == "terminal" and .classification == "accepted" and .endedAt != null)
    ] as $accepted |
    [$relevant[] |
      select(.state == "terminal" and .classification != null and
        .classification != "accepted" and .classification != "incomplete" and .endedAt != null)
    ] as $failed |
    {
      activity: ($relevant | length),
      accepted: $accepted,
      failed: $failed,
      unknown: (($relevant | length) - ($accepted | length) - ($failed | length)),
      legacy: ([$rows[] |
        select(.recordType != "attempt" and .legacyRaw.date == $day)
      ] | length)
    }
  ' 2>&1); then
    LEDGER_STATE=bad
    LEDGER_DIAG="model ledger source is unreadable or malformed: $(printf '%s\n' "$LEDGER_SUMMARY" | sed -n '1p')"
    LEDGER_SUMMARY='{"activity":0,"accepted":[],"failed":[],"unknown":0,"legacy":0}'
  fi
}

STATUS_NOTE=

load_status_note() {
  local files file line skipped=0
  if [ ! -e "$STATE" ]; then
    STATUS_NOTE="status source is absent at $STATE"
    return
  fi
  if [ ! -d "$STATE" ] || [ ! -r "$STATE" ]; then
    STATUS_NOTE="status source is unreadable at $STATE"
    return
  fi
  shopt -s nullglob
  files=("$STATE"/*.status)
  shopt -u nullglob
  if [ "${#files[@]}" -eq 0 ]; then
    STATUS_NOTE="status source is absent: no status logs under $STATE"
    return
  fi
  for file in "${files[@]}"; do
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
      STATUS_NOTE="status source includes an unreadable log at $file"
      return
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      status_line_is_parseable "$line" || skipped=$((skipped + 1))
    done < "$file"
  done
  STATUS_NOTE="${#files[@]} status log(s) present, but status lines have no timestamps and cannot be attributed to $REPORT_DAY"
  if [ "$skipped" -eq 1 ]; then
    STATUS_NOTE="$STATUS_NOTE; 1 status line skipped because it does not match the shared grammar"
  elif [ "$skipped" -gt 1 ]; then
    STATUS_NOTE="$STATUS_NOTE; $skipped status lines skipped because they do not match the shared grammar"
  fi
}

summary_value() {
  local state=$1 value=$2 noun=$3
  case "$state" in
    ok) printf '%s %s' "$value" "$noun" ;;
    floor) printf 'at least %s %s' "$value" "$noun" ;;
    *) printf '%s unavailable' "$noun" ;;
  esac
}

attempt_count() {
  printf '%s\n' "$LEDGER_SUMMARY" | jq -r ".$1 | if type == \"array\" then length else . end"
}

print_attempts() {
  local key=$1
  printf '%s\n' "$LEDGER_SUMMARY" | jq -r --arg key "$key" --argjson limit "$DISPLAY_LIMIT" '
    .[$key][0:$limit][] |
    "- " + (if $key == "failed" then (.primaryFailureClass // "unknown") else .classification end) +
    " - \([.harness,.model,.effort] | map(select(. != null)) | join("/")) - " +
    (if .wallSeconds == null then "duration absent" else (.wallSeconds | tostring) + "s" end) +
    (if $key == "failed" then " (" + .classification + ")" else "" end)
  '
}

print_hidden() {
  local total=$1 shown=$2 noun=$3 hidden
  hidden=$((total - shown))
  if [ "$hidden" -gt 0 ]; then
    printf '... %s more %s (run with --full).\n' "$hidden" "$noun"
  fi
}

print_legacy_gap() {
  local legacy=$1
  [ "$legacy" -gt 0 ] || return
  printf 'Data gap: %s legacy ledger row%s for %s cannot be classified.\n' \
    "$legacy" "$([ "$legacy" -eq 1 ] || printf s)" "$REPORT_DAY"
  printf 'Missing: terminal classification and failure class.\n'
}

append_attention() {
  local item=$1
  if [ -n "$ATTENTION" ]; then
    ATTENTION="$ATTENTION; $item"
  else
    ATTENTION=$item
  fi
}

load_backlog
load_ledger
load_status_note

activity=0
accepted=0
failed=0
unknown=0
legacy=0
if [ "$LEDGER_STATE" = ok ]; then
  activity=$(attempt_count activity)
  accepted=$(attempt_count accepted)
  failed=$(attempt_count failed)
  unknown=$(attempt_count unknown)
  legacy=$(attempt_count legacy)
fi

ATTENTION=
if [ "$BACKLOG_STATE" != ok ]; then
  append_attention 'backlog evidence unavailable'
elif [ "$UNDATED_DELIVERY_COUNT" -gt 0 ]; then
  append_attention "$UNDATED_DELIVERY_COUNT completed task(s) undated"
fi
if [ "$LEDGER_STATE" != ok ]; then
  append_attention 'ledger evidence unavailable'
else
  [ "$unknown" -eq 0 ] || append_attention "$unknown attempt(s) lack terminal outcomes"
  [ "$legacy" -eq 0 ] || append_attention "$legacy legacy ledger row(s) unclassified"
fi
if [ "$REPORT_DAY" = "$TODAY" ] && [ "$BACKLOG_STATE" = ok ] && [ "$BLOCKER_COUNT" -gt 0 ]; then
  append_attention "$BLOCKER_COUNT active blocker(s)"
fi
[ -n "$ATTENTION" ] || ATTENTION='none recorded'

BLOCKER_SUMMARY_STATE=$BACKLOG_STATE
if [ "$REPORT_DAY" != "$TODAY" ] && [ "$BACKLOG_STATE" = ok ] && [ "$BACKLOG_TOTAL" -gt 0 ]; then
  BLOCKER_SUMMARY_STATE=gap
fi
DELIVERY_SUMMARY_STATE=$BACKLOG_STATE
if [ "$BACKLOG_STATE" = ok ] && [ "$UNDATED_DELIVERY_COUNT" -gt 0 ]; then
  DELIVERY_SUMMARY_STATE=gap
  [ "$DELIVERY_COUNT" -eq 0 ] || DELIVERY_SUMMARY_STATE=floor
fi
FAILED_SUMMARY_STATE=$LEDGER_STATE
if [ "$LEDGER_STATE" = ok ] && { [ "$unknown" -gt 0 ] || [ "$legacy" -gt 0 ]; }; then
  FAILED_SUMMARY_STATE=gap
  [ "$failed" -eq 0 ] || FAILED_SUMMARY_STATE=floor
fi

printf 'Daily report - %s\n' "$REPORT_DAY"
printf 'At a glance: %s; %s; %s.\n' \
  "$(summary_value "$DELIVERY_SUMMARY_STATE" "$DELIVERY_COUNT" deliveries)" \
  "$(summary_value "$FAILED_SUMMARY_STATE" "$failed" 'failed attempts')" \
  "$(summary_value "$BLOCKER_SUMMARY_STATE" "$BLOCKER_COUNT" 'active blockers')"
printf 'Needs attention: %s.\n' "$ATTENTION"

printf '\n1. What did we deliver?\n'
case "$BACKLOG_STATE" in
  absent|bad) printf 'Cannot answer: %s.\n' "$BACKLOG_DIAG" ;;
  gap) printf 'Data gap: %s.\n' "$BACKLOG_DIAG" ;;
  *)
    if [ "$DELIVERY_COUNT" -eq 0 ] && [ "$UNDATED_DELIVERY_COUNT" -eq 0 ]; then
      printf 'No activity recorded for %s.\n' "$REPORT_DAY"
    else
      [ "$DELIVERY_COUNT" -eq 0 ] || printf '%s' "$DELIVERIES"
      print_hidden "$DELIVERY_COUNT" "$DELIVERY_SHOWN" deliveries
      if [ "$UNDATED_DELIVERY_COUNT" -gt 0 ]; then
        printf 'Data gap: %s completed task%s has no close date and cannot be attributed to %s.\n' \
          "$UNDATED_DELIVERY_COUNT" "$([ "$UNDATED_DELIVERY_COUNT" -eq 1 ] || printf s)" "$REPORT_DAY"
      fi
    fi
    ;;
esac

printf '\n2. What went wrong?\n'
case "$LEDGER_STATE" in
  absent|bad) printf 'Cannot answer: %s.\n' "$LEDGER_DIAG" ;;
  *)
    if [ "$activity" -eq 0 ]; then
      if [ "$legacy" -gt 0 ]; then
        print_legacy_gap "$legacy"
      else
        printf 'No activity recorded for %s.\n' "$REPORT_DAY"
      fi
    elif [ "$failed" -gt 0 ]; then
      print_attempts failed
      print_hidden "$failed" "$((failed < DISPLAY_LIMIT ? failed : DISPLAY_LIMIT))" 'failed attempts'
      if [ "$unknown" -gt 0 ]; then
        printf 'Data gap: %s attempt%s lacks an explicit terminal outcome.\n' "$unknown" "$([ "$unknown" -eq 1 ] || printf s)"
      fi
      print_legacy_gap "$legacy"
    elif [ "$unknown" -gt 0 ]; then
      printf 'Cannot answer: %s attempt%s lacks an explicit terminal outcome.\n' "$unknown" "$([ "$unknown" -eq 1 ] || printf s)"
      printf 'Missing: terminal classification, failure class, and end timestamp.\n'
      print_legacy_gap "$legacy"
    else
      printf 'No problems recorded for %s across %s accepted attempt%s.\n' "$REPORT_DAY" "$accepted" "$([ "$accepted" -eq 1 ] || printf s)"
      print_legacy_gap "$legacy"
    fi
    ;;
esac

printf '\n3. What is blocking?\n'
case "$BACKLOG_STATE" in
  absent|bad) printf 'Cannot answer: %s.\n' "$BACKLOG_DIAG" ;;
  gap) printf 'Data gap: %s.\n' "$BACKLOG_DIAG" ;;
  *)
    if [ "$BACKLOG_TOTAL" -eq 0 ]; then
      printf 'No activity recorded for %s.\n' "$REPORT_DAY"
    elif [ "$REPORT_DAY" != "$TODAY" ]; then
      printf 'Cannot answer for a past day: backlog blockers have no start or end timestamps.\n'
      printf 'Missing: dated blocker history.\n'
    elif [ "$BLOCKER_COUNT" -eq 0 ]; then
      printf 'No active blockers recorded for %s.\n' "$REPORT_DAY"
    else
      printf '%s' "$BLOCKERS"
      print_hidden "$BLOCKER_COUNT" "$BLOCKER_SHOWN" blockers
    fi
    ;;
esac

printf '\n4. What is good - what should we keep doing?\n'
case "$LEDGER_STATE" in
  absent|bad) printf 'Cannot answer: %s.\n' "$LEDGER_DIAG" ;;
  *)
    if [ "$activity" -eq 0 ]; then
      if [ "$legacy" -gt 0 ]; then
        print_legacy_gap "$legacy"
      else
        printf 'No activity recorded for %s.\n' "$REPORT_DAY"
      fi
    elif [ "$accepted" -gt 0 ]; then
      print_attempts accepted
      print_hidden "$accepted" "$((accepted < DISPLAY_LIMIT ? accepted : DISPLAY_LIMIT))" 'accepted attempts'
      if [ "$unknown" -gt 0 ]; then
        printf 'Data gap: %s attempt%s lacks an explicit terminal outcome, so the positive evidence is incomplete.\n' "$unknown" "$([ "$unknown" -eq 1 ] || printf s)"
      fi
      print_legacy_gap "$legacy"
    elif [ "$unknown" -gt 0 ]; then
      printf 'Cannot answer: %s attempt%s lacks an explicit terminal outcome.\n' "$unknown" "$([ "$unknown" -eq 1 ] || printf s)"
      printf 'Missing: an accepted classification, end timestamp, and outcome evidence.\n'
      print_legacy_gap "$legacy"
    else
      printf 'No accepted outcomes recorded for %s.\n' "$REPORT_DAY"
      print_legacy_gap "$legacy"
    fi
    ;;
esac

printf '\nData limit: %s.\n' "$STATUS_NOTE"
