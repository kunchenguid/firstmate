#!/usr/bin/env bash
# Behavior tests for the per-task Git guard installed by fm-spawn.sh.
#
# The incident regression is executable here: a test process starts in its
# assigned worktree, resolves the project's primary checkout, changes into it,
# and attempts to switch that shared checkout onto a fixture branch.
# The PATH guard must refuse before the branch exists or primary HEAD moves.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-git-guard)
REAL_GIT=$(type -P git)
BASE_PATH=$PATH
fm_git_identity fmtest fmtest@example.invalid

install_guard() {
  local primary=$1 worktree=$2 guard_dir=$3 task_git_dir primary_git_dir
  mkdir -p "$guard_dir"
  cp "$ROOT/bin/fm-worker-git-guard.sh" "$guard_dir/git"
  chmod 0700 "$guard_dir/git"
  task_git_dir=$($REAL_GIT -C "$worktree" rev-parse --absolute-git-dir) || return 1
  primary_git_dir=$($REAL_GIT -C "$primary" rev-parse --absolute-git-dir) || return 1
  task_git_dir=$(cd "$task_git_dir" && pwd -P) || return 1
  primary_git_dir=$(cd "$primary_git_dir" && pwd -P) || return 1
  {
    printf 'worktree=%s\n' "$(cd "$worktree" && pwd -P)"
    printf 'primary=%s\n' "$(cd "$primary" && pwd -P)"
    printf 'real_git=%s\n' "$REAL_GIT"
    printf 'task_git_dir=%s\n' "$task_git_dir"
    printf 'primary_git_dir=%s\n' "$primary_git_dir"
  } > "$guard_dir/git.conf"
  chmod 0600 "$guard_dir/git.conf"
}

PRIMARY="$TMP_ROOT/project"
WORKTREE="$TMP_ROOT/worktree"
GUARD_DIR="$TMP_ROOT/guard/bin"
fm_git_worktree "$PRIMARY" "$WORKTREE" guard-task-base
install_guard "$PRIMARY" "$WORKTREE" "$GUARD_DIR"
PRIMARY_BRANCH=$($REAL_GIT -C "$PRIMARY" branch --show-current)

run_guarded() {
  local cwd=$1
  shift
  (cd "$cwd" && PATH="$GUARD_DIR:$BASE_PATH" "$@")
}

test_setup_assertion_and_worktree_git_succeed() {
  local out rc
  out=$(run_guarded "$WORKTREE" git fm-isolation-check 2>&1); rc=$?
  expect_code 0 "$rc" "the executable isolation assertion should accept the assigned worktree"
  assert_contains "$out" "isolation guard active" "the setup assertion did not report an active guard"
  assert_contains "$out" "worktree='$WORKTREE'" "the setup assertion did not name the assigned worktree"
  run_guarded "$WORKTREE" git switch -q -c guard-task-work \
    || fail "ordinary Git in the disposable task worktree was refused"
  [ "$($REAL_GIT -C "$WORKTREE" branch --show-current)" = guard-task-work ] \
    || fail "the allowed worktree branch switch did not run"
  [ "$($REAL_GIT -C "$PRIMARY" branch --show-current)" = "$PRIMARY_BRANCH" ] \
    || fail "an allowed task worktree command moved primary HEAD"
  pass "worker Git guard: setup assertion and task-worktree Git both succeed"
}

