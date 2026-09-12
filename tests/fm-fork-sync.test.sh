#!/usr/bin/env bash
# Behavior tests for the opt-in fork-sync mechanism (bin/fm-fork-sync.sh):
# inert without a distinct `upstream` remote, fast-forward-only origin and
# local updates when one is present, and a hard gate against project clones,
# task worktrees, and secondmate homes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-sync)
SYNC="$ROOT/bin/fm-fork-sync.sh"
fm_git_identity fmtest fmtest@example.invalid

# make_bare <bare-dir> <branch> <n-commits>: a bare repo with an initial
# history of <n-commits> commits on <branch>, built through a throwaway seed
# checkout so the bare repo itself never needs a worktree.
make_bare() {
  local bare=$1 branch=$2 n=$3 seed="$TMP_ROOT/seed-$$-$RANDOM" i
  git init -q --bare -b "$branch" "$bare"
  git init -q -b "$branch" "$seed"
  for i in $(seq 1 "$n"); do
    printf 'line %s\n' "$i" >> "$seed/file.txt"
    git -C "$seed" add file.txt
    git -C "$seed" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q -m "commit $i"
  done
  git -C "$seed" remote add origin "$bare"
  git -C "$seed" push -q origin "$branch"
  rm -rf "$seed"
}

# advance_bare <bare-dir> <branch> <n-more-commits> [label]: append more
# commits onto a bare repo's existing history. Two calls always produce
# distinct commit content (and thus distinct hashes) as long as their labels
# differ, even if they land in the same wall-clock second - otherwise
# byte-identical commits (same tree, parent, author, message, and
# second-resolution timestamp) can collide, silently turning an intended
# divergence fixture into a coincidental fast-forward.
advance_bare() {
  local bare=$1 branch=$2 n=$3 label=${4:-more} seed="$TMP_ROOT/adv-$$-$RANDOM" i
  git clone -q "$bare" "$seed"
  git -C "$seed" checkout -q "$branch"
  for i in $(seq 1 "$n"); do
    printf '%s %s\n' "$label" "$i" >> "$seed/file.txt"
    git -C "$seed" add file.txt
    git -C "$seed" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q -m "$label $i"
  done
  git -C "$seed" push -q origin "$branch"
  rm -rf "$seed"
}

bare_head_sha() {
  git -C "$1" rev-parse "$2"
}

# make_checkout <checkout-dir> <origin-bare> [upstream-bare]: clone origin into
# a working checkout shaped enough to pass the primary-checkout gate, and wire
# up an `upstream` remote when given.
make_checkout() {
  local dir=$1 origin=$2 upstream=${3:-}
  git clone -q "$origin" "$dir"
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  if [ -n "$upstream" ]; then
    git -C "$dir" remote add upstream "$upstream"
  fi
}

run_sync() {
  local root=$1
  FM_ROOT_OVERRIDE="$root" FM_FORK_SYNC_QUIET=1 "$SYNC"
}

test_no_upstream_remote_is_inert() {
  local origin="$TMP_ROOT/no-upstream-origin" checkout="$TMP_ROOT/no-upstream-checkout" status=0
  make_bare "$origin" main 1
  make_checkout "$checkout" "$origin"
  local before after
  before=$(bare_head_sha "$origin" main)
  run_sync "$checkout" || status=$?
  expect_code 0 "$status" "no-upstream sync"
  after=$(bare_head_sha "$origin" main)
  [ "$before" = "$after" ] || fail "origin moved with no upstream remote configured"
  pass "fm-fork-sync: a single-remote home is entirely inert"
}

