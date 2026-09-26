#!/usr/bin/env bash
# Reap remote job workers that must not keep running: ones whose code root no
# longer exists, and, on request, duplicate restart supervisors.
#
# Usage: fm-remote-job-reap-orphans.sh [--duplicates] [--dry-run]
#   --duplicates collapses this account's workers to the one that owns its
#                worker lock instead of reaping pruned roots.
#   --dry-run    reports what would be stopped and signals nothing.
#
# A remote job worker (bin/fm-remote-job-worker.sh) is launched from a specific
# Firstmate code root: the account's own checkout under the LaunchAgent, a
# remote secondmate's checkout, a no-mistakes gate worktree, a pooled task
# worktree, or a test fixture root. When that root is pruned while the worker is
# running, the worker is reparented to init and, on older builds, keeps polling
# and logging indefinitely. Current workers stop themselves once their root is
# gone (bin/fm-remote-job-worker.sh); the default sweep is the
# belt-and-suspenders pass that clears workers already orphaned that way,
# including ones started before self-termination shipped.
#
# The default sweep's reap condition is exactly fm_remote_job_root_is_live
# failing for the root named in the worker's own command line. A worker whose
# root is gone can never claim, validate, or execute another job, and no healthy
# worker can present a missing root. The account's healthy LaunchAgent worker, a
# live remote secondmate's worker, and any worker whose checkout still exists
# are therefore never candidates of the default sweep, with no dependence on log
# paths, process age, or which home is sweeping.
#
# --duplicates is the supported recovery when restart supervisors have
# multiplied on a host whose code root is live, which the default sweep never
# touches. Its candidates are the top-level workers - restart supervisors, and
# serving children whose supervisor is gone - bound to this account's queue
# (FM_REMOTE_JOB_STATE_ROOT, else ~/.firstmate/remote-job), whatever code root
# launched them. On Linux a worker is bound to a queue by the
# FM_REMOTE_JOB_STATE_ROOT in its own environment, read through
# /proc/<pid>/environ: every Linux start path, older builds included, sets it
# explicitly, and it holds whatever becomes of the worker log. Where that is
# unreadable, the worker is bound by the file its standard output goes to, read
# through lsof: every start path appends a worker tree's output to its own
# queue's logs/dev.firstmate.remote-job.log, and a log that was since removed
# still counts. Another queue's workers and a launchd-run worker are never
# candidates. A process whose parent is itself one of this queue's workers is
# never a candidate or a top-level worker: it is a serving child still under its
# supervisor, or a bash command or process substitution fork of a worker, which
# keeps the worker's command line and environment and goes with that worker's
# tree. A genuine duplicate supervisor's parent is its ensure caller or init,
# never a worker. The sweep keeps only the process that verifiably owns the queue's
# worker lock, with the supervisor directly above it, and stops every other
# candidate, so a host holding hundreds of supervisors is left with exactly one.
# When no process verifiably owns the lock, nothing is healthy and every
# candidate is stopped; fm-remote-doctor.sh --fix runs this collapse first and
# then starts exactly one worker. The owner is read through the shared
# library's identity check, so a duplicate is never mistaken for the owner, and
# an absent queue has nothing to collapse.
#
# Only this user's processes are inspected, and this process, its own process
# group, and any ancestor are never signalled. Each candidate is re-read from
# the live process immediately before it is signalled, so a recycled pid is
# never signalled on the strength of a stale scan line, and is stopped through
# the shared fm_remote_job_stop_worker_tree, so the whole worker tree goes at
# once (TERM first, KILL only for a survivor) and a group whose leader is not
# itself a worker is stopped as a single process instead.
#
# Prints one line per stopped or surviving candidate and nothing when there is
# nothing to do. Exits 0 unless the process scan itself could not run, so a
# caller can sweep without risking its own outcome.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# shellcheck source=bin/fm-remote-job-lib.sh
. "$SCRIPT_DIR/fm-remote-job-lib.sh"

DRY_RUN=0
DUPLICATES=0
REAP_SUFFIX=/bin/fm-remote-job-worker.sh

