# shellcheck shell=bash
# Per-task quota accounting: the readings firstmate takes around a task so a
# supervisor can ask which task a quota window went to.
# Usage: . bin/fm-quota-axi-lib.sh; . bin/fm-timeout-lib.sh; . bin/fm-backend.sh
#        . bin/fm-quota-accounting-lib.sh
#
# This file is the single owner of the accounting field contract below. Its
# producers are bin/fm-spawn.sh (the opening reading, written into the task
# record it publishes) and bin/fm-teardown.sh (the closing reading and the
# delta, written into that same record before it is retired). Its consumer is
# bin/fm-fleet-snapshot.sh, which projects the record onto each task row, and
# bin/fm-bearings-snapshot.sh, which carries that projection into the bearings
# view.
#
# WHAT THE NUMBERS ARE, AND ARE NOT
#
# Every value here is a percentage of one provider quota window, in percentage
# points. None of them is a token count, a request count, or a cost, and none
# may be presented as one: quota-axi reports window occupancy, and the number of
# tokens behind a percentage point is not observable from it.
#
# A delta is also not this task's isolated consumption. Both readings observe
# the whole account, so everything else running in that window - other tasks,
# other homes, the captain's own session - is inside the difference. With more
# than one worker live the delta is an UPPER BOUND on the task it is recorded
# against, never its measured share. It is attribution evidence, not a bill.
#
# A delta across a window reset is meaningless, so both readings record the
# window they came from and the delta is published only when they agree. See
# quota_delta_status below.
#
# NEVER A GATE
#
# Accounting is an observation. Every entry point here returns success and
# records what it could not read, so a missing, outdated, or failing quota-axi
# cannot block a dispatch or a cleanup.
#
# FIELDS IN state/<id>.meta
#
#   quota_unit                      Constant `percent_points_of_quota_window`,
#                                   present whenever a reading was recorded, so
#                                   no reader has to infer the unit.
#   quota_provider                  quota-axi provider the readings came from.
#   quota_account                   That provider's accountKey on a schema 6
#                                   snapshot; absent on schema 5.
#   quota_window                    Window id the readings are anchored to, such
#                                   as `five_hour`.
#   quota_window_resets_at          That window's reset time at the opening
#                                   reading, normalized to UTC `Z` with any
#                                   fractional seconds dropped. Window id plus
#                                   reset time is the window identity the delta
#                                   is validated against.
#   quota_start_status              `recorded` or `unavailable`.
#   quota_start_at                  Unix time firstmate took the opening
#                                   reading, as the worker was launched.
#   quota_start_percent_remaining   Percent of that window left, at the opening
#                                   reading.
#   quota_start_reason              Why no opening reading exists.
#   quota_end_status                `recorded` or `unavailable`.
#   quota_end_at                    Unix time of the closing reading.
#   quota_end_percent_remaining     Percent of that window left, at the closing
#                                   reading.
#   quota_end_window                Window id the closing reading came from.
#   quota_end_window_resets_at      Its reset time, normalized the same way.
#   quota_end_reason                Why no closing reading exists.
#   quota_delta_status              `measured` when both readings exist and came
#                                   from the same provider, account, window id,
#                                   and reset time (within a few seconds, since
#                                   live resetsAt carries sub-second jitter
#                                   across whole-second boundaries);
#                                   `window_reset` when they did
#                                   not, so the difference spans a refill and
#                                   means nothing; `no_start` when only the
#                                   closing reading exists; `unavailable` when
#                                   the closing reading could not be taken.
#   quota_delta_percent_points      Percentage points of that window consumed
#                                   between the two readings, rounded to two
#                                   decimals. Written only when
#                                   quota_delta_status is `measured`. Positive
#                                   means the window drained. See the upper
#                                   bound above.
#
# Every field is optional: a task record written before this existed, or one
# whose readings both failed, simply carries fewer of them.
#
# ALERTING
#
# fm_quota_accounting_alert decides, from a record whose closing reading has
# been written, whether the measured drain is large enough to wake the first
# mate about. The threshold is percentage points of the window, read from the
# local config/quota-drain-alert-threshold file (default 10; see
# docs/configuration.md). Only a `measured` delta can alert: an unavailable,
# unanchored, or window-spanning difference is not evidence a task drained
# anything. The alert is as non-gating as the readings: the caller appends it
# to the existing wake queue best-effort, and a failure to alert never blocks
# a cleanup.
#
# Environment: FM_QUOTA_ACCOUNTING_TIMEOUT bounds each quota-axi call in
# seconds (default 20), so neither hook can stall on a slow vendor read.

