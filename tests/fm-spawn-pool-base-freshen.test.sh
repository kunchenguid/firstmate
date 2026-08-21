#!/usr/bin/env bash
# Regression tests for fm-spawn's pooled-worktree base refresh.
#
# A treehouse pool can return a clean detached worktree whose origin/main was
# advanced after the worktree was allocated.
# These tests drive the real spawn path with a fake terminal, then prove it
# starts the worker from the fetched origin/main tip or stops when origin is
# unreachable.
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
  fm_fake_exit0 "$fakebin" treehouse
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
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  git clone --quiet "file://$origin" "$publisher"
  printf 'must survive a newly spawned branch\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin "$default"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|$default"
}

# A registered local-only project may have NO git remote at all (see the
# project-management skill); its pooled worktree shares the primary checkout's
# object store, so the local default branch tip is the freshest base.
make_remoteless_case() {
  local name=$1 id=$2 default=${3:-main} case_dir home project pool fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b "$default" "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  printf 'must survive a newly spawned branch\n' > "$project/advanced-local.txt"
  git -C "$project" add advanced-local.txt
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-local-default

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

test_remoteless_pool_refreshes_to_local_default_tip() {
  local rec id out status current branch_head
  # The remoteless base comes from the shared default_branch convention
  # (local main/master); a scout is one of the two shapes allowed to run
  # without an origin.
  id='pool-remoteless-main-r6'
  rec=$(make_remoteless_case remoteless-main "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a remoteless local-only project should still spawn a scout"
  assert_contains "$out" "spawned $id" "remoteless scout spawn did not report success"
  current=$(git -C "$PROJECT_DIR" rev-parse "refs/heads/$DEFAULT_BRANCH")
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "remoteless spawn did not refresh to the local $DEFAULT_BRANCH tip"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove the local default branch advanced past the pool base"
  assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-local.txt" \
    "remoteless spawn omitted content committed to the local default branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed remoteless scout spawn: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    printf '# observed remoteless base: HEAD=%s local %s=%s\n' "$branch_head" "$DEFAULT_BRANCH" "$current"
  fi
  pass "a remoteless pooled worktree refreshes to the local default branch tip before launch"
}

# A remoteless primary parked on a feature branch must NOT drag that branch's
# commits into the task base: fm-review-diff, fm-merge-local and fm-teardown all
# resolve the local default as main/master, so spawn has to agree with them.
test_remoteless_off_default_primary_bases_on_local_default() {
  local rec id out status default_tip wip_tip branch_head
  id='pool-remoteless-off-default-r9'
  rec=$(make_remoteless_case remoteless-off-default "$id")
  read_case_record "$rec"
  default_tip=$(git -C "$PROJECT_DIR" rev-parse "refs/heads/$DEFAULT_BRANCH")
  git -C "$PROJECT_DIR" checkout --quiet -b wip
  printf 'stray feature work\n' > "$PROJECT_DIR/wip-only.txt"
  git -C "$PROJECT_DIR" add wip-only.txt
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm wip-work
  wip_tip=$(git -C "$PROJECT_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "a remoteless local-only ship should still launch while the primary sits on a feature branch"
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$default_tip" ] \
    || fail "remoteless spawn did not base on the local $DEFAULT_BRANCH tip while the primary was on wip"
  [ "$branch_head" != "$wip_tip" ] || fail "remoteless spawn based the task on the primary's feature branch"
  [ ! -e "$POOL_DIR/wip-only.txt" ] || fail "remoteless spawn pulled the primary's feature-branch commits into the task base"
  assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-local.txt" \
    "remoteless spawn omitted content committed to the local default branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed off-default remoteless base: HEAD=%s %s=%s wip=%s\n' \
      "$branch_head" "$DEFAULT_BRANCH" "$default_tip" "$wip_tip"
  fi
  pass "a remoteless primary parked on a feature branch still bases the task on the local default branch"
}

test_remoteless_dirty_pool_refuses_without_discarding_work() {
  local rec id out status before
  id='pool-remoteless-dirty-r7'
  rec=$(make_remoteless_case remoteless-dirty "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "remoteless spawn succeeded despite a dirty pooled worktree"
  assert_contains "$out" "is not clean" "remoteless spawn did not clearly refuse a dirty pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "remoteless spawn moved HEAD while refusing a dirty pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "remoteless spawn discarded uncommitted work while refusing the pool"
  pass "a dirty remoteless pooled worktree is refused without discarding its local work"
}

# A remoteless default under any name but main/master refuses: fm-review-diff
# and fm-merge-local resolve only origin/HEAD, main, or master, so a spawnable
# trunk task could never be reviewed or landed through the guarded helpers.
test_remoteless_nonconvention_default_refuses_pool() {
  local rec id out status before
  id='pool-remoteless-trunk-r8'
  rec=$(make_remoteless_case remoteless-trunk "$id" trunk)
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "remoteless spawn succeeded despite a non-main/master local default"
  assert_contains "$out" "no resolvable local default branch" \
    "remoteless spawn did not clearly refuse a non-main/master local default"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "remoteless spawn moved HEAD after refusing a non-main/master local default"
  pass "a remoteless default branch other than main/master refuses the spawn"
}

# A remoteless project cannot deliver through a push: a direct-PR or
# no-mistakes ship refuses at spawn instead of launching work that cannot ship.
test_remoteless_push_modes_refuse() {
  local rec id out status before mode
  for mode in no-mistakes direct-PR; do
    id="pool-remoteless-$mode-r10"
    rec=$(make_remoteless_case "remoteless-mode-$mode" "$id")
    read_case_record "$rec"
    before=$(git -C "$POOL_DIR" rev-parse HEAD)

    out=$(run_spawn "$id" --mode "$mode" --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "a remoteless $mode ship spawned despite having no origin to deliver through"
    assert_contains "$out" "only a scout or a local-only ship" \
      "remoteless $mode spawn did not clearly refuse the push-delivery mode"
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
      || fail "remoteless $mode spawn moved HEAD while refusing"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# observed remoteless %s refusal: %s\n' "$mode" "$(printf '%s\n' "$out" | tail -n 1)"
    fi
  done
  pass "remoteless direct-PR and no-mistakes ships refuse at spawn"
}

test_stale_pool_base_refreshes_before_branching
test_non_main_default_branch_refreshes_before_branching
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base
test_remoteless_pool_refreshes_to_local_default_tip
test_remoteless_off_default_primary_bases_on_local_default
test_remoteless_dirty_pool_refuses_without_discarding_work
test_remoteless_nonconvention_default_refuses_pool
test_remoteless_push_modes_refuse

echo "# all fm-spawn-pool-base-freshen tests passed"
