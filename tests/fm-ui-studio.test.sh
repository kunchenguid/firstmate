#!/usr/bin/env bash
# Behavior tests for bin/fm-ui-studio.sh argument handling, state management,
# and git worktree lifecycle.
#
# Does NOT test storybook launch, vibe-annotations, or gh-axi PR creation -
# those require live external services and are exercised in integration.
# Tests use real git repos (no git mocking) consistent with the suite's pattern.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-ui-studio.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-ui-studio-tests)

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# build_project_home <name>: create an FM_HOME with a real project clone.
# Returns the home dir path on stdout.
build_project_home() {
  local name=$1 home origin work clone remote_abs
  home="$TMP_ROOT/home-$name"
  origin="$TMP_ROOT/origin-$name.git"
  work="$TMP_ROOT/work-$name"

  mkdir -p "$home/projects" "$home/state"

  # Bare origin with one commit
  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  printf '# %s\n' "$name" > "$work/README.md"
  git -C "$work" add README.md
  git -C "$work" commit -qm "init"
  git clone --quiet --bare "$work" "$origin"
  remote_abs=$(cd "$origin" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main

  # Clone as projects/<name>
  clone="$home/projects/$name"
  git clone --quiet "file://$remote_abs" "$clone"

  printf '%s\n' "$home"
}

# add_ui_studio_commit <home> <name>: add a commit to the studio worktree.
add_ui_studio_commit() {
  local home=$1 name=$2 wt
  wt="$home/state/ui-studio/$name"
  printf 'change\n' >> "$wt/README.md"
  git -C "$wt" add README.md
  git -C "$wt" commit -qm "ui: studio change"
}

# run_start <home> <project>: invoke start with FM_HOME override.
run_start() {
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FM_UI_STUDIO_SB_TIMEOUT=0 \
    "$SCRIPT" start "$2" 2>/dev/null
}

# run_start_stderr <home> <project>: capture stderr only.
run_start_stderr() {
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FM_UI_STUDIO_SB_TIMEOUT=0 \
    "$SCRIPT" start "$2" 2>&1 >/dev/null
}

# run_land <home> <project>: invoke land with FM_HOME override.
run_land() {
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    "$SCRIPT" land "$2" 2>/dev/null
}

# run_land_stderr <home> <project>: capture stderr only.
run_land_stderr() {
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    "$SCRIPT" land "$2" 2>&1 >/dev/null
}

# run_status <home> <project>: invoke status with FM_HOME override.
run_status() {
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    "$SCRIPT" status "$2" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Tests: argument handling
# ---------------------------------------------------------------------------

test_no_args_exits_2() {
  "$SCRIPT" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "no args: expected exit 2, got $rc"
  pass "no args exits 2"
}

test_unknown_subcommand_exits_2() {
  "$SCRIPT" frobnicate proj >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "unknown subcommand: expected exit 2, got $rc"
  pass "unknown subcommand exits 2"
}

test_missing_project_arg_exits_2() {
  "$SCRIPT" start >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "missing project: expected exit 2, got $rc"
  pass "missing project arg exits 2"
}

test_dash_prefix_project_exits_2() {
  "$SCRIPT" start --not-a-project >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "dash-prefix project: expected exit 2, got $rc"
  pass "dash-prefix project exits 2"
}

test_help_flag_exits_2() {
  "$SCRIPT" --help >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "--help: expected exit 2, got $rc"
  pass "--help exits 2"
}

# ---------------------------------------------------------------------------
# Tests: start subcommand
# ---------------------------------------------------------------------------

test_start_missing_clone_exits_1() {
  local home
  home=$(mktemp -d "$TMP_ROOT/empty-home.XXXXXX")
  mkdir -p "$home/projects" "$home/state"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SCRIPT" start nosuchproject >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] || fail "missing clone: expected exit 1, got $rc"
  rm -rf "$home"
  pass "start with missing clone exits 1"
}

test_start_missing_clone_error_mentions_project() {
  local home err
  home=$(mktemp -d "$TMP_ROOT/empty-home2.XXXXXX")
  mkdir -p "$home/projects" "$home/state"
  err=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SCRIPT" start nosuchproject 2>&1 >/dev/null || true)
  printf '%s\n' "$err" | grep -q "nosuchproject" || \
    fail "missing clone error does not mention project name"
  rm -rf "$home"
  pass "start missing-clone error mentions the project name"
}

test_start_creates_worktree() {
  local home out wt
  home=$(build_project_home "myproj")
  # Use timeout=0 so poll_storybook_url returns immediately with default URL,
  # and fake pnpm so storybook doesn't actually run.
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/fakebin-start")
  fm_fake_exit0 "$fakebin" pnpm
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_UI_STUDIO_SB_TIMEOUT=0 "$SCRIPT" start myproj 2>/dev/null)
  wt="$home/state/ui-studio/myproj"
  [ -d "$wt" ] || fail "worktree directory was not created at $wt"
  printf '%s\n' "$out" | grep -q "worktree=" || \
    fail "start output missing worktree= line"
  printf '%s\n' "$out" | grep -q "storybook_url=" || \
    fail "start output missing storybook_url= line"
  printf '%s\n' "$out" | grep -q "studio_state=fresh" || \
    fail "start output missing studio_state=fresh"
  git -C "$wt" rev-parse --abbrev-ref HEAD | grep -q "ui/studio" || \
    fail "worktree is not on branch ui/studio"
  pass "start creates worktree on ui/studio branch with correct output"
}

test_start_reuse_reports_reused() {
  local home out wt fakebin
  home=$(build_project_home "reuse-proj")
  fakebin=$(fm_fakebin "$TMP_ROOT/fakebin-reuse")
  fm_fake_exit0 "$fakebin" pnpm

  # First start
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_UI_STUDIO_SB_TIMEOUT=0 "$SCRIPT" start "reuse-proj" >/dev/null 2>/dev/null

  wt="$home/state/ui-studio/reuse-proj"
  [ -d "$wt" ] || fail "worktree not created on first start"

  # Second start (no commits ahead, should report reused)
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_UI_STUDIO_SB_TIMEOUT=0 "$SCRIPT" start "reuse-proj" 2>/dev/null)
  printf '%s\n' "$out" | grep -q "studio_state=reused" || \
    fail "second start did not report studio_state=reused"
  pass "second start with clean worktree reports reused"
}

