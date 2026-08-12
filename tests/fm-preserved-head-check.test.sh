#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-preserved-head-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-preserved-head-check)
DATA_DIR="$TMP_ROOT/data"
SOURCE_REPO="$TMP_ROOT/source"
OTHER_REPO="$TMP_ROOT/other"
mkdir -p "$DATA_DIR/repos" "$DATA_DIR/worktrees/repo" "$SOURCE_REPO" "$OTHER_REPO"

git -C "$SOURCE_REPO" init -q
fm_git_identity "$SOURCE_REPO"
printf 'one\n' > "$SOURCE_REPO/file"
git -C "$SOURCE_REPO" add file
git -C "$SOURCE_REPO" commit -qm one
OLD_HEAD=$(git -C "$SOURCE_REPO" rev-parse HEAD)
printf 'two\n' >> "$SOURCE_REPO/file"
git -C "$SOURCE_REPO" commit -qam two
CURRENT_HEAD=$(git -C "$SOURCE_REPO" rev-parse HEAD)
git clone -q --bare "$SOURCE_REPO" "$DATA_DIR/repos/repo.git"
git --git-dir="$DATA_DIR/repos/repo.git" worktree add -q --detach \
  "$DATA_DIR/worktrees/repo/run-1" "$CURRENT_HEAD"

resolved=$("$CHECK" "$DATA_DIR" repo run-1 "${CURRENT_HEAD:0:12}")
[ "$resolved" = "$CURRENT_HEAD" ] || fail "matching gate head did not resolve to the full commit"
pass "preserved-head-check: accepts the current commit in the matching gate repository"

if output=$("$CHECK" "$DATA_DIR" repo run-1 "$OLD_HEAD" 2>&1); then
  fail "stale status head was accepted"
fi
case "$output" in *'preserved head mismatch'*) ;; *) fail "stale head did not report the equality failure" ;; esac
pass "preserved-head-check: rejects a real but stale gate commit"

git -C "$OTHER_REPO" init -q
fm_git_identity "$OTHER_REPO"
printf 'other\n' > "$OTHER_REPO/file"
git -C "$OTHER_REPO" add file
git -C "$OTHER_REPO" commit -qm other
OTHER_HEAD=$(git -C "$OTHER_REPO" rev-parse HEAD)
if output=$("$CHECK" "$DATA_DIR" repo run-1 "$OTHER_HEAD" 2>&1); then
  fail "commit from an unrelated repository was accepted"
fi
case "$output" in *'not a commit in matching gate repository'*) ;; *) fail "unrelated object did not report repository mismatch" ;; esac
pass "preserved-head-check: rejects an object found only in another repository"

git init -q --bare "$DATA_DIR/repos/wrong.git"
mkdir -p "$DATA_DIR/worktrees/wrong"
git --git-dir="$DATA_DIR/repos/repo.git" worktree add -q --detach \
  "$DATA_DIR/worktrees/wrong/run-1" "$CURRENT_HEAD"
if output=$("$CHECK" "$DATA_DIR" wrong run-1 "$CURRENT_HEAD" 2>&1); then
  fail "run worktree attached to another gate repository was accepted"
fi
case "$output" in *'run gate repository mismatch'*) ;; *) fail "mismatched common directory did not fail closed" ;; esac
pass "preserved-head-check: rejects a mismatched repository identity"
