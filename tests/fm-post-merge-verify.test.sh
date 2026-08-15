#!/usr/bin/env bash
# tests/fm-post-merge-verify.test.sh - post-merge content verification guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-post-merge-verify.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

REMOTE="$TMP_ROOT/remote.git"
CLONE="$TMP_ROOT/clone"

# Deterministic git identity from the shared lib.
setup_repo() {
  mkdir -p "$REMOTE"
  git init -q --bare "$REMOTE"
  git clone -q "$REMOTE" "$CLONE"
  git -C "$CLONE" config user.name "Test"
  git -C "$CLONE" config user.email "test@example.com"
  echo "base" > "$CLONE/base.txt"
  git -C "$CLONE" add base.txt
  git -C "$CLONE" commit -q -m "base"
  git -C "$CLONE" branch -M main
  git -C "$CLONE" push -q -u origin main
}

# Simulate an approved PR: branch with two changed files, one new, one edited.
make_pr_branch() {
  git -C "$CLONE" checkout -q -b feature
  echo "approved-v1" > "$CLONE/approved.txt"
  echo "edited" >> "$CLONE/base.txt"
  git -C "$CLONE" add approved.txt base.txt
  git -C "$CLONE" commit -q -m "feature work"
  BASE=$(git -C "$CLONE" rev-parse main)
  HEAD=$(git -C "$CLONE" rev-parse feature)
}

# Simulate a squash merge that carries the approved blobs onto main.
squash_land() {
  git -C "$CLONE" checkout -q main
  git -C "$CLONE" checkout -q feature -- approved.txt base.txt
  git -C "$CLONE" commit -q -m "merge feature (squashed)"
  git -C "$CLONE" push -q origin main
}

setup_repo
make_pr_branch

# Scenario 1: approved content present on the default branch -> PASS.
squash_land
if "$ROOT/bin/fm-post-merge-verify.sh" "$CLONE" "$BASE" "$HEAD" >"$TMP_ROOT/out1" 2>&1; then
  pass "content present on main passes"
else
  cat "$TMP_ROOT/out1"
  fail "content present on main should pass"
fi
if grep -q "PASS: 2 changed paths" "$TMP_ROOT/out1"; then
  pass "summary reports both paths"
else
  fail "summary should report both paths"
fi

# Scenario 2: content missing from the default branch -> FAIL.
git -C "$CLONE" checkout -q -b feature2 main
git -C "$CLONE" rm -q approved.txt
git -C "$CLONE" commit -q -m "drop approved content"
git -C "$CLONE" push -q -u origin feature2
BASE2=$(git -C "$CLONE" rev-parse main)
HEAD2=$(git -C "$CLONE" rev-parse feature2)
if "$ROOT/bin/fm-post-merge-verify.sh" "$CLONE" "$BASE2" "$HEAD2" >"$TMP_ROOT/out2" 2>&1; then
  fail "missing content should fail"
else
  pass "missing content fails with non-zero exit"
fi
if grep -q "FAIL" "$TMP_ROOT/out2"; then
  pass "failure reported"
else
  fail "failure line expected"
fi

# Scenario 3: content present but differing -> FAIL.
git -C "$CLONE" checkout -q main
echo "different-content" > "$CLONE/base.txt"
git -C "$CLONE" commit -q -am "diverging base.txt content"
git -C "$CLONE" push -q origin main
if "$ROOT/bin/fm-post-merge-verify.sh" "$CLONE" "$BASE" "$HEAD" >"$TMP_ROOT/out3" 2>&1; then
  fail "differing content should fail"
else
  pass "differing content fails with non-zero exit"
fi
if grep -q "DIFFERS" "$TMP_ROOT/out3"; then
  pass "differing path listed"
else
  fail "DIFFERS line expected"
fi

# Scenario 4: missing args -> usage error, non-zero.
if "$ROOT/bin/fm-post-merge-verify.sh" "$CLONE" "$BASE" >"$TMP_ROOT/out4" 2>&1; then
  fail "missing args should fail"
else
  pass "missing args fail with non-zero exit"
fi

exit 0
