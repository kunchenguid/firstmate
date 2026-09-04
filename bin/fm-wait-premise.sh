#!/usr/bin/env bash
# Inspect a paused task's optional machine-readable wait premise.
# Usage: fm-wait-premise.sh <task-id>
#        fm-wait-premise.sh report
#
# The normal command prints exactly one verdict when the latest status is a
# paused line: still-waiting, expired, or unbindable. Existing paused lines with
# a canonical PR URL are accepted as the initial seed; new lines should use the
# explicit wait= form. It is read-only and stays silent when the status or an
# owner check cannot be read. The private
# --shadow-row form returns the premise and verdict as one tab-separated row
# for fm-watch.sh; it has the same read-only and silent-error contract.
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-model-catalog-lib.sh
. "$SCRIPT_DIR/fm-model-catalog-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

FM_WAIT_PREMISE_TIMEOUT=${FM_WAIT_PREMISE_TIMEOUT:-5}
case "$FM_WAIT_PREMISE_TIMEOUT" in
  ''|0|*[!0-9]*) FM_WAIT_PREMISE_TIMEOUT=5 ;;
esac

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

FM_WAIT_PREMISE=
FM_WAIT_PREMISE_TYPE=
FM_WAIT_PREMISE_VALUE=
FM_WAIT_VERDICT=
FM_WAIT_PREMISE_LINE=

wait_premise_parse_line() {
  local line=$1 note url
  FM_WAIT_PREMISE=
  FM_WAIT_PREMISE_TYPE=
  FM_WAIT_PREMISE_VALUE=
  status_is_paused "$line" || return 1
  note=$(status_line_note "$line") || return 1
  if [[ "$note" =~ (^|[[:space:]])wait=(pr|quota):([^[:space:]]+) ]]; then
    FM_WAIT_PREMISE_TYPE=${BASH_REMATCH[2]}
    FM_WAIT_PREMISE_VALUE=${BASH_REMATCH[3]}
  elif [[ "$note" =~ (^|[[:space:]])(https://[^[:space:]]+) ]]; then
    url=${BASH_REMATCH[2]}
    fm_pr_url_parse "$url" || return 2
    FM_WAIT_PREMISE_TYPE='pr'
    FM_WAIT_PREMISE_VALUE=$url
  else
    return 2
  fi
  FM_WAIT_PREMISE="wait=$FM_WAIT_PREMISE_TYPE:$FM_WAIT_PREMISE_VALUE"
}

wait_premise_bindable() {
  case "$FM_WAIT_PREMISE_TYPE" in
    pr) fm_pr_url_parse "$FM_WAIT_PREMISE_VALUE" ;;
    quota)
      case "$FM_WAIT_PREMISE_VALUE" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
      esac
      fm_model_catalog_read "$FM_HOME/config" || return 1
      jq -e --arg provider "$FM_WAIT_PREMISE_VALUE" \
        'any(.pools[]; (.provider | ascii_downcase) == ($provider | ascii_downcase))' \
        "$FM_HOME/config/model-catalog.json" >/dev/null 2>&1 || return 1
      ;;
    *) return 1 ;;
  esac
}

wait_premise_read_task() {
  local task=$1 status_file line
  fm_task_id_path_safe "$task" || return 1
  status_file="$STATE/$task.status"
  [ -f "$status_file" ] && [ ! -L "$status_file" ] || return 1
  line=$(last_status_line "$status_file") || return 1
  [ -n "$line" ] || return 1
  wait_premise_parse_line "$line"
  FM_WAIT_PREMISE_LINE=$(awk 'NF { line++ } END { if (line) print line }' \
    "$status_file" 2>/dev/null) || return 1
  case "$FM_WAIT_PREMISE_LINE" in ''|*[!0-9]*) return 1 ;; esac
}

wait_premise_verdict() {
  local task=$1 out rc read_rc
  FM_WAIT_VERDICT=
  wait_premise_read_task "$task"
  read_rc=$?
  [ "$read_rc" -eq 0 ] || {
    if [ "$read_rc" -eq 2 ]; then
      FM_WAIT_VERDICT=unbindable
      printf '%s\n' "$FM_WAIT_VERDICT"
    fi
    return 0
  }
  if ! wait_premise_bindable; then
    FM_WAIT_VERDICT=unbindable
    printf '%s\n' "$FM_WAIT_VERDICT"
    return 0
  fi
  case "$FM_WAIT_PREMISE_TYPE" in
    pr)
      out=$(FM_PR_POLL_DETAIL_STATE=1 fm_run_timed "$FM_WAIT_PREMISE_TIMEOUT" \
        "$SCRIPT_DIR/fm-pr-poll.sh" --validated \
        "$FM_PR_PROVIDER" "$FM_PR_URL" "$FM_PR_HOST" "$FM_PR_PATH" \
        "$FM_PR_NUMBER" </dev/null 2>/dev/null) || return 1
      case "$out" in
        merged) FM_WAIT_VERDICT=expired; printf '%s\n' "$FM_WAIT_VERDICT" ;;
        open) FM_WAIT_VERDICT=still-waiting; printf '%s\n' "$FM_WAIT_VERDICT" ;;
        *) return 1 ;;
      esac
      ;;
    quota)
      out=$(FM_HOME="$FM_HOME" fm_run_timed "$FM_WAIT_PREMISE_TIMEOUT" \
        "$SCRIPT_DIR/fm-quota-cooldown.sh" authorize \
        --harness wait-premise --provider "$FM_WAIT_PREMISE_VALUE" 2>/dev/null)
      rc=$?
      case "$rc" in
        0) FM_WAIT_VERDICT=expired; printf '%s\n' "$FM_WAIT_VERDICT" ;;
        3) FM_WAIT_VERDICT=still-waiting; printf '%s\n' "$FM_WAIT_VERDICT" ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

