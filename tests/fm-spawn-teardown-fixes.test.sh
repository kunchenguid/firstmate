#!/usr/bin/env bash
# Regression tests for three defect fixes:
#   1. fm-spawn: PROJ=${POS[1]:-} guards against bash 3.2 set-u crash when no
#      project arg is supplied (POS[1] unset).
#   2. fm-spawn: resolve_project_dir_arg routes bare names (no slash) through
#      $PROJECTS/<name> instead of treating them as literal paths.
#   3. fm-teardown: teardown_treehouse_lease_is_ours() skips the treehouse return
#      and emits a warning when treehouse status does not show the slot in-use.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-teardown-fixes)

# --- Fix 1: PROJ=${POS[1]:-} - no crash when project arg is absent -----------

# Run spawn with only a task ID (no project), under bash 3.2 set-u semantics.
# Old code: PROJ=${POS[1]} would blow up with "unbound variable" before reaching
# any meaningful error. New code: PROJ=${POS[1]:-} returns empty string silently.
test_spawn_no_project_arg_does_not_crash_with_unbound_variable() {
  local home out status
  home="$TMP_ROOT/no-proj-home"
  mkdir -p "$home/data"

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    "$SPAWN" nope-no-proj-z1 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "no-proj: spawn should fail (no brief), not succeed"
  # The bug would print something like: "bash: POS[1]: unbound variable"
  # After the fix, no unbound-variable message should appear.
  printf '%s\n' "$out" | grep -i 'unbound variable' >/dev/null \
    && fail "no-proj: got 'unbound variable' crash - fix regressed"
  # The error should be about a missing brief or empty project, not the array.
  printf '%s\n' "$out" | grep -iE 'brief|project|no brief' >/dev/null \
    || fail "no-proj: unexpected error (not brief/project related): $out"
  pass "spawn with no project arg does not crash with unbound variable (fix 1)"
}

# --- Fix 2: resolve_project_dir_arg routes bare names through \$PROJECTS ------

# Spawn with a bare project name (no slash). Old code: the bare name was treated
# as a literal path, so fm-spawn tried cd into the bare name directly from cwd.
# New code: bare names resolve through $PROJECTS/<name>.
test_spawn_bare_project_name_resolves_through_projects_dir() {
  local home projects out status
  home="$TMP_ROOT/bare-name-home"
  projects="$TMP_ROOT/bare-name-projects"
  mkdir -p "$home/data" "$projects/myrepo"

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE="$projects" FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    "$SPAWN" nope-bare-z2 myrepo 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "bare-name: spawn should fail (no brief)"
  # With the fix, the brief lookup must use the path under $projects, not the bare name.
  expected_brief="$home/data/nope-bare-z2/brief.md"
  printf '%s\n' "$out" | grep -F "no brief at $expected_brief" >/dev/null \
    || fail "bare-name: expected 'no brief at $expected_brief', got: $out"
  # Must not have tried to resolve 'myrepo' from cwd (the literal bare name).
  printf '%s\n' "$out" | grep -E "cd: myrepo|No such file.*myrepo" >/dev/null \
    && fail "bare-name: spawn tried to cd into bare project name 'myrepo' from cwd (fix regressed)"
  pass "bare project name is resolved through \$PROJECTS dir, not as literal path (fix 2)"
}

# Verify that an already-pathed argument (containing /) is passed through unchanged.
test_spawn_already_pathed_project_arg_passes_through() {
  local home projects out status dir
  home="$TMP_ROOT/pathed-home"
  projects="$TMP_ROOT/pathed-projects"
  dir="$TMP_ROOT/explicit-dir/myrepo"
  mkdir -p "$home/data" "$projects" "$dir"

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE="$projects" FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    "$SPAWN" nope-pathed-z3 "$dir" 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "pathed: spawn should fail (no brief)"
  expected_brief="$home/data/nope-pathed-z3/brief.md"
  printf '%s\n' "$out" | grep -F "no brief at $expected_brief" >/dev/null \
    || fail "pathed: expected 'no brief at $expected_brief', got: $out"
  pass "absolute path project arg is passed through unchanged (fix 2 - */* branch)"
}

