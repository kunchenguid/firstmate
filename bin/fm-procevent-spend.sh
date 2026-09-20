#!/usr/bin/env bash
# Spend-ceiling process-event adapter.
#
# Usage:
#   fm-procevent-spend.sh arm --task <task-id>
#   fm-procevent-spend.sh arm --fleet
#   fm-procevent-spend.sh poll --task <task-id> --ceiling <tokens> [--interval <secs>] [--scan-budget <secs>]
#   fm-procevent-spend.sh poll --fleet --ceiling <tokens> [--hours <h>] [--family <family>] [--interval <secs>]
#   fm-procevent-spend.sh classify <result-file>
#   fm-procevent-spend.sh terminal <result-file>
#   fm-procevent-spend.sh silent <result-file>
#   fm-procevent-spend.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-spend.sh self-announcing
#   fm-procevent-spend.sh source-id (--task <task-id> | --fleet)
#   fm-procevent-spend.sh retire (--task <task-id> | --fleet)
#
# Ceilings come from config/spend-ceilings.json (docs/configuration.md owns the
# schema):
#   pollIntervalSeconds   cadence for both pollers (default 120)
#   taskCeilingTokens     per-task budget; each spawned Pi or pi-signed
#                         ship/scout gets a spend-task-<id> source that fires
#                         when the task's ledger total reaches it. Other
#                         harnesses are unmeasured and are not armed.
#   fleetWindow           {ceilingTokens, hours (default 168), family (optional)}
#                         one shared spend-fleet source that fires when fleet
#                         spend inside the trailing window reaches the ceiling
#
# A per-task capture is stop-and-report: autohandle delivers `fm-control.sh
# <id> exit` through the verified control path, records state/<id>.spend-stop,
# appends the task's status line (that append is the report; it wakes
# firstmate), and acknowledges the capture so no second wake follows. The stop
# marker is keyed on the task's spawn_gen, so a relaunched incarnation is
# governed again instead of inheriting the prior stop.
# A fleet capture is report-only: autohandle writes the suppression marker
# (state/spend-fleet-fired.json, one fire per window) and deliberately leaves
# the capture unhandled, so the ordinary check wake is the report.
#
# poll       The blocking child the generic runner executes; never run this
#            directly in a conversational turn. It re-reads the spend ledger
#            (bin/fm-spend-ledger.py) until the ceiling is crossed, the task
#            record disappears, or consecutive ledger failures stop the watch.
# classify   Print the captured outcome class: ceiling, gone, stopped, error,
#            or unknown.
# terminal   Every spend result is terminal: a fire, a vanished task, and an
#            error each end the watch.
# silent     `gone` and `stopped` produce no wake - a task ending or an
#            already-applied stop is not an event.
# autohandle Apply the durable action for a captured result (see above).
# self-announcing
#            Declared: a handled task capture announces itself through the
#            task's own state/<id>.status line.
# source-id  Print the canonical source id for --task or --fleet.
# retire     Retire the registration for --task or --fleet.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="$FM_HOME/config/spend-ceilings.json"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

DEFAULT_INTERVAL=120
DEFAULT_FLEET_HOURS=168
MAX_LEDGER_FAILURES=5

LEDGER=${FM_SPEND_LEDGER:-$SCRIPT_DIR/fm-spend-ledger.py}
CONTROL=${FM_CONTROL:-$SCRIPT_DIR/fm-control.sh}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

positive_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; 0) return 1 ;; *) return 0 ;; esac }

positive_number() {
  local n=${1-} LC_ALL=C
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [ "$n" != 0 ] && [[ ! "$n" =~ ^0+(\.0+)?$ ]]
}

valid_id() {
  local id=${1-} LC_ALL=C
  [ -n "$id" ] || return 1
  case "$id" in *[!a-zA-Z0-9._-]*|.|..) return 1 ;; esac
  fm_procevent_source_id_valid "spend-task-$id"
}

source_id_for() {  # --task <id> | --fleet
  case "${1-}" in
    --task) valid_id "${2-}" || die "invalid task id: ${2-}"; printf 'spend-task-%s\n' "$2" ;;
    --fleet) printf 'spend-fleet\n' ;;
    *) usage ;;
  esac
}

