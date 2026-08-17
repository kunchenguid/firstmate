#!/usr/bin/env bash
# Tests for bin/fm-worktree-unique-content.sh - the content-reachability
# classifier behind teardown's dirty-worktree refusal.
#
# The classifier answers "does this worktree hold content that exists nowhere
# else", not "is it dirty". git-status dirtiness is a proxy that inverts when a
# branch is rewritten beneath a live worktree (a bare ref write with no
# checkout): the stale index then presents already-landed work as staged
# deletions and pre-merge line versions as insertions. Discarding that state
# loses nothing, while "preserving" it would delete landed work.
#
# Exit contract under test: 0 only when every differing path is PROVEN to hold
# only content reachable from refs that survive teardown (the checked-out
# branch is excluded because teardown deletes it); 1 for unique or unprovable
# content and for every error; 2 for usage errors.
#
# Matrix:
#   (a) clean worktree                                        -> 0 (nothing held)
#   (b) stale index after branch ref moved beneath worktree   -> 0 (all reachable)
#   (c) one genuinely new staged line                         -> 1 (unique content)
#   (d) stale-index shape plus one new untracked file         -> 1 (mixed refuses)
#   (e) unstaged edit reverting to an ancestor version        -> 0
#   (f) unstaged genuinely new content                        -> 1
#   (g) staged deletion of committed content                  -> 0 (holds nothing)
#   (h) untracked file matching the excluded regex            -> 0
#   (i) untracked file not matching the excluded regex        -> 1
#   (j) content reachable only from the checked-out branch    -> 1 (branch dies)
#   (k) same content with the branch pushed to a remote       -> 0 (remote survives)
#   (l) unmerged (conflicted) entry                           -> 1 (fail closed)
#   (m) empty untracked file                                  -> 0 (empty is not work)
#   (n) detached-HEAD worktree with reachable staleness       -> 0
#   (o) usage errors                                          -> 2
#
# Mutation proof (the refusal must never get weaker): the oracle asserts BOTH
# that fixture (b) passes (precision) and that fixture (d) refuses (safety).
# Each of the four mutation classes applied to the landed predicate - delete
# it, make it unreachable, weaken it to accept one unique blob, and replace it
# with always-reachable - must make the oracle fail, and the unmutated control
# must make it pass. A mutant the oracle cannot catch fails this test, because
# then the oracle would only prove the code exists, not that it decides.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CLS="$ROOT/bin/fm-worktree-unique-content.sh"
TMP_ROOT=$(fm_test_tmproot fm-unique-content)

# Every fixture path must exist before any `git -C "$path"` runs: a helper that
# died inside its command substitution leaves the variable empty, and
# `git -C ""` then resolves against the test runner's own checkout - which is a
# shared repo. This exact accident once created a stray branch and worktree
# there, so the guard is not hypothetical.
require_dir() {
  [ -n "${1:-}" ] && [ -d "$1" ] || fail "fixture dir missing: '${1:-}' (${2:-fixture})"
}

# make_repo <name>: project repo whose main has two commits:
#   C1: alpha.txt v1, docs/keep.txt v1
#   C2: alpha.txt v2, plus tests/landed.txt (the "landed tonight" file)
# Prints the repo dir; read C1/C2 back with rev-parse main~1 / main.
make_repo() {
  local name=$1 repo
  repo="$TMP_ROOT/$name/project"
  mkdir -p "$repo/docs"
  git -C "$repo" init -q -b main
  printf 'alpha v1\n' > "$repo/alpha.txt"
  printf 'keep v1\n' > "$repo/docs/keep.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm C1
  printf 'alpha v2\n' > "$repo/alpha.txt"
  mkdir -p "$repo/tests"
  printf 'landed line 1\nlanded line 2\n' > "$repo/tests/landed.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm C2
  printf '%s\n' "$repo"
}

# make_stale_index_wt <repo>: worktree on branch fm/task at C1, then the branch
# ref rewritten to C2 beneath it - a bare update-ref with no checkout, exactly
# the reflog shape measured in the incident. Index and working tree stay at C1
# while HEAD reads C2, so status inverts the C1..C2 delta. Prints the worktree.
make_stale_index_wt() {
  local repo=$1 wt c1 c2
  wt="$(dirname "$repo")/wt"
  c1=$(git -C "$repo" rev-parse main~1)
  c2=$(git -C "$repo" rev-parse main)
  git -C "$repo" worktree add -q -b fm/task "$wt" "$c1"
  git -C "$repo" update-ref refs/heads/fm/task "$c2"
  printf '%s\n' "$wt"
}

