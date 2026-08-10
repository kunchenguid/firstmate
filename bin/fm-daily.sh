#!/usr/bin/env bash
# fm-daily.sh - summarize one recorded day for a human decision.
# Usage: fm-daily.sh [YYYY-MM-DD]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
BACKLOG="$FM_HOME/data/backlog.md"
LEDGER="$FM_HOME/data/routing-outcomes.jsonl"
STATE="$FM_HOME/state"
TODAY=$(date +%F)

usage() {
  printf 'Usage: %s [YYYY-MM-DD]\n' "${0##*/}" >&2
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

if [ "$#" -gt 1 ]; then
  usage
  exit 2
fi

REPORT_DAY=${1:-$TODAY}
if ! valid_date "$REPORT_DAY"; then
  printf 'error: invalid date: %s (expected a YYYY-MM-DD calendar date)\n' "$REPORT_DAY" >&2
  exit 2
fi

BACKLOG_STATE=ok
BACKLOG_DIAG=
BACKLOG_TOTAL=0
DELIVERIES=
DELIVERY_COUNT=0
BLOCKERS=
BLOCKER_COUNT=0

backlog_bad() {
  BACKLOG_STATE=bad
  BACKLOG_DIAG=$1
  DELIVERIES=
  DELIVERY_COUNT=0
  BLOCKERS=
  BLOCKER_COUNT=0
}

task_ids() {
  sed -n 's/^  \([A-Za-z0-9._-][A-Za-z0-9._-]*\),.*/\1/p'
}

task_field() {
  local record=$1 key=$2
  printf '%s\n' "$record" | sed -n "s/^  $key: //p" | sed -n '1p'
}

task_identity() {
  local record=$1 id=$2 title repo kind
  title=$(task_field "$record" title)
  repo=$(task_field "$record" repo)
  kind=$(task_field "$record" kind)
  printf '%s [%s/%s]: %s' "$id" "$repo" "$kind" "$title"
}

tasks_list() {
  tasks-axi list --file "$BACKLOG" --limit 10000 "$@" 2>&1
}

load_backlog() {
  local listing ids id record closed blocked held blocked_by hold_kind hold_reason detail seen='|'
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
  if ! command -v tasks-axi >/dev/null 2>&1; then
    backlog_bad "backlog source is unreadable or malformed because tasks-axi is unavailable"
    return
  fi
  if ! listing=$(tasks_list --fields closed,held,hold_reason,hold_kind,blocked,blocked_by); then
    backlog_bad "backlog source is unreadable or malformed: $(printf '%s\n' "$listing" | sed -n '1p')"
    return
  fi
  BACKLOG_TOTAL=$(printf '%s\n' "$listing" | sed -n 's/^count: //p' | sed -n '1p')
  case "$BACKLOG_TOTAL" in ''|*[!0-9]*) backlog_bad "backlog source is unreadable or malformed: tasks-axi returned no task count"; return ;; esac

  if ! listing=$(tasks_list --state 'done' --fields closed); then
    backlog_bad "backlog source is unreadable or malformed: $(printf '%s\n' "$listing" | sed -n '1p')"
    return
  fi
  ids=$(printf '%s\n' "$listing" | task_ids)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if ! record=$(tasks-axi show "$id" --file "$BACKLOG" --full 2>&1); then
      backlog_bad "backlog source is unreadable or malformed: $(printf '%s\n' "$record" | sed -n '1p')"
      return
    fi
    closed=$(task_field "$record" closed)
    if [ "$closed" = "$REPORT_DAY" ]; then
      DELIVERIES="${DELIVERIES}- $(task_identity "$record" "$id")\n"
      DELIVERY_COUNT=$((DELIVERY_COUNT + 1))
    fi
  done <<< "$ids"

  [ "$REPORT_DAY" = "$TODAY" ] || return
  for detail in blocked held; do
    if [ "$detail" = blocked ]; then
      if ! listing=$(tasks_list --blocked --fields blocked_by,held,hold_reason,hold_kind); then
        backlog_bad "backlog source is unreadable or malformed: $(printf '%s\n' "$listing" | sed -n '1p')"
        return
      fi
    else
      if ! listing=$(tasks_list --state held --fields blocked_by,held,hold_reason,hold_kind); then
        backlog_bad "backlog source is unreadable or malformed: $(printf '%s\n' "$listing" | sed -n '1p')"
        return
      fi
    fi
    ids=$(printf '%s\n' "$listing" | task_ids)
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      case "$seen" in *"|$id|"*) continue ;; esac
      if ! record=$(tasks-axi show "$id" --file "$BACKLOG" --full 2>&1); then
        backlog_bad "backlog source is unreadable or malformed: $(printf '%s\n' "$record" | sed -n '1p')"
        return
      fi
      blocked=$(task_field "$record" blocked)
      held=$(task_field "$record" held)
      blocked_by=$(task_field "$record" blocked_by)
      hold_kind=$(task_field "$record" hold_kind)
      hold_reason=$(task_field "$record" hold_reason)
      detail=
      if [ "$blocked" = yes ]; then
        detail="blocked by $blocked_by"
      fi
      if [ "$held" = yes ]; then
        [ -z "$detail" ] || detail="$detail; "
        if [ "$hold_kind" = - ]; then
          detail="${detail}held: $hold_reason"
        else
          detail="${detail}held ($hold_kind): $hold_reason"
        fi
      fi
      [ -n "$detail" ] || continue
      BLOCKERS="${BLOCKERS}- $(task_identity "$record" "$id") - $detail\n"
      BLOCKER_COUNT=$((BLOCKER_COUNT + 1))
      seen="${seen}${id}|"
    done <<< "$ids"
  done
}

