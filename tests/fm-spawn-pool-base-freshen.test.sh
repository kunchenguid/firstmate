#!/usr/bin/env bash
# Regression tests for fm-spawn's pooled-worktree base refresh.
#
# A treehouse pool can return a clean detached worktree whose authoritative
# base moved after the worktree was allocated.
# These tests drive the real spawn path with a fake terminal, then prove it
# selects the base from task mode and Git ancestry or stops when that base is
# unsafe or cannot be resolved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
REAL_GIT=$(command -v git)
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
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${FM_FAKE_MERGE_BASE_FAILURE:-0}" = 1 ] \
  && [ "${1:-}" = -C ] \
  && [ "${2:-}" = "${FM_FAKE_MERGE_BASE_DIR:-}" ] \
  && [ "${3:-}" = merge-base ] \
  && [ "${4:-}" = --is-ancestor ]; then
  exit 2
fi
exec "${FM_REAL_GIT:?}" "$@"
SH
  chmod +x "$fakebin/git"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 default=${3:-main} relation=${4:-behind} case_dir home project origin pool publisher fakebin initial
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
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  git clone --quiet "file://$origin" "$publisher"
  printf 'must survive a newly spawned branch\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin "$default"
  if [ "$relation" = ahead ]; then
    git -C "$project" fetch --quiet origin
    git -C "$project" merge --quiet --ff-only "origin/$default"
  fi
  if [ "$relation" = ahead ] || [ "$relation" = diverged ]; then
    printf 'must survive a local-only spawn\n' > "$project/local-main.txt"
    git -C "$project" add local-main.txt
    git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-local-main
  fi

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
    FM_REAL_GIT="$REAL_GIT" FM_FAKE_MERGE_BASE_DIR="$PROJECT_DIR" \
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

test_local_only_prefers_ahead_local_base() {
  local rec id out status local_head remote_head
  id='pool-local-only-ahead-r1'
  rec=$(make_case local-only-ahead "$id" main ahead)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "local-only spawn should use the local branch when it is ahead"
  local_head=$(git -C "$PROJECT_DIR" rev-parse "refs/heads/$DEFAULT_BRANCH")
  remote_head=$(git -C "$POOL_DIR" rev-parse origin/main)
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$local_head" ] \
    || fail "local-only spawn did not use the authoritative local branch"
  [ "$local_head" != "$remote_head" ] || fail "fixture did not leave the local branch ahead of origin/main"
  git -C "$PROJECT_DIR" merge-base --is-ancestor "$remote_head" "$local_head" \
    || fail "fixture made the local branch diverge from origin/main instead of advancing it"
  assert_grep 'must survive a local-only spawn' "$POOL_DIR/local-main.txt" \
    "local-only spawn omitted the local-only commit"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed local-only ahead base: HEAD=%s local=%s origin/main=%s local-main=%s\n' \
      "$(git -C "$POOL_DIR" rev-parse HEAD)" "$local_head" "$remote_head" "$(cat "$POOL_DIR/local-main.txt")"
  fi
  pass "a local-only spawn uses the local default branch when it is ahead of origin"
}

test_local_only_uses_remote_when_local_is_behind() {
  local rec id out status remote_head
  id='pool-local-only-behind-r1'
  rec=$(make_case local-only-behind "$id" main behind)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "local-only spawn should use origin when the local branch is behind"
  remote_head=$(git -C "$POOL_DIR" rev-parse origin/main)
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$remote_head" ] \
    || fail "local-only spawn did not use origin when the local branch was behind"
  [ "$(git -C "$PROJECT_DIR" rev-parse refs/heads/main)" != "$remote_head" ] \
    || fail "fixture did not leave the local branch behind origin/main"
  assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
    "local-only spawn omitted the newer remote commit"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed local-only behind base: HEAD=%s local=%s origin/main=%s advanced-main=%s\n' \
      "$(git -C "$POOL_DIR" rev-parse HEAD)" \
      "$(git -C "$PROJECT_DIR" rev-parse refs/heads/main)" \
      "$remote_head" "$(cat "$POOL_DIR/advanced-main.txt")"
  fi
  pass "a local-only spawn uses origin when the local default branch is behind it"
}

