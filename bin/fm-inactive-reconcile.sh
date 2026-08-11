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
# valid 60..1800) per home, except that --startup performs the same cheap gate
# during a locked session start.
#
# It considers only a direct ordinary crewmate whose durable activity is older
# than that interval and whose last status is not captain-held.
# It then uses fm-crew-state.sh as the sole current-state source.
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
# Main homes also inspect an inactive direct secondmate's validated structured
# home summary.
# A terminal child missing the parent report creates one marked correlated
# request through fm-send and a durable reconciliation obligation.
# The existing pending-reply owner handles its repost and escalation lifecycle.
# Remote summaries use the established fm-on route, never a forge endpoint.
#
# The scan never invokes gh, gh-axi, curl, fm-pr-check.sh, fm-pr-poll.sh, or a
# state *.check.sh.
# It reads only durable local state, fm-crew-state.sh, and a validated
# secondmate-home summary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
OUTCOME_DIR="$STATE/terminal-outcomes"
SCAN_MARKER="$STATE/.inactive-outcome-reconcile"
SCAN_LOCK="$STATE/.inactive-outcome-reconcile.lock"
CREW_STATE_BIN="${FM_INACTIVE_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
SUMMARY_BIN="${FM_INACTIVE_RECONCILE_SUMMARY_BIN:-$SCRIPT_DIR/fm-fleet-snapshot.sh}"
SEND_BIN="${FM_INACTIVE_RECONCILE_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

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

ensure_record() { # <fingerprint> <task> <state> <outcome-key> <origin> <phase> <pr>
  local fingerprint=$1 task=$2 state=$3 outcome_key=$4 origin=$5 phase=$6 pr=$7 tmp
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
    printf 'state=%s\n' "$state"
    printf 'outcome_key=%s\n' "$outcome_key"
    printf 'origin=%s\n' "$origin"
    printf 'phase=%s\n' "$phase"
    printf 'pr=%s\n' "$pr"
    printf 'created_epoch=%s\n' "$(reconcile_now)"
    printf 'request_attempted=0\n'
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
  [ -e "$SCAN_MARKER" ] || { printf '999999\n'; return; }
  now=$(reconcile_now)
  m=$(file_mtime "$SCAN_MARKER" 2>/dev/null || true)
  case "$m" in ''|*[!0-9]*) printf '999999\n'; return ;; esac
  if [ "$now" -lt "$m" ]; then printf '0\n'; else printf '%s\n' $((now - m)); fi
}

meta_field() {
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
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
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  id=$(head -1 "$marker" 2>/dev/null || true)
  valid_id "$id" || return 1
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

parent_has_outcome_report() { # <secondmate-id> <child-id> <state>
  local mate=$1 child=$2 state=$3 key status
  key="inactive-outcome-$mate-$child-$state"
  status="$STATE/$mate.status"
  [ -f "$status" ] || return 1
  grep -Eq "^(done|failed) \[key=${key//./\\.}\]:" "$status" 2>/dev/null
}

summary_for_secondmate() { # <id> <meta>
  local id=$1 meta=$2 home remote_host
  home=$(meta_field "$meta" home)
  remote_host=$(meta_field "$meta" remote_host)
  # Session start keeps its documented blocking path network-free.
  # The existing watcher poll performs the remote summary on its normal cadence.
  if [ -n "$remote_host" ]; then
    [ "${SCAN_STARTUP:-0}" != 1 ] || return 1
    "$SCRIPT_DIR/fm-on.sh" "$id" fm-fleet-snapshot.sh --secondmate-home-summary < /dev/null 2>/dev/null
    return
  fi
  validate_secondmate_home "$id" "$home" 2>/dev/null || return 1
  env \
    FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_HOME="$VALIDATED_HOME" \
    FM_STATE_OVERRIDE="$VALIDATED_HOME/state" \
    FM_DATA_OVERRIDE="$VALIDATED_HOME/data" \
    FM_CONFIG_OVERRIDE="$VALIDATED_HOME/config" \
    FM_PROJECTS_OVERRIDE="$VALIDATED_HOME/projects" \
    "$SUMMARY_BIN" --secondmate-home-summary 2>/dev/null
}

request_secondmate_report() { # <record> <secondmate-id> <child-id> <state> <outcome-key>
  local record=$1 mate=$2 child=$3 state=$4 outcome_key=$5 msg corr rc=0
  [ "$(record_value "$record" request_attempted)" = 1 ] && return 1
  record_field_set "$record" request_attempted 1 || return 2
  msg="INACTIVE OUTCOME RECONCILIATION: child $child is authoritatively $state but has no parent report. Append a terminal parent status report with [key=$outcome_key]."
  corr=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$mate" "$msg" 2>/dev/null || true)
  if [ -n "$corr" ]; then
    msg="$msg Include corr=$corr in that report."
    fm_pending_reply_embed_corr "$msg" "$corr" msg || true
    FM_PENDING_REPLY_EXISTING_CORR="$corr" "$SEND_BIN" "$mate" "$msg" >/dev/null 2>&1 || rc=$?
    record_field_set "$record" correlation "$corr" || true
  else
    "$SEND_BIN" "$mate" "$msg" >/dev/null 2>&1 || rc=$?
  fi
  record_field_set "$record" request_result "$rc" || true
  return "$rc"
}

settle_secondmate_request_if_reported() { # <record> <secondmate-id> <fingerprint>
  local record=$1 mate=$2 fingerprint=$3 corr line
  corr=$(record_value "$record" correlation)
  case "$corr" in [A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9][A-Fa-f0-9]) ;; *) return 0 ;; esac
  line="resolved [key=inactive-outcome-receipt-$fingerprint]: matching terminal parent report received corr=$corr"
  append_once "$STATE/$mate.status" "$line" || return 1
  fm_pending_reply_try_resolve "$STATE" "$corr" "$STATE/$mate.status" >/dev/null 2>&1 || true
}