meta_get() {  # <meta-file> <key> - fixed key names only (spawn_gen et al)
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

config_json() {
  [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || return 1
  jq -e 'type == "object"' "$CONFIG" >/dev/null 2>&1 || return 1
  cat "$CONFIG"
}

# config_value <jq-filter> - print one scalar from the ceiling config, or nothing.
config_value() {
  local cfg
  cfg=$(config_json) || return 1
  printf '%s\n' "$cfg" | jq -er "$1" 2>/dev/null
}

# registered <source-id> - 0 when the source already has a registration file.
registered() { [ -f "$STATE/procevent/$1.source" ]; }

# spend_stop_marker_current <id> - 0 when state/<id>.spend-stop already records
# a stop for the task's current spawn_gen.
spend_stop_marker_current() {
  local id=$1 marker="$STATE/$1.spend-stop" gen
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  gen=$(meta_get "$STATE/$id.meta" spawn_gen)
  [ -n "$gen" ] || return 1
  jq -e --arg g "$gen" '.spawnGen == $g' "$marker" >/dev/null 2>&1
}

# emit_result <status> <detail-kv...> - the captured stdout contract, one
# key: value line per field, matching the quota adapter's shape.
emit_result() {
  local status=$1; shift
  printf 'spend: %s\n' "$RESULT_SOURCE_ID"
  printf 'status: %s\n' "$status"
  while [ "$#" -gt 0 ]; do printf '%s\n' "$1"; shift; done
}

ledger_task_tokens() {  # <id> -> tokens on stdout (0), unknown (2), or failure (1)
  local id=$1 doc parsed state
  local -a argv=("$LEDGER" --state "$STATE" task "$id")
  [ -z "${SCAN_BUDGET-}" ] || argv+=(--scan-budget "$SCAN_BUDGET")
  doc=$("${argv[@]}" 2>/dev/null) || return 1
  parsed=$(printf '%s\n' "$doc" | jq -c '
    if .status == "ok" and (.partial != true) and ((.totals.tokens | type) == "number")
    then {state:"ok", tokens:(.totals.tokens | floor)}
    elif .status == "ok" or .status == "empty"
    then {state:"unknown"}
    else {state:"error"}
    end' 2>/dev/null) || return 1
  state=$(printf '%s\n' "$parsed" | jq -er '.state') || return 1
  case "$state" in
    ok) printf '%s\n' "$parsed" | jq -er '.tokens' ;;
    unknown) return 2 ;;
    *) return 1 ;;
  esac
}

ledger_window_tokens() {  # <hours> [family] -> tokens on stdout, or failure
  local hours=$1 family=${2-} doc
  doc=$("$LEDGER" --state "$STATE" week --hours "$hours" 2>/dev/null) || return 1
  printf '%s\n' "$doc" | jq -er --arg family "$family" '
    if $family == "" then .totalTokens
    else .families[$family].tokens // 0
    end | select(type == "number") | floor' 2>/dev/null
}

fleet_marker_fresh() {  # <hours> - 0 while the last fleet fire is inside its window
  local hours=$1 marker="$STATE/spend-fleet-fired.json" fired_at now
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  fired_at=$(jq -er '.firedAtEpoch | select(type == "number") | floor' "$marker" 2>/dev/null) || return 1
  now=$(date +%s)
  [ $((now - fired_at)) -lt $((hours * 3600)) ]
}

