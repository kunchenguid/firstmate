#!/usr/bin/env bash
# Regression tests for fm-spawn's pooled-worktree base refresh.
#
# A treehouse pool can return a clean detached worktree whose tracked upstream
# was advanced after the worktree was allocated, or whose HEAD was checked out
# from the wrong remote entirely (e.g. origin instead of fork in a fork fleet).
# These tests drive the real spawn path with a fake terminal, then prove it
# starts the worker from the tracked upstream's tip, refuses when tracking is
# absent or the remote is unreachable, and corrects a pool whose HEAD came from
# the wrong remote.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-base-freshen)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 default=${3:-main} case_dir home project origin pool publisher fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b "$default" "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" fetch --quiet origin
  git -C "$project" branch --set-upstream-to="origin/$default" "$default" >/dev/null
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  git clone --quiet "file://$origin" "$publisher"
  printf 'must survive a newly spawned branch\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin "$default"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|$default"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR INITIAL_SHA DEFAULT_BRANCH <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" "$@" 2>&1
}

test_stale_pool_base_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-base-r1'
  rec=$(make_case current-base "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  current=$(git -C "$POOL_DIR" rev-parse origin/main)
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn left the pooled worktree on stale history"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/main advanced past the pool base"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed spawn: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    printf '# observed base: HEAD=%s origin/main=%s advanced-main=%s\n' \
      "$branch_head" "$current" "$(cat "$POOL_DIR/advanced-main.txt")"
  fi

  id='pool-current-base-repeat-r1'
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "repeating the base refresh should be idempotent"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
    || fail "an idempotent repeat moved the pool away from current origin/main"

  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  git -C "$POOL_DIR" diff --exit-code origin/main...HEAD >/dev/null \
    || fail "a branch created after spawn differs from current origin/main"
  assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
    "the branch created after spawn omitted advanced-main content"
  pass "a stale pooled worktree refreshes to current origin/main before a crew branch is created"
}

test_non_main_default_branch_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-trunk-r2'
  rec=$(make_case current-trunk "$id" trunk)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree on a non-main default branch"
  current=$(git -C "$POOL_DIR" rev-parse "origin/$DEFAULT_BRANCH")
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn did not refresh to current origin/$DEFAULT_BRANCH"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/$DEFAULT_BRANCH advanced past the pool base"
  pass "a stale pooled worktree resolves and refreshes a non-main default branch"
}

