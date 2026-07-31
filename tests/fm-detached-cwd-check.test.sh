#!/usr/bin/env bash
# Behavior tests for bin/fm-detached-cwd-check.sh - the deterministic gate that
# keeps a detached Paseo root agent's runtime cwd outside every firstmate-owned
# directory (the detached-paseo-agent skill is the only caller).
#
# All hermetic over temp dirs; the check is driven only through its executable
# interface with FM_ROOT_OVERRIDE / FM_HOME / FM_STATE_OVERRIDE /
# FM_PROJECTS_OVERRIDE / FM_DATA_OVERRIDE.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-detached-cwd-check.sh"
[ -x "$CHECK" ] || fail "bin/fm-detached-cwd-check.sh must be executable"

TMP_ROOT=$(fm_test_tmproot fm-detached-cwd)

# Fixture firstmate layout: a code root, a distinct operational home with a
# projects tree and a registered clone, plus one active task worktree recorded in
# state/<id>.meta. A "safe" tree and the shared parent live outside all of it.
CODE="$TMP_ROOT/fmcode"
HOME_DIR="$TMP_ROOT/home"
WT="$TMP_ROOT/wt/task1"
SAFE="$TMP_ROOT/user/code"
PROJECTS="$TMP_ROOT/relocated-projects"
SECOND_HOME="$TMP_ROOT/secondmate-home"
mkdir -p \
  "$CODE/bin" \
  "$HOME_DIR/data" \
  "$HOME_DIR/state" \
  "$HOME_DIR/projects/alpha/src" \
  "$PROJECTS/beta/src" \
  "$SECOND_HOME/data/private" \
  "$WT/pkg" \
  "$SAFE/sub" \
  "$HOME_DIR/sub"
printf 'worktree=%s\n' "$WT" > "$HOME_DIR/state/task1.meta"
printf -- '- sm - registered idle secondmate (home: %s; scope: fixture; projects: beta; added 2026-07-30)\n' "$SECOND_HOME" > "$HOME_DIR/data/secondmates.md"

run_check() {
  FM_ROOT_OVERRIDE="$CODE" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_PROJECTS_OVERRIDE="$PROJECTS" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    bash "$CHECK" "$1" 2>&1
}

expect_safe() {
  local candidate=$1 label=$2 out status
  out=$(run_check "$candidate"); status=$?
  expect_code 0 "$status" "$label: expected SAFE (exit 0)"
  assert_contains "$out" "SAFE " "$label: output must announce SAFE"
  pass "fm-detached-cwd-check: $label"
}

expect_unsafe() {
  local candidate=$1 label=$2 out status
  out=$(run_check "$candidate"); status=$?
  expect_code 1 "$status" "$label: expected UNSAFE (exit 1)"
  assert_contains "$out" "UNSAFE" "$label: output must announce UNSAFE"
  pass "fm-detached-cwd-check: $label"
}

# --- safe candidates ---------------------------------------------------------

test_safe_outside_directory() {
  expect_safe "$SAFE" "a non-firstmate directory outside the home is permitted"
}

test_safe_parent_of_home_is_allowed() {
  # A candidate that merely CONTAINS firstmate (like /Users/jacobcole/code) is
  # allowed; only a candidate INSIDE firstmate is refused.
  expect_safe "$TMP_ROOT" "the shared parent that contains the firstmate home is permitted"
}

# --- refused: inside firstmate-owned roots -----------------------------------

test_refuse_fm_root_itself() {
  expect_unsafe "$CODE" "the firstmate code root itself is refused"
}

test_refuse_inside_fm_root() {
  expect_unsafe "$CODE/bin" "a directory inside the firstmate code root is refused"
}

test_refuse_fm_home_itself() {
  expect_unsafe "$HOME_DIR" "the operational home itself is refused"
}

test_refuse_inside_fm_home() {
  expect_unsafe "$HOME_DIR/state" "a directory inside the operational home is refused"
}

test_refuse_projects_root() {
  expect_unsafe "$PROJECTS" "the configured projects root is refused"
}

test_refuse_inside_configured_projects_root() {
  expect_unsafe "$PROJECTS/beta/src" "a directory inside the configured projects root is refused"
}

test_refuse_inside_registered_secondmate_home() {
  expect_unsafe "$SECOND_HOME/data/private" "a directory inside a registered idle secondmate home is refused"
}

test_refuse_inside_active_worktree() {
  expect_unsafe "$WT" "an active task worktree is refused"
  expect_unsafe "$WT/pkg" "a directory inside an active task worktree is refused"
}

# --- refused: bypass attempts ------------------------------------------------

test_refuse_relative_path() {
  expect_unsafe "relative/path" "a relative candidate path is refused (ambiguous)"
}

test_refuse_nonexistent_path() {
  expect_unsafe "$TMP_ROOT/does-not-exist" "a nonexistent candidate is refused"
}

test_refuse_traversal_into_home() {
  # A textually 'safe-looking' path whose .. segments escape back into the home.
  expect_unsafe "$SAFE/../../home" "a .. traversal that lands inside the home is refused"
}

test_refuse_traversal_via_home_dotdot() {
  expect_unsafe "$HOME_DIR/sub/.." "a .. traversal resolving to the home itself is refused"
}

test_refuse_symlink_into_fm_root() {
  local link="$TMP_ROOT/evil-link"
  ln -sf "$CODE" "$link"
  expect_unsafe "$link" "a symlink pointing into the firstmate code root is refused"
  rm -f "$link"
}

test_refuse_symlink_into_home() {
  local link="$TMP_ROOT/evil-home-link"
  ln -sf "$HOME_DIR/projects" "$link"
  expect_unsafe "$link" "a symlink pointing into the projects tree is refused"
  rm -f "$link"
}

test_refuse_alternate_case_spelling() {
  # On a case-insensitive filesystem the OS resolves the mixed-case spelling to
  # the real firstmate root (device+inode identity catches it); on a
  # case-sensitive filesystem the path simply does not exist. Either way the
  # candidate must be refused, so an alternate spelling can never bypass the gate.
  expect_unsafe "$TMP_ROOT/FMCODE" "an alternate/case-variant spelling of the code root cannot bypass the gate"
}

test_safe_outside_directory
test_safe_parent_of_home_is_allowed
test_refuse_fm_root_itself
test_refuse_inside_fm_root
test_refuse_fm_home_itself
test_refuse_inside_fm_home
test_refuse_projects_root
test_refuse_inside_configured_projects_root
test_refuse_inside_registered_secondmate_home
test_refuse_inside_active_worktree
test_refuse_relative_path
test_refuse_nonexistent_path
test_refuse_traversal_into_home
test_refuse_traversal_via_home_dotdot
test_refuse_symlink_into_fm_root
test_refuse_symlink_into_home
test_refuse_alternate_case_spelling
