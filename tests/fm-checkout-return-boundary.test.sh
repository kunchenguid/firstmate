#!/usr/bin/env bash
# Tests for the destructive Treehouse-return boundary walk in
# bin/fm-checkout-lock-lib.sh (fm_checkout_treehouse_return_locked).
#
# The walk validates that `treehouse return --force` starts from an acceptable
# worktree boundary. It must refuse a redirected target - a symlinked path
# component, a non-directory, a mount point, a cross-device child - and it must
# NOT refuse a tree merely because ordinary symlinks live inside it. The root
# descriptor remains open across exec so the return stays bound to that root.
# Descendant validation is point-in-time: descendant descriptors are released
# after their subtrees are checked instead of being inherited by Treehouse.
#
# That distinction is the regression this file pins. The walk originally
# refused on ANY symlink entry anywhere in the tree, which made every repo
# whose own committed layout uses symlinks permanently un-reapable: relvino
# carries 177 of them in every worktree (its CLAUDE.md -> AGENTS.md convention
# and its symlinked skills), so no crewmate there could ever be torn down. A
# symlink ENTRY cannot redirect this operation - it is inspected with
# follow_symlinks=False, it is not a directory so it is never queued for
# descent, and each descent opens with O_NOFOLLOW and re-proves identity,
# single-device, and non-mount. Only a symlinked ANCESTOR redirects, and that
# is still refused. This matches how fm-teardown.sh's sibling validator
# (removal_tree_operation) has always treated in-tree symlinks: skip, never
# follow.
#
# The embedded program is extracted from the library rather than reimplemented,
# so these assertions cannot drift away from the code they describe. It ends in
# execvp("treehouse", ...), so with a stub treehouse on PATH exit 0 means the
# boundary was ACCEPTED and exit 74 means it was REFUSED.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-checkout-lock-lib.sh"
fm_test_tmproot_into TMP_ROOT fm-checkout-return-boundary
BOUNDARY_PY="$TMP_ROOT/boundary.py"
REFUSED=74

extract_boundary_program() {
  mkdir -p "$TMP_ROOT"
  python3 - "$LIB" "$BOUNDARY_PY" <<'PY'
import sys

lib_path, out_path = sys.argv[1:]
with open(lib_path, encoding="utf-8") as stream:
    text = stream.read()

marker = "if fm_run_bounded \"$timeout\" python3 -c '"
start = text.index(marker) + len(marker)
end = text.index("\n' \"$checkout\" \"$project\" \"$mode\"", start)
program = text[start:end]
# The program is embedded in a single-quoted shell word, so it can contain no
# apostrophes and needs no unescaping. Assert that rather than assume it.
if "'" in program:
    raise SystemExit("embedded boundary program unexpectedly contains a quote")
with open(out_path, "w", encoding="utf-8") as stream:
    stream.write(program)
PY
}

make_case() {  # <name> -> prints "<case_dir> <project> <worktree>"
  local name=$1 case_dir project worktree
  case_dir="$TMP_ROOT/$name"
  project="$case_dir/project"
  worktree="$case_dir/project/wt"
  mkdir -p "$worktree/nested"
  printf 'content\n' > "$worktree/file"
  printf 'content\n' > "$worktree/nested/file"
  printf '%s %s %s' "$case_dir" "$project" "$worktree"
}

run_boundary() {  # <project> <target> [cd-dir] [fd-limit] -> exit status
  local project=$1 target=$2 cd_dir=${3:-$1} fd_limit=${4:-} fakebin status
  fakebin=$(fm_fakebin "$(dirname "$project")/fake")
  fm_fake_exit0 "$fakebin" treehouse
  (
    if [ -n "$fd_limit" ]; then
      ulimit -n "$fd_limit" || exit 71
    fi
    cd "$cd_dir" || exit 70
    PATH="$fakebin:$PATH" python3 "$BOUNDARY_PY" "$target" "$project" --force
  ) >/dev/null 2>&1
  status=$?
  printf '%s' "$status"
}

run_boundary_low_fd() {  # <project> <target> <open-file-limit> -> exit status
  local project=$1 target=$2 open_file_limit=$3 fakebin status
  fakebin=$(fm_fakebin "$(dirname "$project")/fake-low-fd")
  fm_fake_exit0 "$fakebin" treehouse
  (
    ulimit -n "$open_file_limit" || exit 70
    cd "$project" || exit 71
    PATH="$fakebin:$PATH" python3 "$BOUNDARY_PY" "$target" "$project" --force
  ) >/dev/null 2>&1
  status=$?
  printf '%s' "$status"
}

