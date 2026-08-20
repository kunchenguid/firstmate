#!/usr/bin/env bash
# fm-inactive-reconcile.sh - bounded reconciliation of suspicious inactive terminal outcomes.
#
# Usage:
#   fm-inactive-reconcile.sh scan [--startup]
#   fm-inactive-reconcile.sh acknowledge <fingerprint>
#
# This is an adjunct to the existing watcher poll loop and session-start path,
# not a watcher, daemon, PR poll, or forge client of its own.
# `scan` evaluates at most once per FM_INACTIVE_RECONCILE_SECS (default 900,
# valid 60..1800) per home, except that --startup performs the same cheap scan
# immediately during a locked session start. Each scan uses an aggregate
# FM_INACTIVE_RECONCILE_BUDGET_SECS deadline (default 10, valid 1..30) and
# resumes after its last visited child on the next scan.
# The scan enforces that budget itself through a whole-second deadline, and the
# first due child of every scan is always visited with at least a one-second
# state-read bound: whole-second arithmetic can otherwise round a small budget
# to zero mid-scan, and an invocation that exits having visited nothing would
# advance the durable cursor past a child it never examined. A process-group
# kill one second after the budget remains as a backstop for a scan wedged in
# an unbounded wait (for example a live-held wake-queue lock), so the clean
# deadline path is not racing its own backstop.
#
# It considers only a direct ordinary crewmate whose newest meta, status, or
# turn-ended mtime is older than that interval and whose last status is not
# captain-held. It then uses fm-crew-state.sh as the sole current-state source.
# Only a done or failed state is suspicious enough to create a durable terminal
# outcome record or wake the supervisor.
# Working, paused, parked, blocked, unknown, persistent secondmates, and
# captain-held work retain their existing supervision semantics.
#
# A terminal-outcomes/<fingerprint>.pending record remains until its upstream
# receipt is durable.
# In a secondmate home, that receipt is an idempotent parent-channel status
# append.
# In a main home, a presentation-stage record is acknowledged by fm-wake-drain
# only after its corresponding inactive-outcome wake is handled.
# A receipt is intentionally independent of .hb-surfaced-* bookkeeping.
#
# New fm-terminal-outcome.v1 receipts contain schema, fingerprint, task_id,
# incarnation, state, outcome_key, origin, phase, pr, created_epoch, and
# notice_emitted; the fingerprint binds the spawn incarnation, task id, terminal
# state, PR text, and sanitized last status.
# Pending atomically becomes reported after parent append or presented after
# main-home acknowledgement. The atomic epoch/cursor marker's mtime gates scans,
# and its cursor records the last child visited within the aggregate budget.
#
# The scan reads only durable local state and fm-crew-state.sh; it never invokes
# gh, gh-axi, curl, fm-pr-check.sh, fm-pr-poll.sh, or a state *.check.sh.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
OUTCOME_DIR="$STATE/terminal-outcomes"
SCAN_MARKER="$STATE/.inactive-outcome-reconcile"
SCAN_LOCK="$STATE/.inactive-outcome-reconcile.lock"
CREW_STATE_BIN="${FM_INACTIVE_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

FM_INACTIVE_RECONCILE_SECS=${FM_INACTIVE_RECONCILE_SECS:-900}
case "$FM_INACTIVE_RECONCILE_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-inactive-reconcile: FM_INACTIVE_RECONCILE_SECS must be a whole number from 60 to 1800\n' >&2
    exit 2
    ;;
esac
if [ "$FM_INACTIVE_RECONCILE_SECS" -lt 60 ] || [ "$FM_INACTIVE_RECONCILE_SECS" -gt 1800 ]; then
  printf 'fm-inactive-reconcile: FM_INACTIVE_RECONCILE_SECS must be a whole number from 60 to 1800\n' >&2
  exit 2
fi
FM_INACTIVE_RECONCILE_BUDGET_SECS=${FM_INACTIVE_RECONCILE_BUDGET_SECS:-10}
case "$FM_INACTIVE_RECONCILE_BUDGET_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-inactive-reconcile: FM_INACTIVE_RECONCILE_BUDGET_SECS must be a whole number from 1 to 30\n' >&2
    exit 2
    ;;