reap_die() { printf 'fm-remote-job-reap-orphans: %s\n' "$1" >&2; exit 2; }

reap_usage() {
  cat <<'TXT'
Usage: fm-remote-job-reap-orphans.sh [--duplicates] [--dry-run]

Stop every remote job worker whose Firstmate code root has been pruned. A
worker whose root still exists - the account's LaunchAgent worker, a live
remote secondmate's worker - is never a candidate. --duplicates instead
collapses the workers bound to this account's queue to the one that owns its
worker lock, stopping every duplicate restart supervisor. --dry-run
reports the candidates and signals nothing. Read this script's header for the
full rule.
TXT
}

# The code root a worker command line was launched from, echoed only when the
# command is unambiguously a worker invocation: an absolute script path ending
# in the worker suffix, optionally preceded by the interpreter ps reports as
# "/bin/bash <script>", with at most the --serve argument after it.
reap_worker_root() { # <command>
  local command=$1 path prefix leading
  case "$command" in
    *"$REAP_SUFFIX --serve") path=${command%" --serve"} ;;
    *"$REAP_SUFFIX") path=$command ;;
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
  printf '%s\n' "$prefix"
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

# Print "<pid> <root> <command>" for every worker invocation this account runs,
# never this process, its own process group, or an ancestor.
reap_scan_workers() {
  local uid scan pid command root own_pgid pgid
  uid=$(id -u 2>/dev/null || true)
  case "$uid" in ''|*[!0-9]*) reap_die "cannot resolve the current uid" ;; esac
  scan=$(COLUMNS=10000 LC_ALL=C ps -u "$uid" -o pid=,command= 2>/dev/null) ||
    reap_die "cannot scan this account's processes for remote job workers"
  own_pgid=$(fm_remote_job_process_pgid "$$" 2>/dev/null || true)
  # ps pads the pid column to the widest pid on the host, so the fields are read
  # with default word splitting rather than by fixed offsets or a single space.
  while read -r pid command; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ -n "$command" ] || continue
    root=$(reap_worker_root "$command") || continue
    [ "$pid" != "$$" ] || continue
    reap_is_self_or_ancestor "$pid" && continue
    if [ -n "$own_pgid" ]; then
      pgid=$(fm_remote_job_process_pgid "$pid" 2>/dev/null || true)
      [ "$pgid" != "$own_pgid" ] || continue
    fi
    printf '%s\t%s\t%s\n' "$pid" "$root" "$command"
  done <<EOF
$scan
EOF
}

# True while <pid> still runs exactly the scanned <command>.
reap_still_running() { # <pid> <command>
  local live
  live=$(fm_remote_job_process_command "$1" 2>/dev/null || true)
  read -r live <<< "$live"
  [ "$live" = "$2" ]
}

reap_stop() { # <pid> <what> <root>
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'would reap %s %s (%s)\n' "$2" "$1" "$3"
    return 0
  fi
  if fm_remote_job_stop_worker_tree "$1"; then
    printf 'reaped %s %s (%s)\n' "$2" "$1" "$3"
  else
    printf 'warning: %s %s survived reaping (%s)\n' "$2" "$1" "$3" >&2
  fi
}

reap_orphans() { # <scan>
  local pid root command
  while IFS=$'\t' read -r pid root command; do
    [ -n "$pid" ] || continue
    fm_remote_job_root_is_live "$root" && continue
    reap_still_running "$pid" "$command" || continue
    reap_stop "$pid" "abandoned remote job worker" "pruned code root $root"
  done <<< "$1"
}

# This account's queue, canonical, or nothing when it does not exist yet. The
# collapse never creates one.
reap_state_root() {
  local account_home root
  account_home=$(fm_remote_job_canonical_existing_dir "${HOME:-/nonexistent}" 2>/dev/null) || return 1
  root=${FM_REMOTE_JOB_STATE_ROOT:-$account_home/.firstmate/remote-job}
  root=$(fm_remote_job_canonical_existing_dir "$root" 2>/dev/null) || return 1
  [ -d "$root/jobs" ] && [ ! -L "$root/jobs" ] || return 1
  printf '%s\n' "$root"
}