LEDGER_STATE=ok
LEDGER_DIAG=
LEDGER_SUMMARY='{"activity":0,"accepted":[],"failed":[],"unknown":0}'

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
  if ! LEDGER_SUMMARY=$(printf '%s\n' "$sheet" | node -e '
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => input += chunk);
    process.stdin.on("end", () => {
      const rows = JSON.parse(input);
      if (!Array.isArray(rows)) throw new Error("sheet is not an array");
      const day = process.argv[1];
      const localDay = value => {
        if (value === null || value === undefined) return null;
        const date = new Date(value);
        if (!Number.isFinite(date.valueOf())) throw new Error("invalid timestamp");
        const pad = number => String(number).padStart(2, "0");
        return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate());
      };
      const attempts = rows.filter(row => row.recordType === "attempt");
      const relevant = attempts.filter(row => localDay(row.startedAt) === day || localDay(row.endedAt) === day);
      const accepted = relevant.filter(row => row.state === "terminal" && row.classification === "accepted" && row.endedAt !== null);
      const failed = relevant.filter(row => row.state === "terminal" && ![null, "accepted", "incomplete"].includes(row.classification) && row.endedAt !== null);
      const explicit = new Set([...accepted, ...failed]);
      const unknown = relevant.filter(row => !explicit.has(row)).length;
      process.stdout.write(JSON.stringify({activity: relevant.length, accepted, failed, unknown}));
    });
  ' "$REPORT_DAY" 2>&1); then
    LEDGER_STATE=bad
    LEDGER_DIAG="model ledger source is unreadable or malformed: $(printf '%s\n' "$LEDGER_SUMMARY" | sed -n '1p')"
    LEDGER_SUMMARY='{"activity":0,"accepted":[],"failed":[],"unknown":0}'
  fi
}

STATUS_NOTE=

load_status_note() {
  local files file
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
      STATUS_NOTE="status source is unreadable at $file"
      return
    fi
    if LC_ALL=C grep -Eqv '^[[:lower:]][[:lower:]-]*( \[[^][]+\])?: .+$' "$file"; then
      STATUS_NOTE="status source is malformed at $file"
      return
    fi
  done
  STATUS_NOTE="${#files[@]} status log(s) present, but status lines have no timestamps and cannot be attributed to $REPORT_DAY"
}

attempt_count() {
  printf '%s\n' "$LEDGER_SUMMARY" | jq -r ".$1 | if type == \"array\" then length else . end"
}

