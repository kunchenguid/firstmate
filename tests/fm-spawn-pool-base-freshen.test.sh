#!/usr/bin/env bash
# Regression tests for fm-spawn's pooled-worktree base refresh.
#
# A treehouse pool can return a clean detached worktree whose origin/main was
# advanced after the worktree was allocated.
# These tests drive the real spawn path with a fake terminal, then prove it
# starts the worker from the fetched origin/main tip or stops when origin is
# unreachable.
# A project with no origin remote has no remote tip, so the same guard must
# start the worker from that project's local default branch instead of
# refusing the launch, while every other refusal stays exactly as strict.
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

# Shared fixture: a firstmate home, a project checkout on <default>, and a
# clean detached pooled worktree of it. Callers add the origin remote (or not).
make_case_base() {  # <name> <id> <default>
  local name=$1 id=$2 default=$3 case_dir home project pool fakebin initial
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

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|$default"
}

# Advance the project's LOCAL default branch past the pooled worktree's base,
# without touching the pooled worktree itself.
advance_local_default() {  # <project> <default> <file> <content>
  local project=$1 default=$2 file=$3 content=$4
  printf '%s\n' "$content" > "$project/$file"
  git -C "$project" add "$file"
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "advance-$default"
  git -C "$project" rev-parse "refs/heads/$default"
}

make_case() {
  local name=$1 id=$2 default=${3:-main} record case_dir project origin publisher

  record=$(make_case_base "$name" "$id" "$default")
  IFS='|' read -r case_dir _ project _ _ _ _ <<EOF
$record
EOF
  origin="$case_dir/origin.git"
  publisher="$case_dir/publisher"

  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"

  git clone --quiet "file://$origin" "$publisher"
  printf 'must survive a newly spawned branch\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin "$default"

  printf '%s\n' "$record"
}

# A local-only project: no origin remote at all, so the only base that exists is
# refs/heads/<default> in the shared git dir the pooled worktree is linked to.
make_case_no_remote() {
  local name=$1 id=$2 default=${3:-main} record project
  record=$(make_case_base "$name" "$id" "$default")
  IFS='|' read -r _ _ project _ _ _ _ <<EOF
$record
EOF
  [ -z "$(git -C "$project" remote)" ] \
    || fail "fixture $name was supposed to have no remote at all"
  printf '%s\n' "$record"
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

# The regression guard for the remote-less path: a project that HAS an origin
# must still refuse when that origin cannot be reached, and must not quietly fall
# back to local history. The local default branch is deliberately advanced here,
# so a wrong fallback would both succeed AND move HEAD to an observable commit
# rather than landing on the same SHA by coincidence.
test_unreachable_origin_refuses_stale_pool_base() {
  local rec id out status before after local_tip
  id='pool-unreachable-origin-r2'
  rec=$(make_case unreachable-origin "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  local_tip=$(advance_local_default "$PROJECT_DIR" "$DEFAULT_BRANCH" \
    local-fallback.txt 'an unreachable origin must never reach this')
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$local_tip" != "$before" ] \
    || fail "fixture did not make a wrong local fallback observable"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unreachable origin"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not clearly refuse an unreachable origin"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "spawn changed the pooled worktree after origin became unreachable"
  [ "$after" != "$local_tip" ] \
    || fail "spawn fell back to local history instead of refusing an unreachable origin"
  [ ! -e "$POOL_DIR/local-fallback.txt" ] \
    || fail "spawn adopted the local default branch despite the project having an origin"
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

test_project_without_origin_spawns_from_local_default() {
  local rec id out status local_tip branch_head
  id='pool-no-remote-r6'
  rec=$(make_case_no_remote no-remote "$id")
  read_case_record "$rec"
  local_tip=$(git -C "$PROJECT_DIR" rev-parse "refs/heads/$DEFAULT_BRANCH")

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should launch into a project that has no origin remote"
  assert_contains "$out" "spawned $id" "spawn did not report success without an origin remote"
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$local_tip" ] \
    || fail "spawn did not start at the project's local default-branch commit"
  [ -z "$(git -C "$POOL_DIR" status --porcelain)" ] \
    || fail "spawn left the remote-less pooled worktree dirty"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed no-remote spawn: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    printf '# observed no-remote base: HEAD=%s local %s=%s\n' \
      "$branch_head" "$DEFAULT_BRANCH" "$local_tip"
  fi
  pass "a project with no origin remote spawns from its local default branch"
}

test_project_without_origin_refreshes_moved_local_default() {
  local rec id out status advanced branch_head
  id='pool-no-remote-advanced-r6'
  rec=$(make_case_no_remote no-remote-advanced "$id")
  read_case_record "$rec"
  advanced=$(advance_local_default "$PROJECT_DIR" "$DEFAULT_BRANCH" \
    advanced-local.txt 'must survive a remote-less spawn')
  [ "$advanced" != "$INITIAL_SHA" ] \
    || fail "fixture did not advance the local default branch past the pool base"

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale remote-less pooled worktree"
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$advanced" ] \
    || fail "spawn left the remote-less pooled worktree on stale local history"
  assert_grep 'must survive a remote-less spawn' "$POOL_DIR/advanced-local.txt" \
    "the refreshed remote-less worktree omitted the advanced local content"
  pass "a moved local default branch pulls a remote-less pooled worktree forward"
}

test_project_without_origin_refuses_dirty_pool() {
  local rec id out status before
  id='pool-no-remote-dirty-r6'
  rec=$(make_case_no_remote no-remote-dirty "$id")
  read_case_record "$rec"
  advance_local_default "$PROJECT_DIR" "$DEFAULT_BRANCH" \
    advanced-local.txt 'must not be reachable through a discard' >/dev/null
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "spawn succeeded despite a dirty pooled worktree in a remote-less project"
  assert_contains "$out" "is not clean" \
    "spawn did not clearly refuse a dirty remote-less pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a dirty remote-less pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "spawn discarded uncommitted work in a remote-less project"
  pass "a remote-less project still refuses a dirty pooled worktree without discarding work"
}

test_project_without_origin_refuses_unresolved_default() {
  local rec id out status before
  id='pool-no-remote-unresolved-r6'
  rec=$(make_case_no_remote no-remote-unresolved "$id" sidetrack)
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "spawn succeeded despite an unresolvable default branch in a remote-less project"
  assert_contains "$out" "default branch" \
    "spawn did not clearly refuse an unresolvable remote-less default branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after failing to resolve a remote-less default branch"
  pass "a remote-less project with no resolvable default branch refuses the pooled worktree"
}

test_stale_pool_base_refreshes_before_branching
test_non_main_default_branch_refreshes_before_branching
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base
test_project_without_origin_spawns_from_local_default
test_project_without_origin_refreshes_moved_local_default
test_project_without_origin_refuses_dirty_pool
test_project_without_origin_refuses_unresolved_default

echo "# all fm-spawn-pool-base-freshen tests passed"
