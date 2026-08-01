#!/usr/bin/env bash
# Coordinate one home-local no-mistakes validation slot without a daemon.
# Usage: fm-validation-lane.sh enqueue <task-id>
#        fm-validation-lane.sh check
#        fm-validation-lane.sh show
#
# State lives in state/validation-lane as fm-validation-lane-v2.  It has one
# optional holder=<task-id>, one optional release=<task-id>, and zero or more
# queued=<task-id> records in FIFO order.  An owner also has reservation-kind,
# reservation-run, reservation-start, reservation-state, and
# reservation-started records binding completion to run evidence observed after
# that reservation.  release is the queue head reserved for delivery but not
# yet confirmed by fm-send; keeping it durable means a failed delivery is
# retried and never silently skipped.
#
# enqueue records a task, installs the authenticated watcher check, and releases
# immediately when the slot is free.  check is executed through that registered
# check: it reads the holder's authoritative fm-crew-state result, frees only a
# reservation-bound terminal no-mistakes run-step, then sends the next
# reservation through fm-send.  The task receiving that message starts and owns
# its own pipeline.  Unavailable identity without comparable run-start evidence
# leaves a new head queued or an existing holder held instead of guessing.
#
# A failed send leaves release intact and prints one diagnostic so the watcher
# emits a check wake.  This script never invokes no-mistakes, responds to its
# gates, or changes a task worktree.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LANE="$STATE/validation-lane"
LOCK="$STATE/.validation-lane.lock"
CHECK_ID=validation-lane
CHECK="$STATE/$CHECK_ID.check.sh"
TRUST="$STATE/$CHECK_ID.check-trust"
SEND_BIN="${FM_VALIDATION_LANE_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"
CREW_STATE_BIN="${FM_VALIDATION_LANE_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
REGISTER_BIN="${FM_VALIDATION_LANE_REGISTER_BIN:-$SCRIPT_DIR/fm-check-register.sh}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

lane_error() {
  printf 'validation-lane: %s\n' "$*" >&2
}

require_state() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || {
    lane_error "state directory is unavailable"
    return 1
  }
  LANE_DEVICE=$(fm_pr_file_device "$STATE") || {
    lane_error "cannot read state device"
    return 1
  }
}

lane_lock() {
  local tries=0
  while ! fm_lock_try_acquire "$LOCK"; do
    tries=$((tries + 1))
    if [ "$tries" -ge 50 ]; then
      lane_error "lock remained busy"
      return 1
    fi
    sleep 0.1
  done
}

lane_unlock() {
  fm_lock_release "$LOCK" || true
}

LANE_HOLDER=
LANE_RELEASE=
LANE_RESERVATION_KIND=
LANE_RESERVATION_RUN=
LANE_RESERVATION_START=
LANE_RESERVATION_STATE=
LANE_RESERVATION_STARTED=
LANE_QUEUE=()

reset_lane() {
  LANE_HOLDER=
  LANE_RELEASE=
  LANE_RESERVATION_KIND=
  LANE_RESERVATION_RUN=
  LANE_RESERVATION_START=
  LANE_RESERVATION_STATE=
  LANE_RESERVATION_STARTED=
  LANE_QUEUE=()
}

clear_reservation() {
  LANE_RESERVATION_KIND=
  LANE_RESERVATION_RUN=
  LANE_RESERVATION_START=
  LANE_RESERVATION_STATE=
  LANE_RESERVATION_STARTED=
}

lane_id_seen() {  # <id>
  local id=$1 queued
  [ "$LANE_HOLDER" = "$id" ] && return 0
  [ "$LANE_RELEASE" = "$id" ] && return 0
  for queued in "${LANE_QUEUE[@]}"; do
    [ "$queued" = "$id" ] && return 0
  done
  return 1
}

