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

# git check-ignore consults core.excludesFile, so a machine whose global gitignore
# lists .env.local would silently flip the unignored cases into ignored ones and the
# suite would pass or fail per machine. Point every spawn's git at empty global and
# system configs so only the fixture's own .gitignore decides.
run_spawn() {
  local id=$1
  shift
  local empty="$TMP_ROOT/empty-gitconfig"
  [ -f "$empty" ] || : > "$empty"
  GIT_CONFIG_GLOBAL="$empty" GIT_CONFIG_SYSTEM="$empty" \
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
# to a stale leftover. Compare checksums so no credential value is ever printed.
test_acquired_worktree_refreshes_a_stale_local_env_file() {
  local rec id out status source_sum target_sum
  id='pool-env-local-r3'
  rec=$(make_case env-local-stale "$id")
  read_case_record "$rec"

  ignore_local_env_file
  printf 'FIXTURE_MARKER=current-not-a-real-credential\n' > "$PROJECT_DIR/.env.local"
  chmod 0600 "$PROJECT_DIR/.env.local"
  printf 'FIXTURE_MARKER=stale-leftover-not-a-real-credential\n' > "$POOL_DIR/.env.local"
  chmod 0600 "$POOL_DIR/.env.local"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale .env.local in an acquired slot"
  source_sum=$(cksum < "$PROJECT_DIR/.env.local")
  target_sum=$(cksum < "$POOL_DIR/.env.local")
  [ "$target_sum" = "$source_sum" ] \
    || fail "spawn left a stale .env.local in the acquired pool slot"
  pass "an acquired pooled worktree's stale local environment file is refreshed from the primary checkout"
}

# Revoking the credential by deleting the captain's copy must not leave the slot
# serving the revoked one to whoever takes it next. Assert absence only; the
# fixture carries a synthetic marker and its bytes never reach an assertion.
test_acquired_worktree_retires_a_local_env_file_the_captain_deleted() {
  local rec id out status
  id='pool-env-local-r4'
  rec=$(make_case env-local-deleted "$id")
  read_case_record "$rec"

  ignore_local_env_file
  printf 'FIXTURE_MARKER=revoked-leftover-not-a-real-credential\n' > "$POOL_DIR/.env.local"
  chmod 0600 "$POOL_DIR/.env.local"
  [ ! -e "$PROJECT_DIR/.env.local" ] \
    || fail "the fixture unexpectedly left a source .env.local in the primary checkout"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
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
  mkdir -p "$HOME_DIR/data/$retry"
  printf 'brief for %s\n' "$retry" > "$HOME_DIR/data/$retry/brief.md"
  out=$(run_spawn "$retry" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a slot whose earlier seed was interrupted should still be acquirable"
  [ -f "$POOL_DIR/.env.local" ] \
    || fail "the reissued slot was not seeded after an earlier interrupted seed"
  pass "an interrupted local environment seed leaves the pool slot clean and acquirable"
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
  printf 'FIXTURE_MARKER=revoked-leftover-not-a-real-credential\n' > "$POOL_DIR/.env.local"
  chmod 0600 "$POOL_DIR/.env.local"

  retry='pool-env-local-r7-retry'
  mkdir -p "$HOME_DIR/data/$retry"
  printf 'brief for %s\n' "$retry" > "$HOME_DIR/data/$retry/brief.md"
  out=$(run_spawn "$retry" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should reissue a slot after the source .env.local was revoked"
  [ ! -e "$POOL_DIR/.env.local" ] \
    || fail "spawn left a revoked .env.local in the reissued pool slot"
  [ "$(staged_scratch_count)" = 0 ] \
    || fail "a revoked credential survived in the slot's staging area after reissue"
  pass "an interrupted seed's staged scratch does not outlive the credential's revocation"
}

# spawn_path_device asks stat which filesystem a path is on. The shim answers that
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
test_unignored_copy_matching_the_source_is_retired() {
  local rec id out status
  id='pool-env-local-r8'
  rec=$(make_case env-local-unignored-match "$id")
  read_case_record "$rec"

  # No .gitignore publish, so the path is not ignored. The slot holds a copy that is
  # byte-identical to the clone's current source: this seeding's own earlier work.
  printf 'FIXTURE_MARKER=authored-not-a-real-credential\n' > "$PROJECT_DIR/.env.local"
  chmod 0600 "$PROJECT_DIR/.env.local"
  cp -p "$PROJECT_DIR/.env.local" "$POOL_DIR/.env.local"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should retire its own unignored copy and continue"
  [ ! -e "$POOL_DIR/.env.local" ] \
    || fail "spawn left its own unignored copy wedging the pool slot"
  assert_contains "$out" "no longer ignores .env.local" \
    "spawn did not explain why it removed its own unignored copy"
  pass "an unignored copy identical to the current source is retired so the slot stays usable"
}

test_unignored_copy_differing_from_the_source_is_kept() {
  local rec id out status before after
  id='pool-env-local-r9'
  rec=$(make_case env-local-unignored-differs "$id")
  read_case_record "$rec"

  printf 'FIXTURE_MARKER=authored-not-a-real-credential\n' > "$PROJECT_DIR/.env.local"
  chmod 0600 "$PROJECT_DIR/.env.local"
  # Content the task itself wrote: it differs, so it is real work and must survive.
  printf 'FIXTURE_MARKER=the-task-own-work-not-a-real-credential\n' > "$POOL_DIR/.env.local"
  chmod 0600 "$POOL_DIR/.env.local"
  before=$(cksum < "$POOL_DIR/.env.local")

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "spawn should refuse rather than silently deleting the task's own unignored file"
  [ -f "$POOL_DIR/.env.local" ] \
    || fail "spawn deleted an unignored file it could not prove was its own"
  after=$(cksum < "$POOL_DIR/.env.local")
  [ "$after" = "$before" ] \
    || fail "spawn modified an unignored file that was the task's own work"
  assert_contains "$out" "remove it by hand" \
    "the refusal did not tell the operator how to clear the slot"
  pass "an unignored copy that differs from the source is preserved and the refusal is actionable"
}

test_unignored_local_env_file_is_not_seeded() {
  local rec id out status
  id='pool-env-local-r5'
  rec=$(make_case env-local-unignored "$id")
  read_case_record "$rec"

  # Deliberately no .gitignore publish, so the worktree does not ignore the path.
  printf 'FIXTURE_MARKER=unignored-not-a-real-credential\n' > "$PROJECT_DIR/.env.local"
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
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
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
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
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
test_interrupted_seed_scratch_does_not_outlive_revocation
test_cross_filesystem_layout_degrades_to_a_loud_skip
test_unanswerable_filesystem_question_still_refuses
test_unignored_local_env_file_is_not_seeded
test_unignored_copy_matching_the_source_is_retired
test_unignored_copy_differing_from_the_source_is_kept
test_stale_submodule_pin_explains_itself
test_unpushed_submodule_commit_is_still_uncommitted_work
test_work_inside_submodule_is_still_uncommitted_work
test_stale_pin_carrying_real_work_is_not_called_stale
test_stale_pin_beside_other_dirt_reports_one_verdict

echo "# all fm-spawn-pool-base-freshen tests passed"
