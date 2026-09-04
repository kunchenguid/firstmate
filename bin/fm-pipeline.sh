#!/usr/bin/env bash
# fm-pipeline.sh - the single writer for shadow pipeline probe events.
#
# The probe command reads declared `paused:` waits, asks fm-crew-state.sh for
# current state, and appends one schema=fm-pipeline.v2 event per wait.
# Usage:
#   fm-pipeline.sh probe [--task <id>]
#   fm-pipeline.sh append <validated-event-line>
#   fm-pipeline.sh arm
#   fm-pipeline.sh disarm
#
# FM_HOME selects the operational home and FM_STATE_OVERRIDE selects its state
# directory for tests; neither changes fm-crew-state.sh's authority over state.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG="${FM_PIPELINE_LOG:-$STATE/pipeline-events.log}"
CREW_STATE_BIN="${FM_PIPELINE_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

CHECK_ID='pipeline-probe'
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"

die() {
  printf 'fm-pipeline.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,20p' "$0" | sed 's/^# //' >&2
}

[ ! -L "$STATE" ] || die "state directory is unavailable"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

pipeline_state_file_valid() {
  fm_pr_regular_destination_or_absent "$1"
}

pipeline_shim_content() {  # <home> <state>
  local home=$1 state=$2
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$state")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-pipeline.sh") probe"
}

PIPELINE_SHIM_WRITE_TMP=
PIPELINE_SHIM_WROTE=0

pipeline_shim_write() {  # <body>
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-pipeline-check.XXXXXX" 2>/dev/null) || return 1
  PIPELINE_SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    PIPELINE_SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    PIPELINE_SHIM_WRITE_TMP=
    return 1
  fi
  PIPELINE_SHIM_WRITE_TMP=
  PIPELINE_SHIM_WROTE=1
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

pipeline_shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-pipeline-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

pipeline_trust_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-pipeline-check.XXXXXX" 2>/dev/null) || return 1
  if ! cp "$CHECK_TRUST" "$tmp" 2>/dev/null \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

PIPELINE_ARM_BACKUP=
PIPELINE_ARM_TRUST_BACKUP=
PIPELINE_ARM_TRUST_WROTE=0

pipeline_artifact_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

pipeline_arm_collision_free() {
  local want=$1 path
  if pipeline_artifact_present "$CHECK_SHIM"; then
    [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ] \
      && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
      && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ] || return 1
  else
    pipeline_artifact_present "$CHECK_TRUST" && return 1
  fi
  for path in \
    "$STATE/$CHECK_ID.pr-poll" \
    "$STATE/$CHECK_ID.pr-poll-registration" \
    "$STATE/$CHECK_ID.pr-poll-retirement" \
    "$STATE/$CHECK_ID.pr-poll-merge-notified"; do
    pipeline_artifact_present "$path" && return 1
  done
  if pipeline_artifact_present "$CHECK_TRUST" \
    && ! fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    return 1
  fi
}

pipeline_arm_rollback() {
  [ -z "$PIPELINE_SHIM_WRITE_TMP" ] || rm -f -- "$PIPELINE_SHIM_WRITE_TMP"
  PIPELINE_SHIM_WRITE_TMP=
  if [ -n "$PIPELINE_ARM_TRUST_BACKUP" ]; then
    if mv -f -- "$PIPELINE_ARM_TRUST_BACKUP" "$CHECK_TRUST" 2>/dev/null; then
      PIPELINE_ARM_TRUST_BACKUP=
    else
      rm -f -- "$PIPELINE_ARM_TRUST_BACKUP"
      PIPELINE_ARM_TRUST_BACKUP=
    fi
  elif [ "$PIPELINE_ARM_TRUST_WROTE" -eq 1 ]; then
    rm -f -- "$CHECK_TRUST"
  fi
  if [ -n "$PIPELINE_ARM_BACKUP" ]; then
    if mv -f -- "$PIPELINE_ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null; then
      PIPELINE_ARM_BACKUP=
    else
      rm -f -- "$PIPELINE_ARM_BACKUP"
      PIPELINE_ARM_BACKUP=
    fi
  elif [ "$PIPELINE_SHIM_WROTE" -eq 1 ]; then
    rm -f -- "$CHECK_SHIM"
  fi
  PIPELINE_ARM_TRUST_WROTE=0
  PIPELINE_SHIM_WROTE=0
}

