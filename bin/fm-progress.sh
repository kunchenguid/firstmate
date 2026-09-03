#!/usr/bin/env bash
# fm-progress.sh - show, refresh, record, and summarize the display-only
# progress phase and remaining-time guess for this home's live tasks.
#
# bin/fm-progress-lib.sh is the single owner of the phase model, the
# observation record (state/.progress-<id>), the history record
# (data/phase-history.jsonl), the default bands, and the label suffix; this
# script is its executable surface.
#
# Usage:
#   fm-progress.sh show <id> [--json]   derive the task's phase now, advance its
#                                       observation record, print phase, step,
#                                       elapsed, guess, and label suffix
#   fm-progress.sh tick                 one pass over every local task, which
#                                       the watcher launches as a detached
#                                       single-flight child each poll: bounded
#                                       re-read on the FM_PROGRESS_REFRESH_SECS
#                                       cadence and a Herdr label refresh only
#                                       when the phase or rounded estimate
#                                       changed
#   fm-progress.sh record <id> [--discard]
#                                       teardown's completion hook: append the
#                                       task's per-phase durations to the
#                                       history record (skipped with --discard,
#                                       the forced-teardown case) and remove
#                                       its observation record; never fails
#                                       the caller
#   fm-progress.sh history [<kind> [<mode>]]
#                                       print the per-phase medians and sample
#                                       counts the estimate would use for that
#                                       kind and mode (default ship no-mistakes)
#
# Every subcommand is display-only: nothing here changes a task's lifecycle,
# waits on the network, or writes a file another script owns. `show` and `tick`
# read the crew's current state through bin/fm-crew-state.sh and the captain
# hold through bin/fm-captain-hold.sh `open`; a state that cannot be read is
# reported as unknown rather than as a stale estimate.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-progress-lib.sh
. "$SCRIPT_DIR/fm-progress-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

minutes() {  # <secs>
  printf '%s' "$(( ($1 + 30) / 60 ))"
}

command_show() {
  local id='' json=0 arg
  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      -*) usage >&2; exit 2 ;;
      *) [ -z "$id" ] || { usage >&2; exit 2; }; id=$arg ;;
    esac
  done
  [ -n "$id" ] || { usage >&2; exit 2; }
  if ! fm_progress_read "$STATE" "$DATA" "$id"; then
    if [ "$json" = 1 ]; then
      printf '{"id":"%s","phase":"unknown","estimate":{"text":"unknown"}}\n' "$id"
    else
      printf 'progress: %s has no local task record to read\n' "$id"
    fi
    return 0
  fi
  if [ "$json" = 1 ]; then
    command -v jq >/dev/null 2>&1 || { echo "fm-progress: jq is required for --json" >&2; exit 1; }
    jq -n \
      --arg id "$id" --arg kind "$FM_PROGRESS_KIND" --arg mode "$FM_PROGRESS_MODE" \
      --arg phase "$FM_PROGRESS_PHASE" --arg step "$FM_PROGRESS_STEP" \
      --argjson since "$FM_PROGRESS_SINCE" --argjson elapsed "$FM_PROGRESS_ELAPSED" \
      --arg short "$FM_PROGRESS_SHORT" --arg text "$FM_PROGRESS_TEXT" \
      --arg label "$FM_PROGRESS_LABEL_SUFFIX" \
      '{id:$id,kind:$kind,mode:$mode,phase:$phase,step:($step|if .=="" then null else . end),
        since:$since,elapsed_seconds:$elapsed,
        estimate:{short:($short|if .=="" then null else . end),text:$text},
        label_suffix:$label}'
    return 0
  fi
  printf 'phase: %s' "$FM_PROGRESS_PHASE"
  [ -z "$FM_PROGRESS_STEP" ] || printf ' · step: %s' "$FM_PROGRESS_STEP"
  printf ' · elapsed: %s min · guess: %s · label:%s\n' \
    "$(minutes "$FM_PROGRESS_ELAPSED")" "$FM_PROGRESS_TEXT" "$FM_PROGRESS_LABEL_SUFFIX"
}

