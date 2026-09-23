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
# The second covers what the first structurally could not: a --lane worker whose
# own job record is gone, or past its recorded deadline by
# FM_REMOTE_JOB_LANE_GRACE_SECONDS. A lane wedged that way keeps a live code
# root, so the root test never saw it, yet it holds its home's queue shut and
# every later caller then holds an SSH session open until that caller's own
# deadline. No healthy lane can present that state: it is executing a record
# that exists and has not passed its deadline. The account's own queue is read
# for this, and only when the scan actually found a lane, so a sweep on a host
# with no remote jobs still creates nothing.
#
# Only this user's processes are inspected, and this process, its own process
# group, and any ancestor are never signalled. Each candidate is stopped through
# the shared fm_remote_job_stop_worker_tree, so the whole worker tree goes at
# once (TERM first, KILL only for a survivor) and a group whose leader is not
# itself a worker is stopped as a single process instead.
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
REAP_QUEUE_READY=0

reap_die() { printf 'fm-remote-job-reap-orphans: %s\n' "$1" >&2; exit 2; }

reap_usage() {
  cat <<'TXT'
Usage: fm-remote-job-reap-orphans.sh [--dry-run]

Stop every remote job worker whose Firstmate code root has been pruned, and
every lane worker whose own job record is gone or past its deadline. A
healthy worker - the account's LaunchAgent worker, a live remote secondmate's
worker, a lane inside its deadline - is never a candidate. --dry-run reports
the candidates and signals nothing. Read this script's header for the full
rule.
TXT
}

# Read a worker command line, accepted only when it is unambiguously a worker
# invocation: an absolute script path ending in the worker suffix, optionally
# preceded by the interpreter ps reports as "/bin/bash <script>", with at most
# the --serve argument, or --lane and one safe job id, after it. On success
# REAP_WORKER_ROOT holds the code root it was launched from and REAP_LANE_JOB
# holds the lane's job id, empty for every other worker. Both are returned
# through variables rather than stdout because a command substitution would run
# this in a subshell and lose the second one.
reap_read_worker() { # <command>
  local command=$1 path prefix leading tail
  REAP_WORKER_ROOT=
  REAP_LANE_JOB=
  case "$command" in
    *"$REAP_SUFFIX --serve") path=${command%" --serve"} ;;
    *"$REAP_SUFFIX") path=$command ;;
    *"$REAP_SUFFIX --lane "*)
      tail=${command##*"$REAP_SUFFIX --lane "}
      fm_remote_job_safe_id "$tail" || return 1
      REAP_LANE_JOB=$tail
      path=${command%" --lane $tail"}
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

# Whether this account's job queue could be resolved. Called only once a lane
# candidate exists, so a sweep that found none touches no queue state at all.
reap_queue_ready() {
  case "$REAP_QUEUE_READY" in
    1) return 0 ;;
    2) return 1 ;;
  esac
  if fm_remote_job_prepare_state "${HOME:-}" 2>/dev/null; then
    REAP_QUEUE_READY=1
    return 0
  fi
  REAP_QUEUE_READY=2
  return 1
}

# A lane whose record can no longer justify it: gone, or past its recorded
# deadline by the shared lane grace. An unreadable deadline on a record that
# still exists is indeterminate and never reaped, so a lane racing its own
# record's establishment survives. A record already published `done` is
# deliberately not its own condition: a lane is briefly alive after publishing,
# and reaping on that would race its own record cleanup for no gain, since a
# lane still there past the deadline is reaped anyway.
reap_lane_abandoned() { # <job-id>
  local id=$1 job deadline now
  reap_queue_ready || return 1
  job=$(fm_remote_job_job_dir "$id" 2>/dev/null) || return 0
  deadline=$(fm_remote_job_read_number "$job" deadline 2>/dev/null || true)
  case "$deadline" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ "$now" -ge $((deadline + FM_REMOTE_JOB_LANE_GRACE_SECONDS)) ]
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
  local uid scan pid command live root own_pgid pgid lane reason
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
    elif [ -n "$lane" ] && reap_lane_abandoned "$lane"; then
      reason="abandoned lane for $lane"
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
    if fm_remote_job_stop_worker_tree "$pid"; then
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
