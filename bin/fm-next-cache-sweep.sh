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
#
# INPUT COMPLETENESS INVENTORY
#
# The contract for every item below is that an absent, unreadable, malformed,
# ambiguous, or incomplete ownership input cannot produce a determinate answer.
# A global input refuses the sweep, a project input refuses that project before
# its plan is applied, and a copy input prevents that copy from authorizing any
# deletion while also making its project incomplete.
#
# Each source site is identified by file, function, and the exact statement or
# command that reads it rather than by a numeric line that this inventory itself
# would immediately invalidate. The inventory was built by tracing every
# external command and status, command substitution, filesystem predicate and
# directory entry, file parser, environment or CLI value, Python-to-shell
# boundary, and summary selector. That input-oriented trace includes implicit
# omission paths that a syntax search for `continue` cannot find.
#
# Every verdict below carries both the observation it rests on and its falsifier.
# A falsifier states the exact condition that would make the direction unsafe;
# it is not a claim that a command name alone proves the needed property.
#
# Sweep entry and global ownership inputs:
# - `bin/fm-next-cache-sweep.sh: startup -> BASH_SOURCE, FM_* overrides, cd,
#   readable library predicates, and source`. Checked: every failed directory
#   command substitution is tested, both library paths must pass `-r`, and a
#   nonzero source status exits 2 before deletion authority exists. Falsifier:
#   any failed resolution or library load reaches argument processing with exit 0.
# - `bin/fm-next-cache-sweep.sh: argument loops -> "$@"`. Checked: the option
#   case accepts only `--dry-run`, rejects every other dash-prefixed value with
#   exit 2, and retains non-options verbatim for the project-root proof. Converted
#   wrong verdict: repository reachability alone was insufficient; every retained
#   path must now physically equal its `--show-toplevel`. Falsifier: an explicit
#   subdirectory reaches pool lookup or weakens the clone-exclusion comparison.
# - `bin/fm-next-cache-sweep.sh: command preflight -> command -v treehouse and
#   python3`. Checked: absence exits 2, while every later invocation separately
#   checks the command's status. Falsifier: a missing command falls through, or a
#   found command's later nonzero status is normalized to usable output.
# - `bin/fm-next-cache-sweep.sh: sweep_task_record_state_dirs ->
#   sweep_resolve_directory "$STATE"`. Checked: physical resolution requires a
#   searchable directory and failure propagates through the checked loader to
#   `sweep_die`. Falsifier: an absent or unresolvable primary state directory
#   contributes an empty ownership set.
# - `bin/fm-next-cache-sweep.sh: sweep_task_record_state_dirs ->
#   sweep_read_text_file "$DATA/secondmates.md"`. Checked: the reader requires a
#   regular non-symlink, stages a complete byte-for-byte read, rejects NUL, and
#   propagates failure globally; the absent, unreadable, and NUL tests exercise
#   those branches. Falsifier: any registry read failure yields empty registry
#   text and task enumeration continues.
# - `bin/fm-next-cache-sweep.sh: sweep_task_record_state_dirs -> registry line
#   loop and secondmate_registry_parse_line`. Checked: every registry record is
#   defined by the shared parser's `- ` prefix; such a line must parse, local
#   homes must be absolute and physically resolvable, and remote records are
#   excluded by their explicit placement flag because they cannot own this host's
#   pool. Falsifier: a parser-recognized local record can be ignored, or a remote
#   record can name a worktree in this machine's pool.
# - `bin/fm-next-cache-sweep.sh: sweep_load_task_worktrees -> state directory
#   predicates and sweep_task_meta_files`. Checked: `-d`, `-r`, and `-x` precede
#   a Python `os.scandir` whose exceptions and unsafe names are nonzero, and every
#   nonzero status aborts the global loader. Falsifier: a missing, unreadable, or
#   partially scanned state directory is represented as containing no metadata.
# - `bin/fm-next-cache-sweep.sh: sweep_load_task_worktrees ->
#   sweep_read_text_file "$meta" and metadata field loop`. Checked: the same
#   complete reader rejects NUL, and one shell pass rejects duplicate, missing,
#   non-absolute, or invalid-placement fields before appending a worktree. This
#   replaced unchecked `sed` substitutions. Falsifier: any failed metadata read
#   or parse omits its owner while enumeration still succeeds.
# - `bin/fm-next-cache-sweep.sh: sweep_path_identity -> cd, uname, and stat -L`.
#   Checked: `cd && pwd -P` resolves the referent, `stat -L` follows a final
#   symlink on both probed platforms, and empty or non-numeric device/inode output
#   is rejected; identity-failure and symlink tests exercise the boundary.
#   Falsifier: a broken/unresolved referent or malformed stat answer is treated as
#   a distinct, usable identity.
# - `bin/fm-next-cache-sweep.sh: sweep_task_owns -> recorded paths and identities`.
#   Checked: `grep` status 0 is an exact match, 1 is the only accepted no-match,
#   and every other status is undetermined; resolved device/inode equality catches
#   alternate spellings. Falsifier: a comparison error or unresolved extant path
#   is accepted as proof that no task owns the candidate.
#
# Project discovery, pool, and candidate inputs:
# - `bin/fm-next-cache-sweep.sh: sweep_project_directories -> os.scandir and
#   entry.is_dir`. Checked: Python stages the complete immediate directory set,
#   rejects unsafe paths, and turns enumeration or entry-type exceptions into a
#   checked nonzero status; the unreadable-Git discovery test then preserves each
#   announced project for project-scoped refusal. Falsifier: a directory-entry
#   failure silently removes a project from the requested target set.
# - `bin/fm-next-cache-sweep.sh: sweep_project -> sweep_resolve_directory and Git
#   project queries`. Checked: physical entry and `git rev-parse --show-toplevel`
#   must both succeed, the answer must be safe and physically resolvable, and its
#   physical path must equal the resolved argument before pool lookup. This
#   converts the wrong `--git-dir` verdict observed from `bin/`. Falsifier: any
#   non-root argument supplies the project identity used by candidate provenance.
# - `bin/fm-next-cache-sweep.sh: sweep_pool_entries -> mktemp, treehouse status
#   --json, staged-file read, JSON decode, and temp removal`. Checked: treehouse's
#   status is captured before parsing, the file is decoded strictly as UTF-8 JSON,
#   and staging, parse, top-level-shape, or cleanup failure returns nonzero before
#   a plan exists. Falsifier: a failed or partial pool lookup supplies any
#   candidate or is summarized as an empty pool.
# - `bin/fm-next-cache-sweep.sh: sweep_pool_entries -> status and path fields`.
#   Checked: Python requires both fields to be nonempty strings, the path to be
#   absolute, and rejects NUL, tab, CR, and LF before emitting tab-delimited rows;
#   malformed-field and NUL tests exercise the boundary. Falsifier: shell capture
#   can normalize an unvalidated field into `available` or a different path.
# - `bin/fm-next-cache-sweep.sh: sweep_project_plan -> pool directory predicate,
#   sweep_path_identity, and duplicate identity scan`. Checked: `-d` is required,
#   physical device/inode identity is mandatory, and repeated identity produces
#   an undetermined assessment. The complete pool listing is counted before any
#   assessment begins. Falsifier: an absent/unresolvable path or alias duplicate
#   authorizes deletion, or an early exit can hide a later announced candidate.
# - `bin/fm-next-cache-sweep.sh: sweep_pool_worktree_provenance -> candidate root,
#   project worktree registry, and project-clone exclusion`. Checked: candidate
#   `--show-toplevel` must physically equal the candidate, the candidate identity
#   must appear exactly once in `git worktree list --porcelain -z`, and it must
#   differ from the supplied project identity. The supplied identity is now first
#   proven to be the project root, converting the earlier wrong evidence chain.
#   Falsifier: either root proof can be bypassed, or the linked-worktree registry
#   can be incomplete while verification succeeds.
# - `bin/fm-next-cache-sweep.sh: sweep_unowned_reason -> pool status`. Checked:
#   only byte-exact `available` proceeds, `in-use` records ownership, and every
#   other value records undetermined. Falsifier: any unknown or malformed status
#   reaches clean-tree inspection as though availability were proven.
# - `bin/fm-next-cache-sweep.sh: sweep_unowned_reason -> git status --porcelain
#   and git stash list`. Checked: each command substitution is status-checked,
#   nonempty status or stash output records ownership, and failure records
#   undetermined. Falsifier: Git failure or returned work is classified free.
# - `bin/fm-next-cache-sweep.sh: sweep_project_plan -> fm_next_cache_inspect and
#   FM_NEXT_CACHE_* outputs`. Checked: the inspection status is checked before
#   size and plan values are consumed, so failed discovery, eligibility, or
#   measurement produces an undetermined assessment. Every candidate is assessed
#   before project refusal is applied. Falsifier: incomplete inspection supplies
#   a zero-size/free row or prevents a later announced path receiving an assessment.
#
# Shared build-output discovery and removal inputs:
# - `bin/fm-next-cache-lib.sh: fm_next_cache_size_kb -> du -sk`. Checked: only a
#   zero-status command with leading decimal digits followed by a separator is
#   emitted; failure and malformed output are nonzero, as the size-failure test
#   observes. Falsifier: failed or malformed measurement becomes numeric zero.
# - `bin/fm-next-cache-lib.sh: fm_next_cache_parent_is_next_app -> next.config.*
#   and package.json predicates plus grep`. Checked: a regular config is positive,
#   absent files or grep status 1 are negative, and every other grep status is
#   undetermined. A negative cannot authorize deletion because callers require
#   positive app evidence. Falsifier: an inspection error returns the same status
#   as a proven app and lets the directory qualify.
# - `bin/fm-next-cache-lib.sh: fm_next_cache_is_build_output -> path existence,
#   directory and symlink predicates, physical resolution, containment, git
#   check-ignore, and app-root result`. Checked: only a real nonsymlink directory
#   physically below the supplied root with check-ignore status 0 and app status
#   0 qualifies; proven negatives return 1 and failures return 2. Falsifier: any
#   unresolved, external, symlinked, unignored, or unproven-app path returns 0.
# - `bin/fm-next-cache-lib.sh: fm_next_cache_inspect -> worktree cd and git
#   rev-parse --git-dir`. Checked: entry and Git failure set a named inspection
#   error and return nonzero; `--git-dir` is needed here only to prove a repository
#   is reachable because the sweep separately proves candidate-root provenance
#   and teardown supplies its task worktree. Falsifier: this library answer is
#   itself used to prove that an arbitrary caller path is a worktree root.
# - `bin/fm-next-cache-lib.sh: fm_next_cache_inspect -> mktemp, find -print0,
#   NUL-delimited read, and temp removal`. Checked: the complete `find` status is
#   captured before parsing, documented `-print0` records are path-validated, and
#   any staging, walk, eligibility, measurement, or cleanup failure clears the
#   accumulated plan and returns nonzero. Falsifier: a successful `find -print0`
#   violates its NUL-record contract, or any checked nonzero path leaves a partial
#   plan usable by report or reclaim.
# - `bin/fm-next-cache-lib.sh: fm_next_cache_report and fm_next_cache_reclaim ->
#   plan rows and fm_next_cache_human_kb`. Checked: only inspect-generated numeric
#   size/path rows reach formatting, and repeated inspection or numeric validation
#   failure returns nonzero to the sweep. Falsifier: malformed plan data prints a
#   success or contributes a total.
# - `bin/fm-next-cache-lib.sh: fm_next_cache_reclaim -> rm -rf and post-removal
#   existence predicates`. Checked: bytes are added only after `rm` status 0 and
#   both `-e` and `-L` confirm absence; otherwise the exact path is reported and
#   status is nonzero. Falsifier: a remaining directory or link contributes
#   reclaimed bytes or a successful outcome.
#
# Outcome and summary inputs:
# - `bin/fm-next-cache-sweep.sh: sweep_apply_project_plan -> report or reclaim
#   status and FM_NEXT_CACHE_TOTAL_KB`. Checked: both dry-run and removal statuses
#   are captured and routed through the one terminal-verdict recorder; failed
#   paths become named `failed` verdicts and only ledger-recorded measured work
#   contributes totals. Falsifier: an apply result changes a summary counter
#   without first appending exactly one candidate verdict.
# - `bin/fm-next-cache-sweep.sh: sweep_project_plan, sweep_project, project loop,
#   and final summary -> announced candidates and final verdicts`. Checked: project
#   plans remain atomic, the complete pool list announces indexed candidates
#   before assessment, and one ledger records `reclaimed`, `skipped-as-owned`,
#   `undetermined`, `refused`, or `failed`. Per-project reconciliation proves each
#   index occurs once; run reconciliation gates every clean summary. This converts
#   the wrong early-return verdict. Falsifier: an announced index has zero or two
#   terminal records, or any summary counter changes outside the ledger recorder.
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