reconcile_direct_child() { # <id> <meta> <secondmate-id-or-empty>
  local id=$1 meta=$2 self=${3:-} status turn last age state_line state pr fingerprint outcome_key payload
  status="$STATE/$id.status"
  turn="$STATE/$id.turn-ended"
  last=$(last_status_line "$status")
  status_line_verb "$last" | grep -Fx captain-held >/dev/null 2>&1 && return 0
  age=$(last_activity_age "$meta" "$status" "$turn")
  [ "$age" -ge "$FM_INACTIVE_RECONCILE_SECS" ] || return 0
  state_line=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$CREW_STATE_BIN" "$id" 2>/dev/null || true)
  case "$state_line" in
    'state: done '*) state='done' ;;
    'state: failed '*) state='failed' ;;
    *) return 0 ;;
  esac
  pr=$(pr_for_task "$meta" "$status")
  fingerprint=$(sha256_text "$id|$state|$pr|$(clean_field "$last")")
  if [ -n "$self" ]; then
    outcome_key="inactive-outcome-$self-$id-$state"
  else
    outcome_key="inactive-outcome-main-$id-$state"
  fi
  ensure_record "$fingerprint" "$id" "$state" "$outcome_key" direct "upstream" "$pr" || return 1
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

reconcile_secondmate_child() { # <secondmate-id> <child-id> <state>
  local mate=$1 child=$2 state=$3 fingerprint outcome_key payload
  valid_id "$mate" && valid_id "$child" || return 0
  case "$state" in done|failed) ;; *) return 0 ;; esac
  fingerprint=$(sha256_text "secondmate|$mate|$child|$state")
  outcome_key="inactive-outcome-$mate-$child-$state"
  ensure_record "$fingerprint" "$child" "$state" "$outcome_key" "secondmate:$mate" upstream "" || return 1
  [ -n "$RECORD_PENDING" ] || return 0
  if parent_has_outcome_report "$mate" "$child" "$state"; then
    settle_secondmate_request_if_reported "$RECORD_PENDING" "$mate" "$fingerprint" || return 1
    record_phase_set "$RECORD_PENDING" presentation || return 1
    payload="inactive terminal outcome awaiting captain presentation: secondmate=$mate child=$child state=$state"
    queue_presentation "$RECORD_PENDING" "$fingerprint" "$payload" || true
    return 0
  fi
  request_secondmate_report "$RECORD_PENDING" "$mate" "$child" "$state" "$outcome_key" || true
  payload="inactive terminal outcome missing parent report: secondmate=$mate child=$child state=$state"
  queue_notice_once "$RECORD_PENDING" "inactive-reconcile:$fingerprint" "$payload" || true
}

scan_secondmates() {
  local meta mate kind status last age summary child state
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(meta_field "$meta" kind)
    [ "$kind" = secondmate ] || continue
    mate=$(basename "$meta" .meta)
    valid_id "$mate" || continue
    status="$STATE/$mate.status"
    last=$(last_status_line "$status")
    status_line_verb "$last" | grep -Fx captain-held >/dev/null 2>&1 && continue
    age=$(last_activity_age "$meta" "$status" "$STATE/$mate.turn-ended")
    [ "$age" -ge "$FM_INACTIVE_RECONCILE_SECS" ] || continue
    summary=$(summary_for_secondmate "$mate" "$meta" || true)
    printf '%s' "$summary" | jq -e '
      .schema == "fm-secondmate-home-summary.v1"
      and (.terminal_children | type) == "array"
    ' >/dev/null 2>&1 || continue
    while IFS=$(printf '\t') read -r child state; do
      [ -n "$child" ] || continue
      reconcile_secondmate_child "$mate" "$child" "$state"
    done < <(printf '%s' "$summary" | jq -r '.terminal_children[]? | [.id, .state] | @tsv')
  done
}

scan() {
  local startup=${1:-0} self='' meta id kind
  SCAN_STARTUP=$startup
  mkdir -p "$STATE" "$OUTCOME_DIR" || return 1
  [ ! -L "$OUTCOME_DIR" ] || return 1
  if [ "$startup" != 1 ] && [ "$(scan_marker_age)" -lt "$FM_INACTIVE_RECONCILE_SECS" ]; then
    return 0
  fi
  printf '%s\n' "$(reconcile_now)" > "$SCAN_MARKER" || return 1
  self=$(home_secondmate_id || true)
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    kind=$(meta_field "$meta" kind)
    [ "$kind" = secondmate ] && continue
    reconcile_direct_child "$id" "$meta" "$self"
  done
  if [ -z "$self" ]; then
    scan_secondmates
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

mode=${1:-scan}
case "$mode" in
  scan)
    startup=0
    case "${2:-}" in
      '') ;;
      --startup) startup=1 ;;
      *) printf 'usage: fm-inactive-reconcile.sh scan [--startup]\n' >&2; exit 2 ;;
    esac
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    scan "$startup"
    ;;
  acknowledge)
    [ "$#" -eq 2 ] || { printf 'usage: fm-inactive-reconcile.sh acknowledge <fingerprint>\n' >&2; exit 2; }
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    acknowledge "$2"
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
