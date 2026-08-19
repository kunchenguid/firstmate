#!/usr/bin/env bash
# Reclaim Next.js build output from pooled worktrees that nobody is using.
#
# Teardown (bin/fm-teardown.sh) reclaims a copy on the way back to the pool, so
# this sweep exists for the copies that were returned before that shipped, and
# for a copy whose task record is gone. It is a command a human or firstmate
# runs; there is deliberately no daemon, watcher, schedule, or disk-pressure
# trigger behind it.
#
# Usage: fm-next-cache-sweep.sh [--dry-run] [<project-dir>...]
#   --dry-run   report what would be reclaimed and remove nothing.
#   <project-dir>...  sweep these project clones' pools instead of every clone
#                     under $FM_HOME/projects.
#
# WHAT IT TOUCHES. Only pooled task copies, and only the Next.js build output
# inside them - bin/fm-next-cache-lib.sh's header owns that discovery rule and
# the reason it can never reach source, node_modules, or git data. The project
# clone itself is never swept: firstmate reads its clones and only crewmates
# change them, and a clone is where nothing builds anyway.
#
# A COPY MUST BE PROVEN UNOWNED, all four, or it is skipped:
#   1. treehouse reports it `available`. A live dev server rewrites the build
#      output the moment you delete it, and deleting mid-build is worse than
#      leaving it alone, so a leased copy is out of scope no matter how idle it
#      looks. The pool is shared across firstmate homes and treehouse's lease is
#      the only ownership signal that spans all of them, which is why it comes
#      first rather than last.
#   2. No task record names it. This home's state/*.meta plus every registered
#      secondmate home's, so a copy owned by a task in another home is skipped
#      even if its lease was somehow released.
#   3. The tree is clean. Uncommitted work is unlanded work.
#   4. There are no stashes. A stash is unlanded work that a clean tree does not
#      show, and nobody is watching an idle copy to notice it disappear.
# Checks 3 and 4 read git and change nothing. A copy with a proven owner keeps
# its build output and is reported. An ownership input that is absent,
# unreadable, malformed, or incomplete refuses reclamation at that input's
# scope: task-record enumeration refuses the whole sweep, and pool or worktree
# inspection refuses that project before any of its copies are touched.
#
# One race is left open deliberately. A copy can be leased in the moment between
# the pool reporting it available and the removal running. Closing that would
# need a lease this tool does not own, and the consequence is bounded: the copy
# was leased to start fresh work, so it loses build output it was about to
# regenerate anyway - the same directory `next build` clears at the start of
# every production build. Losing that race costs a rebuild, not work.
#
# It reports every copy it reclaimed, with the space each gave back and a total,
# and says plainly when it found nothing - a cleanup that prints nothing is
# indistinguishable from one that did nothing.
#
# Exit status is 0 when the sweep completed, 1 when a removal or a project's
# pool lookup failed (already reported), 2 on a usage or environment error.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-next-cache-lib.sh
. "$SCRIPT_DIR/fm-next-cache-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

sweep_die() { printf 'fm-next-cache-sweep: %s\n' "$1" >&2; exit 2; }

sweep_incomplete() {
  printf 'sweep: incomplete ownership input: %s; reclamation refused\n' "$1" >&2
  return 1
}

sweep_usage() {
  cat <<'TXT'
Usage: fm-next-cache-sweep.sh [--dry-run] [<project-dir>...]

Reclaim Next.js build output from pooled task copies that nobody is using.
With no project directory, sweeps every project clone under $FM_HOME/projects.

  --dry-run   report what would be reclaimed and remove nothing.

A copy is swept only when the pool reports it available, no task record in this
home or a registered secondmate home names it, its tree is clean, and it holds
no stashes. Proven owners are skipped and reported; incomplete ownership input
refuses its whole scope. Read this script's header for the full rule, and
bin/fm-next-cache-lib.sh's for what counts as build output.
TXT
}

DRY_RUN=0
PROJECT_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sweep_usage; exit 0 ;;
    --) shift; break ;;
    -*) sweep_die "unknown option: $1 (see --help)" ;;
    *) PROJECT_ARGS+=("$1"); shift ;;
  esac
done
while [ "$#" -gt 0 ]; do PROJECT_ARGS+=("$1"); shift; done

command -v treehouse >/dev/null 2>&1 \
  || sweep_die "treehouse is not installed; the pool's lease state is the sweep's first ownership proof and cannot be guessed"
