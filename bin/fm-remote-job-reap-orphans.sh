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
# The reap condition is exactly fm_remote_job_root_is_live failing for the root
# named in the worker's own command line. That is deliberately the whole test:
# a worker whose root is gone can never claim, validate, or execute another job,
# and no healthy worker can present a missing root. The account's healthy
# LaunchAgent worker, a live remote secondmate's worker, and any worker whose
# checkout still exists are therefore never candidates, with no dependence on
# log paths, process age, or which home is sweeping.
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

reap_die() { printf 'fm-remote-job-reap-orphans: %s\n' "$1" >&2; exit 2; }

reap_usage() {
  cat <<'TXT'
Usage: fm-remote-job-reap-orphans.sh [--dry-run]

Stop every remote job worker whose Firstmate code root has been pruned. A
worker whose root still exists - the account's LaunchAgent worker, a live
remote secondmate's worker - is never a candidate. --dry-run reports the
candidates and signals nothing. Read this script's header for the full rule.
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

reap_orphans() {
  local uid scan pid command live root own_pgid pgid start confirmed_start
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
    root=$(reap_worker_root "$command") || continue
    fm_remote_job_root_is_live "$root" && continue
    [ "$pid" != "$$" ] || continue
    reap_is_self_or_ancestor "$pid" && continue
    if [ -n "$own_pgid" ]; then
      pgid=$(fm_remote_job_process_pgid "$pid" 2>/dev/null || true)
      [ "$pgid" != "$own_pgid" ] || continue
    fi
    # Re-read the command from the live process so a recycled pid cannot be
    # signalled on the strength of a stale scan line.
    start=$(fm_remote_job_process_start "$pid" 2>/dev/null || true)
    [ -n "$start" ] || continue
    live=$(fm_remote_job_process_command "$pid" 2>/dev/null || true)
    read -r live <<< "$live"
    [ "$live" = "$command" ] || continue
    confirmed_start=$(fm_remote_job_process_start "$pid" 2>/dev/null || true)
    fm_remote_job_start_identity_matches "$pid" "$start" "$confirmed_start" || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would reap abandoned remote job worker %s (pruned code root %s)\n' "$pid" "$root"
      continue
    fi
    if fm_remote_job_stop_worker_tree "$pid" "$start"; then
      printf 'reaped abandoned remote job worker %s (pruned code root %s)\n' "$pid" "$root"
    else
      printf 'warning: abandoned remote job worker %s survived reaping (pruned code root %s)\n' "$pid" "$root" >&2
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