esac
if [ "$FM_INACTIVE_RECONCILE_BUDGET_SECS" -gt 30 ]; then
  printf 'fm-inactive-reconcile: FM_INACTIVE_RECONCILE_BUDGET_SECS must be a whole number from 1 to 30\n' >&2
  exit 2
fi

if [ "$(uname)" = Darwin ]; then
  file_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

reconcile_now() {
  case "${FM_INACTIVE_RECONCILE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_INACTIVE_RECONCILE_NOW" ;;
  esac
}

clean_field() {
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-1200
}

valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 32)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 32)}'
  else
    printf '%s' "$1" | cksum | awk '{printf "%08x%08x", $1, $2}'
  fi
}

record_path() { printf '%s/%s.%s\n' "$OUTCOME_DIR" "$1" "$2"; }

record_value() {
  local record=$1 key=$2
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  grep "^${key}=" "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

record_phase_set() {
  local record=$1 phase=$2 tmp line
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  tmp=$(mktemp "$OUTCOME_DIR/.record.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in phase=*) continue ;; esac
    printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; }
  done < "$record"
  printf 'phase=%s\n' "$phase" >> "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$record"
}

record_field_set() {
  local record=$1 key=$2 value=$3 tmp line
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  tmp=$(mktemp "$OUTCOME_DIR/.record.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "${key}="*) continue ;; esac
    printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; }
  done < "$record"
  printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$record"
}

ensure_record() { # <fingerprint> <task> <incarnation> <state> <outcome-key> <origin> <phase> <pr>
  local fingerprint=$1 task=$2 incarnation=$3 state=$4 outcome_key=$5 origin=$6 phase=$7 pr=$8 tmp
  RECORD_PENDING=$(record_path "$fingerprint" pending)
  RECORD_PRESENTED=$(record_path "$fingerprint" presented)
  RECORD_REPORTED=$(record_path "$fingerprint" reported)
  if [ -f "$RECORD_PRESENTED" ] || [ -f "$RECORD_REPORTED" ]; then
    RECORD_PENDING=
    return 0
  fi
  if [ -f "$RECORD_PENDING" ] && [ ! -L "$RECORD_PENDING" ]; then
    return 0
  fi
  mkdir -p "$OUTCOME_DIR" || return 1
  [ ! -L "$OUTCOME_DIR" ] || return 1
  tmp=$(mktemp "$OUTCOME_DIR/.pending.XXXXXX") || return 1
  {
    printf 'schema=fm-terminal-outcome.v1\n'
    printf 'fingerprint=%s\n' "$fingerprint"
    printf 'task_id=%s\n' "$task"
    printf 'incarnation=%s\n' "$incarnation"
    printf 'state=%s\n' "$state"
    printf 'outcome_key=%s\n' "$outcome_key"
    printf 'origin=%s\n' "$origin"
    printf 'phase=%s\n' "$phase"
    printf 'pr=%s\n' "$pr"
    printf 'created_epoch=%s\n' "$(reconcile_now)"
    printf 'notice_emitted=0\n'
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$RECORD_PENDING" || { rm -f "$tmp"; return 1; }
}

mark_reported() { # <record>
  local record=$1 reported
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  reported=${record%.pending}.reported
  mv -f "$record" "$reported"
}

queue_key_exists() { # <key>
  local key=$1 queued
  queued=$(fm_wake_queued_keys check 2>/dev/null || true)
  printf '%s\n' "$queued" | grep -Fx -- "$key" >/dev/null 2>&1
}

queue_notice_once() { # <record> <key> <payload>
  local record=$1 key=$2 payload=$3 notified
  notified=$(record_value "$record" notice_emitted)
  [ "$notified" = 1 ] && return 1
  if queue_key_exists "$key"; then
    record_field_set "$record" notice_emitted 1 || return 2
    return 1
  fi
  fm_wake_append check "$key" "$payload" || return 2
  record_field_set "$record" notice_emitted 1 || return 2
  printf 'actionable: %s\n' "$payload"
  return 0
}

queue_presentation() { # <record> <fingerprint> <payload>
  local record=$1 fingerprint=$2 payload=$3 key
  key="inactive-outcome:$fingerprint"
  if queue_key_exists "$key"; then
    return 1
  fi
  fm_wake_append check "$key" "$payload" || return 2
  printf 'actionable: %s\n' "$payload"
  return 0
}

last_activity_age() { # <meta> <status> <turn-ended>
  local meta=$1 status=$2 turn=$3 now m newest=0 file
  now=$(reconcile_now)
  for file in "$meta" "$status" "$turn"; do
    [ -e "$file" ] || continue
    m=$(file_mtime "$file" 2>/dev/null || true)
    case "$m" in ''|*[!0-9]*) continue ;; esac
    [ "$m" -le "$newest" ] || newest=$m
  done
  [ "$newest" -gt 0 ] || { printf '0\n'; return; }
  if [ "$now" -lt "$newest" ]; then printf '0\n'; else printf '%s\n' $((now - newest)); fi
}

scan_marker_age() {
  local now m
  [ -e "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || { printf '999999\n'; return; }
  now=$(reconcile_now)
  m=$(file_mtime "$SCAN_MARKER" 2>/dev/null || true)
  case "$m" in ''|*[!0-9]*) printf '999999\n'; return ;; esac
  if [ "$now" -lt "$m" ]; then printf '0\n'; else printf '%s\n' $((now - m)); fi
}

scan_marker_cursor() {
  [ -f "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || return 0
  grep '^cursor=' "$SCAN_MARKER" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

write_scan_marker() { # <cursor>
  local cursor=$1 marker_tmp
  marker_tmp=$(mktemp "$STATE/.inactive-outcome-reconcile.XXXXXX") || return 1
  {
    printf 'epoch=%s\n' "$(reconcile_now)"
    printf 'cursor=%s\n' "$cursor"
  } > "$marker_tmp" || { rm -f "$marker_tmp"; return 1; }
  chmod 600 "$marker_tmp" 2>/dev/null || true
  mv -f "$marker_tmp" "$SCAN_MARKER" || { rm -f "$marker_tmp"; return 1; }
}

meta_field() {
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

meta_incarnation() { # <meta>
  local meta=$1 incarnation identity
  incarnation=$(meta_field "$meta" spawn_gen)
  if valid_id "$incarnation"; then
    printf '%s\n' "$incarnation"
    return
  fi
  identity=$(meta_field "$meta" tasktmp)
  if [ -z "$identity" ]; then
    identity="$(meta_field "$meta" window)|$(meta_field "$meta" worktree)"
  fi
  printf 'legacy-%s\n' "$(sha256_text "$identity")"
}

pr_for_task() { # <meta> <status>
  local pr=$1 status=$2 value
  value=$(meta_field "$pr" pr)
  if [ -z "$value" ] && [ -f "$status" ]; then
    value=$(grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' "$status" 2>/dev/null | head -1 || true)
  fi
  clean_field "$value"
}

home_secondmate_id() {
  local marker="$FM_HOME/.fm-secondmate-home" id
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 1
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  [ "$(wc -c < "$marker")" -eq "$(LC_ALL=C tr -d '\0' < "$marker" | wc -c)" ] || return 2
  id=$(cat "$marker" 2>/dev/null) || return 2
  valid_id "$id" || return 2
  printf '%s\n' "$id"
}

append_once() { # <path> <line>
  local path=$1 line=$2
  [ ! -L "$path" ] || return 1
  mkdir -p "$(dirname "$path")" || return 1
  if grep -Fqx -- "$line" "$path" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$line" >> "$path"
}

report_to_parent() { # <self-id> <task> <state> <outcome-key> <fingerprint> <pr>
  local self=$1 task=$2 state=$3 outcome_key=$4 fingerprint=$5 pr=$6 parent_record destination line
  parent_record="$FM_HOME/.fm-secondmate-parent"
  fm_secondmate_parent_record_parse "$parent_record" || return 1
  case "$FM_SECONDMATE_PARENT_ROUTE" in
    local)
      [ -n "$FM_SECONDMATE_PARENT_HOME" ] || return 1
      destination="$FM_SECONDMATE_PARENT_HOME/state/$self.status"
      ;;
    remote)
      destination="$STATE/parent-replies.status"
      ;;
    *) return 1 ;;
  esac
  line="$state [key=$outcome_key]: inactive terminal child=$task fingerprint=$fingerprint"
  [ -z "$pr" ] || line="$line pr=$pr"
  append_once "$destination" "$line"
}

reconcile_direct_child_locked() { # <id> <meta> <secondmate-id-or-empty> <timeout>
  local id=$1 meta=$2 self=${3:-} timeout=$4 status turn last age state_line state pr incarnation fingerprint outcome_key payload kind state_rc=0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(meta_field "$meta" kind)
  [ "$kind" = secondmate ] && return 0
  status="$STATE/$id.status"
  turn="$STATE/$id.turn-ended"
  last=$(last_status_line "$status")
  status_line_verb "$last" | grep -Fx captain-held >/dev/null 2>&1 && return 0
  age=$(last_activity_age "$meta" "$status" "$turn")
  [ "$age" -ge "$FM_INACTIVE_RECONCILE_SECS" ] || return 0
  state_line=$(fm_run_timed "$timeout" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$CREW_STATE_BIN" "$id" 2>/dev/null) || state_rc=$?
  [ "$state_rc" -ne 124 ] || return 3
  case "$state_line" in
    'state: done '*) state='done' ;;
    'state: failed '*) state='failed' ;;
    *) return 0 ;;
  esac
  pr=$(pr_for_task "$meta" "$status")
  incarnation=$(meta_incarnation "$meta")
  fingerprint=$(sha256_text "$incarnation|$id|$state|$pr|$(clean_field "$last")")
  if [ -n "$self" ]; then
    outcome_key="inactive-outcome-$self-$id-$state"
  else
    outcome_key="inactive-outcome-main-$id-$state"
  fi
  ensure_record "$fingerprint" "$id" "$incarnation" "$state" "$outcome_key" direct "upstream" "$pr" || return 1
  [ -n "$RECORD_PENDING" ] || return 0
  if [ -n "$self" ]; then
    if report_to_parent "$self" "$id" "$state" "$outcome_key" "$fingerprint" "$pr"; then
      mark_reported "$RECORD_PENDING" || return 1
    else
      payload="inactive terminal outcome needs parent report: child=$id state=$state"
      queue_notice_once "$RECORD_PENDING" "inactive-reconcile:$fingerprint" "$payload" || true
    fi
    return 0
  fi
  record_phase_set "$RECORD_PENDING" presentation || return 1
  payload="inactive terminal outcome awaiting captain presentation: child=$id state=$state"
  [ -z "$pr" ] || payload="$payload pr=$pr"
  queue_presentation "$RECORD_PENDING" "$fingerprint" "$payload" || true
}