sweep_pool_worktree_provenance() {  # <project-dir> <worktree>
  local project=$1 wt=$2 wt_real top top_real tmp verify_status=0
  SWEEP_POOL_PROVENANCE_REASON=
  if ! wt_real=$(sweep_resolve_directory "$wt"); then
    SWEEP_POOL_PROVENANCE_REASON="not an inspectable git worktree"
    return 1
  fi
  if ! top=$(git -C "$wt_real" rev-parse --show-toplevel 2>/dev/null); then
    SWEEP_POOL_PROVENANCE_REASON="not an inspectable git worktree"
    return 1
  fi
  case "$top" in
    ''|*$'\t'*|*$'\r'*|*$'\n'*)
      SWEEP_POOL_PROVENANCE_REASON="worktree root is malformed"
      return 1
      ;;
  esac
  if ! top_real=$(sweep_resolve_directory "$top"); then
    SWEEP_POOL_PROVENANCE_REASON="worktree root cannot be resolved"
    return 1
  fi
  if [ "$top_real" != "$wt_real" ]; then
    SWEEP_POOL_PROVENANCE_REASON="pool path is not a worktree root"
    return 1
  fi
  if ! tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-next-cache-worktrees.XXXXXX" 2>/dev/null); then
    SWEEP_POOL_PROVENANCE_REASON="cannot stage the project's worktree registry"
    return 1
  fi
  if ! git -C "$project" worktree list --porcelain -z > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp" || true
    SWEEP_POOL_PROVENANCE_REASON="cannot read the project's worktree registry"
    return 1
  fi
  python3 - "$tmp" "$wt_real" "$project" <<'PY' || verify_status=$?
