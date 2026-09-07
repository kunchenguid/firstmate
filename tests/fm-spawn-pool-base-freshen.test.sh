#!/usr/bin/env bash
# Regression tests for fm-spawn's pooled-worktree base refresh.
#
# A treehouse pool can return a clean detached worktree whose origin/main was
# advanced after the worktree was allocated.
# These tests drive the real spawn path with a fake terminal, then prove it
# starts the worker from the fetched origin/main tip or stops when origin is
# unreachable.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-base-freshen)

# git consults core.excludesFile for every ignore decision, so a machine whose
# global gitignore lists .env.local (or .env*) would silently flip the unignored
# cases into ignored ones and flatly refuse `git add .env.local` in the tracked
# fixture: the suite would then pass or fail per machine. Emptying the global and
# system config files is NOT enough, because that leaves core.excludesFile unset and
# git falls back to its built-in default path, $XDG_CONFIG_HOME/git/ignore or else
# $HOME/.config/git/ignore. Set the setting explicitly to an empty file instead, and
# export it for the whole file so fixtures and spawns alike are isolated and no
# later case can inherit the dependency again.
: > "$TMP_ROOT/empty-gitignore"
: > "$TMP_ROOT/empty-gitconfig"
printf '[core]\n\texcludesFile = %s\n' "$TMP_ROOT/empty-gitignore" > "$TMP_ROOT/isolated-gitconfig"
export GIT_CONFIG_GLOBAL="$TMP_ROOT/isolated-gitconfig"
export GIT_CONFIG_SYSTEM="$TMP_ROOT/empty-gitconfig"
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
  fm_test_spawn_brief "$home" "$id"
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

run_spawn() {
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
}

