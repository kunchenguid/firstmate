#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's --cwd flag (AGENTS.md task lifecycle: spawn).
#
# --cwd starts the ship/scout harness session inside a named subdirectory of the
# worktree instead of the worktree root. Argument-validation cases (relative-path,
# no '..' segment, --secondmate rejection) fail before any backend call, so they
# use a bare run_spawn wrapper like tests/fm-spawn-batch.test.sh. The meta-recording
# and harness-independence cases need to clear the treehouse-get worktree poll, so
# they reuse tests/fm-spawn-dispatch-profile.test.sh's fake-tmux-plus-real-worktree
# pattern, extended with a stateful pane-path file so the fake tmux can also answer
# the second (--cwd) poll once it observes the `cd <subdir>` text-line send.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-cwd)

# --- argument-validation cases: no fixture needed, fail before any backend call ---

run_spawn() {
  FM_ROOT_OVERRIDE='' \
    FM_HOME='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

test_cwd_rejects_invalid_paths() {
  local label args expect out status
  while IFS='|' read -r label expect args; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(run_spawn $args)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected non-zero exit"
    assert_contains "$out" "$expect" "$label"
  done <<'ROWS'
absolute path is rejected|must be a relative path|cwd-abs-z1 projects/foo --cwd /etc
bare '..' is rejected|must not contain a '..' path segment|cwd-dotdot-z2 projects/foo --cwd ..
leading '../' segment is rejected|must not contain a '..' path segment|cwd-dotdot-z3 projects/foo --cwd ../etc
trailing '/..' segment is rejected|must not contain a '..' path segment|cwd-dotdot-z4 projects/foo --cwd argus/..
embedded '/../' segment is rejected|must not contain a '..' path segment|cwd-dotdot-z5 projects/foo --cwd foo/../bar
empty value is rejected|requires a non-empty value|cwd-empty-z6 projects/foo --cwd=
ROWS
  pass "--cwd rejects absolute, '..'-segment, and empty subdirectory arguments"
}

test_cwd_allows_non_dotdot_dotted_names() {
  # "..foo" and "foo..bar" are ordinary directory names, not a '..' segment, so
  # they must clear path validation and fail later (missing brief) instead.
  local out status
  out=$(run_spawn cwd-dotted-z7 projects/foo --cwd ..foo)
  status=$?
  [ "$status" -ne 0 ] || fail "expected non-zero exit (no such project)"
  assert_not_contains "$out" "must not contain a '..' path segment" \
    "'..foo' is a valid directory name, not a '..' segment"
  pass "--cwd does not false-positive on dotted (non-'..') directory names"
}

test_cwd_rejects_with_secondmate() {
  local out status
  out=$(run_spawn cwd-sm-z8 --secondmate --cwd argus)
  status=$?
  [ "$status" -ne 0 ] || fail "expected non-zero exit"
  assert_contains "$out" "not supported for --secondmate spawns" \
    "--cwd + --secondmate should be rejected"
  pass "--cwd is rejected when combined with --secondmate"
}

# --- fixture cases: need a real worktree and a fake tmux past the treehouse-get poll ---

make_cwd_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ -n "${FM_FAKE_PANE_PATH_FILE:-}" ] && [ -f "$FM_FAKE_PANE_PATH_FILE" ]; then
      cat "$FM_FAKE_PANE_PATH_FILE"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    has_l=0
    for a in "$@"; do [ "$a" = "-l" ] && has_l=1; done
    if [ "$has_l" = 1 ]; then
      if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
        prev=
        for a in "$@"; do
          if [ "$prev" = "-l" ]; then
            printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
          fi
          prev=$a
        done
      fi
    else
      # Plain text-line form: send-keys -t <target> <text> Enter. Simulate the
      # pane actually cd-ing: once the "cd <subdir>" line lands, the next
      # pane_current_path read should reflect it.
      text=${4:-}
      case "$text" in
        "cd "*)
          if [ -n "${FM_FAKE_CD_TARGET:-}" ] && [ -n "${FM_FAKE_PANE_PATH_FILE:-}" ]; then
            printf '%s\n' "$FM_FAKE_CD_TARGET" > "$FM_FAKE_PANE_PATH_FILE"
          fi
          ;;
      esac
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_cwd_case <name> <id>: a home + real git worktree + fake tmux, mirroring
# fm-spawn-dispatch-profile.test.sh's make_spawn_case. Echoes
# "case_dir|home|proj|wt|fakebin". The caller creates any subdirectory it needs
# inside $wt before spawning.
make_cwd_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_cwd_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_cwd_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# run_cwd_spawn <case_dir> <home> <wt> <fakebin> <launchlog> <cd_target> <id...args>:
# spawn with the pane starting at $wt (as the treehouse-get poll expects) and, if
# the fake tmux observes a "cd <subdir>" text line, reporting <cd_target> from then on.
run_cwd_spawn() {
  local case_dir=$1 home=$2 wt=$3 fakebin=$4 launchlog=$5 cd_target=$6 panepathfile
  shift 6
  panepathfile="$case_dir/panepath"
  : > "$launchlog"
  printf '%s\n' "$wt" > "$panepathfile"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_PANE_PATH_FILE="$panepathfile" \
    FM_FAKE_CD_TARGET="$cd_target" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_cwd_missing_subdirectory_fails() {
  local rec id out status
  id=cwd-missing-z9
  rec=$(make_cwd_case cwd-missing "$id")
  read_cwd_case_record "$rec"
  # Deliberately do not create $WT_DIR/argus.

  out=$(run_cwd_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch.log" "$WT_DIR/argus" \
    "$id" "$PROJ_DIR" codex --cwd argus)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should fail when the --cwd subdirectory does not exist"
  assert_contains "$out" "does not exist in worktree" \
    "missing --cwd subdirectory should produce a clear error"
  pass "--cwd fails fast with a clear error when the subdirectory does not exist"
}

test_cwd_recorded_in_meta_only_when_used() {
  local rec id out status meta
  id=cwd-meta-z10
  rec=$(make_cwd_case cwd-meta "$id")
  read_cwd_case_record "$rec"
  mkdir -p "$WT_DIR/argus"
  meta="$HOME_DIR/state/$id.meta"

  out=$(run_cwd_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch-no-cwd.log" "$WT_DIR/argus" \
    "$id" "$PROJ_DIR" codex)
  status=$?
  expect_code 0 "$status" "baseline spawn without --cwd should succeed"
  assert_no_grep "cwd_subdir=" "$meta" "meta should not record cwd_subdir when --cwd was not used"

  out=$(run_cwd_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch-cwd.log" "$WT_DIR/argus" \
    "$id" "$PROJ_DIR" codex --cwd argus)
  status=$?
  expect_code 0 "$status" "spawn with --cwd argus should succeed"
  assert_grep "cwd_subdir=argus" "$meta" "meta should record cwd_subdir=argus when --cwd was used"
  pass "cwd_subdir= is recorded in meta only when --cwd was used"
}

test_harness_resolution_unaffected_by_cwd() {
  local rec id status meta launch_no_cwd launch_cwd
  id=cwd-harness-z11
  rec=$(make_cwd_case cwd-harness "$id")
  read_cwd_case_record "$rec"
  mkdir -p "$WT_DIR/argus"
  meta="$HOME_DIR/state/$id.meta"

  run_cwd_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch-no-cwd.log" "$WT_DIR/argus" \
    "$id" "$PROJ_DIR" --harness pi >/dev/null
  status=$?
  expect_code 0 "$status" "baseline --harness pi spawn should succeed"
  assert_grep "harness=pi" "$meta" "explicit --harness pi should resolve to harness=pi"
  launch_no_cwd=$(cat "$CASE_DIR/launch-no-cwd.log")

  run_cwd_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch-cwd.log" "$WT_DIR/argus" \
    "$id" "$PROJ_DIR" --harness pi --cwd argus >/dev/null
  status=$?
  expect_code 0 "$status" "--harness pi spawn combined with --cwd should succeed"
  assert_grep "harness=pi" "$meta" \
    "--harness pi with --cwd should still resolve harness=pi, not something derived from --cwd"
  assert_grep "cwd_subdir=argus" "$meta" "meta should still record cwd_subdir=argus"
  launch_cwd=$(cat "$CASE_DIR/launch-cwd.log")

  [ "$launch_no_cwd" = "$launch_cwd" ] || fail \
    "the LAUNCH command sent to the pane must be byte-identical with and without --cwd" \
    $'\n'"--- without --cwd ---"$'\n'"$launch_no_cwd" \
    $'\n'"--- with --cwd ---"$'\n'"$launch_cwd"
  pass "harness resolution and LAUNCH construction are unaffected by --cwd"
}

test_cwd_places_claude_turnend_hook_in_subdir() {
  # The claude Stop hook fires only when it lives in the session's start
  # directory, so with --cwd the hook must land under the subdir, not the
  # worktree root, or the turn-end signal is silently orphaned.
  local rec id status excl
  id=cwd-hook-z12
  rec=$(make_cwd_case cwd-hook "$id")
  read_cwd_case_record "$rec"
  mkdir -p "$WT_DIR/argus"

  run_cwd_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch-root.log" "$WT_DIR/argus" \
    "$id" "$PROJ_DIR" claude >/dev/null
  status=$?
  expect_code 0 "$status" "baseline claude spawn without --cwd should succeed"
  [ -f "$WT_DIR/.claude/settings.local.json" ] || \
    fail "without --cwd the claude hook should live at the worktree root"

  rm -rf "$WT_DIR/.claude"
  run_cwd_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch-cwd.log" "$WT_DIR/argus" \
    "$id" "$PROJ_DIR" claude --cwd argus >/dev/null
  status=$?
  expect_code 0 "$status" "claude spawn with --cwd should succeed"
  [ -f "$WT_DIR/argus/.claude/settings.local.json" ] || \
    fail "with --cwd the claude hook must live under the subdir the session starts in"
  [ ! -f "$WT_DIR/.claude/settings.local.json" ] || \
    fail "with --cwd the claude hook must NOT be orphaned at the worktree root"
  excl=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  assert_grep "argus/.claude/settings.local.json" "$excl" \
    "the git-exclude entry must anchor to the moved hook location"
  pass "--cwd places the claude turn-end hook under the session's start subdir"
}

test_cwd_places_grok_turnend_pointer_in_both_locations() {
  # grok's global hook reads $GROK_WORKSPACE_ROOT/.fm-grok-turnend; with --cwd
  # grok may scope that root to the start subdir rather than the worktree root,
  # so the pointer must land in BOTH places or the turn-end signal is orphaned.
  local rec id status
  id=cwd-grok-z13
  rec=$(make_cwd_case cwd-grok "$id")
  read_cwd_case_record "$rec"
  mkdir -p "$WT_DIR/argus"

  GROK_HOME="$CASE_DIR/grok" run_cwd_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch-root.log" "$WT_DIR/argus" \
    "$id" "$PROJ_DIR" grok >/dev/null
  status=$?
  expect_code 0 "$status" "baseline grok spawn without --cwd should succeed"
  [ -f "$WT_DIR/.fm-grok-turnend" ] || \
    fail "without --cwd the grok pointer should live at the worktree root"
  [ ! -f "$WT_DIR/argus/.fm-grok-turnend" ] || \
    fail "without --cwd the grok pointer must NOT be written into a subdir"

  rm -f "$WT_DIR/.fm-grok-turnend"
  GROK_HOME="$CASE_DIR/grok" run_cwd_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch-cwd.log" "$WT_DIR/argus" \
    "$id" "$PROJ_DIR" grok --cwd argus >/dev/null
  status=$?
  expect_code 0 "$status" "grok spawn with --cwd should succeed"
  [ -f "$WT_DIR/.fm-grok-turnend" ] || \
    fail "with --cwd the grok pointer must still exist at the worktree root"
  [ -f "$WT_DIR/argus/.fm-grok-turnend" ] || \
    fail "with --cwd the grok pointer must also live under the session's start subdir"
  pass "--cwd writes the grok turn-end pointer to both the worktree root and the subdir"
}

test_cwd_teardown_removes_subdir_hooks() {
  # Teardown returns the worktree to a reused pool, so it removes our hook files
  # first. With --cwd those files live under the subdir, not the worktree root.
  local rec id status meta teardown
  teardown="$(cd "$(dirname "$SPAWN")" && pwd)/fm-teardown.sh"
  id=cwd-teardown-z14
  rec=$(make_cwd_case cwd-teardown "$id")
  read_cwd_case_record "$rec"
  mkdir -p "$WT_DIR/argus"
  meta="$HOME_DIR/state/$id.meta"

  GROK_HOME="$CASE_DIR/grok" run_cwd_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_DIR/launch-cwd.log" "$WT_DIR/argus" \
    "$id" "$PROJ_DIR" claude --cwd argus >/dev/null
  status=$?
  expect_code 0 "$status" "claude spawn with --cwd should succeed"
  [ -f "$WT_DIR/argus/.claude/settings.local.json" ] || fail "precondition: subdir claude hook should exist"
  # Drop a grok pointer in the subdir too, standing in for a grok+--cwd spawn.
  printf 'token=fm.aaaaaaaaaaaa\n' > "$WT_DIR/argus/.fm-grok-turnend"

  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$PATH" \
    "$teardown" "$id" --force >/dev/null 2>&1 || true

  [ ! -f "$WT_DIR/argus/.claude/settings.local.json" ] || \
    fail "teardown must remove the subdir claude hook so a reused pool worktree cannot fire stale signals"
  [ ! -f "$WT_DIR/argus/.fm-grok-turnend" ] || \
    fail "teardown must remove the subdir grok pointer"
  pass "teardown removes --cwd subdir hooks before returning the worktree to the pool"
}

test_cwd_rejects_invalid_paths
test_cwd_allows_non_dotdot_dotted_names
test_cwd_rejects_with_secondmate
test_cwd_missing_subdirectory_fails
test_cwd_recorded_in_meta_only_when_used
test_harness_resolution_unaffected_by_cwd
test_cwd_places_claude_turnend_hook_in_subdir
test_cwd_places_grok_turnend_pointer_in_both_locations
test_cwd_teardown_removes_subdir_hooks
