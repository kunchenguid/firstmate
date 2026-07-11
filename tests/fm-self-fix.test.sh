#!/usr/bin/env bash
# Behavior tests for bin/fm-self-fix.sh.
#
# Regression coverage for the FM_HOME-aware brief precheck: when FM_HOME
# differs from the repo root, the brief lives under $FM_HOME/data/ and
# the precheck must find it there instead of false-refusing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-self-fix)

# Scratch worktree root must stay OUTSIDE FM_HOME, but point it at a
# temp location so leftover artifacts are cleaned up with the rest of
# the test fixture.
FM_SELFFIX_ROOT="$TMP_ROOT/selffix-scratch"

# ------------------------------------------------------------------
# With FM_HOME set to a directory different from the repo root and
# the brief authored under $FM_HOME/data/<id>/, the precheck must
# find it and proceed (no "no brief" refusal).
#
# Pre-create the scratch worktree path so the run halts at the
# "worktree path already exists" guard, which is strictly after the
# brief check but before any real `git worktree add` or spawn. That
# keeps the test hermetic - no leaked branch, worktree, or tmux
# window in the repo under test - while still proving the brief was
# resolved under FM_HOME.
test_brief_found_with_fmhome_set() {
  local home brief id out status wt
  home="$TMP_ROOT/ops-home"
  id="selffix-brief-a1"
  brief="$home/data/$id/brief.md"
  wt="$FM_SELFFIX_ROOT/$id"

  mkdir -p "$(dirname "$brief")"
  echo "# task: test self-fix" > "$brief"
  mkdir -p "$wt"

  out=$(FM_HOME="$home" FM_SELFFIX_ROOT="$FM_SELFFIX_ROOT" \
    "$ROOT/bin/fm-self-fix.sh" "$id" 2>&1) && status=$? || status=$?

  assert_not_contains "$out" "no brief" \
    "brief found under FM_HOME must not produce a false refusal (got: $out)"
  assert_contains "$out" "worktree path already exists" \
    "precheck must pass the brief check and stop at the worktree guard (got: $out)"
  pass "fm-self-fix.sh: finds brief under FM_HOME"
}

# With no brief at the resolved path, the precheck must still refuse
# AND print the resolved path in the error message so the failure is
# diagnosable.
test_brief_missing_prints_resolved_path() {
  local home id out status
  home="$TMP_ROOT/ops-home-missing"
  mkdir -p "$home/data"
  id="selffix-brief-b2"

  out=$(FM_HOME="$home" FM_SELFFIX_ROOT="$FM_SELFFIX_ROOT" \
    "$ROOT/bin/fm-self-fix.sh" "$id" 2>&1) && status=$? || status=$?

  expect_code 1 "$status" \
    "fm-self-fix.sh with missing brief should exit 1 (got $status)"
  assert_contains "$out" "no brief" \
    "error message should report the missing brief"
  assert_contains "$out" "$home/data/$id/brief.md" \
    "error message should name the resolved data path ($home/data/$id/brief.md)"
  pass "fm-self-fix.sh: missing brief prints resolved FM_HOME path"
}

test_brief_found_with_fmhome_set
test_brief_missing_prints_resolved_path
