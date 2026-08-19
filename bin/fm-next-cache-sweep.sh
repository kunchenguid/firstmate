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

case "${BASH_SOURCE[0]}" in
  */*) script_parent=${BASH_SOURCE[0]%/*} ;;
  *) script_parent=. ;;
esac
if ! SCRIPT_DIR=$(CDPATH='' cd -- "$script_parent" 2>/dev/null && pwd -P); then
  printf 'fm-next-cache-sweep: cannot resolve the script directory\n' >&2
  exit 2
fi
if [ -n "${FM_ROOT_OVERRIDE:-}" ]; then
  FM_ROOT=$FM_ROOT_OVERRIDE
elif ! FM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P); then
  printf 'fm-next-cache-sweep: cannot resolve the firstmate root\n' >&2
  exit 2
fi
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

if [ ! -r "$SCRIPT_DIR/fm-next-cache-lib.sh" ] \
  || [ ! -r "$SCRIPT_DIR/fm-secondmate-registry-lib.sh" ]; then
  printf 'fm-next-cache-sweep: required libraries are unreadable\n' >&2
  exit 2
fi
# shellcheck source=bin/fm-next-cache-lib.sh
. "$SCRIPT_DIR/fm-next-cache-lib.sh" || exit 2
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh" || exit 2

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
  local resolved platform identity device inode
  resolved=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || return 1
  platform=$(uname 2>/dev/null) || return 1
  if [ "$platform" = Darwin ]; then
    identity=$(stat -L -f '%d:%i' "$resolved" 2>/dev/null) || return 1
  else
    identity=$(stat -L -c '%d:%i' "$resolved" 2>/dev/null) || return 1
  fi
  device=${identity%%:*}
  inode=${identity#*:}
  [ "$device:$inode" = "$identity" ] || return 1
  case "$device$inode" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$identity"
}

sweep_read_text_file() {  # <path>
  python3 - "$1" <<'PY'
import os, stat, sys

flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
try:
    fd = os.open(sys.argv[1], flags)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError()
        chunks = []
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        os.close(fd)
except OSError:
    sys.exit(1)
data = b"".join(chunks)
if b"\0" in data:
    sys.exit(1)
sys.stdout.buffer.write(data)
PY
}

sweep_task_meta_files() {  # <state-dir>
  python3 - "$1" <<'PY'
import os, sys

try:
    entries = list(os.scandir(sys.argv[1]))
except OSError:
    sys.exit(1)
paths = []
for entry in entries:
    if entry.name.endswith(".meta"):
        path = entry.path
        if any(c in path for c in "\t\r\n"):
            sys.exit(1)
        paths.append(path)
for path in sorted(paths):
    print(path)
PY
}

sweep_project_directories() {  # <projects-dir>
  python3 - "$1" <<'PY'
import os, sys

try:
    entries = list(os.scandir(sys.argv[1]))
except OSError:
    sys.exit(1)
paths = []
for entry in entries:
    try:
        is_dir = entry.is_dir()
    except OSError:
        sys.exit(1)
    if is_dir:
        path = entry.path
        if any(c in path for c in "\t\r\n"):
            sys.exit(1)
        paths.append(path)
for path in sorted(paths):
    print(path)
PY
}

sweep_task_record_state_dirs() {
  local registry="$DATA/secondmates.md" registry_contents line home resolved_home resolved_state
  if ! resolved_state=$(sweep_resolve_directory "$STATE"); then
    sweep_incomplete "cannot resolve task state directory: $STATE"
    return
  fi
  case "$resolved_state" in *$'\t'*|*$'\r'*|*$'\n'*)
    sweep_incomplete "unsafe task state directory: $STATE"
    return
    ;;
  esac
  TASK_STATE_DIRS=$resolved_state
  if ! registry_contents=$(sweep_read_text_file "$registry"); then
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
          case "$home" in *$'\t'*|*$'\r'*|*$'\n'*)
            sweep_incomplete "unsafe registered local secondmate home: $home"
            return
            ;;
          esac
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
          case "$resolved_home" in *$'\t'*|*$'\r'*|*$'\n'*)
            sweep_incomplete "unsafe resolved local secondmate home: $home"
            return
            ;;
          esac
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
  local state_dir metas meta meta_contents worktree kind remote_host identity line
  local seen_worktree seen_kind seen_remote_host
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
    if ! metas=$(sweep_task_meta_files "$state_dir"); then
      sweep_incomplete "cannot enumerate task metadata in: $state_dir"
      return
    fi
    while IFS= read -r meta; do
      if [ -n "$meta" ]; then
        if ! meta_contents=$(sweep_read_text_file "$meta"); then
          sweep_incomplete "cannot read task metadata: $meta"
          return
        fi
        worktree=
        kind=
        remote_host=
        seen_worktree=0
        seen_kind=0
        seen_remote_host=0
        while IFS= read -r line || [ -n "$line" ]; do
          case "$line" in
            worktree=*)
              [ "$seen_worktree" -eq 0 ] || {
                sweep_incomplete "task metadata has duplicate worktree fields: $meta"
                return
              }
              worktree=${line#worktree=}
              seen_worktree=1
              ;;
            kind=*)
              [ "$seen_kind" -eq 0 ] || {
                sweep_incomplete "task metadata has duplicate kind fields: $meta"
                return
              }
              kind=${line#kind=}
              seen_kind=1
              ;;
            remote_host=*)
              [ "$seen_remote_host" -eq 0 ] || {
                sweep_incomplete "task metadata has duplicate remote_host fields: $meta"
                return
              }
              remote_host=${line#remote_host=}
              seen_remote_host=1
              ;;
          esac
        done <<EOT
$meta_contents
EOT
        case "$worktree" in
          ''|*$'\t'*|*$'\r'*|*$'\n'*)
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
          *$'\t'*|*$'\r'*|*$'\n'*)
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
    done <<EOT
$metas
EOT
  done <<EOT
$TASK_STATE_DIRS
EOT
}

# Does any task record name <path> as its worktree?
sweep_task_owns() {  # <path>
  local path=$1 path_identity recorded
  if [ -n "$TASK_WORKTREES" ]; then
    while IFS= read -r recorded; do
      [ "$recorded" = "$path" ] && return 0
    done <<EOT
$TASK_WORKTREES
EOT
  fi
  path_identity=$(sweep_path_identity "$path") || return 2
  if [ -n "$TASK_WORKTREE_IDENTITIES" ]; then
    while IFS= read -r recorded; do
      [ "$recorded" = "$path_identity" ] && return 0
    done <<EOT
$TASK_WORKTREE_IDENTITIES
EOT
  fi
  return 1
}

# Print "<status>\t<path>" for every worktree in <project-dir>'s pool.
# treehouse resolves the pool from the working directory, and reading pool
# status changes nothing in the clone.
sweep_pool_entries() {  # <project-dir>
  local tmp parse_status=0
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-next-cache-pool.XXXXXX" 2>/dev/null) \
    || return 1
  if ! (cd "$1" && treehouse status --json > "$tmp" 2>/dev/null); then
    rm -f -- "$tmp" || true
    return 1
  fi
  python3 - "$tmp" <<'PY' || parse_status=$?
import json, sys

# Anything this cannot read as a list of pool entries exits non-zero, so the
# caller reports the project as unreadable and sweeps none of its copies. An
# unparseable pool is not an empty pool, and it is certainly not a pool of
# unowned copies.
try:
    raw = open(sys.argv[1], "rb").read()
    if b"\0" in raw:
        raise ValueError()
    pool = json.loads(raw.decode("utf-8"))
except (OSError, UnicodeError, ValueError):
    sys.exit(1)
if not isinstance(pool, list):
    sys.exit(1)
rows = []
for entry in pool:
    if not isinstance(entry, dict):
        sys.exit(1)
    status = entry.get("status")
    path = entry.get("path")
    if not isinstance(status, str) or not status:
        sys.exit(1)
    if not isinstance(path, str) or not path or not path.startswith("/"):
        sys.exit(1)
    if any(c in status or c in path for c in "\0\t\r\n"):
        sys.exit(1)
    rows.append((status, path))
for status, path in rows:
    print("%s\t%s" % (status, path))
PY
  if ! rm -f -- "$tmp"; then return 1; fi
  return "$parse_status"
}

# Classify why <worktree> may not be swept in SWEEP_OWNER_CLASS and
# SWEEP_OWNER_REASON. `owned` is a complete answer; `undetermined` makes the
# project's preflight incomplete.
sweep_unowned_reason() {  # <status> <worktree>
  local status=$1 wt=$2 task_ownership
  SWEEP_OWNER_CLASS=free
  SWEEP_OWNER_REASON=
  # Only the pool's own word for "available" clears this check. Any other
  # value - in-use, a status this version of treehouse does not print, or none
  # at all - means ownership was not established, which is not the same as
  # establishing that there is no owner.
  if [ "$status" = in-use ]; then
    SWEEP_OWNER_CLASS=owned
    SWEEP_OWNER_REASON="in use by the pool"
    return 0
  fi
  if [ "$status" != available ]; then
    SWEEP_OWNER_CLASS=undetermined
    SWEEP_OWNER_REASON="the pool did not report it available"
    return 0
  fi
  sweep_task_owns "$wt"
  task_ownership=$?
  case "$task_ownership" in
    0)
      SWEEP_OWNER_CLASS=owned
      SWEEP_OWNER_REASON="still claimed by a task record"
      return 0
      ;;
    2)
      SWEEP_OWNER_CLASS=undetermined
      SWEEP_OWNER_REASON="cannot compare it with task-record worktrees"
      return 0
      ;;
  esac
  if ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    SWEEP_OWNER_CLASS=undetermined
    SWEEP_OWNER_REASON="not an inspectable git worktree"
    return 0
  fi
  local dirty stashes
  if ! dirty=$(git -C "$wt" status --porcelain 2>/dev/null); then
    SWEEP_OWNER_CLASS=undetermined
    SWEEP_OWNER_REASON="cannot inspect it for uncommitted changes"
    return 0
  fi
  if [ -n "$dirty" ]; then
    SWEEP_OWNER_CLASS=owned
    SWEEP_OWNER_REASON="has uncommitted changes"
    return 0
  fi
  if ! stashes=$(git -C "$wt" stash list 2>/dev/null); then
    SWEEP_OWNER_CLASS=undetermined
    SWEEP_OWNER_REASON="cannot inspect it for stashes"
    return 0
  fi
  if [ -n "$stashes" ]; then
    SWEEP_OWNER_CLASS=owned
    SWEEP_OWNER_REASON="has stashed work"
    return 0
  fi
  return 0
}

SWEEP_PROJECT_PLAN=
SWEEP_PROJECT_INSPECTED=0
sweep_project_plan() {  # <entries>
  local entries=$1 status wt record pool_identity recorded_identity
  local pool_identities=
  SWEEP_PROJECT_PLAN=
  SWEEP_PROJECT_INSPECTED=0
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
      if ! pool_identity=$(sweep_path_identity "$wt"); then
        sweep_incomplete "pool worktree identity cannot be established: $wt"
        return
      fi
      if [ -n "$pool_identities" ]; then
        while IFS= read -r recorded_identity; do
          if [ "$recorded_identity" = "$pool_identity" ]; then
            sweep_incomplete "pool entries name a duplicate filesystem copy: $wt"
            return
          fi
        done <<EOT
$pool_identities
EOT
        pool_identities="$pool_identities"$'\n'"$pool_identity"
      else
        pool_identities=$pool_identity
      fi
      sweep_unowned_reason "$status" "$wt"
      if [ "$SWEEP_OWNER_CLASS" = undetermined ]; then
        sweep_incomplete "$wt could not be assessed ($SWEEP_OWNER_REASON)"
        return
      fi
      if ! fm_next_cache_inspect "$wt"; then
        sweep_incomplete "$wt build output could not be inspected ($FM_NEXT_CACHE_INSPECTION_ERROR)"
        return
      fi
      SWEEP_PROJECT_INSPECTED=$(( SWEEP_PROJECT_INSPECTED + 1 ))
      if [ "$SWEEP_OWNER_CLASS" = owned ]; then
        record="owned"$'\t'"$SWEEP_OWNER_REASON"$'\t'"$FM_NEXT_CACHE_TOTAL_KB"$'\t'"$wt"
      else
        record="free"$'\t'"-"$'\t'"$FM_NEXT_CACHE_TOTAL_KB"$'\t'"$wt"
      fi
      if [ -n "$SWEEP_PROJECT_PLAN" ]; then
        SWEEP_PROJECT_PLAN="$SWEEP_PROJECT_PLAN"$'\n'"$record"
      else
        SWEEP_PROJECT_PLAN=$record
      fi
    fi
  done <<EOT
$entries
EOT
}

sweep_apply_project_plan() {  # <plan>
  local plan=$1 action reason planned_kb wt apply_status
  while IFS=$'\t' read -r action reason planned_kb wt; do
    if [ -n "$action" ]; then
      if [ "$action" = owned ]; then
        if [ "$planned_kb" -gt 0 ]; then
          printf 'sweep: skipped %s (%s), holding %s\n' \
            "$wt" "$reason" "$(fm_next_cache_human_kb "$planned_kb")"
          SKIPPED=$(( SKIPPED + 1 ))
        fi
      else
        apply_status=0
        if [ "$DRY_RUN" = 1 ]; then
          fm_next_cache_report "$wt" "sweep" || apply_status=$?
        else
          fm_next_cache_reclaim "$wt" "sweep" || apply_status=$?
        fi
        if [ "$apply_status" -ne 0 ]; then
          RC=1
          FAILED=$(( FAILED + 1 ))
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
  local project=$1 project_real entries
  SWEEP_PROJECT_INSPECTED=0
  SWEEP_PROJECT_COMPLETE=0
  if ! project_real=$(sweep_resolve_directory "$project"); then
    sweep_incomplete "cannot enter project: $project"
    return
  fi
  if ! git -C "$project_real" rev-parse --git-dir >/dev/null 2>&1; then
    sweep_incomplete "cannot inspect project Git metadata: $project_real"
    return
  fi
  if ! entries=$(sweep_pool_entries "$project_real"); then
    sweep_incomplete "cannot read the worktree pool for $project_real"
    return
  fi
  if ! sweep_project_plan "$entries"; then
    return 1
  fi
  sweep_apply_project_plan "$SWEEP_PROJECT_PLAN"
  SWEEP_PROJECT_COMPLETE=1
}

if [ "${#PROJECT_ARGS[@]}" -gt 0 ]; then
  TARGETS=("${PROJECT_ARGS[@]}")
else
  TARGETS=()
  if ! project_dirs=$(sweep_project_directories "$PROJECTS"); then
    sweep_die "cannot enumerate project clones under $PROJECTS"
  fi
  while IFS= read -r dir; do
    [ -n "$dir" ] && TARGETS+=("$dir")
  done <<EOT
$project_dirs
EOT
fi

[ "${#TARGETS[@]}" -gt 0 ] || sweep_die "no project clones to sweep under $PROJECTS"

sweep_load_task_worktrees || sweep_die "task-record ownership inputs are incomplete"

RC=0
TOTAL_KB=0
RECLAIMED=0
SKIPPED=0
INCOMPLETE=0
INSPECTED=0
FAILED=0
COMPLETE_PROJECTS=0
for project in "${TARGETS[@]}"; do
  sweep_project "$project"
  project_status=$?
  INSPECTED=$(( INSPECTED + SWEEP_PROJECT_INSPECTED ))
  if [ "$project_status" -ne 0 ]; then
    RC=1
    INCOMPLETE=$(( INCOMPLETE + 1 ))
  elif [ "$SWEEP_PROJECT_COMPLETE" -eq 1 ]; then
    COMPLETE_PROJECTS=$(( COMPLETE_PROJECTS + 1 ))
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

FAILED_NOTE=
if [ "$FAILED" -gt 0 ]; then
  FAILED_NOTE="; $(sweep_copies "$FAILED") could not be processed"
fi

if [ "$RECLAIMED" -eq 0 ]; then
  if [ "$FAILED" -gt 0 ]; then
    printf 'sweep: reclamation incomplete%s%s\n' "$FAILED_NOTE" "$INCOMPLETE_NOTE"
  elif [ "$SKIPPED" -gt 0 ]; then
    printf 'sweep: nothing to reclaim; %s were skipped as owned (listed above)%s\n' \
      "$(sweep_copies "$SKIPPED")" "$INCOMPLETE_NOTE"
  elif [ "$INCOMPLETE" -gt 0 ]; then
    if [ "$INSPECTED" -eq 0 ]; then
      printf 'sweep: no copy was completely inspected%s\n' "$INCOMPLETE_NOTE"
    else
      printf 'sweep: nothing to reclaim in %s%s\n' \
        "$(sweep_copies "$INSPECTED")" "$INCOMPLETE_NOTE"
    fi
  elif [ "$INSPECTED" -eq 0 ]; then
    printf 'sweep: nothing to reclaim; %s contained no copies\n' \
      "$(sweep_projects "$COMPLETE_PROJECTS")"
  else
    printf 'sweep: nothing to reclaim; no idle copy holds Next.js build output\n'
  fi
elif [ "$DRY_RUN" = 1 ]; then
  printf 'sweep: would reclaim %s from %s%s%s\n' \
    "$(fm_next_cache_human_kb "$TOTAL_KB")" "$(sweep_copies "$RECLAIMED")" \
    "$FAILED_NOTE" "$INCOMPLETE_NOTE"
else
  printf 'sweep: reclaimed %s from %s%s%s\n' \
    "$(fm_next_cache_human_kb "$TOTAL_KB")" "$(sweep_copies "$RECLAIMED")" \
    "$FAILED_NOTE" "$INCOMPLETE_NOTE"
fi

exit "$RC"
