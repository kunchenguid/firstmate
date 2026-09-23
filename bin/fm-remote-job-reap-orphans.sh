#!/usr/bin/env bash
# Reap remote job workers whose code root no longer exists.
#
# Usage: fm-remote-job-reap-orphans.sh [--dry-run]
#   --dry-run reports what would be reaped and signals nothing.
#
# A remote job worker (bin/fm-remote-job-worker.sh) is launched from a specific
# Firstmate code root: the account's own checkout under the LaunchAgent, a
# remote secondmate's checkout, a no-mistakes gate worktree, a pooled task
# worktree, or a test fixture root. When that root is pruned while the worker is
# running, the worker is reparented to init and, on older builds, keeps polling
# and logging indefinitely. Current workers stop themselves once their root is
# gone (bin/fm-remote-job-worker.sh); this sweep is the belt-and-suspenders pass
# that clears workers already orphaned that way, including ones started before
# self-termination shipped.
#
# There are two reap conditions, and a candidate needs only one.
#
# The first is fm_remote_job_root_is_live failing for the root named in the
# worker's own command line. A worker whose root is gone can never claim,
# validate, or execute another job, and no healthy worker can present a missing
# root. The account's healthy LaunchAgent worker, a live remote secondmate's
# worker, and any worker whose checkout still exists are therefore never
# candidates under it, with no dependence on log paths, process age, or which
# home is sweeping.
#
# The second requires a --lane invocation naming its own absolute queue, a
# running record there past deadline + FM_REMOTE_JOB_LANE_GRACE_SECONDS, and
# a claim supervisor PID/start identity matching the lane. Missing or completed
# records do not qualify: publication may have been reaped before the lane exits.
# A legacy lane without an explicit queue is not eligible under this condition.
# The recorded execution group must have a determinate start identity and must
# differ from both the lane's shared worker group and the sweep's own group.
#
# Pruned roots use fm_remote_job_stop_worker_tree to stop the whole worker tree.
# Overdue lanes use fm_remote_job_stop_recorded_execution to stop only the
# identified lane supervisor and its recorded command execution, preserving
# sibling lanes and the serving worker in their shared group. Reports name
# either "pruned code root" or "abandoned lane" to distinguish those actions.
# tests/fm-remote-job-orphan-reap.test.sh covers queue binding, completion windows,
# identity checks, and shared-group sibling survival.
#
# Only this user's processes are inspected, and this process, its own process
# group, and any ancestor are never signalled.
#
# Prints one line per reaped or surviving candidate and nothing when there is
# nothing to do. Exits 0 unless the process scan itself could not run, so a
# caller can sweep without risking its own outcome.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# shellcheck source=bin/fm-remote-job-lib.sh
. "$SCRIPT_DIR/fm-remote-job-lib.sh"

DRY_RUN=0
REAP_SUFFIX=/bin/fm-remote-job-worker.sh
REAP_WORKER_ROOT=
REAP_LANE_JOB=
REAP_LANE_QUEUE=
REAP_JOB=

reap_die() { printf 'fm-remote-job-reap-orphans: %s\n' "$1" >&2; exit 2; }

reap_usage() {
  cat <<'TXT'
Usage: fm-remote-job-reap-orphans.sh [--dry-run]

Stop every remote job worker whose Firstmate code root has been pruned, and
every lane worker past its deadline in its explicitly named queue. A
healthy worker - the account's LaunchAgent worker, a live remote secondmate's
worker, a lane inside its deadline - is never a candidate. --dry-run reports
the candidates and signals nothing. Read this script's header for the full
rule.
TXT
}