print_attempts() {
  printf '%s\n' "$LEDGER_SUMMARY" | jq -r --arg key "$1" '
    .[$key][] |
    "- " + (if $key == "failed" then (.primaryFailureClass // "unknown") else .classification end) +
    " - \([.harness,.model,.effort] | map(select(. != null)) | join("/")) - " +
    (if .wallSeconds == null then "duration absent" else (.wallSeconds | tostring) + "s" end) +
    (if $key == "failed" then " (" + .classification + ")" else "" end)
  '
}

load_backlog
load_ledger
load_status_note

printf 'Daily report - %s\n' "$REPORT_DAY"

printf '\n1. What did we deliver?\n'
case "$BACKLOG_STATE" in
  absent|bad) printf 'Cannot answer: %s.\n' "$BACKLOG_DIAG" ;;
  *)
    if [ "$DELIVERY_COUNT" -eq 0 ]; then
      printf 'No activity recorded for %s.\n' "$REPORT_DAY"
    else
      printf '%b' "$DELIVERIES"
    fi
    ;;
esac

activity=0
accepted=0
failed=0
unknown=0
if [ "$LEDGER_STATE" = ok ]; then
  activity=$(attempt_count activity)
  accepted=$(attempt_count accepted)
  failed=$(attempt_count failed)
  unknown=$(attempt_count unknown)
fi

printf '\n2. What went wrong?\n'
case "$LEDGER_STATE" in
  absent|bad) printf 'Cannot answer: %s.\n' "$LEDGER_DIAG" ;;
  *)
    if [ "$activity" -eq 0 ]; then
      printf 'No activity recorded for %s.\n' "$REPORT_DAY"
    elif [ "$failed" -gt 0 ]; then
      print_attempts failed
      if [ "$unknown" -gt 0 ]; then
        printf 'Data gap: %s attempt%s lacks an explicit terminal outcome.\n' "$unknown" "$([ "$unknown" -eq 1 ] || printf s)"
      fi
    elif [ "$unknown" -gt 0 ]; then
      printf 'Cannot answer: %s attempt%s lacks an explicit terminal outcome.\n' "$unknown" "$([ "$unknown" -eq 1 ] || printf s)"
      printf 'Missing: terminal classification, failure class, and end timestamp.\n'
    else
      printf 'No problems recorded for %s across %s accepted attempt%s.\n' "$REPORT_DAY" "$accepted" "$([ "$accepted" -eq 1 ] || printf s)"
    fi
    ;;
esac

printf '\n3. What is blocking?\n'
case "$BACKLOG_STATE" in
  absent|bad) printf 'Cannot answer: %s.\n' "$BACKLOG_DIAG" ;;
  *)
    if [ "$BACKLOG_TOTAL" -eq 0 ]; then
      printf 'No activity recorded for %s.\n' "$REPORT_DAY"
    elif [ "$REPORT_DAY" != "$TODAY" ]; then
      printf 'Cannot answer for a past day: backlog holds and dependency blockers have no start or end timestamps.\n'
      printf 'Missing: dated blocker and hold history.\n'
    elif [ "$BLOCKER_COUNT" -eq 0 ]; then
      printf 'No activity recorded for %s.\n' "$REPORT_DAY"
    else
      printf '%b' "$BLOCKERS"
    fi
    ;;
esac

printf '\n4. What is good - what should we keep doing?\n'
case "$LEDGER_STATE" in
  absent|bad) printf 'Cannot answer: %s.\n' "$LEDGER_DIAG" ;;
  *)
    if [ "$activity" -eq 0 ]; then
      printf 'No activity recorded for %s.\n' "$REPORT_DAY"
    elif [ "$accepted" -gt 0 ]; then
      print_attempts accepted
      if [ "$unknown" -gt 0 ]; then
        printf 'Data gap: %s attempt%s lacks an explicit terminal outcome, so the positive evidence is incomplete.\n' "$unknown" "$([ "$unknown" -eq 1 ] || printf s)"
      fi
    elif [ "$unknown" -gt 0 ]; then
      printf 'Cannot answer: %s attempt%s lacks an explicit terminal outcome.\n' "$unknown" "$([ "$unknown" -eq 1 ] || printf s)"
      printf 'Missing: an accepted classification, end timestamp, and outcome evidence.\n'
    else
      printf 'No accepted outcomes recorded for %s.\n' "$REPORT_DAY"
    fi
    ;;
esac

printf '\nData limit: %s.\n' "$STATUS_NOTE"