reconcile_direct_child() { # <id> <meta> <secondmate-id-or-empty> <timeout>
  local id=$1 meta=$2 self=${3:-} timeout=$4 lock rc=0
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  reconcile_direct_child_locked "$id" "$meta" "$self" "$timeout" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

# SCAN_FIRST_VISIT_PENDING is armed by scan() before its passes. The deadline
# below is whole-second arithmetic, so a small budget can quantize to zero
# between the deadline computation and these checks; without the guaranteed
# first visit, such a scan would return 3 having examined no child at all while
# write_scan_marker had already advanced the cursor past the skipped child.
scan_pass() { # <cursor> <after|through> <deadline> <secondmate-id-or-empty>
  local cursor=$1 range=$2 deadline=$3 self=${4:-} meta id remaining rc first
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    case "$range" in
      after) [ -z "$cursor" ] || [[ "$id" > "$cursor" ]] || continue ;;
      through) [ -n "$cursor" ] && [[ "$id" > "$cursor" ]] && continue ;;
    esac
    first=0
    if [ "${SCAN_FIRST_VISIT_PENDING:-0}" -eq 1 ]; then
      first=1
      SCAN_FIRST_VISIT_PENDING=0
    fi
    if [ "$first" -eq 0 ]; then
      [ "$(date +%s)" -lt "$deadline" ] || return 3
    fi
    write_scan_marker "$id" || return 1
    remaining=$((deadline - $(date +%s)))
    if [ "$first" -eq 1 ] && [ "$remaining" -lt 1 ]; then
      remaining=1
    fi
    [ "$remaining" -gt 0 ] || return 3
    reconcile_direct_child "$id" "$meta" "$self" "$remaining" || {
      rc=$?
      [ "$rc" -eq 3 ] && return 3
      return "$rc"
    }
  done
}

