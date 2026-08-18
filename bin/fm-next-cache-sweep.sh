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
# Checks 3 and 4 read git and change nothing. A copy that fails any check keeps
# its build output; the sweep says which check failed and moves on. Every check
# treats "could not determine" as "owned": an unreadable pool, an unparseable
# status, a path that is not an inspectable git worktree, or a git command that
# fails all skip the copy rather than assume it is free.
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

sweep_usage() {
  cat <<'TXT'
Usage: fm-next-cache-sweep.sh [--dry-run] [<project-dir>...]

Reclaim Next.js build output from pooled task copies that nobody is using.
With no project directory, sweeps every project clone under $FM_HOME/projects.

  --dry-run   report what would be reclaimed and remove nothing.

A copy is swept only when the pool reports it available, no task record in this
home or a registered secondmate home names it, its tree is clean, and it holds
no stashes. Anything else is skipped and reported. Read this script's header for
the full rule, and bin/fm-next-cache-lib.sh's for what counts as build output.
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
sweep_task_record_state_dirs() {
  local registry="$DATA/secondmates.md" line home
  printf '%s\n' "$STATE"
  [ -f "$registry" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then continue; fi
    home=$SECONDMATE_REGISTRY_HOME
    [ -n "$home" ] || continue
    printf '%s/state\n' "$home"
  done < "$registry"
}

TASK_WORKTREES=
sweep_load_task_worktrees() {
  local state_dir meta
  TASK_WORKTREES=$(
    while IFS= read -r state_dir; do
      [ -d "$state_dir" ] || continue
      for meta in "$state_dir"/*.meta; do
        [ -f "$meta" ] || continue
        sed -n 's/^worktree=//p' "$meta"
      done
    done < <(sweep_task_record_state_dirs)
  )
}

# Does any task record name <path> as its worktree?
sweep_task_owns() {  # <path>
  local path=$1
  [ -n "$TASK_WORKTREES" ] || return 1
  printf '%s\n' "$TASK_WORKTREES" | grep -Fxq -- "$path"
}

# Print "<status>\t<path>" for every worktree in <project-dir>'s pool.
# treehouse resolves the pool from the working directory, and reading pool
# status changes nothing in the clone.
sweep_pool_entries() {  # <project-dir>
  ( cd "$1" && treehouse status --json 2>/dev/null ) | python3 -c '
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
    status = entry.get("status") or ""
    path = entry.get("path") or ""
    if path:
        print("%s\t%s" % (status, path))
'
}

# Why <worktree> may not be swept, printed as "<class><tab><reason>"; empty when
# it may be. The class separates a copy shown to have an owner (`owned`) from
# one whose ownership could not be established at all (`undetermined`). Both
# skip, but they are reported differently: an undetermined copy is always named,
# because the same broken inspection that hides its owner also hides how much it
# is holding, and a silent skip there would read as "nothing here".
sweep_unowned_reason() {  # <status> <worktree>
  local status=$1 wt=$2
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
  if sweep_task_owns "$wt"; then
    printf 'owned\tstill claimed by a task record\n'
    return 0
  fi
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

if [ "${#PROJECT_ARGS[@]}" -gt 0 ]; then
  TARGETS=("${PROJECT_ARGS[@]}")
else
  TARGETS=()
  for dir in "$PROJECTS"/*/; do
    [ -d "$dir" ] || continue
    dir=${dir%/}
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || continue
    TARGETS+=("$dir")
  done
fi

[ "${#TARGETS[@]}" -gt 0 ] || sweep_die "no project clones to sweep under $PROJECTS"

sweep_load_task_worktrees

RC=0
TOTAL_KB=0
RECLAIMED=0
SKIPPED=0
for project in "${TARGETS[@]}"; do
  if ! project_real=$(CDPATH='' cd -- "$project" 2>/dev/null && pwd -P); then
    printf 'sweep: cannot enter project %s\n' "$project" >&2
    RC=1
    continue
  fi
  if ! entries=$(sweep_pool_entries "$project_real"); then
    printf 'sweep: cannot read the worktree pool for %s\n' "$project_real" >&2
    RC=1
    continue
  fi
  while IFS=$'\t' read -r status wt; do
    [ -n "$wt" ] || continue
    [ -d "$wt" ] || continue
    verdict=$(sweep_unowned_reason "$status" "$wt")
    if [ -n "$verdict" ]; then
      class=${verdict%%	*}
      reason=${verdict#*	}
      fm_next_cache_total_kb "$wt" >/dev/null
      if [ "$class" = undetermined ]; then
        # Always named: the failed inspection that hid the owner also hid the
        # size, so "holding 0" here means "could not measure", not "empty".
        printf 'sweep: skipped %s (%s); its contents could not be assessed\n' "$wt" "$reason"
        SKIPPED=$(( SKIPPED + 1 ))
      elif [ "$FM_NEXT_CACHE_TOTAL_KB" -gt 0 ]; then
        # An owned copy is worth a line only when it is actually holding
        # something; an idle copy that never built anything is not news.
        printf 'sweep: skipped %s (%s), holding %s\n' \
          "$wt" "$reason" "$(fm_next_cache_human_kb "$FM_NEXT_CACHE_TOTAL_KB")"
        SKIPPED=$(( SKIPPED + 1 ))
      fi
      continue
    fi
    if [ "$DRY_RUN" = 1 ]; then
      fm_next_cache_report "$wt" "sweep" || RC=1
    else
      fm_next_cache_reclaim "$wt" "sweep" || RC=1
    fi
    if [ "$FM_NEXT_CACHE_TOTAL_KB" -gt 0 ]; then
      TOTAL_KB=$(( TOTAL_KB + FM_NEXT_CACHE_TOTAL_KB ))
      RECLAIMED=$(( RECLAIMED + 1 ))
    fi
  done <<EOT
$entries
EOT
done

sweep_copies() {  # <count>
  if [ "$1" -eq 1 ]; then printf '1 copy\n'; else printf '%d copies\n' "$1"; fi
}

if [ "$RECLAIMED" -eq 0 ]; then
  if [ "$SKIPPED" -gt 0 ]; then
    printf 'sweep: nothing to reclaim; %s were skipped as owned or unassessable (listed above)\n' \
      "$(sweep_copies "$SKIPPED")"
  else
    printf 'sweep: nothing to reclaim; no idle copy holds Next.js build output\n'
  fi
elif [ "$DRY_RUN" = 1 ]; then
  printf 'sweep: would reclaim %s from %s\n' \
    "$(fm_next_cache_human_kb "$TOTAL_KB")" "$(sweep_copies "$RECLAIMED")"
else
  printf 'sweep: reclaimed %s from %s\n' \
    "$(fm_next_cache_human_kb "$TOTAL_KB")" "$(sweep_copies "$RECLAIMED")"
fi

exit "$RC"