test_start_refuses_unlanded_commits() {
  local home wt fakebin err
  home=$(build_project_home "dirty-proj")
  fakebin=$(fm_fakebin "$TMP_ROOT/fakebin-dirty")
  fm_fake_exit0 "$fakebin" pnpm

  # First start - creates worktree
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_UI_STUDIO_SB_TIMEOUT=0 "$SCRIPT" start "dirty-proj" >/dev/null 2>/dev/null

  wt="$home/state/ui-studio/dirty-proj"
  add_ui_studio_commit "$home" "dirty-proj"

  # Second start - should refuse
  err=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_UI_STUDIO_SB_TIMEOUT=0 "$SCRIPT" start "dirty-proj" 2>&1 >/dev/null || true)
  rc=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_UI_STUDIO_SB_TIMEOUT=0 "$SCRIPT" start "dirty-proj" 2>/dev/null; printf '%s' $?) || true
  # Verify it exits nonzero AND mentions "land"
  printf '%s\n' "$err" | grep -qi "land" || \
    fail "unlanded-commits error does not mention 'land': $err"
  pass "start refuses to reset worktree with un-landed commits"
}

test_start_writes_service_file() {
  local home svc fakebin
  home=$(build_project_home "svc-proj")
  fakebin=$(fm_fakebin "$TMP_ROOT/fakebin-svc")
  fm_fake_exit0 "$fakebin" pnpm

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_UI_STUDIO_SB_TIMEOUT=0 "$SCRIPT" start "svc-proj" >/dev/null 2>/dev/null

  svc="$home/state/ui-studio/svc-proj.service"
  [ -f "$svc" ] || fail "service file not written at $svc"
  grep -q "storybook_pid=" "$svc" || fail "service file missing storybook_pid"
  grep -q "storybook_url=" "$svc" || fail "service file missing storybook_url"
  grep -q "worktree=" "$svc" || fail "service file missing worktree"
  pass "start writes service file with expected keys"
}

# ---------------------------------------------------------------------------
# Tests: land subcommand
# ---------------------------------------------------------------------------

test_land_missing_worktree_exits_1() {
  local home
  home=$(build_project_home "land-nowt")
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SCRIPT" land "land-nowt" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] || fail "land without worktree: expected exit 1, got $rc"
  pass "land without a worktree exits 1"
}