read_lane() {
  local line value first=1 holder_seen=0 release_seen=0
  local reservation_kind_seen=0 reservation_run_seen=0 reservation_start_seen=0 reservation_state_seen=0 reservation_started_seen=0
  reset_lane
  [ -e "$LANE" ] || return 0
  fm_pr_private_file_valid "$LANE" 600 "$LANE_DEVICE" || {
    lane_error "state file is invalid"
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" -eq 1 ]; then
      first=0
      [ "$line" = fm-validation-lane-v2 ] || {
        lane_error "state file has an unknown format"
        return 1
      }
      continue
    fi
    case "$line" in
      holder=*)
        [ "$holder_seen" -eq 0 ] || { lane_error "state has duplicate holder"; return 1; }
        value=${line#holder=}
        fm_pr_task_id_valid "$value" || { lane_error "state has invalid holder"; return 1; }
        lane_id_seen "$value" && { lane_error "state repeats task $value"; return 1; }
        LANE_HOLDER=$value
        holder_seen=1
        ;;
      release=*)
        [ "$release_seen" -eq 0 ] || { lane_error "state has duplicate release"; return 1; }
        value=${line#release=}
        fm_pr_task_id_valid "$value" || { lane_error "state has invalid release"; return 1; }
        lane_id_seen "$value" && { lane_error "state repeats task $value"; return 1; }
        LANE_RELEASE=$value
        release_seen=1
        ;;
      reservation-kind=*)
        [ "$reservation_kind_seen" -eq 0 ] || { lane_error "state has duplicate reservation kind"; return 1; }
        value=${line#reservation-kind=}
        case "$value" in full|coarse|absent|unavailable) ;; *) lane_error "state has invalid reservation kind"; return 1 ;; esac
        LANE_RESERVATION_KIND=$value
        reservation_kind_seen=1
        ;;
      reservation-run=*)
        [ "$reservation_run_seen" -eq 0 ] || { lane_error "state has duplicate reservation run"; return 1; }
        value=${line#reservation-run=}
        case "$value" in none) ;; *) [[ "$value" =~ ^[0-9a-f]{64}$ ]] || { lane_error "state has invalid reservation run"; return 1; } ;; esac
        LANE_RESERVATION_RUN=$value
        reservation_run_seen=1
        ;;
      reservation-start=*)
        [ "$reservation_start_seen" -eq 0 ] || { lane_error "state has duplicate reservation start evidence"; return 1; }
        value=${line#reservation-start=}
        case "$value" in none) ;; *) [[ "$value" =~ ^[0-9a-f]{64}$ ]] || { lane_error "state has invalid reservation start evidence"; return 1; } ;; esac
        LANE_RESERVATION_START=$value
        reservation_start_seen=1
        ;;
      reservation-state=*)
        [ "$reservation_state_seen" -eq 0 ] || { lane_error "state has duplicate reservation state"; return 1; }
        value=${line#reservation-state=}
        case "$value" in active|terminal|other) ;; *) lane_error "state has invalid reservation state"; return 1 ;; esac
        LANE_RESERVATION_STATE=$value
        reservation_state_seen=1
        ;;
      reservation-started=*)
        [ "$reservation_started_seen" -eq 0 ] || { lane_error "state has duplicate reservation start"; return 1; }
        value=${line#reservation-started=}
        case "$value" in 0|1) ;; *) lane_error "state has invalid reservation start"; return 1 ;; esac
        LANE_RESERVATION_STARTED=$value
        reservation_started_seen=1
        ;;
      queued=*)
        value=${line#queued=}
        fm_pr_task_id_valid "$value" || { lane_error "state has invalid queue entry"; return 1; }
        lane_id_seen "$value" && { lane_error "state repeats task $value"; return 1; }
        LANE_QUEUE+=("$value")
        ;;
      *) lane_error "state has an invalid record"; return 1 ;;
    esac
  done < "$LANE"
  [ "$first" -eq 0 ] || { lane_error "state file is empty"; return 1; }
  [ -z "$LANE_HOLDER" ] || [ -z "$LANE_RELEASE" ] || {
    lane_error "state has both holder and pending release"
    return 1
  }
  if [ -n "$LANE_HOLDER" ] || [ -n "$LANE_RELEASE" ]; then
    [ "$reservation_kind_seen" -eq 1 ] && [ "$reservation_run_seen" -eq 1 ] && [ "$reservation_start_seen" -eq 1 ] \
      && [ "$reservation_state_seen" -eq 1 ] && [ "$reservation_started_seen" -eq 1 ] || {
      lane_error "state has an owner without reservation evidence"
      return 1
    }
    if [ "$LANE_RESERVATION_KIND" = full ]; then
      [ "$LANE_RESERVATION_RUN" != none ] || { lane_error "state has a full reservation without a run"; return 1; }
    else
      [ "$LANE_RESERVATION_RUN" = none ] || { lane_error "state has a non-full reservation with a run"; return 1; }
    fi
    [ -n "$LANE_HOLDER" ] || [ "$LANE_RESERVATION_STARTED" = 0 ] || {
      lane_error "pending release claims a started run"
      return 1
    }
  elif [ "$reservation_kind_seen" -ne 0 ] || [ "$reservation_run_seen" -ne 0 ] || [ "$reservation_start_seen" -ne 0 ] \
    || [ "$reservation_state_seen" -ne 0 ] || [ "$reservation_started_seen" -ne 0 ]; then
    lane_error "state has reservation evidence without an owner"
    return 1
  fi
}

