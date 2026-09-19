#!/usr/bin/env bash
# fm-worktree-drift.sh - catch a live ship or scout worker running outside its
# recorded worktree and relaunch it into that worktree before it acts there.
#
# Usage: fm-worktree-drift.sh scan
#        fm-worktree-drift.sh repair [--wake] [<task-id>...]
#        fm-worktree-drift.sh start
#
# WHY. A worker must never run in the primary checkout (AGENTS.md section 8).
# Spawn creates a Herdr task tab with the project's primary checkout as its
# cwd and then enters the worktree through `treehouse get`'s subshell, so the
# pane's recorded cwd stays the primary checkout while the worker runs in the
# worktree. Herdr persists that recorded cwd with the pane's agent session and,
# when it restores its layout after a server restart or a reboot, resumes the
# agent (`claude --resume <session>`) in the recorded cwd - the primary
# checkout - with its conversation intact. The resumed worker then believes it
# is still in its worktree. The restore is Herdr's behavior; this script is the
# Firstmate-side detection and repair. Creating task panes in the worktree in
# the first place is a separate change that this script does not make.
#
# DETECTION (scan). Read-only. For every ship or scout task in this home whose
# record validates (bin/fm-backend.sh's fm_backend_validate_task_endpoint), on
# a backend with a recovery-grade agent classifier (tmux, herdr), whose agent
# reads positively `alive`, the endpoint's foreground working directory
# (fm_backend_current_path; Herdr's foreground_cwd) is compared physically with
# the recorded worktree. A directory equal to or beneath the worktree is fine.
# Anything else read twice, FM_WORKTREE_DRIFT_CONFIRM_SECS apart (default 1),
# is drift, printed as one tab-separated line:
#   drift <task-id> <foreground-cwd> <worktree> <primary|outside>
# `primary` means the directory is the task's recorded project checkout or
# beneath it. An unreadable directory, an ambiguous agent state, a dead agent,
# a secondmate, and any other backend print nothing: a dead endpoint is
# stuck-crewmate recovery's case, and nothing here acts on a guess.
#
# REPAIR (repair). Re-scans (optionally only the named tasks) under a
# single-flight home lock and, for each drifted task, runs the existing
# lifecycle owner - bin/fm-control.sh <id> relaunch - with a progress note
# telling the replacement where the old session was. That relaunch stops the
# old agent, returns the endpoint's shell to the recorded worktree, and starts
# the replacement there. Nothing in this script, and nothing it runs, changes,
# resets, or cleans the directory the worker drifted into.
# After a successful relaunch, a task whose PR merge poll is registered but no
# longer authenticates has it re-registered through bin/fm-pr-check.sh with
# the task's recorded PR.
# Each handled task prints one line starting `WORKTREE_DRIFT:` that names the
# outcome. A failed relaunch records state/.worktree-drift-failed-<id> with the
# drifted directory and is reported once; the same drift is not retried until
# that directory changes or the task's worker is back in its worktree, so a
# relaunch that keeps refusing never loops. A marker whose task record is gone
# is dropped at the next repair, so a later task reusing the id starts clean. With --wake each line is also
# published to the durable wake queue as a `check` row keyed
# worktree-drift-<id>, for a detached run whose output nobody reads inline.
# A repair already under way in this home makes a second one print
# `WORKTREE_DRIFT: repair already under way` and exit 0.
#
# START (start). Launch `repair --wake` detached and return at once: stdio on
# /dev/null so a caller whose stdout is a pipe is never held open, nohup so it
# outlives its caller, and its own process group so a bounded caller's group
# kill cannot stop a relaunch half way (the same three-way detach as
# bin/fm-startup-network.sh's worker).
#
# Callers: bin/fm-session-start.sh (scan inline, then start) and
# bin/fm-watch.sh (scan then repair on FM_WORKTREE_DRIFT_INTERVAL).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIRM_SECS=${FM_WORKTREE_DRIFT_CONFIRM_SECS:-1}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-worktree-drift.sh" | sed 's/^# \{0,1\}//; $d'
}

