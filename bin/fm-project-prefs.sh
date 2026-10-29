#!/usr/bin/env bash
# Resolve and print per-project captain preferences from the active home's
# data/captain-projects/<project>.md.
#
# A project-only preference belongs in that file instead of data/captain.md, so
# only work on that project pays for it: the file is never printed by session
# start and never counts toward the startup memory budget. Every path that acts
# on the project reads it through this script instead, which keeps one reader and
# one name rule: bin/fm-brief.sh prints it while scaffolding a ship or scout
# brief, bin/fm-spawn.sh names it at dispatch, bin/fm-review-diff.sh prints it
# before a review, and bin/fm-pr-merge.sh and bin/fm-merge-local.sh print it to
# stderr before they merge (a failed read there only warns and never changes the
# merge). The ship-landing skill covers the merge decision. docs/configuration.md
# owns the file's layout and the knowledge-routing rule.
#
# <project> is the registry name, the same value as the projects/<name> clone
# directory that bin/fm-brief.sh and bin/fm-spawn.sh take. A name that cannot be
# one plain file name (empty, containing a slash or a control character, or "."
# or "..") has no preferences file, so it reads as a project without one rather
# than refusing work on it. Spaces, a leading dot or dash, and non-ASCII bytes
# are allowed, as in the registry.
#
# Usage: fm-project-prefs.sh show <project>
#        fm-project-prefs.sh show --task <task-id>
#        fm-project-prefs.sh path <project>
#   show prints the file under a one-line header naming the project and path, so
#   the rules cannot be mistaken for cross-project preferences. A project with no
#   file prints nothing and exits 0, because most projects have none.
#   show --task resolves the project from the task's state/<id>.meta project= line
#   (its directory name), for the review and landing paths that hold a task id.
#   path prints the file's path and exits 0 when the file exists, and exits 1
#   silently when it does not.
# A file that exists but is not a readable regular file, or whose directory is a
# symlink, exits 3 naming the path, so a project's rules are never silently
# skipped. Exit 2 is a usage error, and show --task exits 1 when the task record
# is missing or has no project=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PREFS_DIR="$DATA/captain-projects"

project_name_valid() {
  local name=${1-} LC_ALL=C
  case "$name" in
    ''|.|..|*/*|*[[:cntrl:]]*) return 1 ;;
  esac
}

# Prints the file path when it exists. Returns 1 when it is absent, including for
# a name that cannot name a file, and 3 when it exists but cannot be trusted as a
# regular file, after naming the path.
prefs_file_for() {
  local name=$1 file
  project_name_valid "$name" || return 1
  if [ -L "$PREFS_DIR" ] || { [ -e "$PREFS_DIR" ] && [ ! -d "$PREFS_DIR" ]; }; then
    echo "error: $PREFS_DIR must be a plain directory" >&2
    return 3
  fi
  file="$PREFS_DIR/$name.md"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 1
  fi
  if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: $file must be a readable regular file" >&2
    return 3
  fi
  printf '%s\n' "$file"
}

cmd_show() {
  local name file rc=0 meta proj
  if [ "${1:-}" = "--task" ]; then
    [ "$#" -eq 2 ] || { usage >&2; return 2; }
    fm_pr_task_id_valid "$2" || { echo "error: invalid task id" >&2; return 2; }
    meta="$STATE/$2.meta"
    [ -f "$meta" ] || { echo "error: no meta for task $2 at $meta" >&2; return 1; }
    proj=$(grep '^project=' "$meta" | tail -1 | cut -d= -f2- || true)
    [ -n "$proj" ] || { echo "error: meta for task $2 is missing project=" >&2; return 1; }
    name=$(basename "$proj")
  else
    [ "$#" -eq 1 ] || { usage >&2; return 2; }
    name=$1
  fi
  file=$(prefs_file_for "$name") || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) return "$rc" ;;
  esac
  printf '== Per-project captain preferences for %s (%s) - apply to every brief, dispatch, review, and merge for this project ==\n' "$name" "$file"
  cat "$file" || return 3
  printf '== End per-project captain preferences for %s ==\n' "$name"
}

cmd_path() {
  local file rc=0
  [ "$#" -eq 1 ] || { usage >&2; return 2; }
  file=$(prefs_file_for "$1") || rc=$?
  case "$rc" in
    0) printf '%s\n' "$file" ;;
    1) return 1 ;;
    *) return "$rc" ;;
  esac
}

sub=${1:-}
[ "$#" -eq 0 ] || shift
case "$sub" in
  show) cmd_show "$@" ;;
  path) cmd_path "$@" ;;
  *) usage >&2; exit 2 ;;
esac