FM_QUOTA_ACCOUNTING_UNIT=percent_points_of_quota_window

# Set by fm_quota_accounting_read.
FM_QUOTA_ACCOUNTING_PROVIDER=
FM_QUOTA_ACCOUNTING_ACCOUNT=
FM_QUOTA_ACCOUNTING_WINDOW=
FM_QUOTA_ACCOUNTING_RESETS=
FM_QUOTA_ACCOUNTING_PERCENT=
FM_QUOTA_ACCOUNTING_REASON=

fm_quota_accounting_timeout() {
  local t=${FM_QUOTA_ACCOUNTING_TIMEOUT:-20}
  case "$t" in ''|*[!0-9]*|0) t=20 ;; esac
  printf '%s' "$t"
}

# fm_quota_accounting_snapshot
# Print one validated quota-axi --json snapshot and return 0, or print why it
# could not be taken and return 1. The reason travels on stdout rather than in a
# variable because callers capture this in a command substitution, whose subshell
# would discard an assignment. Never prompts for a credential: the plain --json
# read reports an unusable provider instead of unlocking anything.
fm_quota_accounting_snapshot() {
  local timeout output
  timeout=$(fm_quota_accounting_timeout)
  if ! command -v quota-axi >/dev/null 2>&1; then
    printf 'quota-axi is not installed\n'
    return 1
  fi
  if ! fm_quota_axi_compatible "$timeout" >/dev/null 2>&1; then
    printf 'quota-axi is below the %s compatibility floor or would not report its version\n' "$FM_QUOTA_AXI_MIN"
    return 1
  fi
  if ! output=$(fm_run_timed "$timeout" quota-axi --json 2>/dev/null </dev/null); then
    printf 'quota-axi --json failed or exceeded its %ss bound\n' "$timeout"
    return 1
  fi
  if ! printf '%s\n' "$output" | fm_quota_json_valid; then
    printf 'quota-axi --json returned a snapshot this firstmate cannot read\n'
    return 1
  fi
  printf '%s\n' "$output"
}