run_cls() {
  "$CLS" "$@"
}

test_clean_worktree_passes() {
  local repo wt rc
  repo=$(make_repo clean)
  require_dir "$repo" clean
  wt="$(dirname "$repo")/wt"
  git -C "$repo" worktree add -q -b fm/task "$wt" main
  set +e
  run_cls "$wt" > "$TMP_ROOT/clean.out" 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "clean: a clean worktree holds no unique content"
  pass "clean worktree passes"
}

test_stale_index_shape_passes() {
  local repo wt rc status
  repo=$(make_repo stale)
  require_dir "$repo" stale
  wt=$(make_stale_index_wt "$repo")
  status=$(git -C "$wt" status --porcelain)
  [ -n "$status" ] || fail "stale: fixture is not dirty; the stale-index shape was not reproduced"
  printf '%s\n' "$status" | grep -q '^D  tests/landed.txt' \
    || fail "stale: fixture does not stage a deletion of the landed file; got: $status"
  set +e
  run_cls "$wt" > "$TMP_ROOT/stale.out" 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "stale: every blob in the stale index is reachable from main, so nothing unique is held ($(cat "$TMP_ROOT/stale.out"))"
  pass "stale index after a branch ref moved beneath the worktree passes"
}

test_new_staged_line_refuses() {
  local repo wt rc
  repo=$(make_repo new-staged)
  require_dir "$repo" new-staged
  wt="$(dirname "$repo")/wt"
  git -C "$repo" worktree add -q -b fm/task "$wt" main
  printf 'alpha v2\ngenuinely new line\n' > "$wt/alpha.txt"
  git -C "$wt" add alpha.txt
  set +e
  run_cls "$wt" > "$TMP_ROOT/new-staged.out" 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "new-staged: one genuinely new staged line must refuse"
  grep -q 'alpha.txt' "$TMP_ROOT/new-staged.out" \
    || fail "new-staged: refusal does not name the path holding unique content"
  pass "one genuinely new staged line refuses and names the path"
}

test_mixed_stale_plus_new_untracked_refuses() {
  local repo wt rc
  repo=$(make_repo mixed)
  require_dir "$repo" mixed
  wt=$(make_stale_index_wt "$repo")
  printf 'genuinely new untracked line\n' > "$wt/brandnew.txt"
  set +e
  run_cls "$wt" > "$TMP_ROOT/mixed.out" 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "mixed: reachable staleness plus one new file must still refuse"
  grep -q 'brandnew.txt' "$TMP_ROOT/mixed.out" \
    || fail "mixed: refusal does not name the unique file"
  pass "stale-index shape plus one new untracked file refuses"
}

test_unstaged_ancestor_revert_passes() {
  local repo wt rc
  repo=$(make_repo revert)
  require_dir "$repo" revert
  wt="$(dirname "$repo")/wt"
  git -C "$repo" worktree add -q -b fm/task "$wt" main
  printf 'alpha v1\n' > "$wt/alpha.txt"
  set +e
  run_cls "$wt" > "$TMP_ROOT/revert.out" 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "revert: an unstaged revert to an ancestor version holds nothing unique"
  pass "unstaged edit reverting to an ancestor version passes"
}

test_unstaged_new_content_refuses() {
  local repo wt rc
  repo=$(make_repo unstaged-new)
  require_dir "$repo" unstaged-new
  wt="$(dirname "$repo")/wt"
  git -C "$repo" worktree add -q -b fm/task "$wt" main
  printf 'alpha vNEW never committed\n' > "$wt/alpha.txt"
  set +e
  run_cls "$wt" > "$TMP_ROOT/unstaged-new.out" 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "unstaged-new: genuinely new working-tree content must refuse"
  pass "unstaged genuinely new content refuses"
}