# The file a process writes its standard output to.
reap_process_stdout() { # <pid>
  local lsof_bin
  if [ -e "/proc/$1/fd/1" ] || [ -L "/proc/$1/fd/1" ]; then
    readlink "/proc/$1/fd/1" 2>/dev/null
    return
  fi
  if [ -x /usr/sbin/lsof ]; then lsof_bin=/usr/sbin/lsof; else lsof_bin=$(command -v lsof 2>/dev/null) || return 1; fi
  "$lsof_bin" -a -p "$1" -d 1 -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1
}

# True when <pid> serves the queue at <state-root>, whose worker log is <log>.
reap_bound_to_queue() { # <pid> <state-root> <log>
  local environ value
  if environ=$(tr '\0' '\n' 2>/dev/null < "/proc/$1/environ"); then
    value=$(printf '%s\n' "$environ" | sed -n 's/^FM_REMOTE_JOB_STATE_ROOT=//p' | head -n 1)
    [ -n "$value" ] || return 1
    value=$(fm_remote_job_canonical_existing_dir "$value" 2>/dev/null) || return 1
    [ "$value" = "$2" ]
    return
  fi
  value=$(reap_process_stdout "$1" 2>/dev/null) || return 1
  [ "$value" = "$3" ] || [ "$value" = "$3 (deleted)" ]
}

reap_duplicates() { # <scan>
  local state_root log owner='' owner_parent='' pid root command ppid i count
  local -a pids=() commands=() ppids=() tops=()
  state_root=$(reap_state_root) || return 0
  log="$state_root/logs/$FM_REMOTE_JOB_LABEL.log"
  while IFS=$'\t' read -r pid root command; do
    [ -n "$pid" ] || continue
    reap_bound_to_queue "$pid" "$state_root" "$log" || continue
    ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
    pids+=("$pid")
    commands+=("$command")
    ppids+=("$ppid")
  done <<< "$1"
  [ "${#pids[@]}" -gt 0 ] || return 0
  i=0
  count=${#pids[@]}
  while [ "$i" -lt "$count" ]; do
    case " ${pids[*]} " in *" ${ppids[$i]} "*) ;; *)
      case "${commands[$i]}" in *" --serve") ;; *) tops+=("${pids[$i]}") ;; esac ;;
    esac
    i=$((i + 1))
  done
  if fm_remote_job_lock_owner_status "$(fm_remote_job_canonical_existing_dir "${HOME:-/nonexistent}")" 2>/dev/null; then
    owner=$FM_REMOTE_JOB_OWNER_PID
    ppid=$(ps -p "$owner" -o ppid= 2>/dev/null | tr -d '[:space:]')
    case " ${tops[*]:-} " in *" $ppid "*) owner_parent=$ppid ;; esac
  fi
  i=0
  count=${#pids[@]}
  while [ "$i" -lt "$count" ]; do
    pid=${pids[$i]}
    command=${commands[$i]}
    ppid=${ppids[$i]}
    i=$((i + 1))
    [ "$pid" != "$owner" ] && [ "$pid" != "$owner_parent" ] || continue
    # A serving child or a bash fork still under a worker goes with that
    # worker's tree, so only a process whose parent is no worker is a candidate.
    case " ${pids[*]} " in *" $ppid "*) continue ;; esac
    reap_still_running "$pid" "$command" || continue
    reap_stop "$pid" "duplicate remote job worker" "queue $state_root"
  done
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --duplicates) DUPLICATES=1 ;;
    -h|--help) reap_usage; exit 0 ;;
    *) reap_die "unexpected argument: $1" ;;
  esac
  shift
done

# Scanned here rather than in a pipeline so a failed scan exits this script.
SCAN=$(reap_scan_workers) || exit 2
if [ "$DUPLICATES" -eq 1 ]; then
  reap_duplicates "$SCAN"
else
  reap_orphans "$SCAN"
fi