test_in_tree_symlinks_are_accepted() {
  local rec case_dir project worktree status
  rec=$(make_case in-tree-symlinks)
  read -r case_dir project worktree <<EOF
$rec
EOF
  : "$case_dir"
  # Exactly relvino's shape: a committed file symlink at the root, a symlink
  # deeper in the tree, and a symlinked directory - all pointing INSIDE.
  ln -s AGENTS.md "$worktree/CLAUDE.md"
  ln -s ../file "$worktree/nested/link-to-file"
  ln -s nested "$worktree/link-to-dir"
  status=$(run_boundary "$project" "$worktree")
  expect_code 0 "$status" "a worktree containing ordinary in-tree symlinks must be returnable"
  pass "in-tree symlinks are skipped, not refused"
}

test_symlink_escaping_the_tree_is_still_not_followed() {
  local rec case_dir project worktree outside status
  rec=$(make_case escaping-symlink)
  read -r case_dir project worktree <<EOF
$rec
EOF
  outside="$case_dir/outside"
  mkdir -p "$outside/keep"
  printf 'precious\n' > "$outside/keep/file"
  # A symlink pointing clean out of the worktree. It is still only an ENTRY, so
  # the walk accepts the tree - but it must never have descended through it,
  # which the next assertion proves by the target surviving untouched.
  ln -s "$outside" "$worktree/escape"
  status=$(run_boundary "$project" "$worktree")
  expect_code 0 "$status" "an escaping symlink entry must not fail the boundary walk"
  assert_present "$outside/keep/file" "boundary walk followed a symlink out of the tree"
  pass "an escaping symlink is never followed"
}

test_symlinked_ancestor_is_refused() {
  local rec case_dir project worktree real status
  rec=$(make_case symlinked-ancestor)
  read -r case_dir project worktree <<EOF
$rec
EOF
  real="$case_dir/real-worktree"
  mv "$worktree" "$real"
  ln -s "$real" "$worktree"
  status=$(run_boundary "$project" "$worktree")
  expect_code "$REFUSED" "$status" "a symlinked path component must still be refused"
  pass "a symlinked ancestor is refused"
}

test_non_directory_target_is_refused() {
  local rec case_dir project worktree status
  rec=$(make_case non-directory-target)
  read -r case_dir project worktree <<EOF
$rec
EOF
  : "$worktree"
  printf 'not a directory\n' > "$case_dir/project/plain"
  status=$(run_boundary "$project" "$case_dir/project/plain")
  expect_code "$REFUSED" "$status" "a non-directory removal target must be refused"
  pass "a non-directory target is refused"
}

# The walk binds itself to the caller's working directory: the destructive
# return runs `treehouse return --force .` from the project, so it refuses
# outright if the process is not actually standing in the project it was told
# about. Nothing downstream can then be pointed at a different pool.
test_project_cwd_mismatch_is_refused() {
  local rec case_dir project worktree status
  rec=$(make_case foreign-cwd)
  read -r case_dir project worktree <<EOF
$rec
EOF
  mkdir -p "$case_dir/other"
  status=$(run_boundary "$case_dir/other" "$worktree" "$project")
  expect_code "$REFUSED" "$status" "a project argument that is not the working directory must be refused"
  pass "a project/cwd mismatch is refused"
}

test_realistically_large_and_deep_tree_respects_fd_limit() {
  local rec case_dir project worktree fakebin status
  rec=$(make_case realistically-large-tree)
  read -r case_dir project worktree <<EOF
$rec
EOF
  : "$case_dir"
  if ! python3 - "$worktree" <<'PY'
import os
import sys

root = sys.argv[1]
for index in range(42001):
    os.mkdir(os.path.join(root, f"directory-{index:05d}"))
deep = os.path.join(root, "deep")
os.mkdir(deep)
for _ in range(130):
    deep = os.path.join(deep, "d")
    os.mkdir(deep)
PY
  then
    fail "could not generate the greater-than-42,000-directory capacity fixture"
  fi
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/treehouse" <<'SH'
#!/bin/sh
root_descriptor=${FM_TREEHOUSE_RETURN_ROOT_FD:-}
[ -n "$root_descriptor" ] || exit 91
[ "$FM_TREEHOUSE_RETURN_BOUNDARY_FDS" = "$root_descriptor" ] || exit 92
[ -d "/dev/fd/$root_descriptor" ] || exit 93
for candidate in /dev/fd/*; do
  [ -d "$candidate" ] || continue
  [ "${candidate##*/}" = "$root_descriptor" ] || exit 94
done
exit 0
SH
  chmod +x "$fakebin/treehouse"
  (
    ulimit -n 128 || exit 71
    cd "$project" || exit 70
    PATH="$fakebin:$PATH" python3 "$BOUNDARY_PY" "$worktree" "$project"
  ) >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "a worktree with more than 42,000 directories and depth beyond the descriptor limit must return"
  pass "a real greater-than-42,000-directory fixture keeps only its root descriptor across exec"
}

extract_boundary_program
test_in_tree_symlinks_are_accepted
test_symlink_escaping_the_tree_is_still_not_followed
test_symlinked_ancestor_is_refused
test_non_directory_target_is_refused
test_project_cwd_mismatch_is_refused
test_realistically_large_and_deep_tree_respects_fd_limit