cmd_poll() {
  local task='' fleet=0 ceiling='' interval=$DEFAULT_INTERVAL hours=$DEFAULT_FLEET_HOURS family=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task)      [ -n "${2-}" ] || die "--task needs a task id"; task=$2; shift 2 ;;
      --fleet)     fleet=1; shift ;;
      --ceiling)   [ -n "${2-}" ] || die "--ceiling needs a token count"; ceiling=$2; shift 2 ;;
      --interval)  [ -n "${2-}" ] || die "--interval needs seconds"; interval=$2; shift 2 ;;
      --hours)     [ -n "${2-}" ] || die "--hours needs a value"; hours=$2; shift 2 ;;
      --family)    [ -n "${2-}" ] || die "--family needs a value"; family=$2; shift 2 ;;
      --scan-budget) [ -n "${2-}" ] || die "--scan-budget needs seconds"; SCAN_BUDGET=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  positive_int "$ceiling" || die "--ceiling needs a positive integer token count"
  positive_number "$interval" || die "--interval needs a positive number of seconds"
  if [ "$fleet" -eq 1 ]; then
    [ -z "$task" ] || die "--task and --fleet are exclusive"
    RESULT_SOURCE_ID=spend-fleet
    positive_int "$hours" || die "--hours needs a positive integer"
    local tokens fails=0 polls=0
    while :; do
      polls=$((polls + 1))
      if fleet_marker_fresh "$hours"; then
        sleep "$interval"; continue
      fi
      if tokens=$(ledger_window_tokens "$hours" "$family"); then
        fails=0
        if [ "$tokens" -ge "$ceiling" ]; then
          emit_result ceiling \
            "observed_tokens: $tokens" \
            "ceiling_tokens: $ceiling" \
            "window_hours: $hours" \
            "family: ${family:-all}" \
            "condition_polls: $polls"
          exit 0
        fi
      else
        fails=$((fails + 1))
        [ "$fails" -lt "$MAX_LEDGER_FAILURES" ] || {
          emit_result error "detail: spend ledger unreadable for $fails consecutive polls" "condition_polls: $polls"
          exit 0
        }
      fi
      sleep "$interval"
    done
  fi
  [ -n "$task" ] || die "poll needs --task <id> or --fleet"
  valid_id "$task" || die "invalid task id: $task"
  RESULT_SOURCE_ID="spend-task-$task"
  local meta="$STATE/$task.meta" tokens fails=0 polls=0 rc
  while :; do
    polls=$((polls + 1))
    [ -f "$meta" ] || { emit_result gone "task: $task" "condition_polls: $polls"; exit 0; }
    if spend_stop_marker_current "$task"; then
      emit_result stopped "task: $task" "condition_polls: $polls"
      exit 0
    fi
    tokens=
    rc=0
    tokens=$(ledger_task_tokens "$task") || rc=$?
    if [ "$rc" -eq 0 ]; then
      fails=0
      if [ "$tokens" -ge "$ceiling" ]; then
        emit_result ceiling \
          "task: $task" \
          "observed_tokens: $tokens" \
          "ceiling_tokens: $ceiling" \
          "condition_polls: $polls"
        exit 0
      fi
    elif [ "$rc" -ne 2 ]; then
      fails=$((fails + 1))
      [ "$fails" -lt "$MAX_LEDGER_FAILURES" ] || {
        emit_result error "task: $task" "detail: spend ledger unreadable for $fails consecutive polls" "condition_polls: $polls"
        exit 0
      }
    fi
    sleep "$interval"
  done
}

result_field() {  # <file> <key>
  awk -v k="$2" '$0 == "output:" { exit } $0 ~ "^" k ": " { sub("^" k ": ", ""); print; exit }' "$1"
}

result_class() {  # <file>
  local status
  status=$(result_field "$1" status)
  case "$status" in
    ceiling|gone|stopped|error) printf '%s\n' "$status" ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_classify() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  result_class "$file"
}

cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  [ "$(result_class "$file")" != unknown ]
}

cmd_silent() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(result_class "$file")" in gone|stopped) exit 0 ;; *) exit 1 ;; esac
}

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# append_status <id> <line> - append one wake line to state/<id>.status, the
# same durable channel the worker itself reports through. The caller holds the
# per-task stop lock, so marker and line land under one serialization.
append_status() {
  local id=$1 line=$2 status_file="$STATE/$1.status"
  mkdir -p "$STATE" || return 1
  if [ -e "$status_file" ] && { [ ! -f "$status_file" ] || [ -L "$status_file" ]; }; then
    return 1
  fi
  (umask 077; printf '%s\n' "$line" >> "$status_file")
}