test_local_only_prefers_diverged_local_base() {
  local rec id out status local_head remote_head
  id='pool-local-only-diverged-r1'
  rec=$(make_case local-only-diverged "$id" main diverged)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "local-only spawn should use the local branch when it diverged"
  local_head=$(git -C "$PROJECT_DIR" rev-parse refs/heads/main)
  remote_head=$(git -C "$POOL_DIR" rev-parse origin/main)
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$local_head" ] \
    || fail "local-only spawn did not use the diverged authoritative local branch"
  if git -C "$PROJECT_DIR" merge-base --is-ancestor "$local_head" "$remote_head" \
    || git -C "$PROJECT_DIR" merge-base --is-ancestor "$remote_head" "$local_head"; then
    fail "fixture did not diverge the local branch from origin/main"
  fi
  assert_grep 'must survive a local-only spawn' "$POOL_DIR/local-main.txt" \
    "local-only spawn omitted the diverged local commit"
  [ ! -e "$POOL_DIR/advanced-main.txt" ] \
    || fail "local-only spawn used the diverged remote branch instead of the local branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed local-only diverged base: HEAD=%s local=%s origin/main=%s local-main=%s advanced-main=absent\n' \
      "$(git -C "$POOL_DIR" rev-parse HEAD)" "$local_head" "$remote_head" "$(cat "$POOL_DIR/local-main.txt")"
  fi
  pass "a local-only spawn uses the local default branch when it diverged from origin"
}

