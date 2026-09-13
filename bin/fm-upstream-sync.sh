#!/usr/bin/env bash
# Sync upstream changes into the fork repository.
#
# Fetches remotes `origin` (the fork) and `upstream` (the source of truth).
#
# Usage:
#   fm-upstream-sync.sh [--check] [--no-pr] [--help]
#
# Flags:
#   --check    fetch both remotes; if upstream/main is not an ancestor of
#              origin/main, print exactly one line:
#                "upstream: N new commits not in origin/main"
#              If up to date, print nothing. Exit 0 either way. Usable as a
#              custom watcher state check (fast, silent when no action needed).
#   --no-pr    perform the sync and run tests, but stop after tests pass without
#              pushing or creating a pull request.
#   --help, -h show this usage and exit 0.
#
# Default run:
#   1. Check that remotes `origin` and `upstream` are configured; refuse clearly
#      if either remote is missing.
#   2. Fetch both remotes. If origin/main already contains upstream/main, report
#      up to date and exit 0.
#   3. Create a disposable git worktree under ${TMPDIR} on branch
#      fm/upstream-sync-<YYYY-MM-DD> branched from origin/main.
#   4. Run git merge upstream/main with rerere enabled for that invocation
#      (-c rerere.enabled=true -c rerere.autoupdate=true).
#      - If unresolved conflicts remain: print the worktree path and the
#        conflicted file list, leave the worktree for worker resolution, and
#        exit 2.
#      - If merge succeeds cleanly (or rerere auto-resolves and commits):
#        run bin/fm-test-run.sh --changed --base origin/main inside the worktree.
#        - On test failure: print the failing tests and the worktree path, exit 1,
#          push nothing.
#        - On test pass: if --no-pr is specified, stop after tests and exit 0.
#          Otherwise push the branch to origin (never force), open a PR against
#          the fork's main branch with the upstream commit count, test command,
#          pass/fail counts, and the line "merge with a merge commit, never squash",
#          and clean up the disposable worktree.
#
# Invariants:
#   - Never touches the primary checkout's working tree or any local main branch.
#   - Never pushes to upstream.
#   - Never force-pushes.
set -eu
export LC_ALL=C
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/.." && pwd))}"

usage() {
  cat <<'EOF'
Usage:
  fm-upstream-sync.sh [--check] [--no-pr] [--help]

Options:
  --check   Check for new upstream commits; silent when up to date, exit 0
  --no-pr   Run sync merge and tests in a disposable worktree, stop after tests
  --help    Show this help
EOF
}

check_only=false
no_pr=false

while [ $# -gt 0 ]; do
  case "$1" in
    --check)
      check_only=true
      shift
      ;;
    --no-pr)
      no_pr=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

has_origin=0
has_upstream=0
if git -C "$FM_ROOT" remote get-url origin >/dev/null 2>&1; then
  has_origin=1
fi
if git -C "$FM_ROOT" remote get-url upstream >/dev/null 2>&1; then
  has_upstream=1
fi

if [ "$has_origin" -eq 0 ] || [ "$has_upstream" -eq 0 ]; then
  if [ "$has_origin" -eq 0 ] && [ "$has_upstream" -eq 0 ]; then
    echo "error: required remotes 'origin' and 'upstream' are missing" >&2
  elif [ "$has_origin" -eq 0 ]; then
    echo "error: required remote 'origin' is missing" >&2
  else
    echo "error: required remote 'upstream' is missing" >&2
  fi
  exit 1
fi

if [ "$check_only" = true ]; then
  git -C "$FM_ROOT" fetch -q origin 2>/dev/null || true
  git -C "$FM_ROOT" fetch -q upstream 2>/dev/null || true

  if git -C "$FM_ROOT" merge-base --is-ancestor upstream/main origin/main 2>/dev/null; then
    exit 0
  fi

  count=$(git -C "$FM_ROOT" rev-list --count origin/main..upstream/main 2>/dev/null || echo 0)
  printf 'upstream: %s new commits not in origin/main\n' "$count"
  exit 0
fi

git -C "$FM_ROOT" fetch -q origin
git -C "$FM_ROOT" fetch -q upstream

if git -C "$FM_ROOT" merge-base --is-ancestor upstream/main origin/main; then
  echo "already up to date: upstream/main is an ancestor of origin/main"
  exit 0