# --- Fix 4: treehouse lease guard skips return when slot is not in-use --------

# Build a minimal teardown sandbox (worktree + meta, fakebin with mocks).
make_teardown_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$fakebin"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_teardown_meta() {
  local case_dir=$1
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
}

run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

# Teardown where treehouse is present but reports the slot NOT in-use:
# the return must be SKIPPED and a warning emitted.
test_teardown_skips_return_when_treehouse_slot_not_in_use() {
  local case_dir rc return_called_file
  case_dir=$(make_teardown_case treehouse-not-in-use)
  write_teardown_meta "$case_dir"

  # The wt is already pushed to origin so the landed-work check passes.
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "task work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  return_called_file="$case_dir/treehouse-return-called"

  # treehouse status: returns output that does NOT include "in-use" for our wt.
  # treehouse return --force: records a call (should NOT be called).
  local abs_wt
  abs_wt=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  status)
    # Report a different slot as in-use, not our worktree.
    printf 'slot 0: in-use /some/other/worktree\\n'
    exit 0
    ;;
  return)
    printf '%s\n' "treehouse-return-called" >> "$return_called_file"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "not-in-use: teardown should exit 0 when skipping unowned slot (got rc=$rc; stderr: $(cat "$case_dir/stderr"))"
  grep -q "not currently held as an in-use treehouse lease" "$case_dir/stderr" \
    || fail "not-in-use: expected warning about unowned treehouse slot in stderr"
  [ ! -f "$return_called_file" ] \
    || fail "not-in-use: treehouse return was called despite slot not being in-use"
  pass "teardown skips treehouse return and warns when slot is not in-use (fix 4)"
}

# Teardown where treehouse status exits 0 but produces empty output (treehouse
# present but project not pool-managed or no pool info). The function fails open
# (returns 0) and teardown proceeds to attempt the return, which succeeds.
test_teardown_failopen_when_treehouse_status_has_empty_output() {
  local case_dir rc
  case_dir=$(make_teardown_case treehouse-failopen)
  write_teardown_meta "$case_dir"

  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "task work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  # Treehouse exits 0 but prints nothing for status: lease check fails-open,
  # teardown proceeds and calls treehouse return (which also succeeds silently).
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "failopen: teardown should succeed when treehouse status is empty (got rc=$rc; stderr: $(cat "$case_dir/stderr"))"
  grep -q "not currently held as an in-use treehouse lease" "$case_dir/stderr" \
    && fail "failopen: unexpected lease warning when status was empty (fail-open should not warn)"
  pass "teardown proceeds normally when treehouse status is empty - fails open (fix 4)"
}

# Teardown where treehouse reports the slot as in-use for our wt: return proceeds.
test_teardown_returns_when_treehouse_slot_is_ours() {
  local case_dir rc return_called_file
  case_dir=$(make_teardown_case treehouse-in-use)
  write_teardown_meta "$case_dir"

  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "task work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  return_called_file="$case_dir/treehouse-return-called"
  local abs_wt
  abs_wt=$(cd "$case_dir/wt" && pwd -P)

  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  status)
    printf 'slot 0: in-use %s\\n' "$abs_wt"
    exit 0
    ;;
  return)
    printf '%s\n' "treehouse-return-called" >> "$return_called_file"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "in-use: teardown should succeed when slot is ours (got rc=$rc; stderr: $(cat "$case_dir/stderr"))"
  grep -q "not currently held as an in-use treehouse lease" "$case_dir/stderr" \
    && fail "in-use: unexpected skip warning when slot IS ours"
  [ -f "$return_called_file" ] \
    || fail "in-use: treehouse return was NOT called when slot is ours"
  pass "teardown calls treehouse return when slot is confirmed in-use for our path (fix 4)"
}

test_spawn_no_project_arg_does_not_crash_with_unbound_variable
test_spawn_bare_project_name_resolves_through_projects_dir
test_spawn_already_pathed_project_arg_passes_through
test_teardown_skips_return_when_treehouse_slot_not_in_use
test_teardown_failopen_when_treehouse_status_has_empty_output
test_teardown_returns_when_treehouse_slot_is_ours