command_tick() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  fm_progress_tick "$STATE" "$DATA"
}

command_record() {
  local id='' discard=0 arg meta kind mode
  for arg in "$@"; do
    case "$arg" in
      --discard) discard=1 ;;
      -*) usage >&2; exit 2 ;;
      *) [ -z "$id" ] || { usage >&2; exit 2; }; id=$arg ;;
    esac
  done
  [ -n "$id" ] || { usage >&2; exit 2; }
  fm_progress_id_valid "$id" || { echo "fm-progress: invalid task id: $id" >&2; exit 2; }
  if ! fm_progress_record_load "$STATE" "$id"; then
    rm -f "$(fm_progress_record_path "$STATE" "$id")"
    printf 'progress: no observation record for %s; nothing recorded\n' "$id"
    return 0
  fi
  meta="$STATE/$id.meta"
  kind=$(_fm_progress_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  mode=$(_fm_progress_meta_get "$meta" mode)
  [ -n "$mode" ] || { [ "$kind" = scout ] && mode=scout || mode=no-mistakes; }
  if [ "$discard" = 1 ] || [ "$kind" = secondmate ]; then
    rm -f "$(fm_progress_record_path "$STATE" "$id")"
    printf 'progress: observation record for %s removed without recording history\n' "$id"
    return 0
  fi
  # Charge the tail of the current phase before recording.
  fm_progress_observe "$STATE" "$id" "$meta" "$FM_PROGRESS_REC_PHASE" "$FM_PROGRESS_REC_STEP" '' || true
  if fm_progress_history_append "$DATA" "$id" "$kind" "$mode"; then
    printf 'progress: recorded %s (%s, %s): implementing %s min, validating %s min, fixing %s min in %s round(s), ci %s min, waiting %s min\n' \
      "$id" "$kind" "$mode" \
      "$(minutes "$FM_PROGRESS_REC_SECS_IMPLEMENTING")" \
      "$(minutes "$FM_PROGRESS_REC_SECS_VALIDATING")" \
      "$(minutes "$FM_PROGRESS_REC_SECS_FIXING")" "$FM_PROGRESS_REC_FIX_ROUNDS" \
      "$(minutes "$FM_PROGRESS_REC_SECS_CI")" \
      "$(minutes "$FM_PROGRESS_REC_SECS_WAITING")"
  else
    printf 'warning: progress history for %s could not be appended under %s; the observation record is dropped anyway\n' "$id" "$DATA" >&2
  fi
  rm -f "$(fm_progress_record_path "$STATE" "$id")"
  return 0
}

command_history() {
  local kind=${1:-ship} mode=${2:-no-mistakes} out
  [ "$#" -le 2 ] || { usage >&2; exit 2; }
  out=$(fm_progress_history_medians "$DATA" "$kind" "$mode")
  if [ -z "$out" ]; then
    printf 'history: no records for %s %s under %s (default bands apply)\n' "$kind" "$mode" "$(fm_progress_history_path "$DATA")"
    return 0
  fi
  printf 'history: %s %s medians from %s (a phase needs %s samples before its median is used; running long starts past the 75th percentile)\n' \
    "$kind" "$mode" "$(fm_progress_history_path "$DATA")" "$FM_PROGRESS_MIN_SAMPLES"
  printf '%s\n' "$out" | while IFS=$'\t' read -r name median count p75; do
    case "$name" in
      tasks) printf '  %-13s %s matching finished task(s)\n' "$name" "$count" ;;
      fix_rounds) printf '  %-13s median %s round(s), 75th percentile %s, over %s task(s)\n' "$name" "$median" "$p75" "$count" ;;
      *) printf '  %-13s median %s min, 75th percentile %s min, over %s task(s)\n' "$name" "$(minutes "$median")" "$(minutes "$p75")" "$count" ;;
    esac
  done
}

case "${1:-}" in
  show) shift; command_show "$@" ;;
  tick) shift; command_tick "$@" ;;
  record) shift; command_record "$@" ;;
  history) shift; command_history "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