import os, sys

try:
    raw = open(sys.argv[1], "rb").read()
    candidate = os.stat(sys.argv[2])
    project = os.stat(sys.argv[3])
except OSError:
    sys.exit(1)
candidate_id = (candidate.st_dev, candidate.st_ino)
project_id = (project.st_dev, project.st_ino)
if candidate_id == project_id or not raw.endswith(b"\0\0"):
    sys.exit(1)
records = raw[:-2].split(b"\0\0")
if not records or any(not record for record in records):
    sys.exit(1)
seen = set()
matches = 0
for record in records:
    fields = record.split(b"\0")
    worktrees = [field[len(b"worktree "):] for field in fields
                 if field.startswith(b"worktree ")]
    if len(worktrees) != 1 or not worktrees[0] or fields[0] != b"worktree " + worktrees[0]:
        sys.exit(1)
    try:
        info = os.stat(worktrees[0])
    except OSError:
        sys.exit(1)
    identity = (info.st_dev, info.st_ino)
    if identity in seen:
        sys.exit(1)
    seen.add(identity)
    if identity == candidate_id:
        matches += 1
if matches != 1:
    sys.exit(1)
PY
  if ! rm -f -- "$tmp"; then
    SWEEP_POOL_PROVENANCE_REASON="cannot clear the project's worktree registry state"
    return 1
  fi
  if [ "$verify_status" -ne 0 ]; then
    SWEEP_POOL_PROVENANCE_REASON="not a linked worktree registered to this project"
    return 1
  fi
  return 0
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
SWEEP_PROJECT_ANNOUNCED=0
SWEEP_PROJECT_ASSESSED=0
SWEEP_PROJECT_VERDICTS=0
SWEEP_PROJECT_VERDICT_IDS=

