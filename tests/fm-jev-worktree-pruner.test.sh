#!/usr/bin/env bash
# tests/fm-jev-worktree-pruner.test.sh - Test suite for Pattern 27 Worktree Pruner
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
PRUNER_SH="$FM_ROOT/bin/fm-jev-worktree-pruner.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

TDIR=$(mktemp -d "/tmp/fm-jev-wt-test.XXXXXX")
cleanup() { rm -rf "$TDIR"; }
trap cleanup EXIT

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$PRUNER_SH" || fail "shellcheck failed on fm-jev-worktree-pruner.sh"
  pass "shellcheck clean"
else
  echo "skip: shellcheck not found"
fi

# 2. Help flag verification
"$PRUNER_SH" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

# 3. Create mock git repo with worktrees
MOCK_REPO="$TDIR/main_repo"
mkdir -p "$MOCK_REPO"
git init -b main "$MOCK_REPO" >/dev/null 2>&1
git -C "$MOCK_REPO" config user.email "test@example.com"
git -C "$MOCK_REPO" config user.name "Test User"
echo "init" > "$MOCK_REPO/README.md"
git -C "$MOCK_REPO" add README.md
git -C "$MOCK_REPO" commit -m "initial commit" >/dev/null 2>&1
git -C "$MOCK_REPO" update-ref refs/remotes/origin/main HEAD

# Create merged branch and worktree
git -C "$MOCK_REPO" branch feature-merged
git -C "$MOCK_REPO" worktree add "$TDIR/wt-merged" feature-merged >/dev/null 2>&1

# Create dirty uncommitted worktree
git -C "$MOCK_REPO" branch feature-dirty
git -C "$MOCK_REPO" worktree add "$TDIR/wt-dirty" feature-dirty >/dev/null 2>&1
echo "uncommitted change" > "$TDIR/wt-dirty/dirty.txt"

# 4. Audit via JSON
json_out=$("$PRUNER_SH" --repo "$MOCK_REPO" --json)
total=$(echo "$json_out" | jq '.summary.total_worktrees')
eligible=$(echo "$json_out" | jq '.summary.eligible_for_prune')
dirty=$(echo "$json_out" | jq '.summary.uncommitted_dirty')

[ "$total" -ge 2 ] || fail "expected at least 2 worktrees, got $total"
[ "$eligible" -eq 1 ] || fail "expected exactly 1 eligible worktree, got $eligible"
[ "$dirty" -ge 1 ] || fail "expected dirty worktree to be identified"
pass "correctly identified 1 merged/clean worktree and protected dirty worktree"

pass "all Pattern 27 worktree pruner tests passed"

python3 "$(dirname "${BASH_SOURCE[0]}")/jev-safety-fixtures.py" worktree-pruner