scan() {
  local startup=${1:-0} self='' cursor deadline rc=0 marker_rc=0
  mkdir -p "$STATE" "$OUTCOME_DIR" || return 1
  [ ! -L "$OUTCOME_DIR" ] || return 1
  if [ "$startup" != 1 ] && [ "$(scan_marker_age)" -lt "$FM_INACTIVE_RECONCILE_SECS" ]; then
    return 0
  fi
  cursor=$(scan_marker_cursor)
  valid_id "$cursor" || cursor=''
  write_scan_marker "$cursor" || return 1
  if self=$(home_secondmate_id); then
    :
  else
    marker_rc=$?
    self=''
    if [ "$marker_rc" -ne 1 ]; then
      printf 'actionable: inactive terminal outcomes remain unreconciled: invalid .fm-secondmate-home marker\n'
      return 0
    fi
  fi
  deadline=$(( $(date +%s) + FM_INACTIVE_RECONCILE_BUDGET_SECS ))
  SCAN_FIRST_VISIT_PENDING=1
  scan_pass "$cursor" after "$deadline" "$self" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$cursor" ]; then
    scan_pass "$cursor" through "$deadline" "$self" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    write_scan_marker '' || return 1
  elif [ "$rc" -ne 3 ]; then
    return "$rc"
  fi
}