sweep_add_project_assessment() {  # <candidate-id> <action> <reason> <kb> <worktree>
  local candidate_id=$1 action=$2 reason=$3 kb=$4 wt=$5 record
  case "$candidate_id" in ''|*[!0-9]*) return 1 ;; esac
  case "$action" in owned|free|undetermined) ;; *) return 1 ;; esac
  case "$kb" in -) ;; ''|*[!0-9]*) return 1 ;; esac
  case "$reason$wt" in *$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  record="$candidate_id"$'\t'"$action"$'\t'"$reason"$'\t'"$kb"$'\t'"$wt"
  if [ -n "$SWEEP_PROJECT_PLAN" ]; then
    SWEEP_PROJECT_PLAN="$SWEEP_PROJECT_PLAN"$'\n'"$record"
  else
    SWEEP_PROJECT_PLAN=$record
  fi
  SWEEP_PROJECT_ASSESSED=$(( SWEEP_PROJECT_ASSESSED + 1 ))
}

sweep_record_candidate_verdict() {  # <project> <candidate-id> <verdict> <reason> <kb> <worktree>
  local project=$1 candidate_id=$2 verdict=$3 reason=$4 kb=$5 wt=$6
  local recorded_id record human
  case "$candidate_id" in ''|*[!0-9]*) return 1 ;; esac
  case "$verdict" in
    reclaimed|skipped-as-owned|undetermined|refused|failed) ;;
    *) return 1 ;;
  esac
  case "$kb" in -) ;; ''|*[!0-9]*) return 1 ;; esac
  case "$project$reason$wt" in *$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  if [ "$verdict" = skipped-as-owned ] && [ "$kb" -gt 0 ]; then
    human=$(fm_next_cache_human_kb "$kb") || return 1
  fi
  if [ -n "$SWEEP_PROJECT_VERDICT_IDS" ]; then
    while IFS= read -r recorded_id; do
      [ "$recorded_id" = "$candidate_id" ] && return 1
    done <<EOT