test_mid_task_resolved_primary_checkout_is_refused() {
  local probe out rc
  probe="$TMP_ROOT/ref-switch.sh"
  cat > "$probe" <<EOF
#!/usr/bin/env bash
set -e
cd '$PRIMARY'
git switch -q -c pre-marker-lane
git switch -q '$PRIMARY_BRANCH'
EOF
  chmod +x "$probe"
  out=$(run_guarded "$WORKTREE" "$probe" 2>&1); rc=$?
  expect_code 126 "$rc" "a test that changes into the primary checkout must be refused before switching branches"
  assert_contains "$out" "refusing Git in primary checkout '$PRIMARY'" \
    "the mid-task refusal did not identify the primary checkout"
  [ "$($REAL_GIT -C "$PRIMARY" branch --show-current)" = "$PRIMARY_BRANCH" ] \
    || fail "the refused test left primary HEAD on another branch"
  if $REAL_GIT -C "$PRIMARY" show-ref --verify --quiet refs/heads/pre-marker-lane; then
    fail "the refused test created its fixture branch in the primary checkout"
  fi
  pass "worker Git guard: a mid-task test cannot switch the shared primary checkout"
}

test_explicit_primary_targets_are_refused() {
  local out rc
  out=$(run_guarded "$WORKTREE" git -C "$PRIMARY" status 2>&1); rc=$?
  expect_code 126 "$rc" "git -C primary must be refused"
  assert_contains "$out" "refusing Git in primary checkout" "git -C refusal lacked its reason"

  out=$(run_guarded "$WORKTREE" git --namespace fixture -C "$PRIMARY" status 2>&1); rc=$?
  expect_code 126 "$rc" "a valued global option must not hide a later -C primary target"

  out=$(run_guarded "$WORKTREE" git --work-tree="$PRIMARY" status 2>&1); rc=$?
  expect_code 126 "$rc" "--work-tree=primary must be refused"

  out=$(run_guarded "$WORKTREE" git --git-dir="$PRIMARY/.git" status 2>&1); rc=$?
  expect_code 126 "$rc" "--git-dir=primary must be refused"

  out=$(cd "$WORKTREE" && PATH="$GUARD_DIR:$BASE_PATH" GIT_WORK_TREE="$PRIMARY" git status 2>&1); rc=$?
  expect_code 126 "$rc" "GIT_WORK_TREE=primary must be refused"
  pass "worker Git guard: explicit cwd, work-tree, git-dir, and environment targets are refused"
}

test_disposable_fixture_git_remains_available() {
  local fixture
  fixture="$TMP_ROOT/disposable-fixture"
  mkdir -p "$fixture"
  run_guarded "$fixture" git init -q \
    || fail "the guard refused Git in an unrelated disposable fixture"
  run_guarded "$fixture" git status --short >/dev/null \
    || fail "the guard refused ordinary Git after fixture initialization"
  pass "worker Git guard: unrelated disposable fixture repositories remain available"
}

test_nested_task_worktree_is_allowed() {
  local nested_primary nested_worktree nested_guard out rc
  nested_primary="$TMP_ROOT/nested-project"
  nested_worktree="$nested_primary/task-worktree"
  nested_guard="$TMP_ROOT/nested-guard/bin"
  fm_git_worktree "$nested_primary" "$nested_worktree" nested-task-base
  install_guard "$nested_primary" "$nested_worktree" "$nested_guard"

  out=$(cd "$nested_worktree" && PATH="$nested_guard:$BASE_PATH" git status --short 2>&1); rc=$?
  expect_code 0 "$rc" "a legitimate task worktree nested below primary must not be mistaken for primary"
  out=$(cd "$TMP_ROOT" && PATH="$nested_guard:$BASE_PATH" git -C "$nested_worktree" status --short 2>&1); rc=$?
  expect_code 0 "$rc" "an explicit target inside a nested task worktree must remain available"
  out=$(cd "$nested_worktree" && PATH="$nested_guard:$BASE_PATH" git -C "$nested_primary" status 2>&1); rc=$?
  expect_code 126 "$rc" "the nested-worktree exception must not allow the primary checkout itself"
  pass "worker Git guard: a nested assigned worktree is allowed without exposing its primary checkout"
}