test_staged_deletion_passes() {
  local repo wt rc
  repo=$(make_repo deletion)
  require_dir "$repo" deletion
  wt="$(dirname "$repo")/wt"
  git -C "$repo" worktree add -q -b fm/task "$wt" main
  git -C "$wt" rm -q docs/keep.txt
  set +e
  run_cls "$wt" > "$TMP_ROOT/deletion.out" 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "deletion: a staged deletion of committed content holds nothing"
  pass "staged deletion of committed content passes"
}

test_excluded_untracked_regex() {
  local repo wt rc
  repo=$(make_repo excluded)
  require_dir "$repo" excluded
  wt="$(dirname "$repo")/wt"
  git -C "$repo" worktree add -q -b fm/task "$wt" main
  mkdir -p "$wt/.claude"
  printf '{}\n' > "$wt/.claude/settings.json"
  printf 'x\n' > "$wt/.fm-grok-turnend"
  set +e
  run_cls "$wt" --excluded-untracked-regex '^(\.claude/|\.fm-(grok|kimi)-turnend$)' \
    > "$TMP_ROOT/excluded.out" 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "excluded: untracked files matching the excluded regex are not work"
  set +e
  run_cls "$wt" > "$TMP_ROOT/excluded-none.out" 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "excluded: without the regex the same untracked files refuse"
  pass "excluded-untracked regex carves out only what the caller names"
}

test_branch_only_content_refuses_until_pushed() {
  local repo wt rc origin
  repo=$(make_repo branch-only)
  require_dir "$repo" branch-only
  wt="$(dirname "$repo")/wt"
  git -C "$repo" worktree add -q -b fm/task "$wt" main
  printf 'branch v1\n' > "$wt/branch.txt"
  git -C "$wt" add branch.txt
  git -C "$wt" commit -qm B1
  printf 'branch v2\n' > "$wt/branch.txt"
  git -C "$wt" add branch.txt
  git -C "$wt" commit -qm B2
  printf 'branch v1\n' > "$wt/branch.txt"
  git -C "$wt" add branch.txt
  set +e
  run_cls "$wt" > "$TMP_ROOT/branch-only.out" 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "branch-only: content reachable only from the checked-out branch must refuse, because teardown deletes that branch"
  origin="$(dirname "$repo")/origin.git"
  git init -q --bare "$origin"
  git -C "$repo" remote add origin "$origin"
  git -C "$wt" push -q origin fm/task
  git -C "$repo" fetch -q origin
  set +e
  run_cls "$wt" > "$TMP_ROOT/branch-pushed.out" 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "branch-pushed: the same content reachable from a remote-tracking ref passes"
  pass "checked-out-branch-only content refuses until a surviving ref holds it"
}

test_unmerged_entry_refuses() {
  local repo wt rc
  repo=$(make_repo unmerged)
  require_dir "$repo" unmerged
  wt="$(dirname "$repo")/wt"
  git -C "$repo" worktree add -q -b fm/task "$wt" main~1
  printf 'alpha conflict mine\n' > "$wt/alpha.txt"
  git -C "$wt" add alpha.txt
  git -C "$wt" commit -qm mine
  set +e
  git -C "$wt" merge -q main > /dev/null 2>&1
  run_cls "$wt" > "$TMP_ROOT/unmerged.out" 2>&1
  rc=$?
  set -e
  git -C "$wt" status --porcelain | grep -q '^UU ' \
    || fail "unmerged: fixture did not produce a conflicted entry"
  expect_code 1 "$rc" "unmerged: a conflicted entry cannot be proven and must refuse"
  pass "unmerged entry fails closed"
}

test_empty_untracked_file_passes() {
  local repo wt rc
  repo=$(make_repo empty)
  require_dir "$repo" empty
  wt="$(dirname "$repo")/wt"
  git -C "$repo" worktree add -q -b fm/task "$wt" main
  : > "$wt/empty-marker"
  set +e
  run_cls "$wt" > "$TMP_ROOT/empty.out" 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "empty: a zero-byte untracked file holds no content"
  pass "empty untracked file passes"
}

test_detached_head_worktree_passes() {
  local repo wt rc c1 c2
  repo=$(make_repo detached)
  require_dir "$repo" detached
  wt="$(dirname "$repo")/wt"
  c1=$(git -C "$repo" rev-parse main~1)
  c2=$(git -C "$repo" rev-parse main)
  git -C "$repo" worktree add -q --detach "$wt" "$c2"
  git -C "$wt" read-tree -u --reset "$c1"
  set +e
  run_cls "$wt" > "$TMP_ROOT/detached.out" 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "detached: reachable staleness in a detached worktree passes"
  pass "detached-HEAD worktree with reachable staleness passes"
}