iso_epoch() {
  node -e 'const value = new Date(process.argv[1]); if (Number.isNaN(value.getTime())) process.exit(1); process.stdout.write(String(Math.floor(value.getTime() / 1000)));' "$1" 2>/dev/null
}

next_status_after_line() {
  local status_file=$1 pause_line=$2 line line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "${line//[[:space:]]/}" ] || continue
    line_no=$((line_no + 1))
    [ "$line_no" -gt "$pause_line" ] || continue
    printf '%s\n' "$line"
    return 0
  done < "$status_file"
  return 1
}

next_status_after_premise() {
  local status_file=$1 premise=$2 line next='' waiting=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "${line//[[:space:]]/}" ] || continue
    if [ "$waiting" -eq 1 ]; then
      next=$line
      waiting=0
    fi
    if status_is_paused "$line" && wait_premise_parse_line "$line" \
      && [ "$FM_WAIT_PREMISE" = "$premise" ]; then
      waiting=1
    fi
  done < "$status_file"
  [ -n "$next" ] || return 1
  printf '%s\n' "$next"
}

report() {
  local status_file line event_file correction_file timestamp task premise verdict next pause_line correction_timestamp event_key seen_events='' \
    event_epoch correction_epoch pauses=0 bound=0 true_expiries=0 false_expiries=0 \
    latency_count=0 latency_total=0 latency=0

  for status_file in "$STATE"/*.status; do
    [ -f "$status_file" ] && [ ! -L "$status_file" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      status_is_paused "$line" || continue
      pauses=$((pauses + 1))
      if wait_premise_parse_line "$line" && wait_premise_bindable; then
        bound=$((bound + 1))
      fi
    done < "$status_file"
  done

  printf 'bound-share=%s/%s\n' "$bound" "$pauses"
  event_file="$STATE/wait-events.log"
  if [ -f "$event_file" ] && [ ! -L "$event_file" ]; then
    while IFS=$'\t' read -r timestamp task premise verdict pause_line correction_timestamp \
      || [ -n "$timestamp" ]; do
      [ "$verdict" = expired ] || continue
      fm_task_id_path_safe "$task" || continue
      status_file="$STATE/$task.status"
      [ -f "$status_file" ] && [ ! -L "$status_file" ] || continue
      case "$pause_line" in
        ''|*[!0-9]*) event_key="$task:$timestamp:$premise" ;;
        *) event_key="$task:$pause_line" ;;
      esac
      case "|$seen_events|" in *"|$event_key|"*) continue ;; esac
      seen_events="$seen_events|$event_key"
      if case "$pause_line" in ''|*[!0-9]*) false ;; *) true ;; esac; then
        next=$(next_status_after_line "$status_file" "$pause_line" 2>/dev/null) \
          || next=$(last_status_line "$status_file" 2>/dev/null || true)
      else
        next=$(next_status_after_premise "$status_file" "$premise" 2>/dev/null) || continue
      fi
      if status_is_paused "$next" && wait_premise_parse_line "$next" \
        && [ "$FM_WAIT_PREMISE" = "$premise" ]; then
        false_expiries=$((false_expiries + 1))
        continue
      fi
      true_expiries=$((true_expiries + 1))
      if [ -z "$correction_timestamp" ]; then
        correction_file="$STATE/wait-corrections.log"
        if [ -f "$correction_file" ] && [ ! -L "$correction_file" ]; then
          correction_timestamp=$(awk -F '\t' -v task="$task" -v premise="$premise" \
            -v pause_line="$pause_line" \
            '$2 == task && $3 == premise && $4 == "corrected" && \
             (pause_line == "" || $5 == pause_line) { print $1; exit }' \
            "$correction_file" 2>/dev/null || true)
        fi
      fi
      event_epoch=$(iso_epoch "$timestamp") || continue
      correction_epoch=$(iso_epoch "$correction_timestamp") || continue
      case "$event_epoch:$correction_epoch" in
        *[!0-9:]*|*:*:) continue ;;
      esac
      latency=$((correction_epoch - event_epoch))
      [ "$latency" -ge 0 ] || continue
      latency_total=$((latency_total + latency))
      latency_count=$((latency_count + 1))
    done < "$event_file"
  fi
  if [ "$latency_count" -gt 0 ]; then
    printf 'time-to-correction-seconds count=%s total=%s average=%s\n' \
      "$latency_count" "$latency_total" "$((latency_total / latency_count))"
  else
    printf 'time-to-correction-seconds count=0 total=0 average=0\n'
  fi
  printf 'true-expiries=%s\n' "$true_expiries"
  printf 'false-expiries=%s\n' "$false_expiries"
}

case "${1:-}" in
  -h|--help)
    usage
    ;;
  report)
    report
    ;;
  --shadow-row)
    [ "$#" -eq 2 ] || exit 0
    wait_premise_verdict "$2" >/dev/null 2>/dev/null || exit 0
    [ -n "$FM_WAIT_PREMISE" ] && [ -n "$FM_WAIT_VERDICT" ] || exit 0
    printf '%s\t%s\t%s\n' "$FM_WAIT_PREMISE" "$FM_WAIT_VERDICT" \
      "$FM_WAIT_PREMISE_LINE"
    ;;
  '')
    exit 0
    ;;
  *)
    [ "$#" -eq 1 ] || exit 0
    wait_premise_verdict "$1" 2>/dev/null || true
    ;;
esac