# write_marker <id> <seq> <result-file> <outcome> <detail> - durable record of
# the stop decision, keyed on the task's current spawn_gen.
write_marker() {
  local id=$1 seq=$2 result=$3 outcome=$4 detail=$5 gen observed ceiling tmp
  gen=$(meta_get "$STATE/$id.meta" spawn_gen)
  observed=$(result_field "$result" observed_tokens)
  ceiling=$(result_field "$result" ceiling_tokens)
  tmp="$STATE/.$id.spend-stop.${BASHPID:-$$}"
  jq -n --arg id "$id" --arg gen "${gen:-}" --arg outcome "$outcome" \
    --arg detail "$detail" --arg at "$(iso_now)" \
    --argjson seq "$seq" --argjson observed "${observed:-0}" --argjson ceiling "${ceiling:-0}" '
    {version: 1, task: $id, spawnGen: $gen, sequence: $seq,
     observedTokens: $observed, ceilingTokens: $ceiling,
     action: "fm-control exit", actionResult: $outcome, detail: $detail, at: $at}
  ' > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$STATE/$id.spend-stop"
}

cmd_autohandle() {
  local sid=${1-} seq=${2-} result=${3-}
  [ -n "$sid" ] && [ -n "$seq" ] && [ -n "$result" ] || usage
  [ -f "$result" ] || die "result file does not exist: $result"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  case "$sid" in
    spend-fleet)
      # Report-only: leave the capture unhandled so the check wake reaches
      # firstmate, but suppress a re-fire inside the same window.
      local hours fired_marker="$STATE/spend-fleet-fired.json" tmp
      hours=$(result_field "$result" window_hours)
      positive_int "${hours:-0}" || hours=$DEFAULT_FLEET_HOURS
      tmp="$STATE/.spend-fleet-fired.${BASHPID:-$$}"
      jq -n --argjson fired "$(date +%s)" --arg at "$(iso_now)" \
        --arg observed "$(result_field "$result" observed_tokens)" \
        --arg ceiling "$(result_field "$result" ceiling_tokens)" \
        --arg family "$(result_field "$result" family)" '
        {firedAtEpoch: $fired, at: $at,
         observedTokens: ($observed | tonumber? // 0),
         ceilingTokens: ($ceiling | tonumber? // 0),
         family: (if $family == "" then "all" else $family end)}
      ' > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$fired_marker"
      return 1
      ;;
    spend-task-*) ;;
    *) return 1 ;;
  esac
  local id=${sid#spend-task-} class gen
  valid_id "$id" || return 1
  class=$(result_class "$result")
  case "$class" in
    gone|stopped) "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" >/dev/null 2>&1 || true; return 0 ;;
    ceiling) ;;
    *) return 1 ;;
  esac
  gen=$(meta_get "$STATE/$id.meta" spawn_gen)
  if spend_stop_marker_current "$id"; then
    # Same incarnation already stopped: acknowledge so the capture quiets.
    "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" >/dev/null 2>&1 || true
    return 0
  fi
  local lock="$STATE/.spend-stop-$id.lock" rc=0 out=
  fm_lock_acquire_wait "$lock" || return 1
  if spend_stop_marker_current "$id"; then
    fm_lock_release "$lock"
    "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" >/dev/null 2>&1 || true
    return 0
  fi
  local reported=0
  out=$("$CONTROL" "$id" exit 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    write_marker "$id" "$seq" "$result" ok "exit delivered"
    append_status "$id" "failed: spend ceiling crossed - ledger total reached the task ceiling ($(result_field "$result" observed_tokens) >= $(result_field "$result" ceiling_tokens) tokens); agent stopped via fm-control exit" \
      && reported=1
  else
    write_marker "$id" "$seq" "$result" failed "$(printf '%s' "$out" | tail -1)"
    append_status "$id" "blocked: spend ceiling crossed ($(result_field "$result" observed_tokens) >= $(result_field "$result" ceiling_tokens) tokens) but automatic stop failed: $(printf '%s' "$out" | tail -1)" \
      && reported=1
  fi
  fm_lock_release "$lock"
  # A stop with no durable report is worse than no stop: leave the capture
  # unhandled so the ordinary check wake still carries the crossing.
  [ "$rc" -eq 0 ] && [ "$reported" -eq 1 ] || return 1
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" >/dev/null 2>&1
}