test_linked_spawning_home_rejects_primary_before_refresh() {
  local rec id out status returned primary spawning before_reflog
  for returned in primary primary-alias spawning scout; do
    id="pool-linked-${returned}-r12"
    rec=$(make_case "linked-$returned" "$id")
    read_case_record "$rec"
    primary=$PROJECT_DIR
    spawning="$CASE_DIR/secondmate"
    git -C "$primary" worktree add --quiet --detach "$spawning" HEAD
    PROJECT_DIR=$spawning
    case "$returned" in
      primary) POOL_DIR=$primary ;;
      primary-alias)
        ln -s "$primary" "$CASE_DIR/primary-alias"
        POOL_DIR="$CASE_DIR/primary-alias"
        ;;
      spawning) POOL_DIR=$spawning ;;
    esac
    before_reflog=$(git -C "$primary" reflog)
    # The assertion concerns identity, not how long an unchanged cwd is polled.
    fm_test_fake_sleep_noop "$FAKEBIN_DIR"

    out=$(run_spawn "$id" --scout)
    status=$?
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# evidence begin: linked-home spawn, returned=%s\n' "$returned"
      printf '$ bin/fm-spawn.sh %s %s --scout\n%s\nexit=%s\n' "$id" "$PROJECT_DIR" "$out" "$status"
      printf 'primary HEAD before=%s after=%s\n' "$INITIAL_SHA" "$(git -C "$primary" rev-parse HEAD)"
      printf 'primary reflog before:\n%s\nprimary reflog after:\n%s\n' "$before_reflog" "$(git -C "$primary" reflog)"
      if [ -e "$primary/.git/FETCH_HEAD" ]; then
        printf 'FETCH_HEAD:\n'; cat "$primary/.git/FETCH_HEAD"
      else
        printf 'FETCH_HEAD absent\n'
      fi
      if [ -e "$HOME_DIR/state/$id.meta" ]; then
        printf 'saved task metadata:\n'; cat "$HOME_DIR/state/$id.meta"
        printf 'worker HEAD=%s origin/main=%s\n' "$(git -C "$POOL_DIR" rev-parse HEAD)" "$(git -C "$POOL_DIR" rev-parse origin/main)"
      else
        printf 'task metadata absent\n'
      fi
      printf '# evidence end\n'
    fi
    if [ "$returned" = scout ]; then
      expect_code 0 "$status" "a genuine scout copy from a linked home should launch"$'\n'"$out"
      assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" \
        "spawn did not record the genuine scout copy"
      [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$(git -C "$POOL_DIR" rev-parse origin/main)" ] \
        || fail "spawn did not refresh the genuine scout copy"
    else
      [ "$status" -ne 0 ] || fail "linked spawning home accepted $returned as a disposable copy"
      # None of these is an isolated copy, so the worktree poll never adopts one
      # and the wait runs out instead: the spawning directory fails the poll's
      # own project comparison, and the repository primary (named directly or
      # through a symlink) fails the isolation screen the poll shares with the
      # guard. The refusal names the last path the pane reported.
      assert_contains "$out" "did not enter an isolated worktree" \
        "spawn did not explain its isolation refusal"
      assert_contains "$out" "last seen" "refusal did not name the path the pane reported"
      [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
      [ ! -e "$primary/.git/FETCH_HEAD" ] || fail "refused spawn fetched before proving isolation"
    fi
    [ "$(git -C "$primary" rev-parse HEAD)" = "$INITIAL_SHA" ] \
      || fail "spawn reset the repository primary from a linked home"
    [ "$(git -C "$primary" reflog)" = "$before_reflog" ] \
      || fail "spawn touched the primary reflog from a linked home"
    pass "linked spawning home: $returned preserves the primary before any refresh"
  done
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
  fm_test_spawn_brief "$HOME_DIR" "$id"
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

# No worktree provider seeds git-ignored files, so a pooled slot arrives without
# the captain's local environment file whether it was just created or handed back
# by an earlier task. Assert only presence, ownership and mode; the real file holds
# credentials and its contents must never reach a fixture, a log or an assertion.
# Real projects ignore .env.local, and spawn deliberately seeds only an ignored
# file so the copy never becomes untracked work that teardown would refuse.
STAGED_COPY_DEFAULT_MODE=600

ignore_local_env_file() {
  # Publish the ignore rule on the default branch the pooled worktree is refreshed
  # to, so the acquired worktree carries it exactly as a real project's clone does.
  git -C "$PROJECT_DIR" fetch --quiet origin
  git -C "$PROJECT_DIR" reset --quiet --hard "origin/$DEFAULT_BRANCH"
  printf '.env.local\n' > "$PROJECT_DIR/.gitignore"
  git -C "$PROJECT_DIR" add .gitignore
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm ignore-local-env
  git -C "$PROJECT_DIR" push --quiet origin "HEAD:$DEFAULT_BRANCH"
  # A real pooled slot already has the ignore rule in its checkout, so a leftover
  # .env.local sitting in it is ignored rather than counted as uncommitted work.
  git -C "$POOL_DIR" fetch --quiet origin
  git -C "$POOL_DIR" checkout --quiet --detach "origin/$DEFAULT_BRANCH"
}

test_acquired_worktree_is_seeded_with_local_env_file() {
  local rec id out status source_mode source_uid source_gid target_mode target_uid target_gid
  id='pool-env-local-r2'
  rec=$(make_case env-local-seed "$id")
  read_case_record "$rec"

  # The primary checkout owns the captain's local environment file. The pooled
  # slot models a directory spawn acquires without that ignored file.
  #
  # 0640 is deliberate and load-bearing: a staged copy is created at the 0600
  # mktemp default, so a source at 0600 would match the target whether or not the
  # mode was preserved at all. The divergence assertion below keeps this case from
  # going quietly vacuous again if that default ever changes.
  ignore_local_env_file
  : > "$PROJECT_DIR/.env.local"
  chmod 0640 "$PROJECT_DIR/.env.local"
  [ ! -e "$POOL_DIR/.env.local" ] \
    || fail "the pooled fixture unexpectedly started with .env.local"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should seed an acquired pool slot's .env.local"
  [ -f "$POOL_DIR/.env.local" ] \
    || fail "spawn did not seed .env.local in the acquired pool slot"

  source_mode=$(stat -c %a "$PROJECT_DIR/.env.local" 2>/dev/null \
    || stat -f %Lp "$PROJECT_DIR/.env.local")
  [ "$source_mode" != "$STAGED_COPY_DEFAULT_MODE" ] \
    || fail "the fixture's source mode equals the staged copy's default mode, so mode preservation cannot be observed"
  source_uid=$(stat -c %u "$PROJECT_DIR/.env.local" 2>/dev/null \
    || stat -f %u "$PROJECT_DIR/.env.local")
  source_gid=$(stat -c %g "$PROJECT_DIR/.env.local" 2>/dev/null \
    || stat -f %g "$PROJECT_DIR/.env.local")
  target_mode=$(stat -c %a "$POOL_DIR/.env.local" 2>/dev/null \
    || stat -f %Lp "$POOL_DIR/.env.local")
  target_uid=$(stat -c %u "$POOL_DIR/.env.local" 2>/dev/null \
    || stat -f %u "$POOL_DIR/.env.local")
  target_gid=$(stat -c %g "$POOL_DIR/.env.local" 2>/dev/null \
    || stat -f %g "$POOL_DIR/.env.local")
  [ "$target_mode" = "$source_mode" ] \
    || fail "re-seeded .env.local did not preserve its mode"
  # uid and gid are the weaker signal: a single-user test run creates both files as
  # the same owner, so these hold even where preservation was dropped. They pin the
  # contract rather than discriminating, and mode above carries the real proof.
  [ "$target_uid" = "$source_uid" ] \
    || fail "re-seeded .env.local did not preserve its owner"
  [ "$target_gid" = "$source_gid" ] \
    || fail "re-seeded .env.local did not preserve its group"
  pass "an acquired pooled worktree receives the primary checkout's local environment file"
}

# A slot handed back by an earlier task can still hold that task's copy of the file.
# Seeding on every acquisition must refresh it, so a rotated credential never loses
# to a stale leftover. Assert only on the resulting file's presence and metadata.
test_acquired_worktree_refreshes_a_stale_local_env_file() {
  local rec id out status source_mode target_mode source_uid target_uid source_gid target_gid
  id='pool-env-local-r3'
  rec=$(make_case env-local-stale "$id")
  read_case_record "$rec"

  ignore_local_env_file
  : > "$PROJECT_DIR/.env.local"
  chmod 0640 "$PROJECT_DIR/.env.local"
  : > "$POOL_DIR/.env.local"
  chmod 0600 "$POOL_DIR/.env.local"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale .env.local in an acquired slot"
  source_mode=$(stat -c %a "$PROJECT_DIR/.env.local" 2>/dev/null \
    || stat -f %Lp "$PROJECT_DIR/.env.local")
  target_mode=$(stat -c %a "$POOL_DIR/.env.local" 2>/dev/null \
    || stat -f %Lp "$POOL_DIR/.env.local")
  [ "$target_mode" = "$source_mode" ] \
    || fail "reissued .env.local did not preserve its mode"
  source_uid=$(stat -c %u "$PROJECT_DIR/.env.local" 2>/dev/null \
    || stat -f %u "$PROJECT_DIR/.env.local")
  target_uid=$(stat -c %u "$POOL_DIR/.env.local" 2>/dev/null \
    || stat -f %u "$POOL_DIR/.env.local")
  [ "$target_uid" = "$source_uid" ] \
    || fail "reissued .env.local did not preserve its owner"
  source_gid=$(stat -c %g "$PROJECT_DIR/.env.local" 2>/dev/null \
    || stat -f %g "$PROJECT_DIR/.env.local")
  target_gid=$(stat -c %g "$POOL_DIR/.env.local" 2>/dev/null \
    || stat -f %g "$POOL_DIR/.env.local")
  [ "$target_gid" = "$source_gid" ] \
    || fail "reissued .env.local did not preserve its group"
  pass "an acquired pooled worktree's stale local environment file is refreshed from the primary checkout"
}

# Revoking the credential by deleting the captain's copy must not leave the slot
# serving the revoked one to whoever takes it next. Assert absence only; the
# fixture is empty because credential bytes are never part of this assertion.
test_acquired_worktree_retires_a_local_env_file_the_captain_deleted() {
  local rec id second out status
  id='pool-env-local-r4'
  second='pool-env-local-r4b'
  rec=$(make_case env-local-deleted "$id")
  read_case_record "$rec"

  # First acquire the slot while the source exists, so the seed record proves
  # that the pool copy belongs to firstmate before the captain deletes it.
  ignore_local_env_file
  : > "$PROJECT_DIR/.env.local"
  chmod 0600 "$PROJECT_DIR/.env.local"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the fixture's first acquisition should seed the slot"
  [ -f "$POOL_DIR/.env.local" ] || fail "the fixture never got a seeded .env.local"

  rm -f "$PROJECT_DIR/.env.local"
  prepare_second_acquisition "$second"
  [ ! -e "$PROJECT_DIR/.env.local" ] \
    || fail "the fixture unexpectedly left a source .env.local in the primary checkout"

  out=$(run_spawn "$second" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should reissue a slot whose source .env.local was deleted"
  [ ! -e "$POOL_DIR/.env.local" ] \
    || fail "spawn left a revoked .env.local in the reissued pool slot"
  pass "a local environment file deleted from the primary checkout does not survive in a reissued slot"
}

# A seed killed partway through must leave nothing in the working tree, because the
# next acquisition refuses a slot that carries untracked work and teardown refuses
# to return one, which would wedge the slot for good. The shim below kills spawn
# exactly between staging the copy and publishing it, then a second spawn proves
# the slot is still acquirable. Only presence and git's own view are asserted.
interrupt_local_env_seed_copy() {
  cat > "$FAKEBIN_DIR/cp" <<SH
#!/usr/bin/env bash
set -u
for arg in "\$@"; do
  case "\$arg" in
    *fm-env-local.*)
      if [ ! -e "$CASE_DIR/seed-interrupted" ]; then
        : > "$CASE_DIR/seed-interrupted"
        kill -9 \$PPID
        exit 137
      fi
      ;;
  esac
done
exec /bin/cp "\$@"
SH
  chmod +x "$FAKEBIN_DIR/cp"
}

test_interrupted_local_env_seed_leaves_the_slot_acquirable() {
  local rec id retry out status
  id='pool-env-local-r6'
  rec=$(make_case env-local-interrupted "$id")
  read_case_record "$rec"

  ignore_local_env_file
  : > "$PROJECT_DIR/.env.local"
  chmod 0640 "$PROJECT_DIR/.env.local"
  interrupt_local_env_seed_copy

  out=$(run_spawn "$id" --mode no-mistakes --yolo off) || true
  [ -e "$CASE_DIR/seed-interrupted" ] \
    || fail "the fixture never reached the staged copy, so nothing was interrupted"
  [ -z "$(git -C "$POOL_DIR" -c core.quotePath=false status --porcelain)" ] \
    || fail "an interrupted seed left work in the pool slot that the next acquisition would refuse"

  retry='pool-env-local-r6-retry'
  fm_test_spawn_brief "$HOME_DIR" "$retry"
  out=$(run_spawn "$retry" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a slot whose earlier seed was interrupted should still be acquirable"
  [ -f "$POOL_DIR/.env.local" ] \
    || fail "the reissued slot was not seeded after an earlier interrupted seed"
  pass "an interrupted local environment seed leaves the pool slot clean and acquirable"
}

# If firstmate cannot publish the ownership record, it must not leave a copy that
# teardown cannot safely identify. Make the record path unusable and assert that
# acquisition refuses after removing only the copy it just staged.
test_unrecordable_local_env_seed_refuses_without_leaving_a_copy() {
  local rec id out status gitdir record_path
  id='pool-env-local-unrecordable'
  rec=$(make_case env-local-unrecordable "$id")
  read_case_record "$rec"

  ignore_local_env_file
  : > "$PROJECT_DIR/.env.local"
  chmod 0640 "$PROJECT_DIR/.env.local"
  gitdir=$(git -C "$POOL_DIR" rev-parse --absolute-git-dir)
  record_path="$gitdir/fm-env-local-seed-record"
  mkdir "$record_path"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "spawn should refuse when it cannot record the seeded copy"
  [ ! -e "$POOL_DIR/.env.local" ] \
    || fail "spawn left an unrecorded .env.local in the acquired pool slot"
  assert_contains "$out" "could not record its ownership" \
    "spawn did not explain why the unrecorded copy was removed"
  pass "an unrecordable local environment seed refuses without leaving a copy"
}

staged_scratch_count() {
  local gitdir
  gitdir=$(git -C "$POOL_DIR" rev-parse --absolute-git-dir)
  find "$gitdir" -maxdepth 1 -name 'fm-env-local.*' | wc -l | tr -d ' '
}

# The scratch a killed copy leaves behind holds the captain's credential bytes, and
# a linked worktree's git directory is readable from inside the worktree, so it must
# not outlive the revocation that retires the slot's own copy. Count the leftovers;
# never read them.
test_interrupted_seed_scratch_does_not_outlive_revocation() {
  local rec id retry out status
  id='pool-env-local-r7'
  rec=$(make_case env-local-scratch-revoked "$id")
  read_case_record "$rec"

  ignore_local_env_file
  : > "$PROJECT_DIR/.env.local"
  chmod 0640 "$PROJECT_DIR/.env.local"
  interrupt_local_env_seed_copy

  out=$(run_spawn "$id" --mode no-mistakes --yolo off) || true
  [ -e "$CASE_DIR/seed-interrupted" ] \
    || fail "the fixture never reached the staged copy, so nothing was interrupted"
  [ "$(staged_scratch_count)" != 0 ] \
    || fail "the fixture left no staged scratch, so revocation hygiene cannot be observed"

  # The captain revokes by deleting the file, and the slot still holds an earlier
  # task's copy, so the next acquisition takes the retire branch.
  rm -f "$PROJECT_DIR/.env.local"
  truncate -s 1 "$POOL_DIR/.env.local"
  chmod 0600 "$POOL_DIR/.env.local"

  retry='pool-env-local-r7-retry'
  fm_test_spawn_brief "$HOME_DIR" "$retry"
  out=$(run_spawn "$retry" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "spawn removed an unrecorded .env.local after the source was revoked"
  [ -e "$POOL_DIR/.env.local" ] \
    || fail "spawn removed an unrecorded .env.local from the reissued pool slot"
  [ "$(staged_scratch_count)" = 0 ] \
    || fail "a revoked credential survived in the slot's staging area after reissue"
  pass "an interrupted seed's staged scratch does not outlive the credential's revocation"
}

# The mirror of ignore_local_env_file: a task whose brief is to stop ignoring the
# path publishes that away, and the slot's checkout carries the rule's absence just
# as a real reissued slot does.
unignore_local_env_file() {
  git -C "$PROJECT_DIR" fetch --quiet origin
  git -C "$PROJECT_DIR" reset --quiet --hard "origin/$DEFAULT_BRANCH"
  git -C "$PROJECT_DIR" rm --quiet .gitignore
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm unignore-local-env
  git -C "$PROJECT_DIR" push --quiet origin "HEAD:$DEFAULT_BRANCH"
  git -C "$POOL_DIR" fetch --quiet origin
  git -C "$POOL_DIR" checkout --quiet --detach "origin/$DEFAULT_BRANCH"
}

# The sweep has to run on every path through the seeding, including the ones that
# never reach the base refresh. An unignored copy the seeding cannot prove is its
# own refuses the slot in the retire phase, so a sweep placed after that phase
# never runs again for this slot and the scratch holding the captain's credential
# bytes stays readable through the slot's git directory for as long as the wedge
# lasts. Count the leftovers; never read them.
test_scratch_is_swept_even_when_the_retire_phase_refuses() {
  local rec id retry out status before after
  id='pool-env-local-r10'
  rec=$(make_case env-local-scratch-refused "$id")
  read_case_record "$rec"

  ignore_local_env_file
  : > "$PROJECT_DIR/.env.local"
  chmod 0640 "$PROJECT_DIR/.env.local"
  interrupt_local_env_seed_copy

  out=$(run_spawn "$id" --mode no-mistakes --yolo off) || true
  [ -e "$CASE_DIR/seed-interrupted" ] \
    || fail "the fixture never reached the staged copy, so nothing was interrupted"
  [ "$(staged_scratch_count)" != 0 ] \
    || fail "the fixture left no staged scratch, so the entry sweep cannot be observed"

  # The rule the seeding depends on is gone, and the slot holds a copy that differs
  # from the source, so the next acquisition refuses inside the retire phase
  # and never reaches the base refresh or the phase after it.
  unignore_local_env_file
  truncate -s 1 "$POOL_DIR/.env.local"
  chmod 0600 "$POOL_DIR/.env.local"

  retry='pool-env-local-r10-retry'
  fm_test_spawn_brief "$HOME_DIR" "$retry"
  out=$(run_spawn "$retry" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "spawn launched from a slot wedged by an unignored copy it could not prove was its own"
  assert_contains "$out" "remove it by hand" \
    "the retire phase's refusal did not tell the operator how to clear the slot"
  [ "$(staged_scratch_count)" = 0 ] \
    || fail "a staged credential scratch survived an acquisition that refused before the base refresh"
  [ -f "$POOL_DIR/.env.local" ] \
    || fail "the refused acquisition deleted the task's own unignored file"
  pass "a staged scratch is swept even when the acquisition refuses before the base refresh"
}

# Seeding asks stat which filesystem a path is on. The shim answers that
# one question so a cross-filesystem layout can be exercised without a real mount,
# and delegates every other stat call untouched.
fake_device_answer() {
  local mode=$1
  cat > "$FAKEBIN_DIR/stat" <<SH
#!/usr/bin/env bash
set -u
if { [ "\${1:-}" = -f ] && [ "\${2:-}" = %d ]; } || { [ "\${1:-}" = -c ] && [ "\${2:-}" = %d ]; }; then
  if [ "$mode" = unreadable ]; then
    exit 1
  fi
  case "\${3:-}" in
    */worktrees/*) printf '4242\n' ;;
    *) printf '1717\n' ;;
  esac
  exit 0
fi
command -p stat "\$@"
SH
  chmod +x "$FAKEBIN_DIR/stat"
}

# Seeding is a convenience, so a layout that cannot take an atomic rename degrades
# to a loud skip rather than making the slot unspawnable. The warning has to be
# actionable, or a worker finds no credentials and misreports the captain as the
# blocker - the exact trap this seeding removes.
test_cross_filesystem_layout_degrades_to_a_loud_skip() {
  local rec id out status
  id='pool-env-local-r8'
  rec=$(make_case env-local-cross-device "$id")
  read_case_record "$rec"

  ignore_local_env_file
  : > "$PROJECT_DIR/.env.local"
  chmod 0640 "$PROJECT_DIR/.env.local"
  fake_device_answer cross

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a cross-filesystem layout should still spawn"
  [ ! -e "$POOL_DIR/.env.local" ] \
    || fail "spawn seeded .env.local despite reporting it could not publish atomically"
  assert_contains "$out" "on different filesystems" \
    "spawn did not name the cross-filesystem layout as the cause"
  assert_contains "$out" "will find no credentials" \
    "spawn did not say plainly that the worktree carries no credential file"
  assert_contains "$out" "by hand" \
    "spawn did not tell the reader to copy the file from the project clone"
  pass "a cross-filesystem layout spawns and warns instead of blocking the task"
}

# Only a positively established cross-filesystem layout degrades. A filesystem
# question that cannot be answered at all is not that state and still refuses.
test_unanswerable_filesystem_question_still_refuses() {
  local rec id out status
  id='pool-env-local-r9'
  rec=$(make_case env-local-device-unreadable "$id")
  read_case_record "$rec"

  ignore_local_env_file
  : > "$PROJECT_DIR/.env.local"
  chmod 0640 "$PROJECT_DIR/.env.local"
  fake_device_answer unreadable

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a filesystem state it could not establish"
  [ ! -e "$POOL_DIR/.env.local" ] \
    || fail "spawn seeded .env.local without establishing it could publish atomically"
  assert_contains "$out" "could not read which filesystem" \
    "spawn did not name the unreadable filesystem check as the reason it refused"
  pass "an unestablished filesystem state refuses instead of degrading like a cross-filesystem one"
}

# The warn-and-skip branch decides whether an unignored .env.local is copied in.
# Copying one would land untracked work that teardown refuses, stranding the slot,
# so spawn must proceed without seeding and say why.
# Firstmate authors the seeded copy, so when a project drops its ignore rule that
# copy becomes firstmate's own untracked artifact and the next acquisition's clean
# check refuses the slot. Byte-identity to the current source proves authorship, so
# retiring it destroys nothing; anything that differs is the task's work and stays.
# Give this slot a second acquisition to run. The record that proves authorship
# lives with the slot, so a case about retiring a copy must establish it the way
# the field does - by actually seeding it in an earlier acquisition - rather than
# by dropping a file into the slot and asserting the outcome that follows.
prepare_second_acquisition() {  # <id>
  local id=$1
  fm_test_spawn_brief "$HOME_DIR" "$id"
}

test_unignored_copy_matching_the_source_is_retired() {
  local rec id second out status
  id='pool-env-local-r8'
  second='pool-env-local-r8b'
  rec=$(make_case env-local-unignored-match "$id")
  read_case_record "$rec"

  # First acquisition seeds the slot while the project still ignores the file, so
  # the record naming that exact copy exists. The project then stops ignoring it,
  # which is what turns firstmate's own artifact into untracked work.
  ignore_local_env_file
  : > "$PROJECT_DIR/.env.local"
  chmod 0600 "$PROJECT_DIR/.env.local"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the fixture's first acquisition should seed the slot"
  [ -f "$POOL_DIR/.env.local" ] || fail "the fixture never got a seeded .env.local"
  unignore_local_env_file
  prepare_second_acquisition "$second"

  out=$(run_spawn "$second" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should retire its own unignored copy and continue"
  [ ! -e "$POOL_DIR/.env.local" ] \
    || fail "spawn left its own unignored copy wedging the pool slot"
  assert_contains "$out" "no longer ignores .env.local" \
    "spawn did not explain why it removed its own unignored copy"
  pass "an unignored copy this seeding recorded writing is retired so the slot stays usable"
}

# The half that content alone cannot decide. A task can legitimately author a
# .env.local whose bytes equal the project checkout's, and deleting that would tear
# down unlanded work with no discard authority. Nothing seeded this slot, so there
# is no record, and the copy must survive whatever its content is.
test_unignored_copy_matching_the_source_without_a_record_is_kept() {
  local rec id out status before after
  id='pool-env-local-r13'
  rec=$(make_case env-local-unignored-match-no-record "$id")
  read_case_record "$rec"

  # No .gitignore publish, so nothing is ever seeded into this slot.
  : > "$PROJECT_DIR/.env.local"
  chmod 0600 "$PROJECT_DIR/.env.local"
  cp -p "$PROJECT_DIR/.env.local" "$POOL_DIR/.env.local"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "spawn deleted a file whose only evidence of authorship was its content"
  [ -f "$POOL_DIR/.env.local" ] \
    || fail "spawn removed an unignored file this seeding never recorded writing"
  assert_contains "$out" "no record of writing that exact file" \
    "the refusal did not say why content alone is not authorship"
  pass "an unignored copy matching the source is still kept when nothing recorded seeding it"
}

# The record names one exact file. A task that rewrites the seeded copy owns it
# from then on, so the record must stop authorizing its removal.
test_unignored_copy_a_task_rewrote_after_seeding_is_kept() {
  local rec id second out status before after
  id='pool-env-local-r14'
  second='pool-env-local-r14b'
  rec=$(make_case env-local-unignored-rewritten "$id")
  read_case_record "$rec"

  ignore_local_env_file
  : > "$PROJECT_DIR/.env.local"
  chmod 0600 "$PROJECT_DIR/.env.local"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the fixture's first acquisition should seed the slot"
  unignore_local_env_file
  # The task rewrites the seeded copy in place with byte-identical content.
  # Content and inode therefore remain unchanged, but its filesystem change
  # time proves that the task authored it after seeding.
  printf '%s' "$(cat "$PROJECT_DIR/.env.local")" > "$POOL_DIR/.env.local"
  prepare_second_acquisition "$second"

  out=$(run_spawn "$second" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "spawn deleted a seeded copy the task had since rewritten"
  [ -f "$POOL_DIR/.env.local" ] || fail "spawn removed the task's own rewrite"
  assert_contains "$out" "remove it by hand" \
    "the refusal did not tell the operator how to clear the slot"
  pass "a seeded copy the task rewrote is kept, because the record names one exact file"
}

test_unignored_copy_differing_from_the_source_is_kept() {
  local rec id out status before after
  id='pool-env-local-r9'
  rec=$(make_case env-local-unignored-differs "$id")
  read_case_record "$rec"

  : > "$PROJECT_DIR/.env.local"
  chmod 0600 "$PROJECT_DIR/.env.local"
  # Content the task itself wrote: it differs, so it is real work and must survive.
  truncate -s 1 "$POOL_DIR/.env.local"
  chmod 0600 "$POOL_DIR/.env.local"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "spawn should refuse rather than silently deleting the task's own unignored file"
  [ -f "$POOL_DIR/.env.local" ] \
    || fail "spawn deleted an unignored file it could not prove was its own"
  assert_contains "$out" "remove it by hand" \
    "the refusal did not tell the operator how to clear the slot"
  pass "an unignored copy that differs from the source is preserved and the refusal is actionable"
}

# A .env.local the project commits is version-controlled content, not this
# seeding's artifact. git check-ignore cannot tell the difference: it consults the
# index, so a tracked path reports not-ignored even when a .gitignore rule matches
# it, which is why both variants below are exercised. Seeding over such a file would
# write the captain's real credentials into a path the project commits, and deleting
# it makes git report a deletion that the base refresh refuses as uncommitted work
# and teardown then refuses to hand back. The source is deliberately edited away
# from the committed bytes so either a retire or a seed-over is observable.
track_local_env_file() {  # [with-ignore-rule]
  git -C "$PROJECT_DIR" fetch --quiet origin
  git -C "$PROJECT_DIR" reset --quiet --hard "origin/$DEFAULT_BRANCH"
  : > "$PROJECT_DIR/.env.local"
  git -C "$PROJECT_DIR" add .env.local
  if [ "${1:-}" = with-ignore-rule ]; then
    printf '.env.local\n' > "$PROJECT_DIR/.gitignore"
    git -C "$PROJECT_DIR" add .gitignore
  fi
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm track-local-env
  git -C "$PROJECT_DIR" push --quiet origin "HEAD:$DEFAULT_BRANCH"
  git -C "$POOL_DIR" fetch --quiet origin
  git -C "$POOL_DIR" checkout --quiet --detach "origin/$DEFAULT_BRANCH"
  : > "$PROJECT_DIR/.env.local"
}

test_tracked_local_env_file_is_never_touched() {
  local rec id out status variant before after
  for variant in plain with-ignore-rule; do
    id="pool-env-local-tracked-$variant"
    rec=$(make_case "env-local-tracked-$variant" "$id")
    read_case_record "$rec"
    track_local_env_file "$variant"

    [ -f "$POOL_DIR/.env.local" ] \
      || fail "the fixture did not check a tracked .env.local into the pool slot ($variant)"

    out=$(run_spawn "$id" --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "spawn should launch on a project that tracks .env.local ($variant)"
    [ -f "$POOL_DIR/.env.local" ] \
      || fail "spawn deleted the project's tracked .env.local ($variant)"
    [ -z "$(git -C "$POOL_DIR" -c core.quotePath=false status --porcelain)" ] \
      || fail "spawn left the pool slot dirty around a tracked .env.local ($variant)"
    assert_contains "$out" "because the project tracks that file" \
      "spawn did not say it skipped .env.local because the project tracks it ($variant)"
  done
  pass "a tracked .env.local is neither seeded over nor retired, and the slot stays clean"
}

test_unignored_local_env_file_is_not_seeded() {
  local rec id out status
  id='pool-env-local-r5'
  rec=$(make_case env-local-unignored "$id")
  read_case_record "$rec"

  # Deliberately no .gitignore publish, so the worktree does not ignore the path.
  : > "$PROJECT_DIR/.env.local"
  chmod 0600 "$PROJECT_DIR/.env.local"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should still launch when the project does not ignore .env.local"
  [ ! -e "$POOL_DIR/.env.local" ] \
    || fail "spawn seeded an unignored .env.local into the acquired pool slot"
  assert_contains "$out" "because the project does not ignore it" \
    "spawn did not explain why it skipped seeding an unignored .env.local"
  pass "an unignored local environment file is never seeded and the skip is explained"
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

# A slot left on a stale submodule pin is the field failure this diagnosis exists
# for: a refresh moved the superproject and left the submodule behind, so the
# refusal fires a spawn later, on a slot whose own `git status` looks clean to the
# operator. Nothing here is converged - the gate only has to say why. The fixture
# only builds the repositories; the residue itself is produced by a real spawn, so
# these tests cover the reset that actually strands the submodule.
make_submodule_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project origin pool publisher fakebin sub subpin1 subpin2 advanced
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  sub="$case_dir/sub-origin"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$sub"
  printf 'pin one\n' > "$sub/lib.txt"
  git -C "$sub" add lib.txt
  git -C "$sub" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm sub-one
  subpin1=$(git -C "$sub" rev-parse HEAD)
  printf 'pin two\n' > "$sub/lib.txt"
  git -C "$sub" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam sub-two
  subpin2=$(git -C "$sub" rev-parse HEAD)
  git -C "$sub" checkout --quiet "$subpin1"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c protocol.file.allow=always -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    submodule --quiet add "file://$sub" ui
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" worktree add --quiet --detach "$pool" HEAD
  git -C "$pool" -c protocol.file.allow=always submodule --quiet update --init

  # Advance origin and move the submodule pin, exactly as the field incident did.
  git clone --quiet "file://$origin" "$publisher"
  git -C "$publisher" -c protocol.file.allow=always submodule --quiet update --init
  git -C "$publisher/ui" checkout --quiet "$subpin2"
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam advance-pin
  git -C "$publisher" push --quiet origin main
  advanced=$(git -C "$publisher" rev-parse HEAD)

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$subpin1|$subpin2|$advanced"
}

read_submodule_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR SUBPIN1 SUBPIN2 ADVANCED_SHA <<EOF
$1
EOF
}

# The first of two consecutive spawns: it succeeds, resets the superproject onto
# the base that moved the pin, and leaves the submodule checkout on the pin the
# old base recorded. That reset is what strands the slot, so every case below
# starts from residue this code path actually produced rather than a hand-built one.
strand_submodule_pin_via_spawn() {  # <seed-id>
  local id=$1 out status
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the spawn that moves the submodule pin should succeed"
  assert_contains "$out" "spawned $id" "the spawn that moves the submodule pin did not report success"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$ADVANCED_SHA" ] \
    || fail "the first spawn did not move the pooled base across the moved submodule pin"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$SUBPIN1" ] \
    || fail "the first spawn did not strand the submodule on the pin the old base recorded"
}

test_stale_submodule_pin_explains_itself() {
  local rec id out status before before_sub
  id='pool-stale-pin-r7'
  rec=$(make_submodule_case stale-pin "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-stale-pin-seed-r7'
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  before_sub=$(git -C "$POOL_DIR/ui" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "the second spawn launched from a slot carrying a stale submodule pin"
  assert_contains "$out" "stale submodule checkout" \
    "refusal did not name the cause as a stale submodule checkout"
  assert_contains "$out" "submodule 'ui'" "refusal did not name the submodule"
  assert_contains "$out" "$SUBPIN1" "refusal did not report the pin the slot actually has"
  assert_contains "$out" "$SUBPIN2" "refusal did not report the pin the base records"
  # No remedy is printed on purpose: the containment check reads local refs only,
  # so a stale remote-tracking ref can make an unpushed commit look contained, and
  # a checkout command on that judgement could cost the operator a commit.
  assert_not_contains "$out" "submodule update --checkout" \
    "refusal printed a remedy command the containment check cannot stand behind"
  assert_not_contains "$out" "refusing to discard uncommitted work" \
    "a stale pin was misreported as uncommitted work"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a stale submodule pin"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$before_sub" ] \
    || fail "spawn converged the submodule; this gate must never touch the slot"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed stale-pin refusal: %s\n' "$(printf '%s\n' "$out" | grep 'submodule' | head -n 1)"
  fi
  pass "two consecutive spawns across a moved submodule pin end in a refusal naming both pins and no remedy"
}

test_unpushed_submodule_commit_is_still_uncommitted_work() {
  local rec id out status unpushed before before_sub
  id='pool-sub-unpushed-r10'
  rec=$(make_submodule_case sub-unpushed "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-unpushed-seed-r10'
  # A commit made inside the submodule and never pushed leaves the submodule work
  # tree clean and the pins different - the same two facts a stale pin shows. Any
  # checkout of the recorded pin would move HEAD off this commit and leave it
  # unreferenced, so this case must keep the conservative refusal.
  printf 'unlanded submodule work\n' > "$POOL_DIR/ui/unlanded.txt"
  git -C "$POOL_DIR/ui" add unlanded.txt
  git -C "$POOL_DIR/ui" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm unlanded-submodule-work
  unpushed=$(git -C "$POOL_DIR/ui" rev-parse HEAD)
  [ -z "$(git -C "$POOL_DIR/ui" status --porcelain)" ] \
    || fail "fixture did not leave the submodule work tree clean"
  [ "$unpushed" != "$(git -C "$POOL_DIR" rev-parse "HEAD:ui")" ] \
    || fail "fixture did not leave the recorded pin different from what is checked out"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  before_sub=$unpushed

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot holding an unpushed submodule commit"
  assert_contains "$out" "refusing to discard uncommitted work" \
    "an unpushed submodule commit was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "an unpushed submodule commit was misreported as a stale pin"
  assert_not_contains "$out" "is checked out at" \
    "an unpushed submodule commit still drew the stale-pin diagnosis"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$before_sub" ] \
    || fail "spawn moved the submodule off its unpushed commit"
  git -C "$POOL_DIR/ui" cat-file -e "$unpushed^{commit}" \
    || fail "the unpushed submodule commit did not survive the refusal"
  assert_grep 'unlanded submodule work' "$POOL_DIR/ui/unlanded.txt" \
    "spawn discarded the unpushed submodule work while refusing the pool"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a slot holding an unpushed submodule commit"
  pass "an unpushed submodule commit keeps the uncommitted-work refusal and survives it"
}

test_work_inside_submodule_is_still_uncommitted_work() {
  local rec id out status
  id='pool-sub-work-r8'
  rec=$(make_submodule_case sub-work "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-work-seed-r8'
  # Put the submodule back on the pin the base records, so the ONLY deviation is
  # real work inside it. This must never be softened into a stale-pin diagnosis.
  git -C "$POOL_DIR/ui" checkout --quiet "$SUBPIN2"
  printf 'work that must survive\n' > "$POOL_DIR/ui/keep-me.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot holding work inside a submodule"
  assert_contains "$out" "refusing to discard uncommitted work" \
    "work inside a submodule was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "real work inside a submodule was misreported as a stale pin"
  assert_grep 'work that must survive' "$POOL_DIR/ui/keep-me.txt" \
    "spawn discarded work inside the submodule while refusing the pool"
  pass "work inside a submodule is still refused as uncommitted work, not called stale"
}

test_stale_pin_carrying_real_work_is_not_called_stale() {
  local rec id out status
  id='pool-sub-both-r9'
  rec=$(make_submodule_case sub-both "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-both-seed-r9'
  # Stale pin AND real work inside it: calling this merely stale would be wrong, so
  # the refusal must stay the conservative one.
  printf 'work that must survive\n' > "$POOL_DIR/ui/keep-me.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot with a stale pin and work inside it"
  assert_contains "$out" "refusing to discard uncommitted work" \
    "a stale pin carrying real work was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "a submodule holding real work was reported as merely stale"
  assert_grep 'work that must survive' "$POOL_DIR/ui/keep-me.txt" \
    "spawn discarded work inside the submodule while refusing the pool"
  pass "a stale pin carrying real work is refused conservatively, never called stale"
}

test_stale_pin_beside_other_dirt_reports_one_verdict() {
  local rec id out status
  id='pool-sub-mixed-r11'
  rec=$(make_submodule_case sub-mixed "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-mixed-seed-r11'
  # Git sorts status paths, so the stale 'ui' entry is scanned before this file.
  # The conservative verdict must not arrive contradicted by a stale-pin line.
  printf 'notes the operator still wants\n' > "$POOL_DIR/zz-notes.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot with a stale pin beside an untracked file"
  assert_contains "$out" "refusing to discard uncommitted work" \
    "a stale pin beside an untracked file was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "a slot carrying more than a stale pin was reported as merely stale"
  assert_not_contains "$out" "is checked out at" \
    "the stale-pin diagnosis was printed alongside the conservative refusal"
  assert_grep 'notes the operator still wants' "$POOL_DIR/zz-notes.txt" \
    "spawn discarded the untracked file while refusing the pool"
  pass "a stale pin beside other dirt yields the conservative refusal alone, with no stale-pin line"
}

test_linked_spawning_home_rejects_primary_before_refresh
# --- teardown's half of the same .env.local lifecycle -----------------------
#
# Seeding is safe only while the project ignores .env.local, and a task can drop
# that ignore rule mid-flight. The copy firstmate seeded then reads as untracked
# work, and teardown's uncommitted-work check refuses the slot - permanently,
# because the acquisition path that retires such a copy only runs once the slot is
# back in the pool. These cases drive the real spawn and the real teardown in
# sequence, so the two halves are proven against one another rather than against a
# restatement of either. Assert on presence and on the refusal wording only; the
# fixture's bytes are never printed.

# Teardown reaches further than spawn does, so its own external commands need
# stubs. They answer the shape teardown expects and nothing more: no PR exists and
# no validation run is active.
add_teardown_stubs() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/gh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/no-mistakes"
  chmod +x "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"
}

run_teardown() {  # <id>
  local id=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" 2>&1
}

# The task's own committed change is what turns the seeded copy into untracked
# work. Landing that branch on origin leaves the uncommitted-work check as the only
# thing that can refuse the teardown that follows.
# Land the task's branch on origin without touching the ignore rule, so the
# uncommitted-work check is the only thing that can refuse the teardown.
land_task_branch() {  # <id>
  local id=$1
  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -q --allow-empty -m 'task work'
  git -C "$POOL_DIR" push --quiet origin "fm/$id"
  git -C "$POOL_DIR" fetch --quiet origin
}

land_task_branch_without_the_ignore_rule() {  # <id>
  local id=$1
  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  git -C "$POOL_DIR" rm --quiet .gitignore >/dev/null
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm 'drop the local env ignore rule'
  git -C "$POOL_DIR" push --quiet origin "fm/$id"
  git -C "$POOL_DIR" fetch --quiet origin
}

test_teardown_returns_a_slot_whose_task_dropped_the_ignore_rule() {
  local rec id out status
  id='pool-env-local-r11'
  rec=$(make_case env-local-teardown-unignored "$id")
  read_case_record "$rec"
  add_teardown_stubs "$FAKEBIN_DIR"

  ignore_local_env_file
  : > "$PROJECT_DIR/.env.local"
  chmod 0600 "$PROJECT_DIR/.env.local"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should seed the slot before the task drops the rule"
  [ -f "$POOL_DIR/.env.local" ] || fail "the fixture never got a seeded .env.local"

  land_task_branch_without_the_ignore_rule "$id"
  [ -n "$(git -C "$POOL_DIR" status --porcelain)" ] \
    || fail "the fixture did not reproduce the untracked seeded copy teardown must not refuse"

  out=$(run_teardown "$id")
  status=$?
  expect_code 0 "$status" "teardown refused a slot held only by firstmate's own seeded file"
  [ ! -e "$POOL_DIR/.env.local" ] \
    || fail "teardown left its own seeded copy in the slot it handed back"
  assert_contains "$out" "no longer ignores .env.local" \
    "teardown did not explain why it removed its own copy"
  pass "teardown hands back a slot whose task dropped the local environment file's ignore rule"
}

test_teardown_still_refuses_a_task_authored_local_env_file() {
  local rec id out status before after
  id='pool-env-local-r12'
  rec=$(make_case env-local-teardown-task-work "$id")
  read_case_record "$rec"
  add_teardown_stubs "$FAKEBIN_DIR"

  ignore_local_env_file
  : > "$PROJECT_DIR/.env.local"
  chmod 0600 "$PROJECT_DIR/.env.local"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should seed the slot before the task rewrites the file"
  land_task_branch_without_the_ignore_rule "$id"
  # The task then wrote its own content over the seeded copy, so it is real work.
  printf 'task-authored change\n' > "$POOL_DIR/.env.local"

  out=$(run_teardown "$id")
  status=$?
  [ "$status" -ne 0 ] \
    || fail "teardown returned a slot holding the task's own uncommitted work"
  [ -f "$POOL_DIR/.env.local" ] \
    || fail "teardown deleted a file it could not prove was firstmate's own"
  assert_contains "$out" "uncommitted changes" \
    "teardown did not refuse the task's own work as uncommitted"
  pass "teardown still refuses a local environment file the task itself authored"
}

# Content is not authorship, on teardown's side too. Nothing seeded this slot, so a
# .env.local the task wrote is the task's - even when its bytes happen to equal the
# project checkout's - and teardown must refuse it rather than discard unlanded work.
test_teardown_refuses_a_task_authored_copy_matching_the_source() {
  local rec id out status before after
  id='pool-env-local-r15'
  rec=$(make_case env-local-teardown-match-no-record "$id")
  read_case_record "$rec"
  add_teardown_stubs "$FAKEBIN_DIR"

  # No .gitignore publish, so spawn seeds nothing and records nothing.
  : > "$PROJECT_DIR/.env.local"
  chmod 0600 "$PROJECT_DIR/.env.local"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should launch while declining to seed an unignored file"
  [ ! -e "$POOL_DIR/.env.local" ] || fail "the fixture unexpectedly got a seeded copy"

  land_task_branch "$id"
  # The task authors its own file whose content matches the project checkout's.
  cp "$PROJECT_DIR/.env.local" "$POOL_DIR/.env.local"

  out=$(run_teardown "$id")
  status=$?
  [ "$status" -ne 0 ] \
    || fail "teardown discarded a task-authored file whose only evidence was its content"
  [ -f "$POOL_DIR/.env.local" ] || fail "teardown deleted the task's own file"
  assert_contains "$out" "uncommitted changes" \
    "teardown did not refuse the task's own file as uncommitted work"
  pass "teardown refuses a task-authored local environment file even when it matches the source"
}

# The retirement runs only AFTER every work-preservation check has passed. When one
# of them refuses, firstmate's own seeded copy must still be sitting there: a file
# removed ahead of a refusal is a deletion no check ever authorized.
test_teardown_keeps_its_seeded_copy_when_another_check_refuses() {
  local rec id out status
  id='pool-env-local-r16'
  rec=$(make_case env-local-teardown-refusal-order "$id")
  read_case_record "$rec"
  add_teardown_stubs "$FAKEBIN_DIR"

  ignore_local_env_file
  : > "$PROJECT_DIR/.env.local"
  chmod 0600 "$PROJECT_DIR/.env.local"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should seed the slot"
  [ -f "$POOL_DIR/.env.local" ] || fail "the fixture never got a seeded .env.local"

  # Drop the ignore rule, and leave the task's commit unlanded so the landed-work
  # check is what refuses. The task's own file below makes the dirty check refuse
  # first, which is the check whose verdict the seeded copy must not pre-empt.
  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  git -C "$POOL_DIR" rm --quiet .gitignore >/dev/null
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm 'drop the local env ignore rule'
  printf 'notes the task still wants\n' > "$POOL_DIR/zz-task-notes.txt"

  out=$(run_teardown "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "teardown returned a slot holding the task's own uncommitted work"
  [ -f "$POOL_DIR/.env.local" ] \
    || fail "teardown removed its seeded copy before a refusing check had run"
  assert_grep 'notes the task still wants' "$POOL_DIR/zz-task-notes.txt" \
    "teardown discarded the task's own untracked work"
  pass "a refused teardown leaves firstmate's own seeded copy in place"
}

add_teardown_order_stubs() {  # <fakebin>
  local fakebin=$1
  add_teardown_stubs "$fakebin"
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
printf 'lsof\n' >> "$FM_TEARDOWN_ORDER_LOG"
exit 0
SH
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$FM_TEARDOWN_ORDER_TARGET" ]; then
    printf 'rm-env-local\n' >> "$FM_TEARDOWN_ORDER_LOG"
  fi
done
exec /bin/rm "$@"
SH
  chmod +x "$fakebin/lsof" "$fakebin/rm"
}

test_teardown_reaps_before_retiring_seeded_copy() {
  local rec id out status lsof_line rm_line
  id='pool-env-local-r17'
  rec=$(make_case env-local-teardown-reap-order "$id")
  read_case_record "$rec"
  add_teardown_order_stubs "$FAKEBIN_DIR"

  ignore_local_env_file
  : > "$PROJECT_DIR/.env.local"
  chmod 0600 "$PROJECT_DIR/.env.local"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should seed the slot before teardown ordering is tested"
  [ -f "$POOL_DIR/.env.local" ] || fail "the fixture never got a seeded .env.local"

  land_task_branch_without_the_ignore_rule "$id"
  export FM_TEARDOWN_ORDER_LOG="$CASE_DIR/teardown-order.log"
  export FM_TEARDOWN_ORDER_TARGET="$POOL_DIR/.env.local"
  : > "$FM_TEARDOWN_ORDER_LOG"
  out=$(run_teardown "$id")
  status=$?
  expect_code 0 "$status" "teardown should retire the seeded copy after reaping"
  lsof_line=$(awk '$0 == "lsof" { print NR; exit }' "$FM_TEARDOWN_ORDER_LOG")
  rm_line=$(awk '$0 == "rm-env-local" { print NR; exit }' "$FM_TEARDOWN_ORDER_LOG")
  [ -n "$lsof_line" ] || fail "teardown did not run the process reaper"
  [ -n "$rm_line" ] || fail "teardown did not retire the seeded copy"
  [ "$lsof_line" -lt "$rm_line" ] || fail "teardown retired the seeded copy before reaping task processes"
  pass "teardown reaps task processes before retiring the seeded local environment copy"
}

test_stale_pool_base_refreshes_before_branching
test_non_main_default_branch_refreshes_before_branching
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base
test_acquired_worktree_is_seeded_with_local_env_file
test_acquired_worktree_refreshes_a_stale_local_env_file
test_acquired_worktree_retires_a_local_env_file_the_captain_deleted
test_interrupted_local_env_seed_leaves_the_slot_acquirable
test_unrecordable_local_env_seed_refuses_without_leaving_a_copy
test_interrupted_seed_scratch_does_not_outlive_revocation
test_scratch_is_swept_even_when_the_retire_phase_refuses
test_cross_filesystem_layout_degrades_to_a_loud_skip
test_unanswerable_filesystem_question_still_refuses
test_unignored_local_env_file_is_not_seeded
test_unignored_copy_matching_the_source_is_retired
test_unignored_copy_matching_the_source_without_a_record_is_kept
test_unignored_copy_a_task_rewrote_after_seeding_is_kept
test_unignored_copy_differing_from_the_source_is_kept
test_teardown_returns_a_slot_whose_task_dropped_the_ignore_rule
test_teardown_still_refuses_a_task_authored_local_env_file
test_teardown_refuses_a_task_authored_copy_matching_the_source
test_teardown_keeps_its_seeded_copy_when_another_check_refuses
test_teardown_reaps_before_retiring_seeded_copy
test_tracked_local_env_file_is_never_touched
test_stale_submodule_pin_explains_itself
test_unpushed_submodule_commit_is_still_uncommitted_work
test_work_inside_submodule_is_still_uncommitted_work
test_stale_pin_carrying_real_work_is_not_called_stale
test_stale_pin_beside_other_dirt_reports_one_verdict

echo "# all fm-spawn-pool-base-freshen tests passed"
