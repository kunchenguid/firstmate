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

TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-base-freshen)

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

# The durable ownership record fm-spawn publishes before it stamps a slot's
# owner marker, keyed by task id AND spawn generation.
# bin/fm-worktree-ownership-lib.sh owns this path and its format.
owner_pending_record() {  # <task-id> <spawn-generation>
  printf '%s/state/.%s.meta.worktree-owner-pending.%s' "$HOME_DIR" "$1" "$2"
}

owner_pending_records() {  # <task-id>
  local candidate
  for candidate in "$HOME_DIR/state/.$1.meta.worktree-owner-pending."*; do
    [ -e "$candidate" ] || continue
    printf '%s\n' "$candidate"
  done
}

assert_no_owner_pending_records() {  # <task-id> <msg>
  local found
  found=$(owner_pending_records "$1")
  [ -z "$found" ] || fail "$2"$'\n'"$found"
}

# The generation the slot's owner marker names - the one half of the binding a
# test can read back without knowing what the spawn minted.
marker_spawn_generation() {  # <worktree>
  grep '^spawn_gen=' "$1/.fm-task-owner" | cut -d= -f2-
}

# Replaces git with a shim that SIGKILLs its parent - the fm-spawn shell that
# invokes `git -C <slot> fetch` directly - the first time the pooled base
# freshen reaches the network. SIGKILL is the one abort fm-spawn's EXIT trap
# cannot run through, so this reproduces a crashed or rebooted host exactly at
# the point where the slot is already stamped but no task record exists yet.
install_git_that_kills_spawn_on_fetch() {  # <fakebin> <arming-flag>
  local fakebin=$1 flag=$2 real
  real=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -C ] && [ "\${3:-}" = fetch ] && [ -e "$flag" ]; then
  rm -f "$flag"
  kill -9 "\$PPID"
  exit 1
fi
exec "$real" "\$@"
SH
  chmod +x "$fakebin/git"
}