fi

upstream_commit_count=$(git -C "$FM_ROOT" rev-list --count origin/main..upstream/main)
date_str=$(date +%Y-%m-%d)
branch="fm/upstream-sync-$date_str"

tmp_base="${TMPDIR:-/tmp}"
tmp_base="${tmp_base%/}"
worktree_dir=$(mktemp -d "$tmp_base/fm-upstream-sync.XXXXXX")

git -C "$FM_ROOT" worktree prune >/dev/null 2>&1 || true
if ! git -C "$FM_ROOT" worktree add -B "$branch" "$worktree_dir" origin/main >/dev/null 2>&1; then
  echo "error: failed to create worktree at $worktree_dir on branch $branch" >&2
  rmdir "$worktree_dir" 2>/dev/null || true
  exit 1
fi

set +e
merge_out=$(git -C "$worktree_dir" -c rerere.enabled=true -c rerere.autoupdate=true merge --no-edit upstream/main 2>&1)
merge_rc=$?
set -e

conflicts=$(git -C "$worktree_dir" diff --name-only --diff-filter=U)
if [ -n "$conflicts" ]; then
  echo "merge failed: unresolved conflicts in worktree $worktree_dir"
  echo "conflicted files:"
  printf '%s\n' "$conflicts"
  exit 2
fi

if [ "$merge_rc" -ne 0 ]; then
  if git -C "$worktree_dir" commit --no-edit >/dev/null 2>&1; then
    merge_rc=0
  else
    echo "merge failed:" >&2
    printf '%s\n' "$merge_out" >&2
    echo "worktree: $worktree_dir" >&2
    exit 1
  fi
fi

test_log="$worktree_dir/.test-run.log"
test_cmd="bin/fm-test-run.sh --changed --base origin/main"

set +e
(
  cd "$worktree_dir"
  if [ -f "bin/fm-test-run.sh" ]; then
    bash "bin/fm-test-run.sh" --changed --base origin/main
  else
    bin/fm-test-run.sh --changed --base origin/main
  fi
) >"$test_log" 2>&1
test_rc=$?
set -e

if [ "$test_rc" -ne 0 ]; then
  echo "tests failed:"
  failing_tests=$(awk '/^FM_TEST_END / && $4 !~ /^exit=0$/ { print $3 }' "$test_log")
  if [ -n "$failing_tests" ]; then
    printf '%s\n' "$failing_tests"
  else
    cat "$test_log"
  fi
  echo "worktree: $worktree_dir"
  exit 1
fi

passed=0
failed=0
if grep -q "FM_TEST_SUMMARY" "$test_log"; then
  total=$(awk -F'total=' '/FM_TEST_SUMMARY/ {print $2}' "$test_log" | awk '{print $1}')
  failed=$(awk -F'failed=' '/FM_TEST_SUMMARY/ {print $2}' "$test_log" | awk '{print $1}')
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  case "$failed" in ''|*[!0-9]*) failed=0 ;; esac
  passed=$((total - failed))
elif [ "$test_rc" -eq 0 ]; then
  passed="all"
  failed=0
fi

if [ "$no_pr" = true ]; then
  echo "tests passed ($passed passed, $failed failed); stopping after tests (--no-pr)"
  echo "worktree: $worktree_dir"
  exit 0
fi

if ! git -C "$FM_ROOT" push origin "$branch"; then
  echo "error: failed to push branch $branch to origin" >&2
  echo "worktree: $worktree_dir" >&2
  exit 1
fi

pr_title="sync: upstream merge $date_str ($upstream_commit_count new commits)"
pr_body=$(cat <<EOF
Upstream sync: $upstream_commit_count new commits from upstream/main

Test command:
\`$test_cmd\`
$passed passed, $failed failed

merge with a merge commit, never squash
EOF
)

if ! (
  cd "$worktree_dir"
  gh pr create --base main --head "$branch" --title "$pr_title" --body "$pr_body"
); then
  echo "error: failed to create pull request" >&2
  echo "worktree: $worktree_dir" >&2
  exit 1
fi

git -C "$FM_ROOT" worktree remove --force "$worktree_dir" 2>/dev/null || rm -rf "$worktree_dir"
git -C "$FM_ROOT" worktree prune >/dev/null 2>&1 || true