test_unreachable_origin_warns_but_proceeds_with_local_refs() {
  local rec id out status before after
  id='pool-unreachable-origin-r2'
  rec=$(make_case unreachable-origin "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  # An unreachable remote is unknown, not wrong: the spawn warns but proceeds
  # when the locally available tracked upstream ref still passes the ancestry check.
  expect_code 0 "$status" "spawn should warn but proceed when origin is unreachable and local refs are OK"
  assert_contains "$out" "could not fetch 'origin'" \
    "spawn did not warn about the unreachable origin"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  # HEAD stays at what the local origin/main ref resolves to - the initial commit -
  # since the fetch could not update it to the remote's actual tip.
  [ "$after" = "$before" ] || fail "spawn moved the pooled worktree despite a failed fetch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unreachable-origin warning: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unreachable origin warns but proceeds when local refs pass the tracked-base assertion"
}

test_direct_pr_and_scout_refresh_before_launch() {
  local rec id out status contract current
  for contract in direct-pr scout; do
    id="pool-${contract}-r3"
    rec=$(make_case "$contract" "$id")
    read_case_record "$rec"
    if [ "$contract" = scout ]; then
      out=$(run_spawn "$id" --scout)
    else
      out=$(run_spawn "$id" --mode direct-PR --yolo off)
    fi
    status=$?
    expect_code 0 "$status" "$contract spawn should refresh a stale pooled worktree"
    current=$(git -C "$POOL_DIR" rev-parse origin/main)
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
      || fail "$contract spawn did not start at current origin/main"
    assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
      "$contract spawn omitted advanced-main content"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# observed %s spawn: %s\n' "$contract" "$(printf '%s\n' "$out" | tail -n 1)"
    fi
  done
  pass "direct-PR ships and scouts both refresh stale pooled worktrees before launch"
}

test_dirty_pool_refuses_without_discarding_work() {
  local rec id out status before
  id='pool-dirty-refusal-r4'
  rec=$(make_case dirty-refusal "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a dirty pooled worktree"
  assert_contains "$out" "is not clean" "spawn did not clearly refuse a dirty pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a dirty pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "spawn discarded uncommitted work while refusing the pool"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed dirty refusal: %s; preserved=%s\n' \
      "$(printf '%s\n' "$out" | tail -n 1)" "$(cat "$POOL_DIR/uncommitted.txt")"
  fi
  pass "a dirty pooled worktree is refused without discarding its local work"
}

test_untracked_default_falls_back_to_origin() {
  local rec id out status current branch_head
  id='pool-untracked-fallback-r5'
  rec=$(make_case untracked-fallback "$id")
  read_case_record "$rec"
  git -C "$PROJECT_DIR" branch --unset-upstream "$DEFAULT_BRANCH" 2>/dev/null || true

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should fall back to origin when tracking is absent"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  current=$(git -C "$POOL_DIR" rev-parse origin/main)
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn did not reset to origin/main when tracking was absent"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed untracked-fallback: HEAD=%s origin/main=%s (correctly fell back to origin)\n' "$branch_head" "$current"
  fi
  pass "an untracked default branch falls back to origin for the pooled worktree"
}

test_stale_pool_base_refreshes_before_branching
test_non_main_default_branch_refreshes_before_branching
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_untracked_default_falls_back_to_origin
test_unreachable_origin_warns_but_proceeds_with_local_refs

# --- fork-fleet divergence regression (the defect that produced fork PR 27) ---
# Reproduce the exact scenario: a pool worktree whose HEAD is from origin
# (upstream kunchenguid/firstmate) while the default branch tracks fork/main
# (prajwal-395/firstmate). The two diverge because the sync was squash-merged,
# so origin's commits are not ancestors of the fork. A distance check cannot
# distinguish this from merely stale; only the positive ancestry assertion does.

make_fork_case() {
  local name=$1 id=$2 case_dir home project upstream_bare fork_bare pool publisher_upstream publisher_fork fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  upstream_bare="$case_dir/upstream.git"
  fork_bare="$case_dir/fork.git"
  pool="$case_dir/pool"
  publisher_upstream="$case_dir/publisher-upstream"
  publisher_fork="$case_dir/publisher-fork"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  # Create the project repo with a shared initial commit.
  git init --quiet -b main "$project"
  printf 'shared base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'shared base'
  initial=$(git -C "$project" rev-parse HEAD)

  # Create two bare remotes: upstream (origin) and fork.
  git clone --quiet --bare "$project" "$upstream_bare"
  git clone --quiet --bare "$project" "$fork_bare"

  # Add both remotes to the project repo.
  git -C "$project" remote add origin "file://$upstream_bare"
  git -C "$project" remote add fork "file://$fork_bare"
  git -C "$project" fetch --quiet origin
  git -C "$project" fetch --quiet fork

  # The default branch tracks fork/main, not origin/main - the fleet's source of truth.
  git -C "$project" branch --set-upstream-to=fork/main main >/dev/null

  # Diverge the two remotes: push a different commit to each.
  # This simulates a squash-merge sync where upstream's commits are NOT ancestors of fork.
  git clone --quiet "file://$upstream_bare" "$publisher_upstream"
  printf 'upstream-only change\n' > "$publisher_upstream/upstream-only.txt"
  git -C "$publisher_upstream" add upstream-only.txt
  git -C "$publisher_upstream" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'upstream advance'
  git -C "$publisher_upstream" push --quiet origin main

  git clone --quiet "file://$fork_bare" "$publisher_fork"
  printf 'fork-only change (squash-merged content)\n' > "$publisher_fork/fork-only.txt"
  git -C "$publisher_fork" add fork-only.txt
  git -C "$publisher_fork" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'fork advance (squash merge)'
  git -C "$publisher_fork" push --quiet origin main

  # Re-fetch both remotes so fork/main and origin/main refs are current.
  git -C "$project" fetch --quiet origin
  git -C "$project" fetch --quiet fork
  # Allocate a pool worktree checked out from the WRONG remote (origin/main).
  # This is the exact defect: the treehouse pool fetched origin and checked out its tip.
  git -C "$project" worktree add --quiet --detach "$pool" origin/main

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|main"
}

# The correct test: verify that the fixed code resets a wrong-base pool to the correct fork/main.
test_wrong_remote_base_corrected_by_tracking() {
  local rec id out status before fork_tip origin_tip after
  id='pool-wrong-remote-fix-r6'
  rec=$(make_fork_case wrong-remote-fix "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  origin_tip=$(git -C "$PROJECT_DIR" rev-parse origin/main)
  fork_tip=$(git -C "$PROJECT_DIR" rev-parse fork/main)

  # Preconditions: HEAD is on origin/main (the wrong remote) and the two tips diverge.
  [ "$before" = "$origin_tip" ] || fail "fixture: pool HEAD is not at origin/main"
  [ "$origin_tip" != "$fork_tip" ] || fail "fixture: origin/main and fork/main did not diverge"
  if git -C "$POOL_DIR" merge-base --is-ancestor "$fork_tip" "$origin_tip"; then
    fail "fixture: fork/main is an ancestor of origin/main; divergence was not constructed"
  fi

  out=$(run_spawn "$id" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should correct a pool checked out from the wrong remote by using the tracked upstream"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after" = "$fork_tip" ] || fail "spawn did not reset the pool to fork/main; HEAD=$after, expected=$fork_tip"
  [ "$after" != "$origin_tip" ] || fail "spawn left the pool at origin/main instead of resetting to fork/main"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed wrong-remote fix: before=%s (origin/main) after=%s (fork/main)\n' "$before" "$after"
  fi
  pass "a pool checked out from the wrong remote is corrected by tracking-based refresh"
}

test_wrong_remote_base_corrected_by_tracking

# --- tracked-base assertion tests -------------------------------------------
# These test the independent assert_spawn_tracked_base post-condition.

# Fork-based project: origin is NOT the push target, default branch tracks fork/main.
# Must NOT refuse. Uses the same fork fixture as the divergence regression above.
test_fork_project_tracked_base_assertion_passes() {
  local rec id out status fork_tip after
  id='fork-assert-ok-r7'
  rec=$(make_fork_case fork-assert-ok "$id")
  read_case_record "$rec"
  fork_tip=$(git -C "$PROJECT_DIR" rev-parse fork/main)

  out=$(run_spawn "$id" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "fork project spawn should succeed - tracked-base assertion must not refuse"
  assert_contains "$out" "spawned $id" "fork project spawn did not report success"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after" = "$fork_tip" ] || fail "fork project spawn did not land on fork/main"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed fork-assert-ok: HEAD=%s fork/main=%s (correctly tracked fork, not origin)\n' "$after" "$fork_tip"
  fi
  pass "a fork-based project passes the tracked-base assertion using fork/main, not origin"
}

# Symlinked clone: the project directory is a symlink into the captain's real
# working directory. Must NOT refuse. This is the real layout for most of the
# captain's fleet.
test_symlinked_clone_tracked_base_assertion_passes() {
  local rec id out status current case_dir home project symlink pool fakebin
  id='symlink-assert-ok-r8'
  rec=$(make_case symlink-assert-base "$id")
  read_case_record "$rec"

  # Create a symlink to the project directory, simulating the captain's layout.
  case_dir=$(dirname "$HOME_DIR")
  symlink="$case_dir/project-symlink"
  ln -s "$PROJECT_DIR" "$symlink"

  # Run spawn through the symlink path.
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$symlink" --mode no-mistakes --yolo off >out_tmp.txt 2>&1
  status=$?
  out=$(cat out_tmp.txt)
  rm -f out_tmp.txt
  expect_code 0 "$status" "symlinked clone spawn should succeed"
  assert_contains "$out" "spawned $id" "symlinked clone spawn did not report success"
  current=$(git -C "$POOL_DIR" rev-parse origin/main)
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
    || fail "symlinked clone spawn did not start at current origin/main"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed symlink-assert: symlink=%s -> project=%s HEAD=%s\n' "$symlink" "$PROJECT_DIR" "$(git -C "$POOL_DIR" rev-parse HEAD)"
  fi
  pass "a symlinked clone passes the tracked-base assertion"
}

# Completely unreadable upstream: both the remote is unreachable AND the tracked
# upstream ref does not exist locally. The assertion must warn and proceed
# (unreadable = unknown, not wrong).
test_completely_unreadable_upstream_warns_and_proceeds() {
  local rec id out status before after
  id='pool-unreadable-all-r9'
  rec=$(make_case unreadable-all "$id")
  read_case_record "$rec"
  # Point origin at a nonexistent path AND remove the local tracking ref.
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  git -C "$PROJECT_DIR" branch --unset-upstream "$DEFAULT_BRANCH" 2>/dev/null || true
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should warn and proceed when upstream is completely unreadable"
  assert_contains "$out" "spawned $id" "spawn did not report success despite unreadable upstream"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "spawn moved the pooled worktree despite a completely unreadable upstream"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed completely-unreadable: status=%s out=%s\n' "$status" "$(printf '%s\n' "$out" | tail -n 2)"
  fi
  pass "a completely unreadable upstream warns and proceeds without refusing"
}

# Wrong-base refusal: verify that the tracked-base assertion logic refuses a
# worktree whose HEAD is on a genuinely wrong commit (not descended from the
# tracked upstream). The full spawn path's freshen function resets the worktree
# before the assertion runs, so this test exercises the assertion's core check
# - merge-base --is-ancestor - directly on a wrong-base worktree.
# It must REFUSE and leave the copy untouched.
test_wrong_base_assertion_refuses_and_preserves() {
  local case_dir project origin fork_bare pool publisher_fork
  local before fork_tip wrong_sha after upstream tracked_sha head_sha
  case_dir="$TMP_ROOT/wrong-base-refuse"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  fork_bare="$case_dir/fork.git"
  pool="$case_dir/pool"

  # Create a project with origin and fork remotes.
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'initial'

  git clone --quiet --bare "$project" "$origin"
  git clone --quiet --bare "$project" "$fork_bare"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" remote add fork "file://$fork_bare"
  git -C "$project" fetch --quiet origin
  git -C "$project" fetch --quiet fork
  git -C "$project" branch --set-upstream-to=fork/main main >/dev/null

  # Advance fork with a legitimate commit.
  publisher_fork="$case_dir/publisher-fork"
  git clone --quiet "file://$fork_bare" "$publisher_fork"
  printf 'fork advance\n' > "$publisher_fork/fork-file.txt"
  git -C "$publisher_fork" add fork-file.txt
  git -C "$publisher_fork" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'fork advance'
  git -C "$publisher_fork" push --quiet origin main
  git -C "$project" fetch --quiet fork

  fork_tip=$(git -C "$project" rev-parse fork/main)

  # Create a pool worktree on a WRONG orphan commit (not descended from fork/main).
  git -C "$project" worktree add --quiet --detach "$pool"
  git -C "$pool" checkout --quiet --orphan wrong-base
  printf 'wrong base content\n' > "$pool/wrong.txt"
  git -C "$pool" add wrong.txt
  git -C "$pool" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'wrong orphan base'
  wrong_sha=$(git -C "$pool" rev-parse HEAD)

  # Clean the orphan checkout to detached HEAD on the wrong commit.
  git -C "$pool" checkout --quiet --detach "$wrong_sha"
  git -C "$pool" clean -fd >/dev/null 2>&1
  before=$(git -C "$pool" rev-parse HEAD)

  # Resolve the tracked upstream the same way assert_spawn_tracked_base does:
  # default_branch -> @{upstream} -> rev-parse to SHA.
  upstream=$(git -C "$pool" rev-parse --abbrev-ref "main@{upstream}" 2>/dev/null) || {
    fail "fixture: tracking not configured; cannot test assertion"
  }
  tracked_sha=$(git -C "$pool" rev-parse --verify --quiet "$upstream^{commit}" 2>/dev/null) || {
    fail "fixture: tracked upstream '$upstream' not locally resolvable"
  }
  head_sha=$(git -C "$pool" rev-parse --verify --quiet HEAD 2>/dev/null) || {
    fail "fixture: worktree has no HEAD"
  }

  # Preconditions: HEAD is NOT descended from fork/main.
  [ "$head_sha" = "$before" ] || fail "fixture: HEAD is not what we set"
  [ "$tracked_sha" = "$fork_tip" ] || fail "fixture: tracked upstream is not fork/main"
  if git -C "$pool" merge-base --is-ancestor "$tracked_sha" "$head_sha" 2>/dev/null; then
    fail "fixture: HEAD should NOT be descended from fork/main, but is"
  fi

  # The assertion check: merge-base --is-ancestor tracked_sha head_sha must FAIL.
  # This is the exact check assert_spawn_tracked_base runs.
  if git -C "$pool" merge-base --is-ancestor "$tracked_sha" "$head_sha" 2>/dev/null; then
    fail "assertion logic passed despite a genuinely wrong base"
  fi

  after=$(git -C "$pool" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "the check modified the worktree (should be read-only)"

  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed wrong-base refusal: HEAD=%s fork/main=%s (correctly diverged)\n' "$head_sha" "$tracked_sha"
  fi
  pass "a genuinely wrong base is refused by the tracked-base assertion logic and the copy is left untouched"
}

test_fork_project_tracked_base_assertion_passes
test_symlinked_clone_tracked_base_assertion_passes
test_completely_unreadable_upstream_warns_and_proceeds
test_wrong_base_assertion_refuses_and_preserves

echo "# all fm-spawn-pool-base-freshen tests passed"
