#!/usr/bin/env bash
# Behavior tests for fm-integration-review.sh.
#
# fm-integration-review.sh clones a project fresh, fetches the given PR heads,
# merges them in the given order into a disposable worktree, and runs a
# caller-supplied test command after each merge.
# This suite pins two behaviors: a clean multi-PR merge exits 0 and runs the
# test command after every step, and a real content conflict stops the script
# (exit 2) without resolving it and without touching the project's own remote.
#
# All fixtures are local: a bare repo stands in for the forge, and
# refs/pull/N/head is fabricated by hand the way a real forge would populate
# it, so this suite makes no network calls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-integration-review-tests)

# new_origin: a bare repo with a main branch holding one base commit.
# Returns the bare repo's path on stdout.
new_origin() {
  local name=$1
  local origin="$TMP_ROOT/$name-origin.git"
  local seed="$TMP_ROOT/$name-seed"
  git init -q --bare "$origin"
  git init -q "$seed"
  (
    cd "$seed" || exit 1
    fm_git_identity fmtest fmtest@example.invalid
    git checkout -q -b main
    printf 'base\n' > base.txt
    git add base.txt
    git commit -q -m "base"
    git remote add origin "$origin"
    git push -q origin main
  )
  printf '%s\n' "$origin"
}

# fabricate_pr: create a branch on top of main in a throwaway clone of
# $origin, push it, then point refs/pull/<n>/head at its tip - the same shape
# a real forge exposes for an open PR, built locally instead of over the
# network.
fabricate_pr() {
  local origin=$1
  local n=$2
  local file=$3
  local content=$4
  local work="$TMP_ROOT/pr-$n-work-$$-$RANDOM"
  git clone -q "$origin" "$work"
  (
    cd "$work" || exit 1
    fm_git_identity fmtest fmtest@example.invalid
    git checkout -q -b "pr-$n-branch" main
    printf '%s\n' "$content" > "$file"
    git add "$file"
    git commit -q -m "pr $n"
    git push -q origin "HEAD:refs/pull/$n/head"
  )
  rm -rf "$work"
}

# new_project_dir: a working clone of $origin with a project-shaped .git
# directory, the form fm-integration-review.sh's resolve_project_dir accepts
# as an absolute path.
new_project_dir() {
  local origin=$1
  local name=$2
  local dir="$TMP_ROOT/$name-project"
  git clone -q "$origin" "$dir"
  printf '%s\n' "$dir"
}

SCRIPT="$ROOT/bin/fm-integration-review.sh"

# --- test: two non-conflicting PRs merge clean, test command runs each step -

origin=$(new_origin clean)
fabricate_pr "$origin" 1 file-a.txt "from pr 1"
fabricate_pr "$origin" 2 file-b.txt "from pr 2"
project=$(new_project_dir "$origin" clean)

marker="$TMP_ROOT/clean-run-count"
: > "$marker"
out=$("$SCRIPT" "$project" "printf run >> '$marker'" 1 2 2>&1)
code=$?

[ "$code" -eq 0 ] || fail "clean merge-train exited $code, expected 0: $out"
echo "$out" | grep -q "all 2 PRs merged clean" || fail "success line missing from output: $out"
runs=$(grep -o run "$marker" | wc -l | tr -d ' ')
[ "$runs" = "3" ] || fail "expected test command to run 3 times (baseline + 2 merges), got $runs"

pass "clean multi-PR merge-train exits 0 and runs the test command after every step"

# --- test: a real content conflict stops the script without resolving it ---

origin=$(new_origin conflict)
fabricate_pr "$origin" 10 shared.txt "pr 10's version"
fabricate_pr "$origin" 11 shared.txt "pr 11's version"
project=$(new_project_dir "$origin" conflict)

before_sha=$(git -C "$project" rev-parse origin/main)

out=$("$SCRIPT" "$project" "true" 10 11 2>&1)
code=$?

[ "$code" -eq 2 ] || fail "conflicting merge-train exited $code, expected 2: $out"
echo "$out" | grep -q "CONFLICT merging PR #11" || fail "conflict line missing from output: $out"
echo "$out" | grep -qi "does not auto-resolve" || fail "script did not state its no-auto-resolve contract: $out"

after_sha=$(git -C "$project" rev-parse origin/main)
[ "$before_sha" = "$after_sha" ] || fail "project's own origin/main moved during a review run - nothing should ever push back"

pass "a real merge conflict stops the script (exit 2) without resolving it or touching the project's own remote"