reap_read_worker() { # <command>
  local command=$1 path prefix leading tail
  REAP_WORKER_ROOT=
  REAP_LANE_JOB=
  REAP_LANE_QUEUE=
  case "$command" in
    *"$REAP_SUFFIX --serve") path=${command%" --serve"} ;;
    *"$REAP_SUFFIX") path=$command ;;
    *"$REAP_SUFFIX --lane "*)
      tail=${command##*"$REAP_SUFFIX --lane "}
      path=${command%" --lane $tail"}
      REAP_LANE_JOB=${tail%% *}
      fm_remote_job_safe_id "$REAP_LANE_JOB" || return 1
      if [ "$tail" != "$REAP_LANE_JOB" ]; then
        REAP_LANE_QUEUE=${tail#* }
        case "$REAP_LANE_QUEUE" in /*) ;; *) return 1 ;; esac
      fi
      ;;
    *) return 1 ;;
  esac
  prefix=${path%"$REAP_SUFFIX"}
  case "$prefix" in /*) ;; *) return 1 ;; esac
  leading=${prefix%% *}
  # Drop the leading token only when it really is the interpreter binary, so a
  # code root that itself contains a space is read whole rather than split.
  if [ "$leading" != "$prefix" ] && [ -f "$leading" ] && [ -x "$leading" ]; then
    prefix=${prefix#"$leading" }
  fi
  case "$prefix" in /*) ;; *) return 1 ;; esac
  REAP_WORKER_ROOT=$prefix
}

reap_lane_abandoned() {
  local id=$1 queue=$2 pid=$3 job deadline now canonical group lane_pgid own_pgid identity
  REAP_JOB=
  [ -n "$queue" ] || return 1
  canonical=$(fm_remote_job_canonical_existing_dir "$queue/jobs" 2>/dev/null) || return 1
  [ "$canonical" = "$queue/jobs" ] || return 1
  local FM_REMOTE_JOB_JOBS=$canonical
  job=$(fm_remote_job_job_dir "$id" 2>/dev/null) || return 1
  [ "$(fm_remote_job_read_state "$job" 2>/dev/null)" = running ] || return 1
  deadline=$(fm_remote_job_read_number "$job" deadline 2>/dev/null || true)
  case "$deadline" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ "$now" -ge $((deadline + FM_REMOTE_JOB_LANE_GRACE_SECONDS)) ] || return 1
  [ -d "$job/.claim" ] && [ ! -L "$job/.claim" ] || return 1
  [ "$(fm_remote_job_read_process_id "$job/.claim/supervisor" 2>/dev/null)" = "$pid" ] || return 1
  fm_remote_job_supervisor_identity_status "$job" "$pid" || return 1
  if [ -e "$job/.claim/group" ] || [ -L "$job/.claim/group" ]; then
    group=$(fm_remote_job_read_process_id "$job/.claim/group" 2>/dev/null) || return 1
    lane_pgid=$(fm_remote_job_process_pgid "$pid") || return 1
    own_pgid=$(fm_remote_job_process_pgid "$$") || return 1
    [ "$group" != "$lane_pgid" ] && [ "$group" != "$own_pgid" ] || return 1
    fm_remote_job_group_identity_status "$job" "$group"
    identity=$?
    case "$identity" in 0|1) ;; *) return 1 ;; esac
  fi
  REAP_JOB=$job
}

reap_is_self_or_ancestor() { # <pid>
  local pid=$1 walk=$$ i=0
  while [ "$walk" -gt 1 ] && [ "$i" -lt 64 ]; do
    [ "$walk" != "$pid" ] || return 0
    walk=$(ps -p "$walk" -o ppid= 2>/dev/null | tr -d '[:space:]') || return 0
    case "$walk" in ''|*[!0-9]*) return 1 ;; esac
    i=$((i + 1))
  done
  return 1
}

reap_orphans() {
  local uid scan pid command live root own_pgid pgid lane reason stop_command stop_arg
  uid=$(id -u 2>/dev/null || true)
  case "$uid" in ''|*[!0-9]*) reap_die "cannot resolve the current uid" ;; esac
  scan=$(ps -u "$uid" -o pid=,command= 2>/dev/null) ||
    reap_die "cannot scan this account's processes for remote job workers"
  own_pgid=$(fm_remote_job_process_pgid "$$" 2>/dev/null || true)
  # ps pads the pid column to the widest pid on the host, so the fields are read
  # with default word splitting rather than by fixed offsets or a single space.
  while read -r pid command; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ -n "$command" ] || continue
    reap_read_worker "$command" || continue
    root=$REAP_WORKER_ROOT
    lane=$REAP_LANE_JOB
    if ! fm_remote_job_root_is_live "$root"; then
      reason="pruned code root $root"
      stop_command=fm_remote_job_stop_worker_tree
      stop_arg=$pid
    elif [ -n "$lane" ] && reap_lane_abandoned "$lane" "$REAP_LANE_QUEUE" "$pid"; then
      reason="abandoned lane for $lane"
      stop_command=fm_remote_job_stop_recorded_execution
      stop_arg=$REAP_JOB
    else
      continue
    fi
    [ "$pid" != "$$" ] || continue
    reap_is_self_or_ancestor "$pid" && continue
    if [ -n "$own_pgid" ]; then
      pgid=$(fm_remote_job_process_pgid "$pid" 2>/dev/null || true)
      [ "$pgid" != "$own_pgid" ] || continue
    fi
    # Re-read the command from the live process so a recycled pid cannot be
    # signalled on the strength of a stale scan line.
    live=$(fm_remote_job_process_command "$pid" 2>/dev/null || true)
    read -r live <<< "$live"
    [ "$live" = "$command" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would reap abandoned remote job worker %s (%s)\n' "$pid" "$reason"
      continue
    fi
    if "$stop_command" "$stop_arg"; then
      printf 'reaped abandoned remote job worker %s (%s)\n' "$pid" "$reason"
    else
      printf 'warning: abandoned remote job worker %s survived reaping (%s)\n' "$pid" "$reason" >&2
    fi
  done <<EOF
$scan
EOF
}

case "${1:-}" in
  '') ;;
  --dry-run) DRY_RUN=1; [ "$#" -eq 1 ] || reap_die "unexpected arguments" ;;
  -h|--help) reap_usage; exit 0 ;;
  *) reap_die "unexpected argument: $1" ;;
esac

reap_orphans
