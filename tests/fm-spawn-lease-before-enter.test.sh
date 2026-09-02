#!/usr/bin/env bash
# Regression tests for fm-spawn's lease-then-refresh-then-enter order.
#
# The pooled copy must be leased from the spawn process and refreshed BEFORE
# any pane exists, because the first shell to enter a worktree runs git (its
# prompt, gitstatusd) and takes the same index.lock the refresh needs; on a
# large repository that race refused every spawn. These tests drive the real
# spawn path with a fake terminal whose window creation observes the copy the
# moment the pane appears, so they prove the refresh already happened with no
# shell in the copy, that a git lock taken by the new pane cannot make the
# refresh refuse a clean copy, and that a refused launch hands a clean lease
# back while a copy holding uncommitted work stays leased.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-lease-before-enter)

# Spawn-world tmux that additionally records every argv to FM_TMUX_REC and, on
# new-window, snapshots the pooled copy's HEAD into FM_FAKE_NEWWINDOW_HEAD at
# the instant the pane appears. With FM_FAKE_PANE_LOCK=1 it also takes the
# copy's index.lock then, exactly as a fresh shell's git prompt would.
make_lease_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_TMUX_REC:-}" ] || printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window)
    if [ "${FM_FAKE_NEWWINDOW_FAIL:-0}" = 1 ]; then
      printf 'fake tmux: new-window refused\n' >&2
      exit 1
    fi
    if [ -n "${FM_FAKE_NEWWINDOW_HEAD:-}" ]; then
      git -C "${FM_FAKE_PANE_PATH:?}" rev-parse HEAD > "$FM_FAKE_NEWWINDOW_HEAD" 2>/dev/null || printf 'unreadable\n' > "$FM_FAKE_NEWWINDOW_HEAD"
    fi
    if [ "${FM_FAKE_PANE_LOCK:-0}" = 1 ]; then
      : > "$(git -C "${FM_FAKE_PANE_PATH:?}" rev-parse --git-path index.lock)"
    fi
    printf '%s\n' "@leasewid"
    exit 0
    ;;
  list-windows) exit 0 ;;
  has-session|new-session|kill-window|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_test_fake_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

# A project with a bare origin, a detached pooled copy allocated at the initial
# commit, and an origin/main advanced after that allocation - the exact shape
# whose refresh the pane could race.
make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project origin pool publisher fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  fakebin=$(make_lease_fakebin "$case_dir/fake")

  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  git clone --quiet "file://$origin" "$publisher"
  printf 'advanced\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin main

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR INITIAL_SHA <<EOF
$1
EOF
  TMUX_REC="$CASE_DIR/tmux.rec"
  TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  NEWWINDOW_HEAD="$CASE_DIR/newwindow-head"
  : > "$TMUX_REC"
  : > "$TREEHOUSE_LOG"
}

run_spawn() {  # <id> [spawn args...]
  local id=$1
  shift
  FM_TMUX_REC="$TMUX_REC" FM_TREEHOUSE_LOG="$TREEHOUSE_LOG" \
    FM_FAKE_NEWWINDOW_HEAD="$NEWWINDOW_HEAD" \
    fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
}