test_missing_binding_fails_closed() {
  local bad_dir out rc
  bad_dir="$TMP_ROOT/bad/bin"
  mkdir -p "$bad_dir"
  cp "$ROOT/bin/fm-worker-git-guard.sh" "$bad_dir/git"
  chmod 0700 "$bad_dir/git"
  printf 'worktree=%s\n' "$WORKTREE" > "$bad_dir/git.conf"
  out=$(cd "$WORKTREE" && PATH="$bad_dir:$BASE_PATH" git status 2>&1); rc=$?
  expect_code 126 "$rc" "an incomplete binding must refuse rather than delegate to Git"
  assert_contains "$out" "task isolation binding is incomplete" "the incomplete binding refusal was not explicit"
  pass "worker Git guard: missing configuration fails closed"
}

test_spawn_freezes_and_exports_guard() {
  local id tasktmp guard_path guard_dir case_dir home primary worktree fakebin launch_log out rc path_line launch_line
  id="worker-git-spawn-$$"
  tasktmp="/tmp/fm-$id"
  FM_TEST_CLEANUP_DIRS+=("$tasktmp")
  rm -rf "$tasktmp"
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  primary="$case_dir/project"
  worktree="$case_dir/worktree"
  launch_log="$case_dir/launch.log"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$primary" "$worktree" guard-spawn-base
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" codex)
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) shift ;;
        *) break ;;
      esac
    done
    [ "$#" -gt 0 ] && printf '%s\n' "$1" >> "${FM_FAKE_LAUNCH_LOG:-/dev/null}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  : > "$launch_log"
  out=$(FM_FAKE_LAUNCH_LOG="$launch_log" \
    fm_test_run_spawn "$home" "$worktree" "$fakebin" \
    "$id" "$primary" --harness codex --mode no-mistakes --yolo off)
  rc=$?
  expect_code 0 "$rc" "spawn should arm the per-task Git guard"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report success"
  guard_path=$(find "$tasktmp" -mindepth 2 -maxdepth 2 -type f -name git -path '*/git-guard.*/git' -print)
  [ -n "$guard_path" ] || fail "spawn did not freeze the guard executable under tasktmp"
  guard_dir=$(dirname "$guard_path")
  assert_present "$guard_dir/git.conf" "spawn did not freeze the guard binding under tasktmp"
  assert_grep "worktree=$worktree" "$guard_dir/git.conf" "spawn binding lost the assigned worktree"
  assert_grep "primary=$primary" "$guard_dir/git.conf" "spawn binding lost the primary checkout"
  assert_grep "export PATH='$guard_dir':\"\$PATH\"" "$launch_log" \
    "spawn did not put the frozen guard first on the worker PATH: $(cat "$launch_log")"
  path_line=$(grep -nF "export PATH='$guard_dir':\"\$PATH\"" "$launch_log" | cut -d: -f1)
  launch_line=$(grep -n 'encode launch-brief' "$launch_log" | cut -d: -f1)
  [ -n "$path_line" ] && [ -n "$launch_line" ] && [ "$path_line" -lt "$launch_line" ] \
    || fail "the worker launch was sent before its Git guard PATH export"

  out=$(cd "$worktree" && PATH="$guard_dir:$BASE_PATH" git fm-isolation-check 2>&1); rc=$?
  expect_code 0 "$rc" "the spawn-produced executable assertion should accept its worktree"
  out=$(cd "$primary" && PATH="$guard_dir:$BASE_PATH" git switch -q -c spawn-stray 2>&1); rc=$?
  expect_code 126 "$rc" "the spawn-produced guard must refuse a primary branch switch"
  if $REAL_GIT -C "$primary" show-ref --verify --quiet refs/heads/spawn-stray; then
    fail "the spawn-produced guard allowed a stray branch in primary"
  fi
  pass "fm-spawn: every new ship/scout process tree receives a frozen Git guard before launch"
}

test_setup_assertion_and_worktree_git_succeed
test_mid_task_resolved_primary_checkout_is_refused
test_explicit_primary_targets_are_refused
test_disposable_fixture_git_remains_available
test_nested_task_worktree_is_allowed
test_missing_binding_fails_closed
test_spawn_freezes_and_exports_guard
