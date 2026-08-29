#!/usr/bin/env bash
# Reconcile Agent Fleet's real SessionStart mapping into Firstmate task meta.
# Usage: fm-account-session-sync.sh <task-id> [--wait <seconds>] [--require] [--event-seq] [--after-event-seq <integer>]
#        fm-account-session-sync.sh --all
#
# Only managed tasks (meta with account_profile=) are touched.
# The command consumes `agent-fleet --format json session status --task` and
# validates attempt/task/profile/provider/pool stickiness before atomically
# recording the real provider_session_id= in meta.
# An early SessionStart race is normal: without --require, no mapping returns
# quietly non-zero so spawn or the watcher can retry later.
# --require turns the missing mapping into a fail-closed recovery blocker.
# --all scans a rotating bounded batch of managed metas that still lack provider_session_id.
# --all bounds each worker with FM_ACCOUNT_SESSION_TASK_TIMEOUT (the query timeout plus two seconds by default).
set -u

SCRIPT_SOURCE_DIR=${BASH_SOURCE[0]%/*}
[ "$SCRIPT_SOURCE_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_SOURCE_DIR=.
SCRIPT_DIR="$(cd "$SCRIPT_SOURCE_DIR" && pwd -P)"
unset SCRIPT_SOURCE_DIR
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
for required_system_tool in \
  "$FM_ACCOUNT_SYSTEM_SED_BIN" "$FM_ACCOUNT_SYSTEM_DATE_BIN" \
  "$FM_ACCOUNT_SYSTEM_RM_BIN" "$FM_ACCOUNT_SYSTEM_MV_BIN" \
  "$FM_ACCOUNT_SYSTEM_CP_BIN" "$FM_ACCOUNT_SYSTEM_MKTEMP_BIN" \
  "$FM_ACCOUNT_SYSTEM_SLEEP_BIN" "$FM_ACCOUNT_SYSTEM_ENV_BIN" \
  "$FM_ACCOUNT_SYSTEM_BASENAME_BIN"; do
  [ -x "$required_system_tool" ] || {
    echo "error: fixed system tools are required for account session synchronization" >&2
    exit 1
  }
done
unset required_system_tool

WAIT=0
QUERY_TIMEOUT=${FM_ACCOUNT_SESSION_QUERY_TIMEOUT:-5}
ALL_TASK_TIMEOUT=${FM_ACCOUNT_SESSION_TASK_TIMEOUT:-}
ALL_MAX_PARALLEL=${FM_ACCOUNT_SESSION_MAX_PARALLEL:-4}
REQUIRE=0
ALL=0
PRINT_EVENT_SEQ=0
AFTER_EVENT_SEQ=
ID=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) ALL=1; shift ;;
    --require) REQUIRE=1; shift ;;
    --event-seq) PRINT_EVENT_SEQ=1; shift ;;
    --after-event-seq)
      [ "$#" -gt 1 ] || { echo "error: --after-event-seq requires an integer" >&2; exit 2; }
      AFTER_EVENT_SEQ=$2
      shift 2
      ;;
    --after-event-seq=*) AFTER_EVENT_SEQ=${1#--after-event-seq=}; shift ;;
    --updated-at|--after-updated-at|--after-updated-at=*)
      echo "error: timestamp freshness options are unsupported; use the monotonic session event sequence" >&2
      exit 2
      ;;
    --wait)
      [ "$#" -gt 1 ] || { echo "error: --wait requires seconds" >&2; exit 2; }
      WAIT=$2
      shift 2
      ;;
    --wait=*) WAIT=${1#--wait=}; shift ;;
    -h|--help) fm_account_system_exec "$FM_ACCOUNT_SYSTEM_SED_BIN" -n '2,13p' "$0" | fm_account_system_exec "$FM_ACCOUNT_SYSTEM_SED_BIN" 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown option $1" >&2; exit 2 ;;
    *) [ -z "$ID" ] || { echo "error: expected one task id" >&2; exit 2; }; ID=$1; shift ;;
  esac
done
case "$WAIT" in ''|*[!0-9]*) echo "error: --wait must be a non-negative integer" >&2; exit 2 ;; esac
session_event_seq_valid() {  # <value> <allow-zero>
  local value=$1 allow_zero=$2
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  case "$value" in
    0) [ "$allow_zero" = 1 ]; return ;;
    0*) return 1 ;;
  esac
  [ "${#value}" -lt 19 ] && return 0
  [ "${#value}" -eq 19 ] || return 1
  # shellcheck disable=SC2071  # Deliberate lexical comparison avoids signed-64 overflow.
  [[ "$value" < 9223372036854775807 || "$value" == 9223372036854775807 ]]
}
if [ -n "$AFTER_EVENT_SEQ" ] && ! session_event_seq_valid "$AFTER_EVENT_SEQ" 1; then
  echo "error: --after-event-seq must be a non-negative signed 64-bit integer" >&2
  exit 2
fi
case "$QUERY_TIMEOUT" in ''|*[!0-9]*|0) echo "error: FM_ACCOUNT_SESSION_QUERY_TIMEOUT must be a positive integer" >&2; exit 2 ;; esac
if [ -z "$ALL_TASK_TIMEOUT" ]; then
  ALL_TASK_TIMEOUT=$((QUERY_TIMEOUT + 2))
fi
case "$ALL_TASK_TIMEOUT" in ''|*[!0-9]*|0) echo "error: FM_ACCOUNT_SESSION_TASK_TIMEOUT must be a positive integer" >&2; exit 2 ;; esac
case "$ALL_MAX_PARALLEL" in ''|*[!0-9]*|0) echo "error: FM_ACCOUNT_SESSION_MAX_PARALLEL must be a positive integer" >&2; exit 2 ;; esac
if [ "$ALL" = 1 ]; then
  [ -z "$ID" ] || { echo "error: --all does not accept a task id" >&2; exit 2; }
  ALL_LOCK=$(FM_ACCOUNT_META_LOCK_WAIT_SECONDS=0 fm_account_meta_lock_acquire "$STATE" session-sync-all 2>/dev/null) || exit 0
  ALL_CURSOR="$STATE/.account-session-sync.cursor"
  ALL_CURSOR_TMP=
  ALL_PIDS=()
  ALL_REAP_COUNT=0
  # shellcheck disable=SC2329
  cleanup_all() {
    local pid
    for pid in "${ALL_PIDS[@]}"; do
      kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in "${ALL_PIDS[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
    [ -z "$ALL_CURSOR_TMP" ] || fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$ALL_CURSOR_TMP"
    fm_account_meta_lock_release "$ALL_LOCK" >/dev/null 2>&1 || true
  }
  trap cleanup_all EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  launch_group_bounded() {
    [ -n "$FM_ACCOUNT_SYSTEM_PERL_BIN" ] || return 127
    # shellcheck disable=SC2016
    fm_account_system_perl -e '
      use strict;
      use warnings;
      my $seconds = shift @ARGV;
      my $pid = fork();
      die "fork failed" unless defined $pid;
      if (!$pid) {
        setpgrp(0, 0);
        exec @ARGV;
        exit 127;
      }
      my $finish = sub {
        my ($signal, $status) = @_;
        kill $signal, -$pid;
        select undef, undef, undef, 0.2;
        kill "KILL", -$pid;
        waitpid($pid, 0);
        exit $status;
      };
      local $SIG{HUP} = sub { $finish->("HUP", 129) };
      local $SIG{INT} = sub { $finish->("INT", 130) };
      local $SIG{TERM} = sub { $finish->("TERM", 143) };
      local $SIG{ALRM} = sub { $finish->("TERM", 124) };
      alarm $seconds;
      waitpid($pid, 0);
      my $status = $?;
      alarm 0;
      kill "TERM", -$pid;
      select undef, undef, undef, 0.2;
      kill "KILL", -$pid;
      exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
    ' "$@" </dev/null >/dev/null 2>&1 &
    ALL_PIDS+=("$!")
    [ -z "${FM_ACCOUNT_SESSION_WORKER_TEST_LOG:-}" ] \
      || printf '%s\n' "$!" >> "$FM_ACCOUNT_SESSION_WORKER_TEST_LOG"
  }
  reap_all_worker() {
    local target=$1 wait_status=0 index
    wait "$target" || wait_status=$?
    for index in "${!ALL_PIDS[@]}"; do
      if [ "${ALL_PIDS[$index]}" = "$target" ]; then
        unset 'ALL_PIDS[index]'
        break
      fi
    done
    ALL_PIDS=("${ALL_PIDS[@]}")
    ALL_REAP_COUNT=$((ALL_REAP_COUNT + 1))
    if [ "$ALL_REAP_COUNT" -eq 1 ] && [ -n "${FM_ACCOUNT_SESSION_REAP_TEST_READY:-}" ] \
      && [ -n "${FM_ACCOUNT_SESSION_REAP_TEST_PROCEED:-}" ]; then
      printf '%s\n' "${ALL_PIDS[@]}" > "$FM_ACCOUNT_SESSION_REAP_TEST_READY"
      while [ ! -e "$FM_ACCOUNT_SESSION_REAP_TEST_PROCEED" ]; do fm_account_system_exec "$FM_ACCOUNT_SYSTEM_SLEEP_BIN" 0.01; done
    fi
    return "$wait_status"
  }
  tasks=()
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ -n "$(fm_meta_get "$meta" account_profile)" ] || continue
    [ -z "$(fm_meta_get "$meta" provider_session_id)" ] || continue
    task=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_BASENAME_BIN" "$meta" .meta)
    fm_account_valid_id "$task" || continue
    tasks+=("$task")
  done
  [ "${#tasks[@]}" -gt 0 ] || exit 0
  cursor=
  if fm_account_safe_file_destination "$ALL_CURSOR" && [ -f "$ALL_CURSOR" ]; then
    cursor=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_SED_BIN" -n '1p' "$ALL_CURSOR" 2>/dev/null || true)
    fm_account_valid_id "$cursor" || cursor=
  elif [ -e "$ALL_CURSOR" ] || [ -L "$ALL_CURSOR" ]; then
    echo "error: unsafe account session synchronization cursor at $ALL_CURSOR" >&2
    exit 1
  fi
  start=0
  if [ -n "$cursor" ]; then
    for index in "${!tasks[@]}"; do
      if [[ "${tasks[$index]}" > "$cursor" ]]; then
        start=$index
        break
      fi
    done
  fi
  count=${#tasks[@]}
  batch=$ALL_MAX_PARALLEL
  [ "$batch" -le "$count" ] || batch=$count
  launched=()
  for ((offset = 0; offset < batch; offset += 1)); do
    index=$(((start + offset) % count))
    task=${tasks[$index]}
    launched+=("$task")
    launch_group_bounded "$ALL_TASK_TIMEOUT" "$FM_ACCOUNT_SYSTEM_ENV_BIN" FM_ACCOUNT_BOUND_INHERIT_GROUP=1 "$0" "$task"
  done
  ALL_CURSOR_TMP=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MKTEMP_BIN" "$STATE/.account-session-sync.cursor.XXXXXX") || exit 1
  printf '%s\n' "${launched[$((batch - 1))]}" > "$ALL_CURSOR_TMP" || exit 1
  fm_account_safe_file_destination "$ALL_CURSOR" || { echo "error: unsafe account session synchronization cursor at $ALL_CURSOR" >&2; exit 1; }
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MV_BIN" "$ALL_CURSOR_TMP" "$ALL_CURSOR" || exit 1
  ALL_CURSOR_TMP=
  rc=0
  while [ "${#ALL_PIDS[@]}" -gt 0 ]; do
    pid=${ALL_PIDS[0]}
    reap_all_worker "$pid" || rc=1
  done
  exit "$rc"
fi
[ -n "$ID" ] || { echo "usage: fm-account-session-sync.sh <task-id> [--wait <seconds>] [--require] [--event-seq] [--after-event-seq <integer>]" >&2; exit 2; }
META="$STATE/$ID.meta"
LIFECYCLE_LOCK=
LIFECYCLE_LOCK_OWNED=0
LIFECYCLE_LOCK_INHERITED_PID=
LIFECYCLE_LOCK_INHERITED_START=
META_LOCK=
META_TMP=
META_ROLLBACK_TMP=
if [ -n "${FM_ACCOUNT_LIFECYCLE_LOCK_HELD:-}" ]; then
  expected_lifecycle_lock="$STATE/.account-lifecycle-$ID.lock"
  inherited_lock_identity=
  if [ "$FM_ACCOUNT_LIFECYCLE_LOCK_HELD" = "$expected_lifecycle_lock" ]; then
    inherited_lock_identity=$(fm_account_lifecycle_lock_identity "$FM_ACCOUNT_LIFECYCLE_LOCK_HELD" 2>/dev/null) || inherited_lock_identity=
  fi
  case "$inherited_lock_identity" in
    *$'\n'*)
      LIFECYCLE_LOCK_INHERITED_PID=${inherited_lock_identity%%$'\n'*}
      LIFECYCLE_LOCK_INHERITED_START=${inherited_lock_identity#*$'\n'}
      ;;
    *)
      echo "error: invalid inherited account lifecycle lock for $ID" >&2
      exit 1
      ;;
  esac
  if [ -z "$LIFECYCLE_LOCK_INHERITED_PID" ] || [ -z "$LIFECYCLE_LOCK_INHERITED_START" ]; then
    echo "error: invalid inherited account lifecycle lock for $ID" >&2
    exit 1
  fi
  LIFECYCLE_LOCK=$FM_ACCOUNT_LIFECYCLE_LOCK_HELD
else
  LIFECYCLE_LOCK=$(fm_account_lifecycle_lock_acquire "$STATE" "$ID") || exit 1
  LIFECYCLE_LOCK_OWNED=1
fi
release_locks() {
  [ -z "$META_TMP" ] || fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$META_TMP"
  [ -z "$META_ROLLBACK_TMP" ] || fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$META_ROLLBACK_TMP"
  [ -z "$META_LOCK" ] || fm_account_meta_lock_release "$META_LOCK" >/dev/null 2>&1 || true
  [ "$LIFECYCLE_LOCK_OWNED" != 1 ] || fm_account_lifecycle_lock_release "$LIFECYCLE_LOCK" >/dev/null 2>&1 || true
}
trap release_locks EXIT
META_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
fm_account_safe_file_destination "$META" || { echo "error: unsafe meta for task $ID at $META" >&2; exit 1; }
PROFILE=$(fm_meta_get "$META" account_profile)
[ -n "$PROFILE" ] || { fm_account_meta_lock_release "$META_LOCK" || exit 1; exit 0; }
POOL=$(fm_meta_get "$META" account_pool)
HARNESS=$(fm_meta_get "$META" harness)
ACCOUNT_TASK=$(fm_meta_get "$META" account_task)
ATTEMPT=$(fm_meta_get "$META" account_attempt)
WORKSPACE=$(fm_meta_get "$META" worktree)
[ -n "$ACCOUNT_TASK" ] || ACCOUNT_TASK=$ID
[ -n "$ATTEMPT" ] || ATTEMPT=legacy
[ -n "$WORKSPACE" ] || { echo "error: managed task $ID has no worktree for provider-session validation" >&2; exit 1; }
EXISTING=$(fm_meta_get "$META" provider_session_id)
fm_account_meta_lock_release "$META_LOCK" || exit 1
fm_account_pin_fleet_bin || exit 1
binary=$FM_ACCOUNT_FLEET_PINNED_BIN
fm_account_validate_contract "$binary" || exit 1

deadline=$(( $(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DATE_BIN" +%s) + WAIT ))
while :; do
  if json=$(fm_account_run_fleet_bounded "$QUERY_TIMEOUT" "$binary" --format json session status --task "$ACCOUNT_TASK" 2>/dev/null); then
    session_schema=$(fm_account_json_field "$json" '.schema | select(type == "number" and floor == . and (. == 1 or . == 2))' session) || exit 1
    mapped_task=$(fm_account_json_field "$json" '.task | select(type == "string")' session) || exit 1
    mapped_profile=$(fm_account_json_field "$json" '.profile | select(type == "string")' session) || exit 1
    mapped_provider=$(fm_account_json_field "$json" '.provider | select(type == "string")' session) || exit 1
    mapped_pool=$(fm_account_json_field "$json" '.pool | select(type == "string")' session) || exit 1
    mapped_workspace=$(fm_account_json_field "$json" '.workspace | select(type == "string" and length > 0)' session) \
      || { echo "error: Agent Fleet session mapping has no valid workspace for $ID" >&2; exit 1; }
    session_id=$(fm_account_json_field "$json" '.session_id | select(type == "string" and length > 0)' session) || exit 1
    session_event_seq=$(fm_account_json_field "$json" '.session_event_seq | select(type == "number" and floor == . and . >= 0 and . <= 9223372036854775807)' session) || exit 1
    [ "$mapped_task" = "$ACCOUNT_TASK" ] || { echo "error: Agent Fleet session task mismatch for $ID attempt $ATTEMPT" >&2; exit 1; }
    [ "$mapped_profile" = "$PROFILE" ] || { echo "error: Agent Fleet session profile mismatch for $ID" >&2; exit 1; }
    [ "$mapped_pool" = "$POOL" ] || { echo "error: Agent Fleet session pool mismatch for $ID" >&2; exit 1; }
    [ "$mapped_provider" = "$HARNESS" ] || { echo "error: Agent Fleet session provider mismatch for $ID" >&2; exit 1; }
    [ "$mapped_workspace" = "$WORKSPACE" ] || { echo "error: Agent Fleet session workspace mismatch for $ID" >&2; exit 1; }
    case "$session_id" in ''|*$'\n'*|*=*) echo "error: unsafe provider session id for $ID" >&2; exit 1 ;; esac
    session_event_seq_valid "$session_event_seq" 1 \
      || { echo "error: unsafe provider session event sequence for $ID" >&2; exit 1; }
    if { [ "$session_schema" = 1 ] && [ "$session_event_seq" != 0 ]; } \
      || { [ "$session_schema" = 2 ] && [ "$session_event_seq" = 0 ]; }; then
      echo "error: Agent Fleet session event sequence does not match mapping schema for $ID" >&2
      exit 1
    fi
    if [ -z "$AFTER_EVENT_SEQ" ]; then
      break
    fi
    if [ "$session_event_seq" -gt "$AFTER_EVENT_SEQ" ]; then
      break
    fi
  fi
  [ "$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_DATE_BIN" +%s)" -lt "$deadline" ] || {
    if [ "$REQUIRE" = 1 ]; then
      if [ -n "$AFTER_EVENT_SEQ" ]; then
        echo "error: no fresh Agent Fleet SessionStart update for managed task $ID attempt $ATTEMPT; refusing recovery" >&2
      else
        echo "error: no Agent Fleet provider-session mapping for managed task $ID attempt $ATTEMPT; refusing recovery" >&2
      fi
    fi
    exit 1
  }
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_SLEEP_BIN" 1
done
META_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
if [ "$LIFECYCLE_LOCK_OWNED" != 1 ]; then
  current_lock_identity=$(fm_account_lifecycle_lock_identity "$LIFECYCLE_LOCK" 2>/dev/null || true)
  case "$current_lock_identity" in
    *$'\n'*)
      current_lock_pid=${current_lock_identity%%$'\n'*}
      current_lock_start=${current_lock_identity#*$'\n'}
      ;;
    *) current_lock_pid=; current_lock_start= ;;
  esac
  if [ "${FM_ACCOUNT_LIFECYCLE_LOCK_HELD:-}" != "$LIFECYCLE_LOCK" ] \
    || [ "$current_lock_pid" != "$LIFECYCLE_LOCK_INHERITED_PID" ] \
    || [ "$current_lock_start" != "$LIFECYCLE_LOCK_INHERITED_START" ]; then
    fm_account_meta_lock_release "$META_LOCK" >/dev/null 2>&1 || true
    META_LOCK=
    echo "error: managed lifecycle lock was lost before session synchronization for $ID" >&2
    exit 1
  fi
fi
current_account_task=$(fm_meta_get "$META" account_task)
current_attempt=$(fm_meta_get "$META" account_attempt)
[ -n "$current_account_task" ] || current_account_task=$ID
[ -n "$current_attempt" ] || current_attempt=legacy
if [ ! -f "$META" ] \
  || [ "$current_account_task" != "$ACCOUNT_TASK" ] \
  || [ "$current_attempt" != "$ATTEMPT" ] \
  || [ "$(fm_meta_get "$META" account_profile)" != "$PROFILE" ] \
  || [ "$(fm_meta_get "$META" account_pool)" != "$POOL" ] \
  || [ "$(fm_meta_get "$META" harness)" != "$HARNESS" ] \
  || [ "$(fm_meta_get "$META" worktree)" != "$WORKSPACE" ]; then
  fm_account_meta_lock_release "$META_LOCK" >/dev/null 2>&1 || true
  echo "error: managed task generation changed before session synchronization for $ID" >&2
  exit 1
fi
EXISTING=$(fm_meta_get "$META" provider_session_id)
if [ -n "$EXISTING" ] && [ "$EXISTING" != "$session_id" ]; then
  fm_account_meta_lock_release "$META_LOCK" >/dev/null 2>&1 || true
  echo "error: provider session id changed for managed task $ID; refusing to overwrite recovery truth" >&2
  exit 1
fi
if [ -z "$EXISTING" ]; then
  META_TMP=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MKTEMP_BIN" "$STATE/.$ID.meta.sync.XXXXXX") || exit 1
  META_ROLLBACK_TMP=$(fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MKTEMP_BIN" "$STATE/.$ID.meta.sync-rollback.XXXXXX") || exit 1
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_AWK_BIN" '!/^provider_session_id=/' "$META" > "$META_ROLLBACK_TMP" || exit 1
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_CP_BIN" -p "$META_ROLLBACK_TMP" "$META_TMP" || exit 1
  printf 'provider_session_id=%s\n' "$session_id" >> "$META_TMP" || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$META_TMP"; exit 1; }
  fm_account_safe_file_destination "$META" || { echo "error: unsafe meta for task $ID at $META" >&2; exit 1; }
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MV_BIN" "$META_TMP" "$META" || { fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$META_TMP"; exit 1; }
  META_TMP=
  if ! fm_account_lineage_append "$DATA" "$ID" session-bound "$ATTEMPT" "$ACCOUNT_TASK" "$HARNESS" "$POOL" "$PROFILE" "$session_id" "$(fm_meta_get "$META" account_predecessor_task)"; then
    if fm_account_safe_file_destination "$META" && fm_account_system_exec "$FM_ACCOUNT_SYSTEM_MV_BIN" "$META_ROLLBACK_TMP" "$META"; then
      META_ROLLBACK_TMP=
    else
      echo "error: session lineage failed and prior metadata could not be restored for $ID" >&2
      exit 1
    fi
    echo "error: session lineage publication failed; restored unbound metadata for $ID" >&2
    exit 1
  fi
  fm_account_system_exec "$FM_ACCOUNT_SYSTEM_RM_BIN" -f "$META_ROLLBACK_TMP"
  META_ROLLBACK_TMP=
fi
fm_account_meta_lock_release "$META_LOCK" || exit 1
if [ "$PRINT_EVENT_SEQ" = 1 ]; then
  printf '%s\n' "$session_event_seq"
else
  printf '%s\n' "$session_id"
fi
