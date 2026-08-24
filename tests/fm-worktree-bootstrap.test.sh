#!/usr/bin/env bash
# tests/fm-worktree-bootstrap.test.sh - behavior tests for
# bin/fm-worktree-bootstrap.sh: filling a task worktree's untracked dev
# environment from this home's own project clone under projects/<name>,
# driven through the command line against synthetic fixtures only.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worktree-bootstrap) || fail "could not create temp root"

HOME_DIR="$TMP_ROOT/home"
PROJ="$HOME_DIR/projects/myapp"
mkdir -p "$PROJ/state/v3/d1"

# The task worktree must be a real git worktree named after the project clone
# (basename identity), so build one repo and one pool-style worktree.
MAIN_REPO="$TMP_ROOT/main-repo"
WT="$TMP_ROOT/pool/myapp"
fm_git_worktree "$MAIN_REPO" "$WT" crew-side || fail "could not build worktree fixture"

# The project clone doubles as its own git checkout so the self-copy guard has
# a real top level to resolve; extra fixture files live beside the tracked ones.
fm_git_init_commit "$PROJ"

BOOT="$ROOT/bin/fm-worktree-bootstrap.sh"

run_boot() {  # <target-dir> [extra env via caller]; echoes combined output
  local target=$1
  FM_HOME="$HOME_DIR" "$BOOT" "$target" 2>&1
}

test_no_project_clone_is_a_silent_noop() {
  local out rc
  out=$(FM_HOME="$TMP_ROOT/other-home" "$BOOT" "$WT" 2>&1); rc=$?
  expect_code 0 "$rc" "a home without this project's clone must not fail the task"
  assert_contains "$out" "nothing to copy" "a missing project clone must say it is a no-op"
  pass "bootstrap: an absent project clone is a no-op, not an error"
}

test_missing_declaration_is_a_noop() {
  local out rc
  out=$(run_boot "$WT"); rc=$?
  expect_code 0 "$rc" "a project declaring no .worktreeinclude must not fail"
  assert_contains "$out" "declares no .worktreeinclude" "an absent declaration must be reported as a no-op"
  pass "bootstrap: a worktree with no .worktreeinclude gets nothing copied"
}

test_refuses_to_copy_onto_the_source_clone() {
  local out rc
  out=$(run_boot "$PROJ"); rc=$?
  expect_code 0 "$rc" "the self-copy guard must not fail the task"
  assert_contains "$out" "refusing to copy onto itself" "running inside the source clone itself must refuse"
  pass "bootstrap: refuses to copy the project clone onto itself"
}

test_copies_declared_entries_and_skips_comments() {
  cat > "$WT/.worktreeinclude" <<'EOF'
# dev material the worktree needs but git never carries

.dev.vars
state/v3/d1/main.sqlite # local database state
EOF
  printf 'SECRET=dev-only\n' > "$PROJ/.dev.vars"
  printf 'active-db\n' > "$PROJ/state/v3/d1/main.sqlite"

  local out rc
  out=$(cd "$WT" && FM_HOME="$HOME_DIR" "$BOOT" 2>&1); rc=$?
  expect_code 0 "$rc" "copying declared entries must succeed (got: $out)"
  [ "$(cat "$WT/.dev.vars" 2>/dev/null)" = "SECRET=dev-only" ] \
    || fail ".dev.vars was not copied from the project clone"
  [ "$(cat "$WT/state/v3/d1/main.sqlite" 2>/dev/null)" = active-db ] \
    || fail "the declared database state file was not copied from the project clone"
  pass "bootstrap: copies declared files from the project clone (comments and blanks ignored)"
}

test_absent_entry_is_skipped_silently_and_never_fails() {
  printf '.dev.vars\nmissing-elsewhere.txt\n' > "$WT/.worktreeinclude"
  local out rc
  out=$(run_boot "$WT"); rc=$?
  expect_code 0 "$rc" "an absent source must not fail the task"
  assert_not_contains "$out" "warning:" "an absent source must be skipped silently"
  assert_contains "$out" "absent in the project clone" "the summary must account for skipped entries"
  pass "bootstrap: an absent source is skipped silently and stays a success"
}