physical_dir() {  # <path> -> physical path, or the raw path when unresolvable
  (cd -- "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"
}

path_within() {  # <path> <root>
  [ "$1" = "$2" ] && return 0
  case "$1" in
    "$2"/*) return 0 ;;
  esac
  return 1
}

# Set DRIFT_CWD to the endpoint's physical foreground cwd when it lies outside
# the task's worktree, else to empty, with DRIFT_WT, DRIFT_PROJECT, and
# DRIFT_WHERE (primary or outside) describing a drift.
task_drift() {  # <task-id>
  local id=$1 meta kind backend target state cwd wt project
  DRIFT_CWD=
  DRIFT_WT=
  DRIFT_PROJECT=
  DRIFT_WHERE=
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(fm_meta_get "$meta" kind)
  case "$kind" in ship|scout) ;; *) return 0 ;; esac
  fm_backend_validate_task_endpoint "$meta" "$id" 2>/dev/null || return 0
  backend=$FM_BACKEND_VALIDATED_BACKEND
  target=$FM_BACKEND_VALIDATED_TARGET
  case "$backend" in tmux|herdr) ;; *) return 0 ;; esac
  wt=$(fm_meta_get "$meta" worktree)
  project=$(fm_meta_get "$meta" project)
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  state=$(fm_backend_agent_state "$backend" "$target")
  [ "$state" = alive ] || return 0
  wt=$(physical_dir "$wt")
  cwd=$(fm_backend_current_path "$backend" "$target")
  [ -n "$cwd" ] || return 0
  cwd=$(physical_dir "$cwd")
  ! path_within "$cwd" "$wt" || return 0
  sleep "$CONFIRM_SECS"
  cwd=$(fm_backend_current_path "$backend" "$target")
  [ -n "$cwd" ] || return 0
  cwd=$(physical_dir "$cwd")
  ! path_within "$cwd" "$wt" || return 0
  DRIFT_CWD=$cwd
  DRIFT_WT=$wt
  DRIFT_WHERE=outside
  [ -z "$project" ] || DRIFT_PROJECT=$(physical_dir "$project")
  [ -z "$DRIFT_PROJECT" ] || ! path_within "$cwd" "$DRIFT_PROJECT" || DRIFT_WHERE=primary
}

scan_ids() {  # [<task-id>...] -> the task ids to inspect
  local meta id
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@"
    return 0
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    printf '%s\n' "$id"
  done
}

task_id_valid() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

cmd_scan() {
  local id
  while IFS= read -r id; do
    task_id_valid "$id" || continue
    task_drift "$id"
    [ -n "$DRIFT_CWD" ] || continue
    printf 'drift\t%s\t%s\t%s\t%s\n' "$id" "$DRIFT_CWD" "$DRIFT_WT" "$DRIFT_WHERE"
  done < <(scan_ids "$@")
}

# Re-register an armed PR poll that stopped authenticating. Prints a clause
# for the outcome line, or nothing when there is no poll to keep.
reregister_pr_poll() {  # <task-id>
  local id=$1 pr out
  [ -e "$STATE/$id.pr-poll-registration" ] || return 0
  [ ! -e "$STATE/$id.pr-poll-retirement" ] || return 0
  fm_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" && return 0
  pr=$(fm_meta_get "$STATE/$id.meta" pr)
  if [ -z "$pr" ]; then
    printf '; its PR merge poll no longer authenticates and the record names no PR to re-register'
    return 0
  fi
  if out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-pr-check.sh" "$id" "$pr" 2>&1); then
    printf '; its PR merge poll for %s was re-registered' "$pr"
  else
    printf '; re-registering its PR merge poll for %s FAILED: %s' "$pr" "$(printf '%s' "$out" | tr '\n' ' ')"
  fi
}

emit() {  # <task-id> <line>
  printf '%s\n' "$2"
  [ "$WAKE" = 1 ] || return 0
  fm_wake_append check "worktree-drift-$1" "$2" \
    || printf 'WORKTREE_DRIFT: could not queue the outcome for task %s\n' "$1"
}

repair_one() {  # <task-id>, after task_drift found it drifted
  local id=$1 cwd=$DRIFT_CWD where=$DRIFT_WHERE wt=$DRIFT_WT place marker note out poll
  marker="$STATE/.worktree-drift-failed-$id"
  if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$cwd" ]; then
    return 0
  fi
  if [ "$where" = primary ]; then
    place="the primary checkout $DRIFT_PROJECT"
  else
    place="$cwd, outside its worktree"
  fi
  note="Your previous session was found running in $cwd instead of your recorded worktree $wt (a restored terminal resumed it in the directory the pane was created in). It was stopped before continuing there and relaunched in $wt. Verify isolation with pwd -P first, never run anything in $cwd, then continue from the local copy as it stands."
  if out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$id" relaunch --note "$note" 2>&1); then
    rm -f -- "$marker"
    poll=$(reregister_pr_poll "$id")
    emit "$id" "WORKTREE_DRIFT: task $id's worker was running in $place (dir $cwd), not its worktree $wt; it was relaunched into its worktree${poll}"
  else
    printf '%s\n' "$cwd" > "$marker"
    emit "$id" "WORKTREE_DRIFT: task $id's worker is running in $place (dir $cwd), not its worktree $wt, and relaunching it into its worktree FAILED: $(printf '%s' "$out" | tr '\n' ' ')- stop it before it acts there (bin/fm-control.sh $id exit), then relaunch it"
  fi
}

cmd_repair() {
  local lock id marker
  lock="$STATE/.worktree-drift.lock"
  if ! fm_lock_try_acquire "$lock"; then
    printf 'WORKTREE_DRIFT: repair already under way\n'
    return 0
  fi
  # shellcheck disable=SC2064 # The lock path is fixed for this run.
  trap "fm_lock_release '$lock' >/dev/null 2>&1 || true" EXIT
  for marker in "$STATE"/.worktree-drift-failed-*; do
    [ -f "$marker" ] || continue
    [ -e "$STATE/${marker##*/.worktree-drift-failed-}.meta" ] || rm -f -- "$marker"
  done
  while IFS= read -r id; do
    task_id_valid "$id" || continue
    task_drift "$id"
    if [ -n "$DRIFT_CWD" ]; then
      repair_one "$id"
    else
      rm -f -- "$STATE/.worktree-drift-failed-$id"
    fi
  done < <(scan_ids "$@")
}

VERB=${1:-}
[ "$#" -eq 0 ] || shift
WAKE=0
case "$VERB" in
  -h|--help) usage; exit 0 ;;
  scan) cmd_scan "$@" ;;
  repair)
    if [ "${1:-}" = --wake ]; then
      WAKE=1
      shift
    fi
    for id in "$@"; do
      task_id_valid "$id" || { echo "error: invalid task id '$id'" >&2; exit 2; }
    done
    cmd_repair "$@"
    ;;
  start)
    set -m 2>/dev/null || true
    nohup "$SCRIPT_DIR/fm-worktree-drift.sh" repair --wake >/dev/null 2>&1 </dev/null &
    ;;
  *) usage >&2; exit 2 ;;
esac