test_forwards_origin_and_local_on_genuine_fast_forward() {
  local upstream="$TMP_ROOT/ff-upstream" origin="$TMP_ROOT/ff-origin" checkout="$TMP_ROOT/ff-checkout" status=0
  make_bare "$upstream" main 1
  git clone -q --bare "$upstream" "$origin"
  advance_bare "$upstream" main 2
  make_checkout "$checkout" "$origin" "$upstream"
  local upstream_sha
  upstream_sha=$(bare_head_sha "$upstream" main)
  run_sync "$checkout" || status=$?
  expect_code 0 "$status" "fast-forward sync"
  [ "$(bare_head_sha "$origin" main)" = "$upstream_sha" ] || fail "origin was not fast-forwarded to upstream"
  [ "$(git -C "$checkout" rev-parse HEAD)" = "$upstream_sha" ] || fail "local checkout was not fast-forwarded"
  [ "$(git -C "$checkout" status --porcelain --untracked-files=no)" = "" ] || fail "local checkout unexpectedly dirty after fast-forward"
  grep -q 'more 2' "$checkout/file.txt" || fail "local working tree content was not updated"
  pass "fm-fork-sync: a genuine fast-forward updates origin and the local checkout"
}

test_dirty_tree_updates_origin_but_skips_local() {
  local upstream="$TMP_ROOT/dirty-upstream" origin="$TMP_ROOT/dirty-origin" checkout="$TMP_ROOT/dirty-checkout" status=0
  make_bare "$upstream" main 1
  git clone -q --bare "$upstream" "$origin"
  advance_bare "$upstream" main 1
  make_checkout "$checkout" "$origin" "$upstream"
  local head_before upstream_sha
  head_before=$(git -C "$checkout" rev-parse HEAD)
  upstream_sha=$(bare_head_sha "$upstream" main)
  printf 'dirty\n' >> "$checkout/file.txt"
  run_sync "$checkout" || status=$?
  expect_code 0 "$status" "dirty-tree sync"
  [ "$(bare_head_sha "$origin" main)" = "$upstream_sha" ] || fail "origin was not updated despite a dirty local tree"
  [ "$(git -C "$checkout" rev-parse HEAD)" = "$head_before" ] || fail "local HEAD moved despite a dirty tree"
  grep -q '^dirty$' "$checkout/file.txt" || fail "uncommitted local edit was lost"
  pass "fm-fork-sync: a dirty tracked tree still syncs origin but skips the local fast-forward"
}

test_feature_branch_updates_origin_but_skips_local() {
  local upstream="$TMP_ROOT/feature-upstream" origin="$TMP_ROOT/feature-origin" checkout="$TMP_ROOT/feature-checkout" status=0
  make_bare "$upstream" main 1
  git clone -q --bare "$upstream" "$origin"
  advance_bare "$upstream" main 1
  make_checkout "$checkout" "$origin" "$upstream"
  git -C "$checkout" checkout -qb some-feature
  local head_before upstream_sha
  head_before=$(git -C "$checkout" rev-parse HEAD)
  upstream_sha=$(bare_head_sha "$upstream" main)
  run_sync "$checkout" || status=$?
  expect_code 0 "$status" "feature-branch sync"
  [ "$(bare_head_sha "$origin" main)" = "$upstream_sha" ] || fail "origin was not updated while on a feature branch"
  [ "$(git -C "$checkout" rev-parse HEAD)" = "$head_before" ] || fail "feature branch HEAD moved"
  [ "$(git -C "$checkout" symbolic-ref --short HEAD)" = "some-feature" ] || fail "checked-out branch changed"
  pass "fm-fork-sync: a non-default local branch still syncs origin but skips the local fast-forward"
}

