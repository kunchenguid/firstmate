#!/usr/bin/env bash
# Characterization coverage for primary-home scope detection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-primary-scope-lib.sh"

test_plain_primary_checkout_is_in_scope() {
  local fixture root state
  fixture=$(fm_test_tmproot fm-primary-scope)
  root="$fixture/plain"
  state="$root/state"
  mkdir -p "$root/bin" "$state"
  printf '%s\n' '# fixture' > "$root/AGENTS.md"
  git -C "$root" init -q
  # shellcheck source=/dev/null
  . "$LIB"
  fm_primary_scope_matches "$root" "$state" || fail "plain primary checkout should be in scope"
  pass "primary-scope-lib: plain primary checkout is in scope"
}

test_linked_worktree_is_out_of_scope() {
  local fixture repo linked state
  fixture=$(fm_test_tmproot fm-primary-scope)
  repo="$fixture/repo"
  linked="$fixture/linked"
  state="$linked/state"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name test
  : > "$repo/file"
  git -C "$repo" add file
  git -C "$repo" commit -qm initial
  git -C "$repo" worktree add -q "$linked"
  mkdir -p "$linked/bin" "$state"
  printf '%s\n' '# fixture' > "$linked/AGENTS.md"
  # shellcheck source=/dev/null
  . "$LIB"
  if fm_primary_scope_matches "$linked" "$state"; then
    fail "linked task worktree must be out of scope"
  fi
  pass "primary-scope-lib: linked task worktree is out of scope"
}

test_valid_secondmate_marker_is_in_scope() {
  local fixture root state
  fixture=$(fm_test_tmproot fm-primary-scope)
  root="$fixture/secondmate"
  state="$root/state"
  mkdir -p "$root/bin" "$state"
  printf '%s\n' '# fixture' > "$root/AGENTS.md"
  printf '%s\n' crew-17 > "$root/.fm-secondmate-home"
  # shellcheck source=/dev/null
  . "$LIB"
  fm_primary_scope_matches "$root" "$state" || fail "valid secondmate marker should be in scope"
  pass "primary-scope-lib: valid secondmate marker is in scope"
}

test_plain_primary_checkout_is_in_scope
test_linked_worktree_is_out_of_scope
test_valid_secondmate_marker_is_in_scope
echo "# fm-primary-scope-lib.test.sh: all assertions passed"