write_lane() {
  local tmp queued
  if [ -z "$LANE_HOLDER" ] && [ -z "$LANE_RELEASE" ] && [ "${#LANE_QUEUE[@]}" -eq 0 ]; then
    if [ -e "$LANE" ] || [ -L "$LANE" ]; then
      fm_pr_private_file_valid "$LANE" 600 "$LANE_DEVICE" || {
        lane_error "state file is invalid"
        return 1
      }
      rm -f -- "$LANE" || return 1
    fi
    return 0
  fi
  fm_pr_regular_destination_on_device_or_absent "$LANE" "$LANE_DEVICE" || {
    lane_error "state destination is unavailable"
    return 1
  }
  umask 077
  tmp=$(mktemp "$STATE/.fm-validation-lane.XXXXXX") || return 1
  trap 'rm -f -- "${tmp:-}"' RETURN
  {
    printf '%s\n' fm-validation-lane-v2
    [ -z "$LANE_HOLDER" ] || printf 'holder=%s\n' "$LANE_HOLDER"
    [ -z "$LANE_RELEASE" ] || printf 'release=%s\n' "$LANE_RELEASE"
    if [ -n "$LANE_HOLDER" ] || [ -n "$LANE_RELEASE" ]; then
      printf 'reservation-kind=%s\n' "$LANE_RESERVATION_KIND"
      printf 'reservation-run=%s\n' "$LANE_RESERVATION_RUN"
      printf 'reservation-start=%s\n' "$LANE_RESERVATION_START"
      printf 'reservation-state=%s\n' "$LANE_RESERVATION_STATE"
      printf 'reservation-started=%s\n' "$LANE_RESERVATION_STARTED"
    fi
    for queued in "${LANE_QUEUE[@]}"; do
      printf 'queued=%s\n' "$queued"
    done
  } > "$tmp" || return 1
  chmod 0600 "$tmp" || return 1
  fm_pr_private_file_valid "$tmp" 600 "$LANE_DEVICE" || return 1
  fm_pr_regular_destination_on_device_or_absent "$LANE" "$LANE_DEVICE" || return 1
  mv -f -- "$tmp" "$LANE" || return 1
  tmp=
  trap - RETURN
}

install_check() {
  local tmp
  fm_pr_regular_destination_on_device_or_absent "$CHECK" "$LANE_DEVICE" || {
    lane_error "watcher check destination is unavailable"
    return 1
  }
  umask 077
  tmp=$(mktemp "$STATE/.fm-validation-lane-check.XXXXXX") || return 1
  trap 'rm -f -- "${tmp:-}"' RETURN
  printf '#!/usr/bin/env bash\nexec %q check\n' "$SCRIPT_DIR/fm-validation-lane.sh" > "$tmp" || return 1
  chmod 0700 "$tmp" || return 1
  [ -f "$tmp" ] && [ ! -L "$tmp" ] || return 1
  [ "$(fm_pr_file_mode "$tmp")" = 700 ] || return 1
  [ "$(fm_pr_file_device "$tmp")" = "$LANE_DEVICE" ] || return 1
  [ "$(fm_pr_file_link_count "$tmp")" = 1 ] || return 1
  mv -f -- "$tmp" "$CHECK" || return 1
  tmp=
  trap - RETURN
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$REGISTER_BIN" "$CHECK_ID" >/dev/null || {
    lane_error "could not register watcher check"
    return 1
  }
}

remove_check() {
  local path
  for path in "$CHECK" "$TRUST"; do
    [ ! -e "$path" ] && [ ! -L "$path" ] && continue
    fm_pr_private_file_valid "$path" "$( [ "$path" = "$CHECK" ] && printf 700 || printf 600 )" "$LANE_DEVICE" || {
      lane_error "watcher artifact is invalid"
      return 1
    }
    rm -f -- "$path" || return 1
  done
}

refresh_check() {
  if [ -n "$LANE_HOLDER" ] || [ -n "$LANE_RELEASE" ] || [ "${#LANE_QUEUE[@]}" -gt 0 ]; then
    install_check
  else
    remove_check
  fi
}