# fm_quota_accounting_select <snapshot-json> <provider> <harness> <model> <prefer-window-id>
# Print five lines: `ok`, account, window, reset time, percent remaining - or
# `err`, the reason, and three empty lines. One field per line rather than one
# delimited record, because a tab is an IFS whitespace character and `read`
# would collapse the empty account a schema 5 snapshot legitimately produces.
# The provider row is bound through fm-quota-axi-lib.sh's quota_row, so schema 5
# and schema 6 snapshots resolve identically to every other consumer.
fm_quota_accounting_select() {
  printf '%s\n' "$1" | jq -r \
    --arg provider "$2" --arg harness "$3" --arg model "$4" --arg prefer "$5" \
    "$FM_QUOTA_ROW_JQ"'
    quota_lane($harness; $model) as $lane
    | quota_row(.; $provider; $lane) as $row
    | if $row == null then
        ["err", "provider \($provider) is not in the quota snapshot", "", "", ""]
      else
        ([ $row.windows[]?
           | select((.id | type) == "string" and (.id | length) > 0)
           | select((.percentRemaining | type) == "number")
           | select((.resetsAt | type) == "string" and (.resetsAt | length) > 0)
           | {id,
              kind: (.kind // ""),
              pct: .percentRemaining,
              resets: (.resetsAt | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z"))} ]) as $windows
        | if ($windows | length) == 0 then
            ["err", "provider \($provider) reports no resetting quota window", "", "", ""]
          else
            (if $prefer == "" then null
             else ([$windows[] | select(.id == $prefer)] | first) end) as $pinned
            | ($pinned
               // ([$windows[] | select(.kind == "session")] | sort_by(.resets, .id) | first)
               // ($windows | sort_by(.resets, .id) | first)) as $selected
            | ["ok", ($row.accountKey // ""), $selected.id, $selected.resets,
               ($selected.pct | tostring)]
          end
      end
    | .[]
  ' 2>/dev/null || printf 'err\nquota snapshot could not be read\n\n\n\n'
}

# fm_quota_accounting_read <harness> <model> [prefer-window-id]
# Take one reading for the window a task of this harness consumes. On success
# set FM_QUOTA_ACCOUNTING_{PROVIDER,ACCOUNT,WINDOW,RESETS,PERCENT}; otherwise
# set FM_QUOTA_ACCOUNTING_REASON and return 1.
#
# A reading prefers the window already recorded for the task, so the closing
# reading is anchored to the window the opening one chose rather than to
# whatever the vendor happens to report as tightest now. With no preference it
# takes the provider's session window, which is the short refilling window a
# burst of concurrent workers drains, and falls back to the window that resets
# soonest.
fm_quota_accounting_read() {
  local harness=$1 model=${2:-} prefer=${3:-} snapshot provider result status
  FM_QUOTA_ACCOUNTING_PROVIDER=
  FM_QUOTA_ACCOUNTING_ACCOUNT=
  FM_QUOTA_ACCOUNTING_WINDOW=
  FM_QUOTA_ACCOUNTING_RESETS=
  FM_QUOTA_ACCOUNTING_PERCENT=
  FM_QUOTA_ACCOUNTING_REASON=
  if [ -z "$harness" ]; then
    FM_QUOTA_ACCOUNTING_REASON='the task record names no harness'
    return 1
  fi
  if ! provider=$(fm_quota_provider_for_harness "$harness" "$model"); then
    FM_QUOTA_ACCOUNTING_REASON="quota-axi tracks no provider for harness $harness"
    return 1
  fi
  if ! snapshot=$(fm_quota_accounting_snapshot 2>/dev/null); then
    FM_QUOTA_ACCOUNTING_REASON=${snapshot:-quota-axi could not be read}
    return 1
  fi
  result=$(fm_quota_accounting_select "$snapshot" "$provider" "$harness" "$model" "$prefer")
  {
    read -r status
    read -r FM_QUOTA_ACCOUNTING_ACCOUNT
    read -r FM_QUOTA_ACCOUNTING_WINDOW
    read -r FM_QUOTA_ACCOUNTING_RESETS
    read -r FM_QUOTA_ACCOUNTING_PERCENT
  } <<EOF
$result
EOF
  if [ "$status" != ok ]; then
    FM_QUOTA_ACCOUNTING_REASON=${FM_QUOTA_ACCOUNTING_ACCOUNT:-quota snapshot could not be read}
    FM_QUOTA_ACCOUNTING_ACCOUNT=
    FM_QUOTA_ACCOUNTING_WINDOW=
    FM_QUOTA_ACCOUNTING_RESETS=
    FM_QUOTA_ACCOUNTING_PERCENT=
    return 1
  fi
  FM_QUOTA_ACCOUNTING_PROVIDER=$provider
  return 0
}

# fm_quota_accounting_start_lines <harness> <model>
# Print the opening reading as task-record lines. Always succeeds: a reading
# that could not be taken is recorded as unavailable with its reason.
fm_quota_accounting_start_lines() {
  local now
  now=$(date +%s)
  if fm_quota_accounting_read "$1" "${2:-}"; then
    printf 'quota_unit=%s\n' "$FM_QUOTA_ACCOUNTING_UNIT"
    printf 'quota_provider=%s\n' "$FM_QUOTA_ACCOUNTING_PROVIDER"
    [ -z "$FM_QUOTA_ACCOUNTING_ACCOUNT" ] || printf 'quota_account=%s\n' "$FM_QUOTA_ACCOUNTING_ACCOUNT"
    printf 'quota_window=%s\n' "$FM_QUOTA_ACCOUNTING_WINDOW"
    printf 'quota_window_resets_at=%s\n' "$FM_QUOTA_ACCOUNTING_RESETS"
    printf 'quota_start_status=recorded\n'
    printf 'quota_start_at=%s\n' "$now"
    printf 'quota_start_percent_remaining=%s\n' "$FM_QUOTA_ACCOUNTING_PERCENT"
  else
    printf 'quota_start_status=unavailable\n'
    printf 'quota_start_at=%s\n' "$now"
    printf 'quota_start_reason=%s\n' "$FM_QUOTA_ACCOUNTING_REASON"
  fi
  return 0
}

# fm_quota_accounting_same_reset <a> <b>
# Whether two normalized reset times name the same quota window. Live
# quota-axi reports resetsAt with sub-second jitter that can wobble across a
# whole-second boundary between the opening and closing readings, so times
# within a few seconds are the same window identity. Times that cannot be
# parsed fall back to exact string equality.
fm_quota_accounting_same_reset() {
  [ "$1" = "$2" ] && return 0
  jq -en --arg a "$1" --arg b "$2" \
    '(($a | fromdateiso8601) - ($b | fromdateiso8601)) as $d
     | (if $d < 0 then -$d else $d end) <= 5' >/dev/null 2>&1
}

# fm_quota_accounting_delta <start-percent> <end-percent>
# Percentage points drained between the two readings, rounded to two decimals.
fm_quota_accounting_delta() {
  jq -n --arg start "$1" --arg end "$2" \
    '((($start | tonumber) - ($end | tonumber)) * 100 | round) / 100' 2>/dev/null
}

# fm_quota_accounting_end_lines <meta>
# Print the closing reading and the delta as task-record lines, reading the
# task's harness, model, and opening reading from its own record. Always
# succeeds.
fm_quota_accounting_end_lines() {
  local meta=$1 harness model now
  local start_status start_provider start_account start_window start_resets start_percent
  local delta
  harness=$(fm_meta_get "$meta" harness)
  model=$(fm_meta_get "$meta" model)
  [ "$model" != default ] || model=
  start_status=$(fm_meta_get "$meta" quota_start_status)
  start_provider=$(fm_meta_get "$meta" quota_provider)
  start_account=$(fm_meta_get "$meta" quota_account)
  start_window=$(fm_meta_get "$meta" quota_window)
  start_resets=$(fm_meta_get "$meta" quota_window_resets_at)
  start_percent=$(fm_meta_get "$meta" quota_start_percent_remaining)
  now=$(date +%s)
  if ! fm_quota_accounting_read "$harness" "$model" "$start_window"; then
    printf 'quota_end_status=unavailable\n'
    printf 'quota_end_at=%s\n' "$now"
    printf 'quota_end_reason=%s\n' "$FM_QUOTA_ACCOUNTING_REASON"
    printf 'quota_delta_status=unavailable\n'
    return 0
  fi
  printf 'quota_unit=%s\n' "$FM_QUOTA_ACCOUNTING_UNIT"
  printf 'quota_end_status=recorded\n'
  printf 'quota_end_at=%s\n' "$now"
  printf 'quota_end_percent_remaining=%s\n' "$FM_QUOTA_ACCOUNTING_PERCENT"
  printf 'quota_end_window=%s\n' "$FM_QUOTA_ACCOUNTING_WINDOW"
  printf 'quota_end_window_resets_at=%s\n' "$FM_QUOTA_ACCOUNTING_RESETS"
  if [ "$start_status" != recorded ] || [ -z "$start_percent" ]; then
    printf 'quota_delta_status=no_start\n'
    return 0
  fi
  if [ "$start_provider" != "$FM_QUOTA_ACCOUNTING_PROVIDER" ] ||
    [ "$start_account" != "$FM_QUOTA_ACCOUNTING_ACCOUNT" ] ||
    [ "$start_window" != "$FM_QUOTA_ACCOUNTING_WINDOW" ] ||
    ! fm_quota_accounting_same_reset "$start_resets" "$FM_QUOTA_ACCOUNTING_RESETS"; then
    printf 'quota_delta_status=window_reset\n'
    return 0
  fi
  delta=$(fm_quota_accounting_delta "$start_percent" "$FM_QUOTA_ACCOUNTING_PERCENT") || delta=
  if [ -z "$delta" ]; then
    printf 'quota_delta_status=window_reset\n'
    return 0
  fi
  printf 'quota_delta_status=measured\n'
  printf 'quota_delta_percent_points=%s\n' "$delta"
  return 0
}

# fm_quota_accounting_meta_write <meta>
# Replace every key present on stdin in <meta>, atomically, preserving every
# other line in place. The caller must already hold that record's lock. Returns
# 1 without touching the record when it cannot be rewritten.
fm_quota_accounting_meta_write() {
  local meta=$1 payload dir tmp line key keys=' '
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  payload=$(cat) || return 1
  [ -n "$payload" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) keys="$keys${line%%=*} " ;;
      *) return 1 ;;
    esac
  done <<EOF
$payload
EOF
  dir=$(dirname "$meta")
  tmp=$(mktemp "$dir/.fm-quota-accounting.XXXXXX") || return 1
  {
    while IFS= read -r line || [ -n "$line" ]; do
      key=${line%%=*}
      case "$keys" in
        *" $key "*) continue ;;
      esac
      printf '%s\n' "$line"
    done < "$meta"
    printf '%s\n' "$payload"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$meta" || { rm -f -- "$tmp"; return 1; }
  return 0
}

FM_QUOTA_ACCOUNTING_ALERT_DEFAULT=10

# fm_quota_accounting_alert_threshold <config-dir>
# Print the alert threshold in percentage points of the quota window: the first
# non-empty line of <config-dir>/quota-drain-alert-threshold when it is a
# non-negative number, otherwise the default.
fm_quota_accounting_alert_threshold() {
  local value
  value=$(sed -n '/[^[:space:]]/{s/^[[:space:]]*//;s/[[:space:]]*$//;p;q;}' \
    "$1/quota-drain-alert-threshold" 2>/dev/null)
  case "$value" in
    ''|*[!0-9.]*|.|*.*.*) value=$FM_QUOTA_ACCOUNTING_ALERT_DEFAULT ;;
  esac
  printf '%s' "$value"
}

# fm_quota_accounting_alert <meta> <task-id> <config-dir>
# When the record carries a measured delta above the configured threshold,
# print the wake payload naming the task and the measured drain and return 0;
# otherwise print nothing and return 1. Only a `measured` delta can alert, and
# the unit is named in the payload for the same reason it is named in the
# summary.
fm_quota_accounting_alert() {
  local meta=$1 id=$2 config=$3 delta threshold window provider over
  [ "$(fm_meta_get "$meta" quota_delta_status)" = measured ] || return 1
  delta=$(fm_meta_get "$meta" quota_delta_percent_points)
  threshold=$(fm_quota_accounting_alert_threshold "$config")
  over=$(jq -n --arg d "$delta" --arg t "$threshold" \
    '($d | tonumber) > ($t | tonumber)' 2>/dev/null) || return 1
  [ "$over" = true ] || return 1
  window=$(fm_meta_get "$meta" quota_window)
  provider=$(fm_meta_get "$meta" quota_provider)
  printf 'check: quota drain: task %s drained %s percentage points of the %s %s quota window while it ran (alert threshold %s), shared with everything else running in that window' \
    "$id" "$delta" "$provider" "$window" "$threshold"
}

# fm_quota_accounting_summary <meta>
# One plain-English clause naming what the record accounts for, or empty when it
# carries no closing reading. The unit is named in the text because a bare
# percentage reads as a share of something else.
fm_quota_accounting_summary() {
  local meta=$1 status delta window provider
  status=$(fm_meta_get "$meta" quota_delta_status)
  case "$status" in
    measured)
      delta=$(fm_meta_get "$meta" quota_delta_percent_points)
      window=$(fm_meta_get "$meta" quota_window)
      provider=$(fm_meta_get "$meta" quota_provider)
      printf 'quota: %s percentage points of the %s %s window drained while this task ran, shared with everything else running in it' \
        "$delta" "$provider" "$window"
      ;;
    window_reset)
      printf 'quota: not attributable; the quota window reset while this task ran'
      ;;
    no_start)
      printf 'quota: not attributable; no reading was recorded when this task was dispatched'
      ;;
    unavailable)
      printf 'quota: not attributable; %s' "$(fm_meta_get "$meta" quota_end_reason)"
      ;;
  esac
}