cmd_arm() {
  local mode='' id=''
  case "${1-}" in
    --task) mode=task; id=${2-}; [ "$#" -eq 2 ] || usage; valid_id "$id" || die "invalid task id: $id" ;;
    --fleet) mode=fleet; [ "$#" -eq 1 ] || usage ;;
    *) usage ;;
  esac
  local interval ceiling sid
  interval=$(config_value '.pollIntervalSeconds // empty') || interval=
  [ -n "$interval" ] && positive_number "$interval" || interval=$DEFAULT_INTERVAL
  if [ "$mode" = task ]; then
    ceiling=$(config_value '.taskCeilingTokens // empty') || ceiling=
    if [ -z "$ceiling" ] || ! positive_int "$ceiling"; then
      printf 'no taskCeilingTokens configured; not arming spend-task-%s\n' "$id"
      return 0
    fi
    sid="spend-task-$id"
    if registered "$sid"; then
      printf 'already armed: %s\n' "$sid"
      return 0
    fi
    [ -f "$STATE/$id.meta" ] || die "no task record for $id; refusing to arm a ceiling for a task that is not recorded"
    local harness
    harness=$(meta_get "$STATE/$id.meta" harness)
    case "$harness" in
      pi|pi-signed) ;;
      *)
        printf 'unmeasured harness %s; not arming spend-task-%s\n' "${harness:-unknown}" "$id"
        return 0
        ;;
    esac
    "$SCRIPT_DIR/fm-procevent.sh" register spend "$sid" \
      -- "$SCRIPT_DIR/fm-procevent-spend.sh" poll --task "$id" --ceiling "$ceiling" --interval "$interval" || exit 1
    printf 'armed: %s ceiling=%s interval=%ss\n' "$sid" "$ceiling" "$interval"
    return 0
  fi
  local hours family
  ceiling=$(config_value '.fleetWindow.ceilingTokens // empty') || ceiling=
  if [ -z "$ceiling" ] || ! positive_int "$ceiling"; then
    printf 'no fleetWindow.ceilingTokens configured; not arming spend-fleet\n'
    return 0
  fi
  hours=$(config_value '.fleetWindow.hours // empty') || hours=
  [ -n "$hours" ] && positive_int "$hours" || hours=$DEFAULT_FLEET_HOURS
  family=$(config_value '.fleetWindow.family // empty' 2>/dev/null) || family=
  sid=spend-fleet
  if registered "$sid"; then
    printf 'already armed: %s\n' "$sid"
    return 0
  fi
  local -a argv=("$SCRIPT_DIR/fm-procevent-spend.sh" poll --fleet --ceiling "$ceiling" --hours "$hours" --interval "$interval")
  [ -z "$family" ] || argv+=(--family "$family")
  "$SCRIPT_DIR/fm-procevent.sh" register spend "$sid" -- "${argv[@]}" || exit 1
  printf 'armed: %s ceiling=%s hours=%s family=%s interval=%ss\n' "$sid" "$ceiling" "$hours" "${family:-all}" "$interval"
}

cmd_retire() {
  local sid
  sid=$(source_id_for "$@")
  "$SCRIPT_DIR/fm-procevent.sh" retire "$sid"
}

case "${1-}" in
  arm)             shift; cmd_arm "$@" ;;
  poll)            shift; cmd_poll "$@" ;;
  classify)        shift; cmd_classify "$@" ;;
  terminal)        shift; cmd_terminal "$@" ;;
  silent)          shift; cmd_silent "$@" ;;
  autohandle)      shift; cmd_autohandle "$@" ;;
  self-announcing) [ "$#" -eq 1 ] || usage; exit 0 ;;
  source-id)       shift; source_id_for "$@" ;;
  retire)          shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