command -v python3 >/dev/null 2>&1 \
  || sweep_die "python3 is not installed; it reads the pool's JSON status"

# Every state directory whose task records could own a pooled copy: this home's
# plus every locally registered secondmate's. A remote secondmate's home lives on
# another machine and cannot hold this machine's pool, so it is not consulted.
TASK_STATE_DIRS=
sweep_resolve_directory() {
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

sweep_path_identity() {  # <path>
  local resolved
  resolved=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || return 1
  if [ "$(uname)" = Darwin ]; then
    stat -L -f '%d:%i' "$resolved" 2>/dev/null
  else
    stat -L -c '%d:%i' "$resolved" 2>/dev/null
  fi
}

sweep_task_record_state_dirs() {
  local registry="$DATA/secondmates.md" registry_contents line home resolved_home
  TASK_STATE_DIRS=$STATE
  if [ ! -f "$registry" ] || [ -L "$registry" ] || [ ! -r "$registry" ] \
    || ! registry_contents=$(cat "$registry" 2>/dev/null); then
    sweep_incomplete "cannot read secondmate registry: $registry"
    return
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '- '*)
        if ! secondmate_registry_parse_line "$line"; then
          sweep_incomplete "malformed secondmate registry entry in $registry: $line"
          return
        fi
        if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ]; then
          home=$SECONDMATE_REGISTRY_HOME
          case "$home" in
            /*) ;;
            *)
              sweep_incomplete "unsafe non-absolute secondmate home: $home"
              return
              ;;
          esac
          if ! resolved_home=$(sweep_resolve_directory "$home"); then
            sweep_incomplete "cannot resolve registered local secondmate home: $home"
            return
          fi
          TASK_STATE_DIRS="$TASK_STATE_DIRS"$'\n'"$resolved_home/state"
        fi
        ;;
    esac
  done <<EOT
$registry_contents
EOT
}

TASK_WORKTREES=
TASK_WORKTREE_IDENTITIES=
sweep_load_task_worktrees() {
  local state_dir meta meta_contents worktree kind remote_host identity
  TASK_WORKTREES=
  TASK_WORKTREE_IDENTITIES=
  sweep_task_record_state_dirs || return 1
  while IFS= read -r state_dir; do
    if [ -z "$state_dir" ]; then
      sweep_incomplete "task state directory enumeration returned an empty path"
      return
    fi
    if [ ! -d "$state_dir" ] || [ ! -r "$state_dir" ] || [ ! -x "$state_dir" ]; then
      sweep_incomplete "cannot read task state directory: $state_dir"
      return
    fi
    for meta in "$state_dir"/*.meta; do
      if [ -e "$meta" ] || [ -L "$meta" ]; then
        if [ ! -f "$meta" ] || [ -L "$meta" ] || [ ! -r "$meta" ] \
          || ! meta_contents=$(cat "$meta" 2>/dev/null); then
          sweep_incomplete "cannot read task metadata: $meta"
          return
        fi
        worktree=$(printf '%s\n' "$meta_contents" | sed -n 's/^worktree=//p')
        kind=$(printf '%s\n' "$meta_contents" | sed -n 's/^kind=//p')
        remote_host=$(printf '%s\n' "$meta_contents" | sed -n 's/^remote_host=//p')
        case "$worktree" in
          ''|*$'\n'*)
            sweep_incomplete "task metadata has no single worktree: $meta"
            return
            ;;
          /*) ;;
          *)
            sweep_incomplete "task metadata has a non-absolute worktree: $meta ($worktree)"
            return
            ;;
        esac
        case "$kind$remote_host" in
          *$'\n'*)
            sweep_incomplete "task metadata has ambiguous placement: $meta"
            return
            ;;
        esac
        if [ -n "$remote_host" ]; then
          if [ "$kind" != secondmate ]; then
            sweep_incomplete "task metadata has an invalid remote placement: $meta"
            return
          fi
        else
          if ! identity=$(sweep_path_identity "$worktree"); then
            sweep_incomplete "cannot resolve task-record worktree: $worktree"
            return
          fi
          if [ -n "$TASK_WORKTREES" ]; then
            TASK_WORKTREES="$TASK_WORKTREES"$'\n'"$worktree"
            TASK_WORKTREE_IDENTITIES="$TASK_WORKTREE_IDENTITIES"$'\n'"$identity"
          else
            TASK_WORKTREES=$worktree
            TASK_WORKTREE_IDENTITIES=$identity
          fi
        fi
      fi
    done
  done <<EOT
$TASK_STATE_DIRS
EOT
}

# Does any task record name <path> as its worktree?
sweep_task_owns() {  # <path>
  local path=$1 path_identity
  if [ -n "$TASK_WORKTREES" ] && printf '%s\n' "$TASK_WORKTREES" | grep -Fxq -- "$path"; then
    return 0
  fi
  path_identity=$(sweep_path_identity "$path") || return 2
  if [ -n "$TASK_WORKTREE_IDENTITIES" ] \
    && printf '%s\n' "$TASK_WORKTREE_IDENTITIES" | grep -Fxq -- "$path_identity"; then
    return 0
  fi
  return 1
}

# Print "<status>\t<path>" for every worktree in <project-dir>'s pool.
# treehouse resolves the pool from the working directory, and reading pool
# status changes nothing in the clone.
sweep_pool_entries() {  # <project-dir>
  local raw
  raw=$(cd "$1" && treehouse status --json 2>/dev/null) || return 1
  printf '%s\n' "$raw" | python3 -c '
import json, sys

# Anything this cannot read as a list of pool entries exits non-zero, so the
# caller reports the project as unreadable and sweeps none of its copies. An
# unparseable pool is not an empty pool, and it is certainly not a pool of
# unowned copies.
try:
    pool = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if not isinstance(pool, list):
    sys.exit(1)
for entry in pool:
    if not isinstance(entry, dict):
        sys.exit(1)
    status = entry.get("status")
    path = entry.get("path")
    if not isinstance(status, str) or not status:
        sys.exit(1)
    if not isinstance(path, str) or not path or not path.startswith("/"):
        sys.exit(1)
    if any(c in status or c in path for c in "\t\r\n"):
        sys.exit(1)
    print("%s\t%s" % (status, path))
'
}

# Why <worktree> may not be swept, printed as "<class><tab><reason>"; empty when
# it may be. `owned` is a complete answer for that copy. `undetermined` makes
# the project's preflight incomplete, so none of that project's copies may be
# touched.
sweep_unowned_reason() {  # <status> <worktree>
  local status=$1 wt=$2 task_ownership
  # Only the pool's own word for "available" clears this check. Any other
  # value - in-use, a status this version of treehouse does not print, or none
  # at all - means ownership was not established, which is not the same as
  # establishing that there is no owner.
  if [ "$status" = in-use ]; then
    printf 'owned\tin use by the pool\n'
    return 0
  fi
  if [ "$status" != available ]; then
    printf 'undetermined\tthe pool did not report it available\n'
    return 0
  fi
  sweep_task_owns "$wt"
  task_ownership=$?
  case "$task_ownership" in
    0)
      printf 'owned\tstill claimed by a task record\n'
      return 0
      ;;
    2)
      printf 'undetermined\tcannot compare it with task-record worktrees\n'
      return 0
      ;;
  esac
  if ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'undetermined\tnot an inspectable git worktree\n'
    return 0
  fi
  local dirty stashes
  if ! dirty=$(git -C "$wt" status --porcelain 2>/dev/null); then
    printf 'undetermined\tcannot inspect it for uncommitted changes\n'
    return 0
  fi
  if [ -n "$dirty" ]; then
    printf 'owned\thas uncommitted changes\n'
    return 0
  fi
  if ! stashes=$(git -C "$wt" stash list 2>/dev/null); then
    printf 'undetermined\tcannot inspect it for stashes\n'
    return 0
  fi
  if [ -n "$stashes" ]; then
    printf 'owned\thas stashed work\n'
    return 0
  fi
  printf '\n'
}

sweep_project_plan() {  # <entries>
  local entries=$1 status wt verdict class reason plan='' record
  while IFS=$'\t' read -r status wt; do
    if [ -n "$status$wt" ]; then
      if [ -z "$status" ] || [ -z "$wt" ]; then
        sweep_incomplete "pool entry did not yield a complete status and path"
        return
      fi
      if [ ! -d "$wt" ]; then
        sweep_incomplete "pool worktree is not an inspectable directory: $wt"
        return
      fi
      verdict=$(sweep_unowned_reason "$status" "$wt")
      if [ -n "$verdict" ]; then
        class=${verdict%%	*}
        reason=${verdict#*	}
        if [ "$class" = undetermined ]; then
          sweep_incomplete "$wt could not be assessed ($reason)"
          return
        fi
        record="owned"$'\t'"$reason"$'\t'"$wt"
      else
        record="free"$'\t'"-"$'\t'"$wt"
      fi
      if [ -n "$plan" ]; then
        plan="$plan"$'\n'"$record"
      else
        plan=$record
      fi
    fi
  done <<EOT
$entries
EOT
  printf '%s\n' "$plan"
}

sweep_apply_project_plan() {  # <plan>
  local plan=$1 action reason wt
  while IFS=$'\t' read -r action reason wt; do
    if [ -n "$action" ]; then
      if [ "$action" = owned ]; then
        fm_next_cache_total_kb "$wt" >/dev/null
        if [ "$FM_NEXT_CACHE_TOTAL_KB" -gt 0 ]; then
          printf 'sweep: skipped %s (%s), holding %s\n' \
            "$wt" "$reason" "$(fm_next_cache_human_kb "$FM_NEXT_CACHE_TOTAL_KB")"
          SKIPPED=$(( SKIPPED + 1 ))
        fi
      else
        if [ "$DRY_RUN" = 1 ]; then
          fm_next_cache_report "$wt" "sweep" || RC=1
        else
          fm_next_cache_reclaim "$wt" "sweep" || RC=1
        fi
        if [ "$FM_NEXT_CACHE_TOTAL_KB" -gt 0 ]; then
          TOTAL_KB=$(( TOTAL_KB + FM_NEXT_CACHE_TOTAL_KB ))
          RECLAIMED=$(( RECLAIMED + 1 ))
        fi
      fi
    fi
  done <<EOT
$plan
EOT
}

sweep_project() {  # <project>
  local project=$1 project_real entries plan
  if ! project_real=$(sweep_resolve_directory "$project"); then
    sweep_incomplete "cannot enter project: $project"
    return
  fi
  if ! entries=$(sweep_pool_entries "$project_real"); then
    sweep_incomplete "cannot read the worktree pool for $project_real"
    return
  fi
  if ! plan=$(sweep_project_plan "$entries"); then
    return 1
  fi
  sweep_apply_project_plan "$plan"
}

if [ "${#PROJECT_ARGS[@]}" -gt 0 ]; then
  TARGETS=("${PROJECT_ARGS[@]}")
else
  TARGETS=()
  for dir in "$PROJECTS"/*/; do
    if [ -d "$dir" ]; then
      dir=${dir%/}
      if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        TARGETS+=("$dir")
      fi
    fi
  done