$SWEEP_PROJECT_VERDICT_IDS
EOT
    SWEEP_PROJECT_VERDICT_IDS="$SWEEP_PROJECT_VERDICT_IDS"$'\n'"$candidate_id"
  else
    SWEEP_PROJECT_VERDICT_IDS=$candidate_id
  fi
  record="$project"$'\t'"$candidate_id"$'\t'"$verdict"$'\t'"$reason"$'\t'"$kb"$'\t'"$wt"
  if [ -n "$CANDIDATE_LEDGER" ]; then
    CANDIDATE_LEDGER="$CANDIDATE_LEDGER"$'\n'"$record"
  else
    CANDIDATE_LEDGER=$record
  fi
  SWEEP_PROJECT_VERDICTS=$(( SWEEP_PROJECT_VERDICTS + 1 ))
  CANDIDATE_VERDICTS=$(( CANDIDATE_VERDICTS + 1 ))
  case "$verdict" in
    reclaimed) ;;
    skipped-as-owned)
      if [ "$kb" -gt 0 ]; then
        printf 'sweep: skipped-as-owned %s (%s), holding %s\n' \
          "$wt" "$reason" "$human"
      fi
      ;;
    undetermined)
      printf 'sweep: undetermined %s (%s)\n' "$wt" "$reason" >&2
      ;;
    refused)
      printf 'sweep: refused %s (%s)\n' "$wt" "$reason" >&2
      ;;
    failed)
      printf 'sweep: failed %s (%s)\n' "$wt" "$reason" >&2
      ;;
  esac
}

sweep_summarize_candidate_ledger() {
  local project candidate_id verdict reason kb wt rows=0
  TOTAL_KB=0
  RECLAIMED=0
  SKIPPED=0
  INSPECTED=0
  FAILED=0
  if [ -n "$CANDIDATE_LEDGER" ]; then
    while IFS=$'\t' read -r project candidate_id verdict reason kb wt; do
      case "$project$reason$wt" in *$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
      case "$candidate_id" in ''|*[!0-9]*) return 1 ;; esac
      case "$kb" in -) ;; ''|*[!0-9]*) return 1 ;; esac
      rows=$(( rows + 1 ))
      case "$verdict" in
        reclaimed)
          [ "$kb" = - ] && return 1
          INSPECTED=$(( INSPECTED + 1 ))
          if [ "$kb" -gt 0 ]; then
            TOTAL_KB=$(( TOTAL_KB + kb ))
            RECLAIMED=$(( RECLAIMED + 1 ))
          fi
          ;;
        skipped-as-owned)
          [ "$kb" = - ] && return 1
          INSPECTED=$(( INSPECTED + 1 ))
          [ "$kb" -gt 0 ] && SKIPPED=$(( SKIPPED + 1 ))
          ;;
        undetermined|refused)
          ;;
        failed)
          [ "$kb" = - ] && return 1
          INSPECTED=$(( INSPECTED + 1 ))
          FAILED=$(( FAILED + 1 ))
          if [ "$kb" -gt 0 ]; then
            TOTAL_KB=$(( TOTAL_KB + kb ))
            RECLAIMED=$(( RECLAIMED + 1 ))
          fi
          ;;
        *) return 1 ;;
      esac
    done <<EOT
