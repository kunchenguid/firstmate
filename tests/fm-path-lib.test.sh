#!/usr/bin/env bash
# Tests for bin/fm-path-lib.sh, the physical-directory identity helpers
# bin/fm-teardown.sh uses to decide whether a task's recorded worktree path and
# the treehouse-recorded worktree path name the SAME directory object.
#
# The bug these exist for: on a host where two path strings are aliases for one
# physical directory - a bind mount or macOS firmlink such as /home/x and
# /data00/home/x - firstmate's task metadata records one alias while the
# treehouse worktree inventory records the other. `pwd -P` canonicalizes
# symlinks but NOT those aliases, so a string-only compare reported the worktree
# as not treehouse-managed and refused an otherwise-safe teardown. The fix adds a
# (device, inode) identity fallback.
#
# macOS limitation: a real bind mount / firmlink cannot be created here, so these
# fixtures use a symlink alias. That is faithful for the logic under test: both
# the bind-mount case and the symlink case reduce to "two DISTINCT path strings
# that stat to one shared dev:ino", which is exactly the fallback comparison. The
# only difference is whether `pwd -P` would have collapsed the strings earlier;
# the identity compare itself is identical, and is what these tests pin.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-path-lib.sh disable=SC1091
. "$ROOT/bin/fm-path-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-path-lib-tests)

test_identical_string_matches() {
  local d="$TMP_ROOT/same/real"
  mkdir -p "$d"
  fm_same_physical_dir "$d" "$d" || fail "identical path did not match itself"
  pass "identical string paths match"
}

test_alias_to_same_object_matches() {
  local real link
  real="$TMP_ROOT/alias/real"
  link="$TMP_ROOT/alias/link"
  mkdir -p "$real"
  ln -s "$real" "$link"
  # Two DISTINCT strings that resolve to one directory object: this is the exact
  # shape of the bind-mount alias, and must match via the dev:ino fallback.
  [ "$real" != "$link" ] || fail "fixture strings are not distinct"
  fm_same_physical_dir "$link" "$real" || fail "alias to the same directory object did not match"
  fm_same_physical_dir "$real" "$link" || fail "alias match is not symmetric"
  pass "distinct path strings for one directory object match on device+inode"
}

test_distinct_directories_do_not_match() {
  local a b
  a="$TMP_ROOT/distinct/a"
  b="$TMP_ROOT/distinct/b"
  mkdir -p "$a" "$b"
  # Two genuinely different directories must never collide.
  fm_same_physical_dir "$a" "$b" && fail "two different directories were treated as the same object"
  pass "genuinely different directories do not match"
}

test_missing_directory_never_matches() {
  local real missing
  real="$TMP_ROOT/missing/real"
  missing="$TMP_ROOT/missing/gone"
  mkdir -p "$real"
  fm_same_physical_dir "$missing" "$real" && fail "a missing path matched an existing directory"
  fm_same_physical_dir "$real" "$missing" && fail "an existing directory matched a missing path"
  fm_same_physical_dir "" "$real" && fail "an empty path matched"
  pass "a missing or empty path never matches"
}

test_dir_identity_is_shared_by_aliases_and_unique_per_object() {
  local real link other id_real id_link id_other
  real="$TMP_ROOT/ident/real"
  link="$TMP_ROOT/ident/link"
  other="$TMP_ROOT/ident/other"
  mkdir -p "$real" "$other"
  ln -s "$real" "$link"
  id_real=$(fm_dir_identity "$real") || fail "dir identity failed on a real directory"
  id_link=$(fm_dir_identity "$link") || fail "dir identity failed through a symlink alias"
  id_other=$(fm_dir_identity "$other") || fail "dir identity failed on a second directory"
  [ -n "$id_real" ] || fail "dir identity was empty"
  [ "$id_real" = "$id_link" ] || fail "an alias reported a different device:inode than its target"
  [ "$id_real" != "$id_other" ] || fail "two different directories shared a device:inode"
  pass "device:inode is shared by aliases and distinct per directory object"
}

test_identical_string_matches
test_alias_to_same_object_matches
test_distinct_directories_do_not_match
test_missing_directory_never_matches
test_dir_identity_is_shared_by_aliases_and_unique_per_object

echo "# all fm-path-lib tests passed"
