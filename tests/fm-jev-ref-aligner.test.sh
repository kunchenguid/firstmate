#!/usr/bin/env bash
# tests/fm-jev-ref-aligner.test.sh - Test suite for Pattern 24 Git Ref & Divergence Realigner
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
ALIGNER_SH="$FM_ROOT/bin/fm-jev-ref-aligner.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

TDIR=$(mktemp -d "/tmp/fm-jev-ref-aligner-test.XXXXXX")
cleanup() { rm -rf "$TDIR"; }
trap cleanup EXIT

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$ALIGNER_SH" || fail "shellcheck failed on fm-jev-ref-aligner.sh"
  pass "shellcheck clean"
else
  echo "skip: shellcheck not found"
fi

# 2. Help flag verification
"$ALIGNER_SH" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

# 3. Create mock remote and local clones for testing
REMOTE_REPO="$TDIR/remote.git"
git init --bare -q "$REMOTE_REPO"

# Initial commit on origin
CLONE1="$TDIR/clone1"
git init -q "$CLONE1"
git -C "$CLONE1" config user.name "Test User"
git -C "$CLONE1" config user.email "test@example.com"
echo "hello" > "$CLONE1/file.txt"
git -C "$CLONE1" add file.txt
git -C "$CLONE1" commit -q -m "initial commit"
git -C "$CLONE1" branch -M main
git -C "$CLONE1" remote add origin "$REMOTE_REPO"
git -C "$CLONE1" push -q -u origin main


# Set default branch on bare repo
git -C "$REMOTE_REPO" symbolic-ref HEAD refs/heads/main

# Clone 2 (will fall behind)
CLONE2="$TDIR/clone2"
git clone -b main -q "$REMOTE_REPO" "$CLONE2"
git -C "$CLONE2" config user.name "Test User"
git -C "$CLONE2" config user.email "test@example.com"


# Advance origin via Clone 1
echo "update 1" >> "$CLONE1/file.txt"
git -C "$CLONE1" commit -q -am "commit 2"
git -C "$CLONE1" push -q origin main

# Fetch in Clone 2 so origin/main is updated, but local main is behind
git -C "$CLONE2" fetch -q origin

# 4. Test behind detection and dry-run
res_json=$("$ALIGNER_SH" --roots "$TDIR" --dry-run --json)
behind_count=$(echo "$res_json" | jq '.summary.behind')
[ "$behind_count" -ge 1 ] || fail "failed to detect behind worktree: $res_json"
pass "detected worktree behind upstream ($behind_count behind)"

# 5. Test auto fast-forward on clean worktree
"$ALIGNER_SH" --roots "$TDIR" --auto-ff --json >/dev/null 2>&1
res2_json=$("$ALIGNER_SH" --roots "$TDIR" --json)
up_to_date_count=$(echo "$res2_json" | jq '.summary.up_to_date')
[ "$up_to_date_count" -ge 2 ] || fail "fast-forward failed: $res2_json"
pass "auto fast-forward advanced clean branch to upstream HEAD"

# 6. Test dirty worktree protection: dirty worktrees must NEVER be touched
echo "dirty edit" >> "$CLONE2/file.txt"
echo "update 2" >> "$CLONE1/file.txt"
git -C "$CLONE1" commit -q -am "commit 3"
git -C "$CLONE1" push -q origin main
git -C "$CLONE2" fetch -q origin

res_dirty=$("$ALIGNER_SH" --roots "$TDIR" --auto-ff --json)
clone2_action=$(echo "$res_dirty" | jq -r '.worktrees[] | select(.path | contains("clone2")) | .action')
[ "$clone2_action" = "ff_skipped_dirty" ] || fail "dirty worktree was not skipped: $clone2_action"
pass "dirty worktree safely protected from auto-ff (action=$clone2_action)"

pass "all Pattern 24 git ref aligner tests passed"