acknowledge() { # <fingerprint>
  local fingerprint=$1 pending presented phase
  case "$fingerprint" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  [ -d "$OUTCOME_DIR" ] && [ ! -L "$OUTCOME_DIR" ] || return 1
  pending=$(record_path "$fingerprint" pending)
  presented=$(record_path "$fingerprint" presented)
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 0
  phase=$(record_value "$pending" phase)
  [ "$phase" = presentation ] || return 0
  mv -f "$pending" "$presented"
}

acknowledge_notice() { # <fingerprint>
  local fingerprint=$1 pending
  case "$fingerprint" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  [ -d "$OUTCOME_DIR" ] && [ ! -L "$OUTCOME_DIR" ] || return 1
  pending=$(record_path "$fingerprint" pending)
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 0
  record_field_set "$pending" notice_emitted 1
}

mode=${1:-scan}
case "$mode" in
  scan)
    startup=0
    case "${2:-}" in
      '') ;;
      --startup) startup=1 ;;
      *) printf 'usage: fm-inactive-reconcile.sh scan [--startup]\n' >&2; exit 2 ;;
    esac
    # The scan's own whole-second deadline enforces the budget; this outer
    # process-group kill is only the backstop for a scan wedged outside every
    # bounded section (an unbounded lock wait), so it fires one second after
    # the deadline instead of racing the clean bounded exit it exists to guard.
    if fm_run_timed $((FM_INACTIVE_RECONCILE_BUDGET_SECS + 1)) "$0" _scan-locked "$startup"; then
      :
    elif [ "$?" -ne 124 ]; then
      exit 1
    fi
    ;;
  _scan-locked)
    [ "$#" -eq 2 ] || exit 2
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    scan "$2"
    ;;
  acknowledge)
    [ "$#" -eq 2 ] || { printf 'usage: fm-inactive-reconcile.sh acknowledge <fingerprint>\n' >&2; exit 2; }
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    acknowledge "$2"
    ;;
  acknowledge-notice)
    [ "$#" -eq 2 ] || exit 2
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    acknowledge_notice "$2"
    ;;
  -h|--help)
    sed -n '2,40{s/^# \{0,1\}//;p;}' "$0"
    ;;
  *)
    printf 'usage: fm-inactive-reconcile.sh scan [--startup]\n' >&2
    printf '       fm-inactive-reconcile.sh acknowledge <fingerprint>\n' >&2
    exit 2
    ;;
esac