pipeline_arm_interrupted() {
  pipeline_arm_rollback
  printf 'fm-pipeline.sh: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

pipeline_arm() {
  local want home state
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  case "$STATE" in
    /*) state=$STATE ;;
    *) state=$(CDPATH='' cd -- "$STATE" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  want=$(pipeline_shim_content "$home" "$state")
  pipeline_arm_collision_free "$want" || return 1
  PIPELINE_ARM_BACKUP=
  PIPELINE_ARM_TRUST_BACKUP=
  PIPELINE_ARM_TRUST_WROTE=0
  PIPELINE_SHIM_WROTE=0
  if pipeline_artifact_present "$CHECK_TRUST"; then
    PIPELINE_ARM_TRUST_BACKUP=$(pipeline_trust_backup) || return 1
  fi
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    PIPELINE_ARM_BACKUP=$(pipeline_shim_backup) || {
      [ -z "$PIPELINE_ARM_TRUST_BACKUP" ] || rm -f -- "$PIPELINE_ARM_TRUST_BACKUP"
      PIPELINE_ARM_TRUST_BACKUP=
      return 1
    }
  fi
  trap pipeline_arm_interrupted HUP INT TERM
  if ! pipeline_shim_write "$want"; then
    trap - HUP INT TERM
    pipeline_arm_rollback
    return 1
  fi
  PIPELINE_ARM_TRUST_WROTE=1
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    pipeline_arm_rollback
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$PIPELINE_ARM_BACKUP" ] || rm -f -- "$PIPELINE_ARM_BACKUP"
  [ -z "$PIPELINE_ARM_TRUST_BACKUP" ] || rm -f -- "$PIPELINE_ARM_TRUST_BACKUP"
  PIPELINE_ARM_BACKUP=
  PIPELINE_ARM_TRUST_BACKUP=
  PIPELINE_ARM_TRUST_WROTE=0
  PIPELINE_SHIM_WROTE=0
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

pipeline_disarm() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$REGISTER_BIN" retire "$CHECK_ID"
}

meta_value() {  # <meta-file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

pipeline_status_key() {  # <line> -> tagged key identity
  local line=$1 key prefix
  if _fm_key_before_colon "$line"; then
    prefix=${line%%:*}
    key=${prefix#*\[key=}
    key=${key%%\]*}
    _fm_decision_slug_ok "$key" || return 1
    printf 'key:%s\n' "$key"
    return 0
  fi
  if key=$(_fm_key_at_note_head "$line"); then
    _fm_decision_slug_ok "$key" || return 1
    printf 'key:%s\n' "$key"
  else
    printf '%s\n' unkeyed
  fi
}

wait_identity() {  # <tagged-key>
  case "$1" in
    unkeyed) printf '%s\n' 'ext:-' ;;
    key:-) printf '%s\n' 'ext:%2D' ;;
    key:default) printf '%s\n' 'ext:%64efault' ;;
    key:*) printf 'ext:%s\n' "${1#key:}" ;;
    *) return 1 ;;
  esac
}

active_paused() {  # <status-file> -> line-number<TAB>key<TAB>line per active pause
  local file=$1 activities active_key active_verb pause
  local line key number latest_number latest_key latest_line
  activities=$(status_open_activities_with_key "$file" pipeline_status_key)
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS=$'\t' read -r active_key active_verb _; do
    [ "$active_verb" = "$pause" ] || continue
    number=0
    latest_number=0
    latest_key=
    latest_line=
    while IFS= read -r line || [ -n "$line" ]; do
      number=$((number + 1))
      if status_is_paused "$line"; then
        if key=$(pipeline_status_key "$line") && [ "$key" = "$active_key" ]; then
          latest_number=$number
          latest_key=$key
          latest_line=$line
        fi
      fi
    done < "$file"
    [ "$latest_number" -gt 0 ] || continue
    printf '%s\t%s\t%s\n' "$latest_number" "$latest_key" "$latest_line"
  done <<EOF
$activities
EOF
}

observation_elapsed_since() {  # <task-id> <wait> <step> <generation> <evidence> <now>
  local id=$1 wait=$2 step=$3 gen=$4 evidence=$5 now=$6 pipeline="$STATE/$1.pipeline"
  local observed
  pipeline_state_file_valid "$pipeline" || return 1
  observed=$(awk -v wait="$wait" -v step="$step" -v gen="$gen" -v evidence="$evidence" '
    $1 == "wait=" wait && $2 == "step=" step && $3 == "gen=" gen && $4 == "evidence=" evidence {
      candidate=substr($5, length("observed_at=")+1)
      if (candidate ~ /^[0-9]+$/) observed=candidate
    }
    END { print observed }
  ' "$pipeline" 2>/dev/null || true)
  case "$observed" in
    ''|*[!0-9]*) observed= ;;
  esac
  if [ -n "$observed" ]; then
    if [ "$now" -ge "$observed" ]; then
      printf '%s\n' "$((now - observed))"
    else
      printf '%s\n' '0'
    fi
    return 0
  fi
  printf 'wait=%s step=%s gen=%s evidence=%s observed_at=%s\n' \
    "$wait" "$step" "$gen" "$evidence" "$now" >> "$pipeline" || return 1
  printf '%s\n' '0'
}

event_valid() {  # <event-line>
  local line=$1
  [ "$(printf '%s\n' "$line" | awk '{print NF}')" -eq 14 ] || {
    printf 'fm-pipeline.sh: event must have exactly 14 key=value fields\n' >&2
    return 1
  }
  printf '%s\n' "$line" | awk '
    BEGIN { OFS=""; ok=1 }
    {
      for (field=1; field<=14; field++) {
        if ($field !~ /^[^=[:space:]]+=[^=[:space:]]+$/) ok=0
      }
      split($1, a, "="); split($2, b, "="); split($3, c, "=");
      split($4, d, "="); split($5, e, "="); split($6, f, "=");
      split($7, g, "="); split($8, h, "="); split($9, i, "=");
      split($10, j, "="); split($11, k, "="); split($12, l, "=");
      split($13, m, "="); split($14, n, "=");
      if (a[1]!="ts" || b[1]!="task" || c[1]!="kind" || d[1]!="step" ||
          e[1]!="since" || f[1]!="probe" || g[1]!="rule" || h[1]!="action" ||
          i[1]!="mode" || j[1]!="evidence" || k[1]!="gen" || l[1]!="attempt" ||
          m[1]!="wait" || n[1]!="snap") ok=0;
      if (a[2] !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) ok=0;
      if (b[2] !~ /^[A-Za-z0-9._-]+$/ || b[2] ~ /^\./) ok=0;
      if (c[2] !~ /^(-|[^[:space:]=]+)$/) ok=0;
      if (d[2] !~ /^(-|[^[:space:]=]+)$/) ok=0;
      if (e[2] !~ /^[0-9]+$/) ok=0;
      if (f[2] !~ /^(ok|stall|fail|unknown)$/) ok=0;
      if (g[2] !~ /^(-|doorbell-then-relaunch|trust-accept|rotate-seat|recheck-external|refuse-duplicate|answer-owned-gate|verify-claimant|adopt-out-of-band-merge)$/) ok=0;
      if (h[2] !~ /^(would-heal|healed|discarded:stale|escalated|advanced|none)$/) ok=0;
      if (i[2] != "shadow") ok=0;
      if (j[2] == "-" && h[2] == "would-heal") ok=0;
      if (j[2] != "-" && j[2] !~ /^[^[:space:]]+:[^[:space:]]+$/) ok=0;
      if (k[2] !~ /^(-|[^[:space:]=]+)$/) ok=0;
      if (l[2] !~ /^(-|[^[:space:]=]+)$/) ok=0;
      if (m[2] !~ /^ext:(-|%2D|%64efault|[A-Za-z0-9._-]+)$/) ok=0;
      if (n[2] !~ /^(-|[^[:space:]=]+)$/) ok=0;
      if (h[2] == "would-heal" && (f[2] != "stall" || g[2] == "-")) ok=0;
      exit(ok ? 0 : 1)
    }
  ' || {
    if printf '%s\n' "$line" | awk '{print $10}' | grep -q '^evidence=-$' &&
      printf '%s\n' "$line" | grep -q 'action=would-heal'; then
      printf 'fm-pipeline.sh: would-heal with evidence=- is inadmissible\n' >&2
    else
      printf 'fm-pipeline.sh: malformed shadow event\n' >&2
    fi
    return 1
  }
}

valid_event_lines() {
  local file=$1 line rejected=0
  while IFS= read -r line || [ -n "$line" ]; do
    if event_valid "$line" >/dev/null 2>&1; then
      printf '%s\n' "$line"
    else
      rejected=$((rejected + 1))
    fi
  done < "$file"
  printf '__fm_pipeline_rejected_rows=%s\n' "$rejected"
}

lock_log() {
  local lock="$LOG.lock"
  mkdir -p "$(dirname "$LOG")" || die "cannot create log directory"
  fm_lock_acquire_wait "$lock" || die "cannot acquire event log lock"
  PIPELINE_LOCK_DIR=$lock
  trap 'fm_lock_release "$PIPELINE_LOCK_DIR"' EXIT
}

append_event() {
  local line=$1
  event_valid "$line" || return 1
  lock_log
  append_event_locked "$line" || die "cannot append event log"
  fm_lock_release "$PIPELINE_LOCK_DIR" || die "cannot release event log lock"
  trap - EXIT
}

append_event_locked() {
  local line=$1
  event_valid "$line" || return 1
  pipeline_state_file_valid "$LOG" || return 1
  printf '%s\n' "$line" >> "$LOG"
}

probe_task() {  # <id>
  local id=$1 status_file meta
  local pauses line_no key line current current_state now ts since kind step gen attempt wait rule action probe evidence
  fm_task_id_path_safe "$id" || die "invalid task id: $id"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  status_file="$STATE/$id.status"
  meta="$STATE/$id.meta"
  pipeline_state_file_valid "$status_file" || die "status file is unavailable: $id"
  pipeline_state_file_valid "$meta" || die "meta file is unavailable: $id"
  [ -f "$status_file" ] || return 0
  pauses=$(active_paused "$status_file")
  [ -n "$pauses" ] || return 0
  current=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT" \
    "$CREW_STATE_BIN" "$id" 2>/dev/null) || current=
  current_state=${current#state: }
  current_state=${current_state%% · *}
  now=$(date +%s)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  kind=-
  step=-
  gen=-
  attempt=-
  if [ -f "$meta" ]; then
    kind=$(meta_value "$meta" kind); [ -n "$kind" ] || kind=-
    step=$(meta_value "$meta" step); [ -n "$step" ] || step=-
    gen=$(meta_value "$meta" spawn_gen); [ -n "$gen" ] || gen=-
    attempt=$(meta_value "$meta" attempt); [ -n "$attempt" ] || attempt=-
  fi
  lock_log
  while IFS=$'\t' read -r line_no key line; do
    wait=$(wait_identity "$key")
    evidence="state/$id.status:$line_no"
    rule=-
    action=none
    case "$current_state" in
      paused)
        if [ "$key" = unkeyed ]; then
          probe=unknown
        else
          probe=ok
        fi
        ;;
      working|parked|done|blocked|failed)
        probe=stall
        rule=recheck-external
        action=would-heal
        ;;
      *)
        probe=unknown
        ;;
    esac
    since=$(observation_elapsed_since "$id" "$wait" "$step" "$gen" "$evidence" "$now") || die "cannot record pipeline observation"
    append_event_locked "ts=$ts task=$id kind=$kind step=$step since=$since probe=$probe rule=$rule action=$action mode=shadow evidence=$evidence gen=$gen attempt=$attempt wait=$wait snap=-" || die "cannot append event log"
  done <<EOF
$pauses
EOF
  fm_lock_release "$PIPELINE_LOCK_DIR" || die "cannot release event log lock"
  trap - EXIT
}

probe_all() {
  local file id
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  for file in "$STATE"/*.status; do
    pipeline_state_file_valid "$file" || continue
    id=${file##*/}
    id=${id%.status}
    fm_task_id_path_safe "$id" || continue
    probe_task "$id"
  done
}

command=${1:-}
shift || true
case "$command" in
  probe)
    task=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) [ "$#" -ge 2 ] || die '--task requires an id'; task=$2; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown probe option: $1" ;;
      esac
    done
    if [ -n "$task" ]; then probe_task "$task"; else probe_all; fi
    ;;
  append)
    [ "$#" -eq 1 ] || die 'append requires one event line'
    append_event "$1"
    ;;
  arm)
    pipeline_arm || die 'could not arm pipeline watcher check'
    ;;
  disarm)
    pipeline_disarm || die 'could not disarm pipeline watcher check'
    ;;
  --help|-h)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