run_spawn() {
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
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
  assert_grep 'schema=fm-task-owner.v1' "$POOL_DIR/.fm-task-owner" \
    "spawn did not stamp a versioned owner marker"
  assert_grep "task_id=$id" "$POOL_DIR/.fm-task-owner" \
    "spawn owner marker does not name the task"
  assert_grep "spawn_gen=$(grep '^spawn_gen=' "$HOME_DIR/state/$id.meta" | cut -d= -f2-)" \
    "$POOL_DIR/.fm-task-owner" \
    "spawn owner marker generation does not match metadata"
  assert_grep 'task_owner_marker=1' "$HOME_DIR/state/$id.meta" \
    "spawn did not publish the explicit owner-marker awareness bit"
  assert_no_owner_pending_records "$id" \
    "the published task record left its superseded ownership record behind"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed spawn: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    printf '# observed base: HEAD=%s origin/main=%s advanced-main=%s\n' \
      "$branch_head" "$current" "$(cat "$POOL_DIR/advanced-main.txt")"
  fi

  id='pool-current-base-repeat-r1'
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  # Teardown clears the owner marker when it returns the slot; without that the
  # pool would be handing a live task's workspace to a second task.
  rm -f "$POOL_DIR/.fm-task-owner"
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

# A pool slot that still carries another task's owner marker is that task's live
# workspace. Handing it to a second agent is the exact way one task destroys
# another's work, so acquisition refuses rather than restamping it.
test_fresh_spawn_refuses_a_slot_marked_for_another_task() {
  local rec id other out status
  id='pool-foreign-marker-r1'
  rec=$(make_case foreign-marker "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the first spawn should take the pool slot"$'\n'"$out"

  other='pool-foreign-marker-r2'
  mkdir -p "$HOME_DIR/data/$other"
  printf 'brief for %s\n' "$other" > "$HOME_DIR/data/$other/brief.md"

  out=$(run_spawn "$other" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a slot still marked for task $id"
  assert_contains "$out" "already belongs to task $id" \
    "the refusal did not name the task that still owns the slot"
  assert_contains "$out" "not task $other" \
    "the refusal did not name the task being refused"
  assert_grep "task_id=$id" "$POOL_DIR/.fm-task-owner" \
    "the refused spawn overwrote the live task's owner marker"
  assert_absent "$HOME_DIR/state/$other.meta" \
    "the refused spawn published a task record for the slot it could not own"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed foreign-marker refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 2 | head -n 1)"
  fi
  pass "a fresh spawn refuses a pool slot another task's owner marker still claims"
}

# A spawn killed between taking the slot and publishing its task record used to
# leave a marker nothing could attribute: no record existed, so no teardown
# existed either, and the pool slot refused every later spawn forever while the
# refusal named a teardown that could not be run. The ownership record now goes
# down before the marker, so the interruption leaves recoverable metadata.
test_killed_spawn_leaves_an_attributable_ownership_record() {
  local rec id other out status pending marker_gen
  id='pool-killed-spawn-r1'
  rec=$(make_case killed-spawn "$id")
  read_case_record "$rec"
  install_git_that_kills_spawn_on_fetch "$FAKEBIN_DIR" "$CASE_DIR/kill-on-fetch"
  : > "$CASE_DIR/kill-on-fetch"

  status=0
  out=$(run_spawn "$id" --mode no-mistakes --yolo off) || status=$?

  [ "$status" -ne 0 ] || fail "the fixture never interrupted the spawn"$'\n'"$out"
  assert_present "$POOL_DIR/.fm-task-owner" \
    "the fixture did not reproduce an interruption that skips the abort trap"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the fixture published a task record, so the slot was never orphaned"
  marker_gen=$(marker_spawn_generation "$POOL_DIR")
  [ -n "$marker_gen" ] || fail "the orphaned marker carries no spawn generation"
  pending=$(owner_pending_record "$id" "$marker_gen")
  assert_present "$pending" \
    "the killed spawn left its owner marker with no ownership record for its own generation"
  assert_grep "worktree=$POOL_DIR" "$pending" \
    "the surviving ownership record does not name the slot the marker sits in"

  # The recovery an operator can actually perform has to be the one the refusal
  # names: there is no task record here, so there is no teardown to run.
  other='pool-killed-spawn-r2'
  mkdir -p "$HOME_DIR/data/$other"
  printf 'brief for %s\n' "$other" > "$HOME_DIR/data/$other/brief.md"
  status=0
  out=$(run_spawn "$other" --mode no-mistakes --yolo off) || status=$?

  [ "$status" -ne 0 ] || fail "spawn accepted a slot an interrupted spawn still marks"
  assert_contains "$out" "already belongs to task $id" \
    "the refusal did not name the task the marker belongs to"
  assert_contains "$out" "No teardown exists for task $id" \
    "the refusal still points at a teardown for a task that has no record"
  assert_contains "$out" "$pending" \
    "the refusal did not name the interrupted spawn's ownership record"
  assert_grep "task_id=$id" "$POOL_DIR/.fm-task-owner" \
    "the refused spawn reclaimed another task's owner marker"
  assert_present "$pending" \
    "the refused spawn deleted another task's ownership record"
  assert_no_owner_pending_records "$other" \
    "the refused spawn left its own ownership record on a slot it never took"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed interrupted-owner refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 2 | head -n 1)"
  fi
  pass "a spawn killed before publishing its record leaves an attributable owner marker"
}

# A lost ownership record must not turn the task id in a surviving marker into
# authority for a fresh spawn. Only --relaunch first proves the record, path,
# generation handoff, and prior worker state; a fresh recovery spawn has none of
# that evidence and must preserve the marker rather than restamping the slot.
test_fresh_respawn_refuses_same_id_marker_after_pending_record_is_lost() {
  local rec id out status marker_gen pending before
  id='pool-respawn-lost-pending-r1'
  rec=$(make_case respawn-lost-pending "$id")
  read_case_record "$rec"
  install_git_that_kills_spawn_on_fetch "$FAKEBIN_DIR" "$CASE_DIR/kill-on-fetch"
  : > "$CASE_DIR/kill-on-fetch"

  status=0
  out=$(run_spawn "$id" --mode no-mistakes --yolo off) || status=$?
  [ "$status" -ne 0 ] || fail "the fixture never interrupted the first spawn"$'\n'"$out"
  marker_gen=$(marker_spawn_generation "$POOL_DIR")
  [ -n "$marker_gen" ] || fail "the fixture left no owner marker to protect"
  pending=$(owner_pending_record "$id" "$marker_gen")
  assert_present "$pending" "the fixture left no ownership record to lose"
  rm -f "$pending"
  before=$(cat "$POOL_DIR/.fm-task-owner")

  status=0
  out=$(run_spawn "$id" --mode no-mistakes --yolo off) || status=$?

  [ "$status" -ne 0 ] || fail "a fresh spawn reused $id and overwrote its surviving owner marker"$'\n'"$out"
  assert_contains "$out" "a fresh spawn refuses any existing owner marker" \
    "the refusal did not distinguish fresh spawn from metadata-backed relaunch"
  assert_contains "$out" "task $id" \
    "the refusal did not name the task identity in the surviving marker"
  [ "$(cat "$POOL_DIR/.fm-task-owner")" = "$before" ] \
    || fail "the refused fresh spawn overwrote the surviving marker's generation"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the refused fresh spawn published a task record for a slot it could not prove"
  assert_no_owner_pending_records "$id" \
    "the refused fresh spawn published a replacement ownership record"
  pass "a fresh spawn refuses a same-id marker after its pending record is lost"
}

# Recovery is told to keep the same task identity, so respawning the very id
# whose spawn was killed is the expected next move. That respawn must not draw a
# second slot: doing so leaves the first one behind an owner marker whose only
# evidence - the earlier generation's ownership record - the new spawn would
# have overwritten under a task-id-keyed name.
test_respawn_of_a_killed_task_id_refuses_until_its_claim_is_resolved() {
  local rec id out status marker_gen pending before
  id='pool-respawn-killed-r1'
  rec=$(make_case respawn-killed "$id")
  read_case_record "$rec"
  install_git_that_kills_spawn_on_fetch "$FAKEBIN_DIR" "$CASE_DIR/kill-on-fetch"
  : > "$CASE_DIR/kill-on-fetch"

  status=0
  out=$(run_spawn "$id" --mode no-mistakes --yolo off) || status=$?
  [ "$status" -ne 0 ] || fail "the fixture never interrupted the first spawn"$'\n'"$out"
  marker_gen=$(marker_spawn_generation "$POOL_DIR")
  [ -n "$marker_gen" ] || fail "the fixture left no owner marker to strand"
  pending=$(owner_pending_record "$id" "$marker_gen")
  assert_present "$pending" "the fixture left no ownership record for the killed generation"
  before=$(cat "$pending")

  # Same task id, exactly as stuck-crewmate recovery prescribes.
  status=0
  out=$(run_spawn "$id" --mode no-mistakes --yolo off) || status=$?

  [ "$status" -ne 0 ] || fail "a respawn of $id took another worktree while its earlier claim was unresolved"$'\n'"$out"
  assert_contains "$out" "unresolved worktree ownership record" \
    "the refusal did not report the unresolved ownership record"
  assert_contains "$out" "$marker_gen" \
    "the refusal did not name the unresolved spawn generation"
  assert_contains "$out" "$POOL_DIR" \
    "the refusal did not name the worktree the unresolved generation took"
  assert_contains "$out" "$pending" \
    "the refusal did not name the ownership record to resolve"
  [ "$(cat "$pending")" = "$before" ] \
    || fail "the respawn rewrote the killed generation's ownership record"
  assert_grep "spawn_gen=$marker_gen" "$POOL_DIR/.fm-task-owner" \
    "the respawn reclaimed the stranded slot's owner marker"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the refused respawn published a task record anyway"
  [ "$(owner_pending_records "$id" | wc -l)" = 1 ] \
    || fail "the refused respawn published a second ownership record"$'\n'"$(owner_pending_records "$id")"

  # Resolving the claim the way the refusal describes lets the id spawn again.
  rm -f "$POOL_DIR/.fm-task-owner" "$pending"
  status=0
  out=$(run_spawn "$id" --mode no-mistakes --yolo off) || status=$?
  expect_code 0 "$status" "a resolved claim should let the same task id spawn again"$'\n'"$out"
  assert_grep "task_id=$id" "$POOL_DIR/.fm-task-owner" \
    "the recovered spawn did not take the slot it was given"
  pass "a respawn of a killed task id refuses until its earlier ownership claim is resolved"
}

# A record that exists but has moved on: it names another spawn generation and
# another worktree, so its teardown retires a marker somewhere else entirely and
# will never clear this slot's. Naming that teardown as the remedy would be
# naming one that cannot work.
test_owner_marker_a_moved_on_record_cannot_retire_names_the_real_remedy() {
  local rec id other out status moved
  id='pool-stale-record-r1'
  rec=$(make_case stale-record "$id")
  read_case_record "$rec"

  status=0
  out=$(run_spawn "$id" --mode no-mistakes --yolo off) || status=$?
  expect_code 0 "$status" "the first spawn should take the pool slot"$'\n'"$out"

  # Rebind the record to a different generation and a different worktree, and
  # leave this slot's marker exactly where the first spawn stamped it.
  moved="$CASE_DIR/moved-slot"
  mkdir -p "$moved"
  sed -e "s|^worktree=.*|worktree=$moved|" -e 's|^spawn_gen=.*|spawn_gen=smoved.1.1|' \
    "$HOME_DIR/state/$id.meta" > "$HOME_DIR/state/$id.meta.next"
  mv -f "$HOME_DIR/state/$id.meta.next" "$HOME_DIR/state/$id.meta"

  other='pool-stale-record-r2'
  mkdir -p "$HOME_DIR/data/$other"
  printf 'brief for %s\n' "$other" > "$HOME_DIR/data/$other/brief.md"
  status=0
  out=$(run_spawn "$other" --mode no-mistakes --yolo off) || status=$?

  [ "$status" -ne 0 ] || fail "spawn accepted a slot another task's marker still claims"
  assert_contains "$out" "already belongs to task $id" \
    "the refusal did not name the task the marker claims"
  assert_contains "$out" "will never retire this marker" \
    "the refusal still points at a teardown that cannot clear this slot"
  assert_contains "$out" "remove $POOL_DIR/.fm-task-owner to release the slot" \
    "the refusal did not name the recovery that actually clears the slot"
  assert_grep "task_id=$id" "$POOL_DIR/.fm-task-owner" \
    "the refused spawn removed a marker belonging to another task"
  pass "a marker its own task's record has moved past names marker removal, not a teardown"
}

# A record that says two things about its worktree says nothing safe about who
# owns this slot. Calling that "moved on" and telling the operator to delete the
# marker would delete the only binding protecting a live worker - the exact
# outcome the marker exists to prevent - so ambiguity must read as unknown
# ownership instead.
test_ambiguous_record_never_advises_removing_the_marker() {
  local rec id other out status
  id='pool-ambiguous-record-r1'
  rec=$(make_case ambiguous-record "$id")
  read_case_record "$rec"

  status=0
  out=$(run_spawn "$id" --mode no-mistakes --yolo off) || status=$?
  expect_code 0 "$status" "the first spawn should take the pool slot"$'\n'"$out"

  # A partially rewritten record that ends up saying two different things about
  # both halves of ownership - the state fm_worktree_meta_claim already treats
  # as a real possibility - while the task is live in the slot.
  printf 'spawn_gen=%s\n' 'sduplicate.1.1' >> "$HOME_DIR/state/$id.meta"
  printf 'worktree=%s\n' "$CASE_DIR/some-other-slot" >> "$HOME_DIR/state/$id.meta"

  other='pool-ambiguous-record-r2'
  mkdir -p "$HOME_DIR/data/$other"
  printf 'brief for %s\n' "$other" > "$HOME_DIR/data/$other/brief.md"
  status=0
  out=$(run_spawn "$other" --mode no-mistakes --yolo off) || status=$?

  [ "$status" -ne 0 ] || fail "spawn accepted a slot a live task's marker still claims"
  assert_contains "$out" "already belongs to task $id" \
    "the refusal did not name the task the marker claims"
  assert_contains "$out" "does not say clearly enough who owns this slot" \
    "the refusal did not report the record as undecidable"
  assert_not_contains "$out" "remove $POOL_DIR/.fm-task-owner to release the slot" \
    "an unreadable record led the refusal to advise deleting a live worker's marker"
  assert_not_contains "$out" "will never retire this marker" \
    "an ambiguous record was reported as one that had moved on"
  assert_grep "task_id=$id" "$POOL_DIR/.fm-task-owner" \
    "the refused spawn removed the live task's owner marker"
  pass "an ambiguous record reads as unknown ownership, never as a marker to delete"
}

# An ownership record whose slot carries no marker for it strands nothing: the
# claim is already resolved and the file is leftover paperwork. Refusing on it
# would wedge the task id for good with no supported way out.
test_resolved_ownership_record_does_not_block_a_fresh_spawn() {
  local rec id out status leftover
  id='pool-resolved-claim-r1'
  rec=$(make_case resolved-claim "$id")
  read_case_record "$rec"
  leftover=$(owner_pending_record "$id" sgone.1.1)
  mkdir -p "$CASE_DIR/returned-slot"
  {
    printf '%s\n' 'schema=fm-task-owner-pending.v1'
    printf 'task_id=%s\n' "$id"
    printf '%s\n' 'spawn_gen=sgone.1.1'
    printf 'worktree=%s\n' "$CASE_DIR/returned-slot"
  } > "$leftover"

  status=0
  out=$(run_spawn "$id" --mode no-mistakes --yolo off) || status=$?

  expect_code 0 "$status" "a resolved ownership record must not block a fresh spawn"$'\n'"$out"
  assert_contains "$out" "already resolved" \
    "the spawn stepped over the leftover record without reporting it"
  assert_contains "$out" "$leftover" \
    "the notice did not name the leftover record that is safe to delete"
  assert_grep "task_id=$id" "$POOL_DIR/.fm-task-owner" \
    "the spawn did not take the slot it was given"
  assert_present "$leftover" \
    "the spawn deleted a leftover ownership record instead of reporting it"
  pass "an ownership record whose slot strands nothing is reported, not treated as a block"
}

# A marker whose task this home has no metadata for at all - what survives once
# an interrupted spawn's ownership record has been cleaned up but the slot was
# returned without clearing the marker. The slot still refuses, but the remedy
# named is the only one that exists.
test_unattributed_owner_marker_refusal_names_a_remedy_that_exists() {
  local rec id out status
  id='pool-orphan-marker-r1'
  rec=$(make_case orphan-marker "$id")
  read_case_record "$rec"
  {
    printf '%s\n' 'schema=fm-task-owner.v1'
    printf 'task_id=%s\n' 'gone-task-r9'
    printf 'spawn_gen=%s\n' 'sgone.1.1'
  } > "$POOL_DIR/.fm-task-owner"

  status=0
  out=$(run_spawn "$id" --mode no-mistakes --yolo off) || status=$?

  [ "$status" -ne 0 ] || fail "spawn accepted a slot another task's marker still claims"
  assert_contains "$out" "already belongs to task gone-task-r9" \
    "the refusal did not name the task the marker claims"
  assert_contains "$out" "no spawn ownership record" \
    "the refusal did not report that nothing attributes the marker"
  assert_contains "$out" "remove $POOL_DIR/.fm-task-owner to release the slot" \
    "the refusal did not name the only recovery available for an unattributed marker"
  assert_grep "task_id=gone-task-r9" "$POOL_DIR/.fm-task-owner" \
    "the refused spawn overwrote an unattributed marker instead of refusing"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the refused spawn published a task record for a slot it could not own"
  pass "an unattributed owner marker refuses the slot and names a recovery that exists"
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
  assert_absent "$POOL_DIR/.fm-task-owner" \
    "an aborted spawn returned control with a stale owner marker in the pool slot"
  assert_no_owner_pending_records "$id" \
    "an aborted spawn left this generation's ownership record behind"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "an aborted spawn published task metadata despite failing before launch"
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
  # The seed task hands the slot back the way a teardown would, so the case
  # under test acquires an unowned slot rather than a live task's workspace.
  rm -f "$POOL_DIR/.fm-task-owner"
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
test_fresh_spawn_refuses_a_slot_marked_for_another_task
test_killed_spawn_leaves_an_attributable_ownership_record
test_fresh_respawn_refuses_same_id_marker_after_pending_record_is_lost
test_respawn_of_a_killed_task_id_refuses_until_its_claim_is_resolved
test_owner_marker_a_moved_on_record_cannot_retire_names_the_real_remedy
test_ambiguous_record_never_advises_removing_the_marker
test_resolved_ownership_record_does_not_block_a_fresh_spawn
test_unattributed_owner_marker_refusal_names_a_remedy_that_exists
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base
test_stale_submodule_pin_explains_itself
test_unpushed_submodule_commit_is_still_uncommitted_work
test_work_inside_submodule_is_still_uncommitted_work
test_stale_pin_carrying_real_work_is_not_called_stale
test_stale_pin_beside_other_dirt_reports_one_verdict

echo "# all fm-spawn-pool-base-freshen tests passed"