test_diverged_local_updates_origin_but_skips_local() {
  local upstream="$TMP_ROOT/diverged-local-upstream" origin="$TMP_ROOT/diverged-local-origin" checkout="$TMP_ROOT/diverged-local-checkout" status=0
  make_bare "$upstream" main 1
  git clone -q --bare "$upstream" "$origin"
  advance_bare "$upstream" main 1
  make_checkout "$checkout" "$origin" "$upstream"
  printf 'local only\n' >> "$checkout/file.txt"
  git -C "$checkout" add file.txt
  git -C "$checkout" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q -m "local-only commit"
  local head_before upstream_sha
  head_before=$(git -C "$checkout" rev-parse HEAD)
  upstream_sha=$(bare_head_sha "$upstream" main)
  run_sync "$checkout" || status=$?
  expect_code 0 "$status" "diverged-local sync"
  [ "$(bare_head_sha "$origin" main)" = "$upstream_sha" ] || fail "origin was not updated despite diverged local history"
  [ "$(git -C "$checkout" rev-parse HEAD)" = "$head_before" ] || fail "diverged local HEAD moved"
  pass "fm-fork-sync: a diverged local branch still syncs origin but never rewrites local history"
}

test_diverged_origin_never_force_pushed() {
  local upstream="$TMP_ROOT/diverged-origin-upstream" origin="$TMP_ROOT/diverged-origin-origin" checkout="$TMP_ROOT/diverged-origin-checkout" status=0
  make_bare "$upstream" main 1
  git clone -q --bare "$upstream" "$origin"
  advance_bare "$origin" main 1 origin-only
  advance_bare "$upstream" main 2 upstream-only
  make_checkout "$checkout" "$origin" "$upstream"
  local origin_before
  origin_before=$(bare_head_sha "$origin" main)
  run_sync "$checkout" || status=$?
  expect_code 0 "$status" "diverged-origin sync"
  [ "$(bare_head_sha "$origin" main)" = "$origin_before" ] || fail "origin was force-updated despite a genuine divergence"
  pass "fm-fork-sync: a diverged origin is left alone rather than force-pushed"
}

test_secondmate_home_is_inert() {
  local upstream="$TMP_ROOT/sm-upstream" origin="$TMP_ROOT/sm-origin" checkout="$TMP_ROOT/sm-checkout" status=0
  make_bare "$upstream" main 1
  git clone -q --bare "$upstream" "$origin"
  advance_bare "$upstream" main 1
  make_checkout "$checkout" "$origin" "$upstream"
  printf 'sm-fork-sync-test\n' > "$checkout/.fm-secondmate-home"
  local origin_before
  origin_before=$(bare_head_sha "$origin" main)
  run_sync "$checkout" || status=$?
  expect_code 0 "$status" "secondmate-home sync"
  [ "$(bare_head_sha "$origin" main)" = "$origin_before" ] || fail "a secondmate home was synced"
  pass "fm-fork-sync: a secondmate home never runs fork sync"
}

test_linked_worktree_is_inert() {
  local upstream="$TMP_ROOT/wt-upstream" origin="$TMP_ROOT/wt-origin" checkout="$TMP_ROOT/wt-checkout" linked="$TMP_ROOT/wt-linked" status=0
  make_bare "$upstream" main 1
  git clone -q --bare "$upstream" "$origin"
  advance_bare "$upstream" main 1
  make_checkout "$checkout" "$origin" "$upstream"
  git -C "$checkout" worktree add -q -b wt-linked-branch "$linked"
  mkdir -p "$linked/bin" "$linked/state"
  : > "$linked/AGENTS.md"
  local origin_before
  origin_before=$(bare_head_sha "$origin" main)
  run_sync "$linked" || status=$?
  expect_code 0 "$status" "linked-worktree sync"
  [ "$(bare_head_sha "$origin" main)" = "$origin_before" ] || fail "a linked task worktree was allowed to sync"
  pass "fm-fork-sync: a linked task worktree never runs fork sync"
}

test_no_upstream_remote_is_inert
test_forwards_origin_and_local_on_genuine_fast_forward
test_dirty_tree_updates_origin_but_skips_local
test_feature_branch_updates_origin_but_skips_local
test_diverged_local_updates_origin_but_skips_local
test_diverged_origin_never_force_pushed
test_secondmate_home_is_inert
test_linked_worktree_is_inert
