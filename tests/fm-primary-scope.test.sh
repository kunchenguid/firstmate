#!/usr/bin/env bash
# Executable contract tests for the shared primary-session scope predicate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-primary-scope)
SCOPE="$ROOT/bin/fm-primary-scope.sh"

make_primary() {
  local root=$1 state=$2
  fm_git_init_commit "$root"
  mkdir -p "$root/bin" "$state"
  : > "$root/AGENTS.md"
}

expect_scope() {
  local expected=$1 label=$2 root=$3 state=$4 status=0
  "$SCOPE" --root "$root" --state "$state" >/dev/null 2>&1 || status=$?
  expect_code "$expected" "$status" "$label"
}

test_plain_primary_is_in_scope() {
  local root="$TMP_ROOT/primary" state="$TMP_ROOT/primary-state"
  make_primary "$root" "$state"
  expect_scope 0 "plain primary must be in scope" "$root" "$state"
  pass "fm-primary-scope: a plain Firstmate primary is in scope"
}

test_linked_worktree_is_inert_despite_inherited_home_state() {
  local base="$TMP_ROOT/base" root="$TMP_ROOT/linked-worktree" primary_state="$TMP_ROOT/inherited-primary-state"
  fm_git_worktree "$base" "$root" fm/primary-scope-linked
  mkdir -p "$root/bin" "$primary_state"
  : > "$root/AGENTS.md"
  expect_scope 1 "linked task worktree must be inert" "$root" "$primary_state"
  pass "fm-primary-scope: a linked task worktree is inert despite another home's state"
}

test_marked_secondmate_home_is_in_scope() {
  local base="$TMP_ROOT/secondmate-base" root="$TMP_ROOT/secondmate-home" state="$TMP_ROOT/secondmate-state"
  fm_git_worktree "$base" "$root" fm/primary-scope-secondmate
  mkdir -p "$root/bin" "$state"
  : > "$root/AGENTS.md"
  printf 'secondmate-test\n' > "$root/.fm-secondmate-home"
  expect_scope 0 "marked secondmate primary must be in scope" "$root" "$state"
  pass "fm-primary-scope: a valid marked secondmate home remains in scope"
}

test_plain_primary_is_in_scope
test_linked_worktree_is_inert_despite_inherited_home_state
test_marked_secondmate_home_is_in_scope