$CANDIDATE_LEDGER
EOT
  fi
  [ "$rows" -eq "$CANDIDATE_VERDICTS" ]
}

sweep_reconcile_project_verdicts() {  # <project>
  local project=$1 expected recorded matches
  if [ "$SWEEP_PROJECT_VERDICTS" -ne "$SWEEP_PROJECT_ANNOUNCED" ]; then
    sweep_incomplete "candidate verdict reconciliation failed for $project ($SWEEP_PROJECT_ANNOUNCED announced, $SWEEP_PROJECT_VERDICTS recorded)"
    return
  fi
  expected=1
  while [ "$expected" -le "$SWEEP_PROJECT_ANNOUNCED" ]; do
    matches=0
    if [ -n "$SWEEP_PROJECT_VERDICT_IDS" ]; then
      while IFS= read -r recorded; do
        [ "$recorded" = "$expected" ] && matches=$(( matches + 1 ))
      done <<EOT
$SWEEP_PROJECT_VERDICT_IDS
EOT
    fi
    if [ "$matches" -ne 1 ]; then
      sweep_incomplete "candidate verdict reconciliation failed for $project (candidate $expected has $matches verdicts)"
      return
    fi
    expected=$(( expected + 1 ))
  done
}

sweep_project_plan() {  # <project> <entries>
  local project=$1 entries=$2 status wt pool_identity recorded_identity
  local candidate_id=0 action reason kb duplicate record_error=0 project_refused=0
  local pool_identities=
  SWEEP_PROJECT_PLAN=
  SWEEP_PROJECT_ANNOUNCED=0
  SWEEP_PROJECT_ASSESSED=0
  SWEEP_PROJECT_VERDICTS=0
  SWEEP_PROJECT_VERDICT_IDS=
  while IFS=$'\t' read -r status wt; do
    if [ -n "$status$wt" ]; then
      SWEEP_PROJECT_ANNOUNCED=$(( SWEEP_PROJECT_ANNOUNCED + 1 ))
      CANDIDATE_ANNOUNCED=$(( CANDIDATE_ANNOUNCED + 1 ))
    fi
  done <<EOT
$entries
EOT
  while IFS=$'\t' read -r status wt; do
    if [ -n "$status$wt" ]; then
      candidate_id=$(( candidate_id + 1 ))
      action=undetermined
      reason=
      kb=-
      if [ -z "$status" ] || [ -z "$wt" ]; then
        reason="pool entry did not yield a complete status and path"
      elif [ ! -d "$wt" ]; then
        reason="pool worktree is not an inspectable directory"
      elif ! pool_identity=$(sweep_path_identity "$wt"); then
        reason="pool worktree identity cannot be established"
      elif ! sweep_pool_worktree_provenance "$project" "$wt"; then
        reason="pool provenance could not be established: $SWEEP_POOL_PROVENANCE_REASON"
      else
        duplicate=0
        if [ -n "$pool_identities" ]; then
          while IFS= read -r recorded_identity; do
            [ "$recorded_identity" = "$pool_identity" ] && duplicate=1
          done <<EOT
$pool_identities
EOT
        fi
        if [ "$duplicate" -eq 1 ]; then
          reason="pool entries name a duplicate filesystem copy"
        else
          if [ -n "$pool_identities" ]; then
            pool_identities="$pool_identities"$'\n'"$pool_identity"
          else
            pool_identities=$pool_identity
          fi
          sweep_unowned_reason "$status" "$wt"
          if [ "$SWEEP_OWNER_CLASS" = undetermined ]; then
            reason=$SWEEP_OWNER_REASON
          elif ! fm_next_cache_inspect "$wt"; then
            reason="build output could not be inspected: $FM_NEXT_CACHE_INSPECTION_ERROR"
          else
            kb=$FM_NEXT_CACHE_TOTAL_KB
            if [ "$SWEEP_OWNER_CLASS" = owned ]; then
              action=owned
              reason=$SWEEP_OWNER_REASON
            else
              action=free
              reason=-
            fi
          fi
        fi
      fi
      if ! sweep_add_project_assessment \
        "$candidate_id" "$action" "$reason" "$kb" "$wt"; then
        record_error=1
      fi
      [ "$action" = undetermined ] && project_refused=1
    fi
  done <<EOT
$entries
EOT
  if [ "$record_error" -ne 0 ] \
    || [ "$SWEEP_PROJECT_ASSESSED" -ne "$SWEEP_PROJECT_ANNOUNCED" ]; then
    sweep_incomplete "candidate assessment reconciliation failed for $project ($SWEEP_PROJECT_ANNOUNCED announced, $SWEEP_PROJECT_ASSESSED assessed)"
    return
  fi
  if [ "$project_refused" -eq 1 ]; then
    while IFS=$'\t' read -r candidate_id action reason kb wt; do
      if [ -n "$candidate_id" ]; then
        if [ "$action" = undetermined ]; then
          sweep_record_candidate_verdict \
            "$project" "$candidate_id" undetermined "$reason" "$kb" "$wt" \
            || record_error=1
        else
          sweep_record_candidate_verdict \
            "$project" "$candidate_id" refused \
            "another pool candidate made project preflight incomplete" "$kb" "$wt" \
            || record_error=1
        fi
      fi
    done <<EOT
$SWEEP_PROJECT_PLAN
EOT
    if [ "$record_error" -ne 0 ]; then
      sweep_incomplete "candidate verdict could not be recorded for $project"
      return
    fi
    sweep_reconcile_project_verdicts "$project" || return 1
    sweep_incomplete "one or more announced pool candidates could not be fully assessed for $project"
    return
  fi
}