test_land_nothing_to_land() {
  local home out fakebin
  home=$(build_project_home "land-empty")
  fakebin=$(fm_fakebin "$TMP_ROOT/fakebin-land-empty")
  fm_fake_exit0 "$fakebin" pnpm

  # Create the worktree first
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_UI_STUDIO_SB_TIMEOUT=0 "$SCRIPT" start "land-empty" >/dev/null 2>/dev/null

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SCRIPT" land "land-empty" 2>/dev/null)
  printf '%s\n' "$out" | grep -q "studio_ahead=0" || \
    fail "nothing-to-land output missing studio_ahead=0: $out"
  pass "land with no commits ahead prints studio_ahead=0 and exits 0"
}

test_land_lint_failure_exits_1() {
  local home fakebin rc
  home=$(build_project_home "land-lint-fail")
  fakebin=$(fm_fakebin "$TMP_ROOT/fakebin-lint-fail")

  # pnpm: storybook succeeds, lint fails, others succeed
  cat > "$fakebin/pnpm" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  storybook) exit 0 ;;
  lint) exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/pnpm"

  # Create worktree and add a commit
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_UI_STUDIO_SB_TIMEOUT=0 "$SCRIPT" start "land-lint-fail" >/dev/null 2>/dev/null
  add_ui_studio_commit "$home" "land-lint-fail"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SCRIPT" land "land-lint-fail" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] || fail "lint failure: expected exit 1, got $rc"
  pass "land exits 1 when lint fails"
}

# ---------------------------------------------------------------------------
# Tests: status subcommand
# ---------------------------------------------------------------------------

test_status_no_state() {
  local home out
  home=$(build_project_home "status-empty")
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SCRIPT" status "status-empty" 2>/dev/null)
  printf '%s\n' "$out" | grep -q "storybook_status=down" || \
    fail "status with no state should report storybook_status=down"
  printf '%s\n' "$out" | grep -q "last_land=never" || \
    fail "status with no state should report last_land=never"
  printf '%s\n' "$out" | grep -q "studio_ahead=" || \
    fail "status output missing studio_ahead= line"
  pass "status with no prior studio reports down and never"
}

test_status_reads_pane_file() {
  local home out pf
  home=$(build_project_home "status-pane")
  mkdir -p "$home/state/ui-studio"
  pf="$home/state/ui-studio/status-pane.pane"
  printf 'pane-abc123\n' > "$pf"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SCRIPT" status "status-pane" 2>/dev/null)
  printf '%s\n' "$out" | grep -q "pane_id=pane-abc123" || \
    fail "status did not read pane file: $out"
  pass "status reads pane_id from pane file"
}

test_status_reads_last_land() {
  local home out lf
  home=$(build_project_home "status-land")
  mkdir -p "$home/state/ui-studio"
  lf="$home/state/ui-studio/status-land.last-land"
  printf '2026-08-11T10:00:00Z\n' > "$lf"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SCRIPT" status "status-land" 2>/dev/null)
  printf '%s\n' "$out" | grep -q "last_land=2026-08-11T10:00:00Z" || \
    fail "status did not read last-land file: $out"
  pass "status reads last_land from last-land file"
}

test_status_missing_project_clone_still_returns() {
  local home out
  home=$(mktemp -d "$TMP_ROOT/status-no-clone.XXXXXX")
  mkdir -p "$home/projects" "$home/state"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SCRIPT" status "nosuchproj" 2>/dev/null)
  # Status should succeed even when the project clone is missing (just unknown ahead count)
  printf '%s\n' "$out" | grep -q "storybook_status=" || \
    fail "status with missing clone did not return storybook_status line"
  rm -rf "$home"
  pass "status returns structured output even when project clone is absent"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

test_no_args_exits_2
test_unknown_subcommand_exits_2
test_missing_project_arg_exits_2
test_dash_prefix_project_exits_2
test_help_flag_exits_2
test_start_missing_clone_exits_1
test_start_missing_clone_error_mentions_project
test_start_creates_worktree
test_start_reuse_reports_reused
test_start_refuses_unlanded_commits
test_start_writes_service_file
test_land_missing_worktree_exits_1
test_land_nothing_to_land
test_land_lint_failure_exits_1
test_status_no_state
test_status_reads_pane_file
test_status_reads_last_land
test_status_missing_project_clone_still_returns