test_usage_errors() {
  local rc
  set +e
  run_cls > /dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" "usage: no worktree argument"
  set +e
  run_cls --bogus-flag x > /dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" "usage: unknown flag"
  set +e
  run_cls "$TMP_ROOT/does-not-exist" > /dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "usage: nonexistent worktree refuses on the refuse side"
  pass "usage errors exit 2 and a missing worktree refuses"
}

# --- mutation proof ---------------------------------------------------------

ORACLE_STALE_WT=
ORACLE_MIXED_WT=

prepare_oracle_fixtures() {
  local repo
  repo=$(make_repo oracle-stale)
  require_dir "$repo" oracle-stale
  ORACLE_STALE_WT=$(make_stale_index_wt "$repo")
  repo=$(make_repo oracle-mixed)
  require_dir "$repo" oracle-mixed
  ORACLE_MIXED_WT=$(make_stale_index_wt "$repo")
  printf 'genuinely new line\n' > "$ORACLE_MIXED_WT/brandnew.txt"
}

# oracle <classifier>: precision (stale fixture exits 0) AND safety (mixed
# fixture exits 1). Returns non-zero when either half fails.
oracle() {
  local cls=$1 rc
  set +e
  "$cls" "$ORACLE_STALE_WT" > /dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || return 1
  set +e
  "$cls" "$ORACLE_MIXED_WT" > /dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || return 1
  return 0
}

make_mutant() {  # <name> <sed-script>
  local name=$1 sed_prog=$2 dst
  dst="$TMP_ROOT/mutants/$name"
  mkdir -p "$TMP_ROOT/mutants"
  sed -e "$sed_prog" "$CLS" > "$dst"
  chmod +x "$dst"
  if cmp -s "$CLS" "$dst"; then
    fail "mutant $name: sed changed nothing - a mutation anchor moved, so this proof is vacuous"
  fi
  printf '%s\n' "$dst"
}

test_mutation_classes_are_caught() {
  local marker mutant
  prepare_oracle_fixtures
  for marker in 'MUTATION:predicate-begin' 'MUTATION:predicate-end' 'MUTATION:call-site' 'MUTATION:verdict'; do
    grep -q "$marker" "$CLS" || fail "mutation anchor '$marker' missing from the classifier"
  done

  oracle "$CLS" || fail "control: the unmutated classifier fails its own oracle"

  mutant=$(make_mutant delete '/# MUTATION:predicate-begin/,/# MUTATION:predicate-end/d')
  if oracle "$mutant"; then
    fail "mutant delete survived: with the predicate deleted the oracle still passes"
  fi

  mutant=$(make_mutant unreachable '/MUTATION:call-site/s/unreachable_blobs(needed, reachable)/list(needed)/')
  if oracle "$mutant"; then
    fail "mutant unreachable survived: with the predicate never invoked the oracle still passes"
  fi

  mutant=$(make_mutant weaken '/MUTATION:verdict/s/if unique:/if len(unique) > 1:/')
  if oracle "$mutant"; then
    fail "mutant weaken survived: a predicate accepting one genuinely new blob passes the oracle"
  fi

  mutant=$(make_mutant always-true '/MUTATION:call-site/s/unreachable_blobs(needed, reachable)/[]/')
  if oracle "$mutant"; then
    fail "mutant always-true survived: a predicate that approves everything passes the oracle"
  fi

  pass "all four mutation classes are caught and the control passes"
}

test_clean_worktree_passes
test_stale_index_shape_passes
test_new_staged_line_refuses
test_mixed_stale_plus_new_untracked_refuses
test_unstaged_ancestor_revert_passes
test_unstaged_new_content_refuses
test_staged_deletion_passes
test_excluded_untracked_regex
test_branch_only_content_refuses_until_pushed
test_unmerged_entry_refuses
test_empty_untracked_file_passes
test_detached_head_worktree_passes
test_usage_errors
test_mutation_classes_are_caught

printf 'ok - fm-worktree-unique-content tests passed\n'