sweep_apply_project_plan() {  # <project> <plan>
  local project=$1 plan=$2 candidate_id action reason planned_kb wt apply_status
  local record_error=0
  while IFS=$'\t' read -r candidate_id action reason planned_kb wt; do
    if [ -n "$candidate_id" ]; then
      if [ "$action" = owned ]; then
        sweep_record_candidate_verdict \
          "$project" "$candidate_id" skipped-as-owned "$reason" "$planned_kb" "$wt" \
          || record_error=1
      elif [ "$action" = free ]; then
        apply_status=0
        if [ "$DRY_RUN" = 1 ]; then
          fm_next_cache_report "$wt" "sweep" || apply_status=$?
        else
          fm_next_cache_reclaim "$wt" "sweep" || apply_status=$?
        fi
        if [ "$apply_status" -ne 0 ]; then
          sweep_record_candidate_verdict \
            "$project" "$candidate_id" failed \
            "build output could not be processed" "$FM_NEXT_CACHE_TOTAL_KB" "$wt" \
            || record_error=1
        else
          sweep_record_candidate_verdict \
            "$project" "$candidate_id" reclaimed - "$FM_NEXT_CACHE_TOTAL_KB" "$wt" \
            || record_error=1
        fi
      else
        sweep_record_candidate_verdict \
          "$project" "$candidate_id" failed "candidate plan is invalid" 0 "$wt" \
          || record_error=1
      fi
    fi
  done <<EOT
$plan
EOT
  [ "$record_error" -eq 0 ]
}