# Fresh-copy semantics without any deletion: recycled content is overwritten,
# stale extras are left alone for teardown to discard with the whole worktree.
test_overwrites_stale_copy_but_deletes_nothing() {
  printf 'stale-db\n' > "$WT/state/v3/d1/main.sqlite"
  printf 'orphan-from-prior-crew\n' > "$WT/state/v3/d1/orphan.sqlite"
  printf 'active-db-fresh\n' > "$PROJ/state/v3/d1/main.sqlite"
  printf 'state/v3/d1/main.sqlite\n' > "$WT/.worktreeinclude"
  local out rc
  out=$(run_boot "$WT"); rc=$?
  expect_code 0 "$rc" "overwriting a stale destination must succeed (got: $out)"
  [ "$(cat "$WT/state/v3/d1/main.sqlite" 2>/dev/null)" = active-db-fresh ] \
    || fail "a recycled worktree kept its stale file instead of a fresh copy"
  [ "$(cat "$WT/state/v3/d1/orphan.sqlite" 2>/dev/null)" = orphan-from-prior-crew ] \
    || fail "bootstrap deleted a stale extra file; it has no deletion path - teardown owns discarding"
  pass "bootstrap: overwrites stale content file by file and deletes nothing"
}

test_refuses_unsafe_declaration_paths() {
  local out rc
  for bad in "/etc/passwd" "../escape" "." "./"; do
    printf '%s\n' "$bad" > "$WT/.worktreeinclude"
    out=$(run_boot "$WT"); rc=$?
    [ "$rc" -ne 0 ] || fail "unsafe declaration path '$bad' must be refused, not acted on"
    assert_contains "$out" "refusing unsafe path" "a malformed declaration must name the offending entry"
  done
  pass "bootstrap: refuses absolute, parent-relative, and clone-root declaration paths"
}

# Best-effort contract: a copy that cannot land is a stderr warning and exit 0,
# and the other declared entries around it are still copied.
test_copy_failure_warns_without_failing_the_task() {
  printf 'file\n' > "$WT/sub"
  mkdir -p "$PROJ/sub"
  printf 'unlandable\n' > "$PROJ/sub/file.txt"
  printf '.dev.vars\nsub/file.txt\n' > "$WT/.worktreeinclude"
  local out rc
  out=$(run_boot "$WT"); rc=$?
  expect_code 0 "$rc" "a failed copy must warn, not fail the task"
  assert_contains "$out" "warning:" "a failed copy must leave a stderr warning behind"
  [ "$(cat "$WT/.dev.vars" 2>/dev/null)" = "SECRET=dev-only" ] \
    || fail "an unrelated entry must still be copied when another entry fails"
  pass "bootstrap: a copy failure warns and the rest of the list proceeds"
}

# A declared directory that cannot be read (permissions, broken mount) must not
# masquerade as a successful copy - the exact silent-miss this tool exists to
# prevent. It stays best-effort: warn, count a failure, keep going.
test_unreadable_declared_directory_warns_and_is_not_counted_copied() {
  [ "$(id -u)" -eq 0 ] && { pass "bootstrap: unreadable-directory check needs a non-root runner"; return 0; }
  rm -rf "$PROJ/state"
  mkdir -p "$PROJ/state/d1"
  printf 'unreadable-db\n' > "$PROJ/state/d1/main.sqlite"
  printf 'orphan\n' > "$PROJ/.dev.vars"
  printf '.dev.vars\nstate\n' > "$WT/.worktreeinclude"
  chmod 000 "$PROJ/state"
  local out rc
  out=$(run_boot "$WT"); rc=$?
  chmod 755 "$PROJ/state"
  expect_code 0 "$rc" "an unreadable declared directory must stay best-effort exit 0"
  assert_contains "$out" "warning:" "an unreadable declared directory must leave a stderr warning behind"
  assert_contains "$out" "1 copy failures" "the summary must count an unreadable directory as a failure, not copied"
  [ ! -e "$WT/state/d1/main.sqlite" ] || fail "nothing can be copied from an unreadable source directory"
  [ "$(cat "$WT/.dev.vars" 2>/dev/null)" = orphan ] \
    || fail "an unrelated entry must still be copied when another entry's source cannot be read"
  pass "bootstrap: an unreadable declared directory warns instead of counting as copied"
}

test_no_project_clone_is_a_silent_noop
test_missing_declaration_is_a_noop
test_refuses_to_copy_onto_the_source_clone
test_copies_declared_entries_and_skips_comments
test_absent_entry_is_skipped_silently_and_never_fails
test_overwrites_stale_copy_but_deletes_nothing
test_refuses_unsafe_declaration_paths
test_copy_failure_warns_without_failing_the_task
test_unreadable_declared_directory_warns_and_is_not_counted_copied

echo "# all fm-worktree-bootstrap tests passed"