reserve_next() {
  local task
  [ -n "$LANE_HOLDER" ] && return 0
  [ -n "$LANE_RELEASE" ] && return 0
  [ "${#LANE_QUEUE[@]}" -gt 0 ] || return 0
  task=${LANE_QUEUE[0]}
  capture_reservation "$task" || return 1
  LANE_RELEASE=$task
  LANE_QUEUE=("${LANE_QUEUE[@]:1}")
}

CREW_OBS_STATE=
CREW_OBS_SOURCE=
CREW_OBS_KIND=
CREW_OBS_RUN=
CREW_OBS_START=

hash_run_id() {  # <run-id>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

read_crew_observation() {  # <task-id>
  local task=$1 out lines run_id run_start
  CREW_OBS_STATE=
  CREW_OBS_SOURCE=
  CREW_OBS_KIND=
  CREW_OBS_RUN=none
  CREW_OBS_START=none
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$CREW_STATE_BIN" --validation-lane "$task" 2>/dev/null) || {
    lane_error "cannot read reservation state for $task"
    return 1
  }
  lines=$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')
  [ "$lines" = 6 ] || { lane_error "reservation state for $task is malformed"; return 1; }
  [ "$(printf '%s\n' "$out" | sed -n '1p')" = fm-crew-validation-v2 ] \
    || { lane_error "reservation state for $task has an unknown format"; return 1; }
  CREW_OBS_STATE=$(printf '%s\n' "$out" | sed -n '2s/^state=//p')
  CREW_OBS_SOURCE=$(printf '%s\n' "$out" | sed -n '3s/^source=//p')
  CREW_OBS_KIND=$(printf '%s\n' "$out" | sed -n '4s/^run-kind=//p')
  run_id=$(printf '%s\n' "$out" | sed -n '5s/^run-id=//p')
  run_start=$(printf '%s\n' "$out" | sed -n '6s/^run-start=//p')
  case "$CREW_OBS_STATE" in working|parked|done|blocked|paused|failed|unknown) ;; *) lane_error "reservation state for $task has an invalid state"; return 1 ;; esac
  case "$CREW_OBS_SOURCE" in run-step|pane|status-log|none) ;; *) lane_error "reservation state for $task has an invalid source"; return 1 ;; esac
  case "$CREW_OBS_KIND" in full|coarse|absent|unavailable) ;; *) lane_error "reservation state for $task has an invalid run kind"; return 1 ;; esac
  if [ "$CREW_OBS_KIND" = full ]; then
    [ -n "$run_id" ] || { lane_error "reservation state for $task is missing its run id"; return 1; }
    CREW_OBS_RUN=$(hash_run_id "$run_id") || { lane_error "cannot bind reservation run for $task"; return 1; }
    [[ "$CREW_OBS_RUN" =~ ^[0-9a-f]{64}$ ]] || { lane_error "cannot bind reservation run for $task"; return 1; }
  else
    [ -z "$run_id" ] || { lane_error "reservation state for $task has an unexpected run id"; return 1; }
  fi
  if [ -n "$run_start" ]; then
    [[ "$run_start" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}#[1-9][0-9]*$ ]] \
      || { lane_error "reservation state for $task has invalid run-start evidence"; return 1; }
    CREW_OBS_START=$(hash_run_id "$run_start") || { lane_error "cannot bind reservation start for $task"; return 1; }
    [[ "$CREW_OBS_START" =~ ^[0-9a-f]{64}$ ]] || { lane_error "cannot bind reservation start for $task"; return 1; }
  fi
}

crew_observation_is_unavailable_empty() {
  [ "$CREW_OBS_KIND" = unavailable ] && [ "$CREW_OBS_START" = none ]
}

capture_reservation() {  # <task-id>
  read_crew_observation "$1" || return 1
  if crew_observation_is_unavailable_empty; then
    lane_error "cannot reserve validation slot for $1 without comparable run evidence"
    return 1
  fi
  LANE_RESERVATION_KIND=$CREW_OBS_KIND
  LANE_RESERVATION_RUN=$CREW_OBS_RUN
  LANE_RESERVATION_START=$CREW_OBS_START
  case "$CREW_OBS_SOURCE:$CREW_OBS_STATE" in
    run-step:done|run-step:failed) LANE_RESERVATION_STATE=terminal ;;
    run-step:*) LANE_RESERVATION_STATE=active ;;
    *) LANE_RESERVATION_STATE=other ;;
  esac
  LANE_RESERVATION_STARTED=0
}