fi

[ "${#TARGETS[@]}" -gt 0 ] || sweep_die "no project clones to sweep under $PROJECTS"

sweep_load_task_worktrees || sweep_die "task-record ownership inputs are incomplete"

RC=0
TOTAL_KB=0
RECLAIMED=0
SKIPPED=0
INCOMPLETE=0
for project in "${TARGETS[@]}"; do
  if ! sweep_project "$project"; then
    RC=1
    INCOMPLETE=$(( INCOMPLETE + 1 ))
  fi
done

sweep_copies() {  # <count>
  if [ "$1" -eq 1 ]; then printf '1 copy\n'; else printf '%d copies\n' "$1"; fi
}

sweep_projects() {  # <count>
  if [ "$1" -eq 1 ]; then printf '1 project\n'; else printf '%d projects\n' "$1"; fi
}

INCOMPLETE_NOTE=
if [ "$INCOMPLETE" -gt 0 ]; then
  INCOMPLETE_NOTE="; $(sweep_projects "$INCOMPLETE") could not be inspected"
fi

if [ "$RECLAIMED" -eq 0 ]; then
  if [ "$SKIPPED" -gt 0 ]; then
    printf 'sweep: nothing to reclaim; %s were skipped as owned (listed above)%s\n' \
      "$(sweep_copies "$SKIPPED")" "$INCOMPLETE_NOTE"
  elif [ "$INCOMPLETE" -gt 0 ]; then
    printf 'sweep: nothing to reclaim in inspected projects%s\n' "$INCOMPLETE_NOTE"
  else
    printf 'sweep: nothing to reclaim; no idle copy holds Next.js build output\n'
  fi
elif [ "$DRY_RUN" = 1 ]; then
  printf 'sweep: would reclaim %s from %s%s\n' \
    "$(fm_next_cache_human_kb "$TOTAL_KB")" "$(sweep_copies "$RECLAIMED")" "$INCOMPLETE_NOTE"
else
  printf 'sweep: reclaimed %s from %s%s\n' \
    "$(fm_next_cache_human_kb "$TOTAL_KB")" "$(sweep_copies "$RECLAIMED")" "$INCOMPLETE_NOTE"
fi

exit "$RC"