test_local_only_refuses_failed_ancestry_inspection() {
  local rec id out status before after
  id='pool-local-only-ancestry-failure-r1'
  rec=$(make_case local-only-ancestry-failure "$id" main ahead)
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(FM_FAKE_MERGE_BASE_FAILURE=1 run_spawn "$id" --mode local-only --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "local-only spawn continued after ancestry inspection failed"
  assert_contains "$out" "could not compare local default 'refs/heads/main'" \
    "spawn did not identify the failed local ancestry comparison"
  assert_contains "$out" "inspect the repository object graph and retry" \
    "spawn did not provide remediation for a failed ancestry comparison"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "spawn moved the pool after ancestry inspection failed"
  pass "a failed local-only ancestry inspection refuses the pooled worktree"
}

test_remote_backed_mode_uses_origin_when_local_is_ahead() {
  local rec id out status local_head remote_head
  id='pool-remote-mode-local-ahead-r1'
  rec=$(make_case remote-mode-local-ahead "$id" main ahead)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "remote-backed spawn should use origin when the local branch is ahead"
  local_head=$(git -C "$PROJECT_DIR" rev-parse refs/heads/main)
  remote_head=$(git -C "$POOL_DIR" rev-parse origin/main)
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$remote_head" ] \
    || fail "remote-backed spawn did not use origin when the local branch was ahead"
  [ "$local_head" != "$remote_head" ] || fail "fixture did not leave the local branch ahead of origin/main"
  [ ! -e "$POOL_DIR/local-main.txt" ] \
    || fail "remote-backed spawn used the ahead local branch instead of origin"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed remote-backed local-ahead base: HEAD=%s local=%s origin/main=%s local-main=absent\n' \
      "$(git -C "$POOL_DIR" rev-parse HEAD)" "$local_head" "$remote_head"
  fi
  pass "a remote-backed spawn uses origin when the local default branch is ahead"
}

test_local_only_without_origin_uses_local_base() {
  local rec id out status local_head feature_head
  id='pool-local-only-no-origin-r1'
  rec=$(make_case local-only-no-origin "$id" trunk behind)
  read_case_record "$rec"
  git -C "$PROJECT_DIR" remote remove origin
  git -C "$PROJECT_DIR" config --local init.defaultBranch "$DEFAULT_BRANCH"
  printf 'must survive without an origin\n' > "$PROJECT_DIR/local-trunk.txt"
  git -C "$PROJECT_DIR" add local-trunk.txt
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-local-trunk
  local_head=$(git -C "$PROJECT_DIR" rev-parse "refs/heads/$DEFAULT_BRANCH")
  git -C "$PROJECT_DIR" checkout --quiet -b fixture-current
  printf 'must not become the pooled base\n' > "$PROJECT_DIR/feature-only.txt"
  git -C "$PROJECT_DIR" add feature-only.txt
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-feature
  feature_head=$(git -C "$PROJECT_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "local-only spawn should work without an origin"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$local_head" ] \
    || fail "local-only spawn without origin did not use repository-local init.defaultBranch"
  [ "$local_head" != "$feature_head" ] \
    || fail "fixture did not distinguish the configured default from the current branch"
  assert_grep 'must survive without an origin' "$POOL_DIR/local-trunk.txt" \
    "local-only spawn without origin omitted the local default branch commit"
  [ ! -e "$POOL_DIR/feature-only.txt" ] \
    || fail "local-only spawn without origin treated the current feature branch as default"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed local-only no-origin base: HEAD=%s local-default=%s current-feature=%s local-trunk=%s feature-only=absent\n' \
      "$(git -C "$POOL_DIR" rev-parse HEAD)" "$local_head" "$feature_head" "$(cat "$POOL_DIR/local-trunk.txt")"
  fi
  pass "a local-only spawn without origin uses repository-local init.defaultBranch"
}

test_local_only_without_resolvable_default_refuses_detached_checkout() {
  local rec id out status before after
  id='pool-local-only-no-default-r1'
  rec=$(make_case local-only-no-default "$id" topic behind)
  read_case_record "$rec"
  git -C "$PROJECT_DIR" remote remove origin
  git -C "$PROJECT_DIR" config --local init.defaultBranch trunk
  git -C "$PROJECT_DIR" checkout --quiet --detach
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "local-only spawn used detached HEAD as the default branch"
  assert_contains "$out" "repository-local init.defaultBranch 'trunk'" \
    "spawn did not identify the configured local default"
  assert_contains "$out" "refs/heads/trunk" \
    "spawn did not name the missing configured local reference"
  assert_contains "$out" "refs/heads/main and refs/heads/master are also missing" \
    "spawn did not name the missing fallback references"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "spawn moved the pool after rejecting an unresolved local default"
  pass "a detached local-only checkout without a resolvable default is refused"
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

test_unreachable_origin_refuses_stale_pool_base() {
  local rec id out status before after
  id='pool-unreachable-origin-r2'
  rec=$(make_case unreachable-origin "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unreachable origin"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not clearly refuse an unreachable origin"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "spawn changed the pooled worktree after origin became unreachable"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unreachable-origin refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unreachable origin refuses a potentially stale pooled worktree"
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

test_unresolved_remote_default_refuses_pool() {
  local rec id out status before
  id='pool-unresolved-default-r5'
  rec=$(make_case unresolved-default "$id")
  read_case_record "$rec"
  git --git-dir="$CASE_DIR/origin.git" symbolic-ref HEAD refs/heads/missing-default
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unresolved remote default branch"
  assert_contains "$out" "could not resolve origin's current default branch" \
    "spawn did not clearly refuse an unresolved remote default branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after failing to resolve the remote default branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unresolved-default refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unresolved remote default branch refuses the pooled worktree"
}

test_stale_pool_base_refreshes_before_branching
test_local_only_prefers_ahead_local_base
test_local_only_uses_remote_when_local_is_behind
test_local_only_prefers_diverged_local_base
test_local_only_refuses_failed_ancestry_inspection
test_remote_backed_mode_uses_origin_when_local_is_ahead
test_local_only_without_origin_uses_local_base
test_local_only_without_resolvable_default_refuses_detached_checkout
test_non_main_default_branch_refreshes_before_branching
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base

echo "# all fm-spawn-pool-base-freshen tests passed"