deliver_release() {
  local task=$1 out rc
  [ -n "$task" ] || return 0
  lane_lock || return 1
  if ! read_lane; then lane_unlock; return 1; fi
  if [ "$LANE_RELEASE" != "$task" ]; then
    lane_unlock
    return 0
  fi
  if out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SEND_BIN" "$task" \
    'Validation slot reserved. Start the no-mistakes validation pipeline now and follow its active gates.' 2>&1); then
    LANE_RELEASE=
    LANE_HOLDER=$task
    if ! write_lane || ! refresh_check; then
      lane_unlock
      return 1
    fi
    lane_unlock
    printf 'released %s\n' "$task"
    return 0
  else
    rc=$?
  fi
  lane_unlock
  out=$(printf '%s' "$out" | tr '\r\n' ' ' | cut -c1-500)
  [ -n "$out" ] || out="fm-send exited $rc"
  printf 'release failed for %s: %s\n' "$task" "$out"
  return 0
}

enqueue() {  # <task-id>
  local task=$1 release='' reserve_ok=1
  fm_pr_task_id_valid "$task" || { lane_error "invalid task id"; return 2; }
  lane_lock || return 1
  if ! read_lane; then lane_unlock; return 1; fi
  if lane_id_seen "$task"; then
    release=$LANE_RELEASE
    if ! refresh_check; then lane_unlock; return 1; fi
    lane_unlock
    if [ -n "$release" ]; then
      deliver_release "$release"
    else
      printf 'already queued %s\n' "$task"
    fi
    return 0
  fi
  LANE_QUEUE+=("$task")
  reserve_next || reserve_ok=0
  release=$LANE_RELEASE
  if ! write_lane || ! refresh_check; then lane_unlock; return 1; fi
  lane_unlock
  [ "$reserve_ok" -eq 1 ] || return 1
  if [ -n "$release" ]; then
    deliver_release "$release"
  else
    printf 'queued %s\n' "$task"
  fi
}

holder_terminal() {
  local task=$1 identity_started=0
  read_crew_observation "$task" || return 2
  crew_observation_is_unavailable_empty && return 1
  if [ "$LANE_RESERVATION_KIND" = absent ]; then
    case "$CREW_OBS_KIND" in full|coarse) identity_started=1 ;; esac
  elif [ "$LANE_RESERVATION_KIND" = full ] && [ "$CREW_OBS_KIND" = full ] \
    && [ "$CREW_OBS_RUN" != "$LANE_RESERVATION_RUN" ]; then
    identity_started=1
  fi
  if [ "$CREW_OBS_START" != none ] && [ "$CREW_OBS_START" != "$LANE_RESERVATION_START" ]; then
    identity_started=1
  fi
  if [ "$identity_started" -eq 1 ]; then
    LANE_RESERVATION_STARTED=1
  fi
  [ "$LANE_RESERVATION_STARTED" = 1 ] \
    && [ "$CREW_OBS_SOURCE" = run-step ] \
    && { [ "$CREW_OBS_STATE" = "done" ] || [ "$CREW_OBS_STATE" = "failed" ]; }
}

check() {
  local release='' reserve_ok=1 terminal_rc
  lane_lock || return 1
  if ! read_lane; then lane_unlock; return 1; fi
  if [ -n "$LANE_HOLDER" ]; then
    holder_terminal "$LANE_HOLDER"
    terminal_rc=$?
    if [ "$terminal_rc" -eq 0 ]; then
      LANE_HOLDER=
      clear_reservation
    elif [ "$terminal_rc" -eq 2 ]; then
      lane_unlock
      return 1
    fi
  fi
  reserve_next || reserve_ok=0
  release=$LANE_RELEASE
  if ! write_lane || ! refresh_check; then lane_unlock; return 1; fi
  lane_unlock
  [ "$reserve_ok" -eq 1 ] || return 1
  [ -z "$release" ] || deliver_release "$release"
}

show() {
  lane_lock || return 1
  if ! read_lane; then lane_unlock; return 1; fi
  printf 'holder=%s\nrelease=%s\n' "${LANE_HOLDER:--}" "${LANE_RELEASE:--}"
  printf 'queued=%s\n' "${LANE_QUEUE[@]:--}"
  lane_unlock
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

fm_refuse_if_gate_agent
require_state || exit 1
case "${1:-}" in
  enqueue) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; enqueue "$2" ;;
  check) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; check ;;
  show) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; show ;;
  *) usage >&2; exit 2 ;;
esac
