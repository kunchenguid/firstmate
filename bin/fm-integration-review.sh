#!/usr/bin/env bash
# Merge a set of individually-green PRs against one project in a disposable
# worktree, in a declared dependency order, and run the project's real test
# suite after each merge. This is the standing fix for the finding that
# isolated per-crewmate gates (each PR validated alone via no-mistakes) cannot
# by themselves prove that N independently-green PRs actually compose - a
# real cross-PR NameError shipped past four independent per-PR gates in the
# 2026-07-21 sdlc-demo run before a dedicated review pass caught it.
#
# This script is the artifact-producing half of that fix: given an explicit
# PR list and dependency order, it produces a disposable merge-train branch
# and a saved, reproducible test transcript. It does not decide whether the
# result is acceptable and it never merges anything to the project's default
# branch - that decision belongs to the captain, informed by this script's
# output, per the milestone-integration-review skill.
#
# Usage:
#   fm-integration-review.sh <project-dir-or-name> <test-command> <pr-number>...
#
# <project-dir-or-name> resolves the same way fm-fleet-sync.sh resolves it:
#   a path (absolute or relative to caller's cwd), or a bare "<name>" /
#   "projects/<name>" form resolved against this home's projects dir
#   ($FM_HOME/projects, or $FM_PROJECTS_OVERRIDE).
# <test-command> is run verbatim (via `sh -c`) after each merge step, from the
#   worktree root - e.g. "python3 -m pytest tests/ -q" or "npm test".
# <pr-number>... is the ordered list of PR numbers to merge, in the order to
#   merge them - the caller (a milestone-integration-review dispatch, or the
#   captain) decides that order; this script does not infer dependencies.
#
# On any merge conflict, the script stops and reports it rather than
# resolving it - conflict resolution across independently-built PRs requires
# understanding what each side intended, which is exactly the judgment this
# script is not meant to automate. Re-run after a human or a dispatched
# crewmate resolves the conflict on the merge-train branch directly.
#
# Output: a transcript on stdout (safe to redirect - `tee` it to a saved file
# for the same durable-evidence reason `verify-49-tests.txt` exists in the
# 2026-07-21 run: a captain-facing "N/N passing" claim needs a reproducible
# artifact behind it, not prose). Exit 0 iff every merge was clean and every
# test-command run exited 0. The worktree is left in place on both success and
# failure for inspection; nothing is torn down automatically.
set -eu

usage() {
  awk '/^# Usage:/{f=1} f{print substr($0,3)} /^set -eu/{exit}' "$0"
  exit "${1:-0}"
}

[ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] && usage 0
[ $# -ge 3 ] || {
  echo "error: need <project-dir-or-name> <test-command> <pr-number>..." >&2
  usage 1
}

PROJECT_ARG=$1
TEST_CMD=$2
shift 2
PR_NUMBERS=("$@")

# Resolve the project directory the same way fm-fleet-sync.sh does.
resolve_project_dir() {
  local arg=$1
  case "$arg" in
    /*) printf '%s\n' "$arg"; return 0 ;;
  esac
  local projects_root="${FM_PROJECTS_OVERRIDE:-${FM_HOME:-}/projects}"
  local name=$arg
  case "$arg" in
    projects/*) name=${arg#projects/} ;;
  esac
  if [ -n "$projects_root" ] && [ -d "$projects_root/$name" ]; then
    printf '%s\n' "$projects_root/$name"
    return 0
  fi
  if [ -d "$arg" ]; then
    printf '%s\n' "$(cd "$arg" && pwd)"
    return 0
  fi
  echo "error: cannot resolve project '$arg' (checked '$projects_root/$name' and cwd-relative path)" >&2
  return 1
}

PROJECT_DIR=$(resolve_project_dir "$PROJECT_ARG")
[ -d "$PROJECT_DIR/.git" ] || { echo "error: '$PROJECT_DIR' is not a git repo" >&2; exit 1; }

REMOTE_URL=$(git -C "$PROJECT_DIR" remote get-url origin)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-integration-review.XXXXXX")
trap 'echo "worktree left at: $WORK"' EXIT

echo "=== fm-integration-review: $PROJECT_ARG, PRs: ${PR_NUMBERS[*]} ==="
echo "=== cloning fresh into $WORK/repo ==="
git clone -q "$REMOTE_URL" "$WORK/repo"
cd "$WORK/repo"

FETCH_REFSPECS=()
BRANCH_NAMES=()
for pr in "${PR_NUMBERS[@]}"; do
  FETCH_REFSPECS+=("pull/$pr/head:pr$pr")
  BRANCH_NAMES+=("pr$pr")
done

echo "=== fetching PR heads: ${FETCH_REFSPECS[*]} ==="
git fetch -q origin "${FETCH_REFSPECS[@]}"

BASE=$(git merge-base main "${BRANCH_NAMES[0]}")
echo "=== base: $BASE ==="
git checkout -q -b integration-review-train "$BASE"

echo "--- baseline ($BASE) ---"
sh -c "$TEST_CMD"

for i in "${!BRANCH_NAMES[@]}"; do
  pr=${PR_NUMBERS[$i]}
  branch=${BRANCH_NAMES[$i]}
  echo "=== merging PR #$pr ($branch) ==="
  if ! git merge -q --no-edit "$branch"; then
    echo "CONFLICT merging PR #$pr - stopping. Resolve on branch integration-review-train in $WORK/repo and re-run the test command manually; this script does not auto-resolve conflicts." >&2
    exit 2
  fi
  echo "--- test after PR #$pr ---"
  sh -c "$TEST_CMD"
done

echo "=== all ${#PR_NUMBERS[@]} PRs merged clean, tests green after every step ==="
echo "worktree: $WORK/repo (left in place; nothing pushed, nothing merged to $PROJECT_ARG)"
