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

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR INITIAL_SHA DEFAULT_BRANCH <<EOF
$1
EOF
}

# Same shape as make_case, but the project has NO remotes at all (a registered
# local-only project): no origin bare repo and no publisher clone. The primary
# checkout's own default branch is then advanced past the pooled worktree's
# allocation base, so a refresh has real work to prove.
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
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-local

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|$default"
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

test_remoteless_ship_and_scout_refresh_to_primary_default_tip() {
  local rec id out status contract current branch_head
  for contract in ship scout; do
    id="pool-remoteless-${contract}-r6"
    rec=$(make_remoteless_case "remoteless-$contract" "$id")
    read_case_record "$rec"
    if [ "$contract" = scout ]; then
      out=$(run_spawn "$id" --scout)
    else
      out=$(run_spawn "$id" --mode no-mistakes --yolo off)
    fi
    status=$?
    expect_code 0 "$status" "$contract spawn should refresh a remoteless pooled worktree from the primary's default branch"
    assert_contains "$out" "spawned $id" "$contract spawn did not report success for a remoteless project"
    current=$(git -C "$PROJECT_DIR" rev-parse "refs/heads/$DEFAULT_BRANCH")
    branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
    [ "$branch_head" = "$current" ] || fail "$contract spawn did not start at the primary's current default-branch tip"
    [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove the primary's default branch advanced past the pool base"
    assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-local.txt" \
      "$contract spawn omitted content committed to the remoteless primary after pool allocation"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# observed remoteless %s spawn: %s\n' "$contract" "$(printf '%s\n' "$out" | tail -n 1)"
      printf '# observed remoteless base: HEAD=%s primary/%s=%s\n' "$branch_head" "$DEFAULT_BRANCH" "$current"
    fi
  done
  pass "remoteless ships and scouts refresh pooled worktrees to the primary's default-branch tip"
}

test_remoteless_dirty_pool_refuses_without_discarding_work() {
  local rec id out status before
  id='pool-remoteless-dirty-r7'
  rec=$(make_remoteless_case remoteless-dirty "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a dirty remoteless pooled worktree"
  assert_contains "$out" "is not clean" "spawn did not clearly refuse a dirty remoteless pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a dirty remoteless pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "spawn discarded uncommitted work while refusing the remoteless pool"
  pass "a dirty remoteless pooled worktree is refused without discarding its local work"
}

test_remoteless_non_main_default_refreshes_to_primary_tip() {
  local rec id out status current branch_head
  id='pool-remoteless-trunk-r8'
  rec=$(make_remoteless_case remoteless-trunk "$id" trunk)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a remoteless pooled worktree from a trunk default branch"
  assert_contains "$out" "spawned $id" "spawn did not report success for a remoteless trunk project"
  current=$(git -C "$PROJECT_DIR" rev-parse "refs/heads/$DEFAULT_BRANCH")
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn did not refresh to the remoteless primary's $DEFAULT_BRANCH tip"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove $DEFAULT_BRANCH advanced past the pool base"
  assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-local.txt" \
    "spawn omitted content committed to the remoteless trunk primary after pool allocation"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed remoteless trunk spawn: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    printf '# observed remoteless trunk base: HEAD=%s primary/%s=%s\n' "$branch_head" "$DEFAULT_BRANCH" "$current"
  fi
  pass "a remoteless primary on a non-main default branch refreshes the pooled worktree to its tip"
}

test_remoteless_detached_primary_uses_configured_default() {
  local rec id out status current branch_head
  id='pool-remoteless-configured-r9'
  rec=$(make_remoteless_case remoteless-configured "$id" trunk)
  read_case_record "$rec"
  git -C "$PROJECT_DIR" checkout --quiet --detach
  git -C "$PROJECT_DIR" config init.defaultBranch "$DEFAULT_BRANCH"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should resolve a detached remoteless primary through init.defaultBranch"
  current=$(git -C "$PROJECT_DIR" rev-parse "refs/heads/$DEFAULT_BRANCH")
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn did not refresh to the configured default branch's tip"
  pass "a detached remoteless primary resolves its default branch from init.defaultBranch"
}

test_remoteless_configured_default_beats_checked_out_feature_branch() {
  local rec id out status trunk_tip feature_tip branch_head
  id='pool-remoteless-config-wins-r11'
  rec=$(make_remoteless_case remoteless-config-wins "$id" trunk)
  read_case_record "$rec"
  git -C "$PROJECT_DIR" checkout --quiet -b fm-unfinished-feature
  printf 'unfinished feature work\n' > "$PROJECT_DIR/feature-only.txt"
  git -C "$PROJECT_DIR" add feature-only.txt
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm feature-work
  git -C "$PROJECT_DIR" config init.defaultBranch "$DEFAULT_BRANCH"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh from the configured default branch despite a checked-out feature branch"
  trunk_tip=$(git -C "$PROJECT_DIR" rev-parse "refs/heads/$DEFAULT_BRANCH")
  feature_tip=$(git -C "$PROJECT_DIR" rev-parse refs/heads/fm-unfinished-feature)
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$trunk_tip" ] || fail "spawn did not refresh to the configured default branch's tip"
  [ "$branch_head" != "$feature_tip" ] || fail "spawn based the pool on the primary's checked-out feature branch"
  [ ! -e "$POOL_DIR/feature-only.txt" ] || fail "spawn propagated feature-branch work into the pooled worktree"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed config-wins spawn: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    printf '# observed config-wins base: HEAD=%s trunk=%s feature=%s\n' "$branch_head" "$trunk_tip" "$feature_tip"
  fi
  pass "a configured init.defaultBranch outranks the primary's checked-out feature branch when refreshing the pool"
}

test_remoteless_configured_default_beats_stale_main_ref() {
  local rec id out status trunk_tip stale_main branch_head
  id='pool-remoteless-config-over-main-r12'
  rec=$(make_remoteless_case remoteless-config-over-main "$id" trunk)
  read_case_record "$rec"
  git -C "$PROJECT_DIR" branch main "$INITIAL_SHA"
  git -C "$PROJECT_DIR" config init.defaultBranch "$DEFAULT_BRANCH"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh from the configured default branch despite a retained stale main ref"
  trunk_tip=$(git -C "$PROJECT_DIR" rev-parse "refs/heads/$DEFAULT_BRANCH")
  stale_main=$(git -C "$PROJECT_DIR" rev-parse refs/heads/main)
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$trunk_tip" ] || fail "spawn did not refresh to the configured default branch's tip"
  [ "$branch_head" != "$stale_main" ] || fail "spawn based the pool on the retained stale main ref"
  assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-local.txt" \
    "spawn omitted trunk content while a stale main ref was retained"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed config-over-main spawn: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    printf '# observed config-over-main base: HEAD=%s trunk=%s stale-main=%s\n' "$branch_head" "$trunk_tip" "$stale_main"
  fi
  pass "a configured init.defaultBranch outranks a retained stale main ref when refreshing the pool"
}

test_remoteless_unresolvable_default_refuses_pool() {
  local rec id out status before
  id='pool-remoteless-nodefault-r10'
  rec=$(make_remoteless_case remoteless-nodefault "$id" trunk)
  read_case_record "$rec"
  git -C "$PROJECT_DIR" checkout --quiet --detach
  git -C "$PROJECT_DIR" config init.defaultBranch missing-default
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unresolvable remoteless default branch"
  assert_contains "$out" "could not determine the default branch of remoteless primary checkout" \
    "spawn did not clearly refuse an unresolvable remoteless default branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after failing to resolve the remoteless default branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed remoteless nodefault refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "a detached primary with no resolvable default branch refuses the remoteless pooled worktree rather than guessing a base"
}

test_stale_pool_base_refreshes_before_branching
test_non_main_default_branch_refreshes_before_branching
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base
test_remoteless_ship_and_scout_refresh_to_primary_default_tip
test_remoteless_dirty_pool_refuses_without_discarding_work
test_remoteless_non_main_default_refreshes_to_primary_tip
test_remoteless_detached_primary_uses_configured_default
test_remoteless_configured_default_beats_checked_out_feature_branch
test_remoteless_configured_default_beats_stale_main_ref
test_remoteless_unresolvable_default_refuses_pool

echo "# all fm-spawn-pool-base-freshen tests passed"