sweep_project() {  # <project>
  local project=$1 project_real project_top project_top_real entries
  SWEEP_PROJECT_ANNOUNCED=0
  SWEEP_PROJECT_ASSESSED=0
  SWEEP_PROJECT_VERDICTS=0
  SWEEP_PROJECT_VERDICT_IDS=
  SWEEP_PROJECT_COMPLETE=0
  if ! project_real=$(sweep_resolve_directory "$project"); then
    sweep_incomplete "cannot enter project: $project"
    return
  fi
  if ! project_top=$(git -C "$project_real" rev-parse --show-toplevel 2>/dev/null); then
    sweep_incomplete "cannot inspect project Git metadata: $project_real"
    return
  fi
  case "$project_top" in
    ''|*$'\t'*|*$'\r'*|*$'\n'*)
      sweep_incomplete "project root is malformed for: $project_real"
      return
      ;;
  esac
  if ! project_top_real=$(sweep_resolve_directory "$project_top"); then
    sweep_incomplete "cannot resolve project root for: $project_real"
    return
  fi
  if [ "$project_top_real" != "$project_real" ]; then
    sweep_incomplete "project path is not a project root: $project_real"
    return
  fi
  if ! entries=$(sweep_pool_entries "$project_real"); then
    sweep_incomplete "cannot read the worktree pool for $project_real"
    return
  fi
  if ! sweep_project_plan "$project_real" "$entries"; then
    return 1
  fi
  if ! sweep_apply_project_plan "$project_real" "$SWEEP_PROJECT_PLAN"; then
    sweep_reconcile_project_verdicts "$project_real" || true
    sweep_incomplete "candidate verdict could not be recorded for $project_real"
    return
  fi
  sweep_reconcile_project_verdicts "$project_real" || return 1
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
CANDIDATE_LEDGER=
CANDIDATE_ANNOUNCED=0
CANDIDATE_VERDICTS=0
for project in "${TARGETS[@]}"; do
  sweep_project "$project"
  project_status=$?
  if [ "$project_status" -ne 0 ]; then
    RC=1
    INCOMPLETE=$(( INCOMPLETE + 1 ))
  elif [ "$SWEEP_PROJECT_COMPLETE" -eq 1 ]; then
    COMPLETE_PROJECTS=$(( COMPLETE_PROJECTS + 1 ))
  else
    RC=1
    INCOMPLETE=$(( INCOMPLETE + 1 ))
  fi
done

LEDGER_INCOMPLETE=0
if ! sweep_summarize_candidate_ledger; then
  printf 'sweep: incomplete candidate verdict ledger: malformed terminal record\n' >&2
  RC=1
  LEDGER_INCOMPLETE=1
fi
if [ "$CANDIDATE_VERDICTS" -ne "$CANDIDATE_ANNOUNCED" ]; then
  printf 'sweep: incomplete candidate verdict ledger: %d announced, %d recorded\n' \
    "$CANDIDATE_ANNOUNCED" "$CANDIDATE_VERDICTS" >&2
  RC=1
  LEDGER_INCOMPLETE=1
fi
if [ "$FAILED" -gt 0 ]; then RC=1; fi

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
if [ "$LEDGER_INCOMPLETE" -ne 0 ]; then
  INCOMPLETE_NOTE="$INCOMPLETE_NOTE; candidate verdicts were incomplete ($CANDIDATE_ANNOUNCED announced, $CANDIDATE_VERDICTS recorded)"
fi

FAILED_NOTE=
if [ "$FAILED" -gt 0 ]; then
  FAILED_NOTE="; $(sweep_copies "$FAILED") could not be processed"
fi

RUN_COMPLETE=0
if [ "$INCOMPLETE" -eq 0 ] && [ "$FAILED" -eq 0 ] \
  && [ "$LEDGER_INCOMPLETE" -eq 0 ] \
  && [ "$COMPLETE_PROJECTS" -eq "${#TARGETS[@]}" ]; then
  RUN_COMPLETE=1
fi

if [ "$RUN_COMPLETE" -eq 0 ]; then
  if [ "$DRY_RUN" = 1 ] && [ "$RECLAIMED" -gt 0 ]; then
    printf 'sweep: would reclaim %s from %s, but inspection was incomplete%s%s\n' \
      "$(fm_next_cache_human_kb "$TOTAL_KB")" "$(sweep_copies "$RECLAIMED")" \
      "$FAILED_NOTE" "$INCOMPLETE_NOTE"
  elif [ "$RECLAIMED" -gt 0 ]; then
    printf 'sweep: reclaimed %s from %s, but processing was incomplete%s%s\n' \
      "$(fm_next_cache_human_kb "$TOTAL_KB")" "$(sweep_copies "$RECLAIMED")" \
      "$FAILED_NOTE" "$INCOMPLETE_NOTE"
  else
    printf 'sweep: reclamation incomplete%s%s\n' "$FAILED_NOTE" "$INCOMPLETE_NOTE"
  fi
elif [ "$RECLAIMED" -eq 0 ]; then
  if [ "$SKIPPED" -gt 0 ]; then
    printf 'sweep: nothing to reclaim; %s were skipped as owned (listed above)%s\n' \
      "$(sweep_copies "$SKIPPED")" "$INCOMPLETE_NOTE"
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