test_refresh_completes_before_any_pane_exists() {
  local rec id out status current seen
  id='lease-order-l1'
  rec=$(make_case order "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should lease, refresh, then create the pane"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  current=$(git -C "$POOL_DIR" rev-parse origin/main)
  [ "$current" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/main advanced past the pool base"
  seen=$(cat "$NEWWINDOW_HEAD" 2>/dev/null || true)
  [ -n "$seen" ] || fail "the fake terminal never observed the copy at window creation"
  [ "$seen" = "$current" ] \
    || fail "the pane was created before the copy was refreshed (HEAD at creation $seen, origin/main $current)"
  assert_grep "get --lease --lease-holder fm-$id" "$TREEHOUSE_LOG" \
    "spawn did not lease the copy from its own process"
  assert_grep "new-window -dP -F #{window_id} -t firstmate: -n fm-$id -c $POOL_DIR" "$TMUX_REC" \
    "the pane was not created with the leased copy as its starting directory"
  assert_no_grep "treehouse get" "$TMUX_REC" "a treehouse get was still typed into the pane"
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" "meta did not record the leased copy"
  assert_no_grep "return" "$TREEHOUSE_LOG" "a successful spawn returned its own lease"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed HEAD at window creation=%s origin/main=%s\n' "$seen" "$current"
  fi
  pass "the leased copy is refreshed before the pane exists and the pane starts inside it"
}

test_pane_git_lock_cannot_refuse_a_clean_copy() {
  local rec id out status current lock
  id='lease-pane-lock-l2'
  rec=$(make_case pane-lock "$id")
  read_case_record "$rec"

  out=$(FM_FAKE_PANE_LOCK=1 run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a git lock taken by the new pane must not refuse the spawn"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  current=$(git -C "$POOL_DIR" rev-parse origin/main)
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
    || fail "the copy was not refreshed to current origin/main"
  lock=$(git -C "$POOL_DIR" rev-parse --git-path index.lock)
  [ -f "$lock" ] || fail "fixture did not leave the pane's simulated index.lock in place"
  # The divergence must be real: with that lock held, the refresh itself is
  # exactly what git refuses, so the old create-then-refresh order would have
  # stopped here.
  git -C "$POOL_DIR" reset --hard "$current" >/dev/null 2>&1 \
    && fail "fixture lock did not block a reset; the simulated pane race is vacuous"
  rm -f "$lock"
  pass "a git lock taken by the new pane cannot make the refresh refuse a clean copy"
}

test_refused_launch_returns_a_clean_lease() {
  local rec id out status before
  id='lease-return-l3'
  rec=$(make_case return-clean "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unreachable origin"
  assert_contains "$out" "could not fetch origin" "spawn did not clearly refuse an unreachable origin"
  assert_grep "return --force $POOL_DIR" "$TREEHOUSE_LOG" \
    "a refused launch left a clean, never-entered lease held"
  assert_no_grep "new-window" "$TMUX_REC" "a refused launch still created a pane"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] || fail "the refusal moved HEAD"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused launch published a task record"
  pass "a launch refused before any endpoint exists returns its clean lease to the pool"
}

test_refusal_after_create_began_retains_the_lease() {
  local rec id out status
  id='lease-retain-l6'
  rec=$(make_case retain-after-create "$id")
  read_case_record "$rec"

  out=$(FM_FAKE_NEWWINDOW_FAIL=1 run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded although window creation was refused"
  assert_grep "new-window" "$TMUX_REC" "the create call that ends the return window never ran"
  # `treehouse return` terminates every process inside the copy, so once a
  # create call may have opened a shell there the lease must be kept, not
  # returned under that shell.
  assert_no_grep "^return" "$TREEHOUSE_LOG" \
    "a refusal after window creation began returned the lease under a possible pane"
  assert_contains "$out" "leased copy '$POOL_DIR' is retained" \
    "the retained lease was not reported"
  assert_contains "$out" "treehouse return --force '$POOL_DIR'" \
    "the retained lease's release command was not reported"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused launch published a task record"
  pass "a refusal after endpoint creation began retains the lease instead of terminating what may sit in it"
}

test_dirty_copy_stays_leased_and_untouched() {
  local rec id out status
  id='lease-dirty-l4'
  rec=$(make_case dirty "$id")
  read_case_record "$rec"
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a dirty pooled copy"
  assert_contains "$out" "is not clean" "spawn did not clearly refuse a dirty copy"
  assert_contains "$out" "holds uncommitted work; leaving it leased" \
    "the refusal did not say the dirty copy stays leased"
  assert_no_grep "return" "$TREEHOUSE_LOG" "a dirty copy was returned, which would reset it"
  assert_no_grep "new-window" "$TMUX_REC" "a refused launch still created a pane"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" "the dirty copy's work was discarded"
  pass "a copy holding uncommitted work is refused, stays leased, and is never reset"
}

test_lease_without_a_path_refuses_before_any_endpoint() {
  local rec id out status
  id='lease-nopath-l5'
  rec=$(make_case no-path "$id")
  read_case_record "$rec"

  out=$(FM_FAKE_LEASE_PATH="$CASE_DIR/not-a-directory" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded without a usable leased path"
  assert_contains "$out" "did not report exactly one existing absolute worktree path" \
    "spawn did not clearly refuse an unusable lease result"
  assert_no_grep "new-window" "$TMUX_REC" "spawn created a pane without a leased copy"
  assert_no_grep "return" "$TREEHOUSE_LOG" "spawn tried to return a lease it never held"
  pass "a lease that yields no usable path refuses before any endpoint exists"
}

test_refresh_completes_before_any_pane_exists
test_pane_git_lock_cannot_refuse_a_clean_copy
test_refused_launch_returns_a_clean_lease
test_refusal_after_create_began_retains_the_lease
test_dirty_copy_stays_leased_and_untouched
test_lease_without_a_path_refuses_before_any_endpoint

echo "# all fm-spawn-lease-before-enter tests passed"
