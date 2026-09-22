#!/usr/bin/env bash
# Regression tests for fm-spawn's pooled-worktree base refresh.
#
# A treehouse pool can return a clean detached worktree whose origin/main was
# advanced after the worktree was allocated.
# These tests drive the real spawn path with a fake terminal, then prove it
# starts the worker from the fetched origin tip, launches a clean origin-less
# pool as-is, or stops when a configured origin is unusable.
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

test_remote_seeded_home_spawns_from_treehouse_pool() {
  local rec id out status lock
  id='pool-remote-seeded-r13'
  rec=$(make_case remote-seeded "$id")
  read_case_record "$rec"
  cat > "$HOME_DIR/.fm-secondmate-parent" <<'REC'
schema=fm-secondmate-parent.v1
route=remote
parent_host=parent-machine
REC

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" \
    "a remote-seeded secondmate home should allocate and launch from its Treehouse pool"$'\n'"$out"
  assert_contains "$out" "spawned $id" \
    "the remote-seeded spawn did not report success"
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" \
    "the remote-seeded spawn did not publish its allocated pool worktree"
  lock=$(FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$PROJECT_DIR") \
    || fail "the launched remote-seeded home could not resolve its Treehouse project lock"
  case "$lock" in
    "$HOME_DIR/state/"*) ;;
    *) fail "the remote-seeded spawn anchored its lock outside its local root: $lock" ;;
  esac
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# remote-seeded Treehouse spawn command\n'
    printf '$ FM_HOME=%s bin/fm-spawn.sh %s %s --scout\n%s\nexit=%s\n' \
      "$HOME_DIR" "$id" "$PROJECT_DIR" "$out" "$status"
    printf 'published worktree=%s\nresolved project lock=%s\n' "$POOL_DIR" "$lock"
  fi
  pass "a remote-seeded secondmate home allocates and launches from its Treehouse pool"
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

test_expected_head_launches_exact_origin_commit() {
  local rec id out status
  id='pool-expected-head-r1'
  rec=$(make_case expected-head "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" update-ref refs/remotes/origin/stale "$INITIAL_SHA"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$INITIAL_SHA")
  status=$?
  expect_code 0 "$status" "spawn should launch from the exact origin-backed candidate"$'\n'"$out"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$INITIAL_SHA" ] \
    || fail "spawn did not reset the pooled worktree to the exact requested candidate"
  [ "$(git -C "$POOL_DIR" rev-parse origin/main)" != "$INITIAL_SHA" ] \
    || fail "fixture did not distinguish the requested candidate from the current default tip"
  assert_grep "expected_head=$INITIAL_SHA" "$HOME_DIR/state/$id.meta" \
    "spawn did not bind the exact candidate in task metadata"
  git -C "$POOL_DIR" show-ref --verify --quiet refs/remotes/origin/stale \
    || fail "expected-head authorization pruned an unrelated stale remote-tracking ref"
  pass "an expected-head spawn launches and records the exact origin-backed commit instead of the default tip"
}

test_expected_head_hashes_in_candidate_object_format() {
  local rec id out status caller candidate path
  for path in regular symlink; do
    id="pool-expected-object-format-$path-r22"
    rec=$(make_case "expected-object-format-$path" "$id")
    read_case_record "$rec"
    caller="$CASE_DIR/caller-sha256"
    git init --quiet --object-format=sha256 "$caller"
    candidate=$INITIAL_SHA
    if [ "$path" = symlink ]; then
      git -C "$PROJECT_DIR" fetch --quiet origin
      git -C "$PROJECT_DIR" reset --hard origin/main >/dev/null
      git -C "$PROJECT_DIR" rm -q README.md advanced-main.txt
      ln -s reviewed-target "$PROJECT_DIR/reviewed-link"
      git -C "$PROJECT_DIR" add reviewed-link
      git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
        commit -qm reviewed-symlink
      git -C "$PROJECT_DIR" push --quiet origin main
      candidate=$(git -C "$PROJECT_DIR" rev-parse HEAD)
    fi

    out=$(cd "$caller" && run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$candidate")
    status=$?
    expect_code 0 "$status" "expected-head $path hashing should use the candidate repository format"$'\n'"$out"
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$candidate" ] \
      || fail "object-format-safe $path spawn did not converge the reviewed candidate"
    assert_grep "expected_head=$candidate" "$HOME_DIR/state/$id.meta" \
      "object-format-safe $path spawn did not record the reviewed candidate"
  done
  pass "expected-head hashes regular files and symlinks in candidate format"
}

test_expected_head_ignores_replacement_objects() {
  local rec id out status replacement worker_evidence launch_log pending raw_launch
  id='pool-expected-replace-r1'
  rec=$(make_case expected-replace "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" fetch --quiet origin
  replacement=$(git -C "$POOL_DIR" rev-parse origin/main)
  git -C "$POOL_DIR" replace "$INITIAL_SHA" "$replacement"
  git -C "$POOL_DIR" show "$INITIAL_SHA:advanced-main.txt" >/dev/null \
    || fail "replacement fixture did not reinterpret the candidate as the replacement tree"
  ! GIT_NO_REPLACE_OBJECTS=1 git -C "$POOL_DIR" show "$INITIAL_SHA:advanced-main.txt" >/dev/null 2>&1 \
    || fail "replacement fixture did not distinguish the origin candidate tree"
  worker_evidence="$CASE_DIR/worker-evidence"
  launch_log="$CASE_DIR/launch.log"
  pending="$CASE_DIR/pending-launch"
  raw_launch="printf '%s\\n' \"\${GIT_NO_REPLACE_OBJECTS:-}\" > '$worker_evidence'; git -C '$POOL_DIR' show HEAD:README.md >> '$worker_evidence'; if [ -e '$POOL_DIR/advanced-main.txt' ]; then printf 'replacement-tree\\n' >> '$worker_evidence'; else printf 'origin-tree\\n' >> '$worker_evidence'; fi"

  out=$(FM_FAKE_LAUNCH_LOG="$launch_log" FM_FAKE_PENDING_LAUNCH="$pending" \
    FM_FAKE_EXECUTE_LAUNCH=1 \
    run_spawn "$id" "$raw_launch" --mode no-mistakes --yolo off --expected-head "$INITIAL_SHA")
  status=$?
  expect_code 0 "$status" "spawn should ignore local replacement objects for the exact candidate"$'\n'"$out"
  [ ! -e "$POOL_DIR/advanced-main.txt" ] \
    || fail "expected-head reset checked out the replacement commit's tree"
  [ "$(cat "$POOL_DIR/README.md")" = base ] \
    || fail "expected-head reset did not check out the origin commit's content"
  [ -f "$worker_evidence" ] || fail "the fake worker did not record exact-head launch evidence"
  [ "$(sed -n '1p' "$worker_evidence")" = 1 ] \
    || fail "the launched worker did not inherit GIT_NO_REPLACE_OBJECTS=1"
  [ "$(sed -n '2p' "$worker_evidence")" = base ] \
    || fail "the launched worker read replaced content for the recorded candidate"
  [ "$(sed -n '3p' "$worker_evidence")" = origin-tree ] \
    || fail "the launched worker observed the replacement tree"
  pass "expected-head reset and worker Git reads ignore replacement objects"
}

test_expected_head_refuses_non_origin_commit_and_invalid_input() {
  local rec id out status local_only origin_tip grafts
  id='pool-expected-local-r1'
  rec=$(make_case expected-local "$id")
  read_case_record "$rec"
  printf 'local only\n' > "$POOL_DIR/local-only.txt"
  git -C "$POOL_DIR" add local-only.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm local-only
  local_only=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$local_only")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a commit that origin does not serve"
  assert_contains "$out" "not an ancestor of any head returned by the origin fetch" \
    "spawn did not explain that the exact candidate lacks origin authority"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "origin-refused expected head published task metadata"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$local_only" ] \
    || fail "origin-refused expected head moved the clean local-only commit"

  id='pool-expected-graft-r23'
  rec=$(make_case expected-graft "$id")
  read_case_record "$rec"
  printf 'local graft candidate\n' > "$POOL_DIR/local-graft.txt"
  git -C "$POOL_DIR" add local-graft.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm local-graft
  local_only=$(git -C "$POOL_DIR" rev-parse HEAD)
  origin_tip=$(git -C "$CASE_DIR/origin.git" rev-parse HEAD)
  git -C "$POOL_DIR" fetch --quiet origin
  grafts=$(git -C "$POOL_DIR" rev-parse --git-path info/grafts)
  printf '%s %s\n' "$origin_tip" "$local_only" > "$grafts"
  git -C "$POOL_DIR" merge-base --is-ancestor "$local_only" "$origin_tip" \
    || fail "graft fixture did not forge origin ancestry"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$local_only")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted origin ancestry forged by Git grafts"
  assert_contains "$out" "has active Git grafts" \
    "spawn did not explain that graft metadata blocks exact-head authorization"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "graft-refused expected head published task metadata"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$local_only" ] \
    || fail "graft-refused expected head moved the clean local-only commit"

  id='pool-expected-invalid-r1'
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off --expected-head origin/main)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an arbitrary ref as --expected-head"
  assert_contains "$out" "one full 40-hex commit id" \
    "spawn did not reject an arbitrary ref at its public interface"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "invalid expected head published task metadata"
  pass "expected-head accepts neither local, graft-authorized, nor arbitrary coordinates"
}

test_expected_head_ignores_ambient_git_redirection() {
  local rec id out status attacker
  id='pool-expected-git-env-r1'
  rec=$(make_case expected-git-env "$id")
  read_case_record "$rec"
  attacker="$CASE_DIR/attacker"
  git init --quiet -b main "$attacker"
  printf 'unrelated\n' > "$attacker/unrelated.txt"
  git -C "$attacker" add unrelated.txt
  git -C "$attacker" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm unrelated

  out=$(GIT_DIR="$attacker/.git" GIT_WORK_TREE="$attacker" \
    run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$INITIAL_SHA")
  status=$?
  expect_code 0 "$status" "ambient Git redirection must not replace the explicit candidate worktree"$'\n'"$out"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$INITIAL_SHA" ] \
    || fail "ambient Git redirection displaced exact candidate convergence"
  assert_grep "expected_head=$INITIAL_SHA" "$HOME_DIR/state/$id.meta" \
    "ambient Git redirection displaced the metadata binding"

  id='pool-default-git-env-r1'
  fm_test_spawn_brief "$HOME_DIR" "$id"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(GIT_DIR="$attacker/.git" GIT_WORK_TREE="$attacker" \
    run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "ordinary spawn stopped honoring ambient Git redirection"
  assert_contains "$out" "did not enter an isolated worktree" \
    "ordinary spawn did not preserve its ambient Git behavior"
  pass "only expected-head verification ignores ambient Git repository redirection"
}

test_expected_head_ignores_ambient_git_config_overrides() {
  local rec id out status attacker_origin unauthorized worker_evidence pending raw_launch original_url
  id='pool-expected-git-config-r1'
  rec=$(make_case expected-git-config "$id")
  read_case_record "$rec"
  attacker_origin="$CASE_DIR/attacker.git"
  git -C "$POOL_DIR" fetch --quiet origin
  git -C "$POOL_DIR" reset --hard origin/main >/dev/null
  printf 'not served by origin\n' > "$POOL_DIR/unauthorized.txt"
  git -C "$POOL_DIR" add unauthorized.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm unauthorized
  unauthorized=$(git -C "$POOL_DIR" rev-parse HEAD)
  git init --quiet --bare "$attacker_origin"
  git -C "$POOL_DIR" push --quiet "file://$attacker_origin" HEAD:refs/heads/main
  git -C "$POOL_DIR" reset --hard "$INITIAL_SHA" >/dev/null
  [ "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.url \
    GIT_CONFIG_VALUE_0="file://$attacker_origin" \
    git -C "$POOL_DIR" config --get remote.origin.url)" = "file://$attacker_origin" ] \
    || fail "fixture did not override origin through Git command-scope configuration"

  out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.url \
    GIT_CONFIG_VALUE_0="file://$attacker_origin" \
    run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$unauthorized")
  status=$?
  [ "$status" -ne 0 ] || fail "ambient Git config authorized a candidate absent from the recorded origin"
  assert_contains "$out" "not an ancestor of any head returned by the origin fetch" \
    "spawn did not reject the candidate absent from the recorded origin"
  [ ! -e "$HOME_DIR/state/$id.meta" ] \
    || fail "Git-config-refused expected head published task metadata"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$INITIAL_SHA" ] \
    || fail "Git config override moved the pool during exact-head refusal"

  id='pool-expected-global-git-config-r16'
  fm_test_spawn_brief "$HOME_DIR" "$id"
  original_url=$(git -C "$POOL_DIR" remote get-url origin)
  git config --file "$HOME_DIR/user-home/.gitconfig" \
    "url.file://$attacker_origin.insteadOf" "$original_url"
  GIT_CONFIG_GLOBAL="$HOME_DIR/user-home/.gitconfig" git -C "$POOL_DIR" ls-remote origin \
    | grep -Fq "$unauthorized" \
    || fail "fixture did not redirect origin transport through global Git configuration"
  out=$(GIT_CONFIG_GLOBAL="$HOME_DIR/user-home/.gitconfig" \
    run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$unauthorized")
  status=$?
  rm -f "$HOME_DIR/user-home/.gitconfig"
  [ "$status" -ne 0 ] || fail "global Git config redirected exact-head origin authorization"
  assert_contains "$out" "not an ancestor of any head returned by the origin fetch" \
    "spawn did not reject the candidate absent from the repository-local origin"
  [ ! -e "$HOME_DIR/state/$id.meta" ] \
    || fail "global-Git-config-refused expected head published task metadata"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$INITIAL_SHA" ] \
    || fail "global Git config moved the pool during exact-head refusal"

  id='pool-default-git-config-r1'
  fm_test_spawn_brief "$HOME_DIR" "$id"
  worker_evidence="$CASE_DIR/ordinary-worker-git-config"
  pending="$CASE_DIR/ordinary-pending-launch"
  raw_launch="git config --get fixture.ambient > '$worker_evidence'"
  out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=fixture.ambient \
    GIT_CONFIG_VALUE_0=preserved FM_FAKE_PENDING_LAUNCH="$pending" \
    FM_FAKE_EXECUTE_LAUNCH=1 \
    run_spawn "$id" "$raw_launch" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ordinary spawn should retain ambient Git config behavior"$'\n'"$out"
  [ -f "$worker_evidence" ] \
    || fail "ordinary worker did not record its ambient Git configuration"
  [ "$(cat "$worker_evidence")" = preserved ] \
    || fail "ordinary spawn stopped preserving ambient Git configuration"
  pass "only expected-head authorization ignores ambient Git configuration overrides"
}

test_expected_head_refuses_unsupported_lifecycle_shapes() {
  local rec id out status
  id='pool-expected-shapes-r1'
  rec=$(make_case expected-shapes "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --relaunch --expected-head "$INITIAL_SHA")
  status=$?
  [ "$status" -ne 0 ] || fail "relaunch accepted --expected-head"
  assert_contains "$out" "--expected-head cannot override it" \
    "relaunch did not explain its expected-head refusal"

  out=$(run_spawn "$id" --secondmate --expected-head "$INITIAL_SHA")
  status=$?
  [ "$status" -ne 0 ] || fail "secondmate accepted --expected-head"
  assert_contains "$out" "not secondmates" \
    "secondmate did not explain its expected-head refusal"

  out=$(run_spawn "$id=$PROJECT_DIR" --scout --expected-head "$INITIAL_SHA")
  status=$?
  [ "$status" -ne 0 ] || fail "batch dispatch accepted --expected-head"
  assert_contains "$out" "batch dispatch does not support --expected-head" \
    "batch dispatch did not explain its expected-head refusal"
  pass "relaunch, secondmate, and batch dispatch refuse expected-head contradictions"
}

test_expected_head_is_reverified_immediately_before_launch() {
  local rec id out status real_sleep marker mutation launch_log pending started
  for mutation in head dirty assume; do
    id="pool-expected-race-$mutation-r2"
    rec=$(make_case "expected-race-$mutation" "$id")
    read_case_record "$rec"
    marker="$CASE_DIR/mutated-after-launch-staging"
    launch_log="$CASE_DIR/launch.log"
    pending="$CASE_DIR/pending-launch"
    started="$CASE_DIR/worker-started"
    real_sleep=$(command -v sleep)
    cat > "$FAKEBIN_DIR/sleep" <<EOF
#!/bin/sh
if [ -e '$pending' ] && [ ! -e '$marker' ]; then
  if [ '$mutation' = head ]; then
    git -C '$POOL_DIR' reset --hard 'origin/main' >/dev/null
  elif [ '$mutation' = assume ]; then
    git -C '$POOL_DIR' update-index --assume-unchanged README.md
    printf 'late suppressed mutation\n' > '$POOL_DIR/README.md'
  else
    printf 'late mutation\n' > '$POOL_DIR/late-untracked.txt'
  fi
  : > '$marker'
fi
exec '$real_sleep' "\$@"
EOF
    chmod +x "$FAKEBIN_DIR/sleep"

    out=$(FM_FAKE_LAUNCH_LOG="$launch_log" FM_FAKE_PENDING_LAUNCH="$pending" \
      FM_FAKE_WORKER_START_LOG="$started" \
      run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$INITIAL_SHA")
    status=$?
    [ "$status" -ne 0 ] || fail "spawn launched after the final-window $mutation mutation"
    [ -e "$marker" ] || fail "fixture did not apply the $mutation mutation after launch text settled"
    [ ! -e "$pending" ] || fail "$mutation refusal left the staged launch text in the pane"
    [ ! -e "$started" ] || fail "$mutation refusal submitted the staged launch and started a worker"
    case "$mutation" in
      head) assert_contains "$out" "moved to" "spawn did not report the final-window HEAD mismatch" ;;
      dirty|assume) assert_contains "$out" "dirty candidate" "spawn did not report the final-window dirty tree" ;;
    esac
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "$mutation refusal left published task metadata"
  done
  pass "expected-head launch rechecks HEAD and cleanliness after text settles without starting a worker"
}

test_expected_head_rejects_submodule_index_suppression() {
  local rec id out status
  id=pool-expected-submodule-skip-worktree-r18
  rec=$(make_submodule_case expected-submodule-skip-worktree "$id")
  read_submodule_case "$rec"
  git -C "$POOL_DIR/ui" update-index --skip-worktree lib.txt
  printf 'suppressed submodule mutation\n' >"$POOL_DIR/ui/lib.txt"
  [ -z "$(git -C "$POOL_DIR" status --porcelain --ignore-submodules=none)" ] \
    || fail "fixture did not hide the skip-worktree submodule mutation"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$ADVANCED_SHA")
  status=$?
  [ "$status" -ne 0 ] || fail "expected-head spawn launched with skip-worktree content inside a submodule"
  assert_grep 'suppressed submodule mutation' "$POOL_DIR/ui/lib.txt" \
    "expected-head refusal discarded skip-worktree content inside the submodule"
  [ ! -e "$HOME_DIR/state/$id.meta" ] \
    || fail "skip-worktree-refused expected head published task metadata"
  pass "expected-head rejects suppressed index content in initialized submodules"
}

test_expected_head_rejects_hidden_file_mode_changes() {
  local rec id out status
  id=pool-expected-hidden-file-mode-r19
  rec=$(make_case expected-hidden-file-mode "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" config core.fileMode false
  chmod +x "$POOL_DIR/README.md"
  [ -x "$POOL_DIR/README.md" ] || fail "fixture did not change the tracked executable bit"
  [ -z "$(git -C "$POOL_DIR" status --porcelain)" ] \
    || fail "fixture did not hide the executable-bit change through repository config"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$INITIAL_SHA")
  status=$?
  [ "$status" -ne 0 ] || fail "expected-head spawn launched with altered tracked file mode"
  [ -x "$POOL_DIR/README.md" ] \
    || fail "expected-head refusal discarded the hidden file-mode change"
  [ ! -e "$HOME_DIR/state/$id.meta" ] \
    || fail "file-mode-refused expected head published task metadata"
  pass "expected-head rejects file-mode changes hidden by repository config"
}

test_expected_head_rejects_filtered_worktree_bytes() {
  local rec id out status attributes expected
  id=pool-expected-filtered-bytes-r21
  rec=$(make_case expected-filtered-bytes "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" config filter.review.clean "sed 's/^SMUDGED$/base/'"
  git -C "$POOL_DIR" config filter.review.smudge "sed 's/^base$/SMUDGED/'"
  attributes=$(git -C "$POOL_DIR" rev-parse --git-path info/attributes)
  printf 'README.md filter=review\n' >"$attributes"
  printf 'force checkout\n' >"$POOL_DIR/README.md"
  git -C "$POOL_DIR" reset --hard "$INITIAL_SHA" >/dev/null
  [ "$(cat "$POOL_DIR/README.md")" = SMUDGED ] \
    || fail "fixture did not smudge the tracked worktree bytes"
  [ -z "$(git -C "$POOL_DIR" status --porcelain)" ] \
    || fail "fixture did not map the smudged bytes back through the clean filter"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$INITIAL_SHA")
  status=$?
  [ "$status" -ne 0 ] || fail "expected-head spawn launched filtered bytes outside the reviewed blob"
  [ "$(cat "$POOL_DIR/README.md")" = SMUDGED ] \
    || fail "expected-head refusal discarded the filtered worktree bytes"
  [ ! -e "$HOME_DIR/state/$id.meta" ] \
    || fail "filtered-bytes-refused expected head published task metadata"

  id=pool-expected-submodule-filtered-bytes-r21
  rec=$(make_submodule_case expected-submodule-filtered-bytes "$id")
  read_submodule_case "$rec"
  expected=$(git -C "$POOL_DIR" rev-parse HEAD)
  git -C "$POOL_DIR/ui" config filter.review.clean "sed 's/^SMUDGED$/pin one/'"
  git -C "$POOL_DIR/ui" config filter.review.smudge "sed 's/^pin one$/SMUDGED/'"
  attributes=$(git -C "$POOL_DIR/ui" rev-parse --git-path info/attributes)
  printf 'lib.txt filter=review\n' >"$attributes"
  printf 'force checkout\n' >"$POOL_DIR/ui/lib.txt"
  git -C "$POOL_DIR/ui" reset --hard "$SUBPIN1" >/dev/null
  [ "$(cat "$POOL_DIR/ui/lib.txt")" = SMUDGED ] \
    || fail "fixture did not smudge tracked bytes inside the initialized submodule"
  [ -z "$(git -C "$POOL_DIR" status --porcelain --ignore-submodules=none)" ] \
    || fail "fixture did not hide filtered submodule bytes from superproject status"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$expected")
  status=$?
  [ "$status" -ne 0 ] || fail "expected-head spawn launched filtered submodule bytes outside the reviewed blob"
  [ "$(cat "$POOL_DIR/ui/lib.txt")" = SMUDGED ] \
    || fail "expected-head refusal discarded filtered bytes inside the submodule"
  [ ! -e "$HOME_DIR/state/$id.meta" ] \
    || fail "filtered-submodule-refused expected head published task metadata"
  pass "expected-head rejects filtered bytes in reviewed trees and submodules"
}

test_expected_head_retires_endpoint_when_cancel_fails() {
  local rec id out status real_sleep marker pending started retired
  id=pool-expected-cancel-fail-r9
  rec=$(make_case expected-cancel-fail "$id")
  read_case_record "$rec"
  marker="$CASE_DIR/mutated-after-launch-staging"
  pending="$CASE_DIR/pending-launch"
  started="$CASE_DIR/worker-started"
  retired="$CASE_DIR/endpoint-retired"
  real_sleep=$(command -v sleep)
  cat > "$FAKEBIN_DIR/sleep" <<EOF
#!/bin/sh
if [ -e '$pending' ] && [ ! -e '$marker' ]; then
  printf 'late mutation\n' > '$POOL_DIR/late-untracked.txt'
  : > '$marker'
fi
exec '$real_sleep' "\$@"
EOF
  chmod +x "$FAKEBIN_DIR/sleep"

  out=$(FM_FAKE_PENDING_LAUNCH="$pending" FM_FAKE_WORKER_START_LOG="$started" \
    FM_FAKE_CANCEL_KEY_FAIL=1 FM_FAKE_ENDPOINT_RETIRE_LOG="$retired" \
    run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$INITIAL_SHA")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched after cancellation failed"
  [ -e "$marker" ] || fail "fixture did not mutate the worktree after launch text settled"
  assert_grep 'kill-window' "$retired" "failed cancellation did not retire the new endpoint"
  [ ! -e "$pending" ] || fail "retired endpoint retained the staged launch text"
  [ ! -e "$started" ] || fail "failed cancellation submitted the staged launch"
  assert_contains "$out" "dirty candidate" "spawn did not report the final-window dirty tree"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "failed cancellation left published task metadata"
  pass "expected-head refusal retires its endpoint when staged input cannot be cancelled"
}

test_expected_head_preserves_ownership_when_endpoint_survives() {
  local rec id out status real_sleep marker pending started retired
  id=pool-expected-retire-unknown-r10
  rec=$(make_case expected-retire-unknown "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  marker="$CASE_DIR/mutated-after-launch-staging"
  pending="$CASE_DIR/pending-launch"
  started="$CASE_DIR/worker-started"
  retired="$CASE_DIR/endpoint-retire-attempted"
  real_sleep=$(command -v sleep)
  cat > "$FAKEBIN_DIR/sleep" <<EOF
#!/bin/sh
if [ -e '$pending' ] && [ ! -e '$marker' ]; then
  printf 'late mutation\n' > '$POOL_DIR/late-untracked.txt'
  : > '$marker'
fi
exec '$real_sleep' "\$@"
EOF
  chmod +x "$FAKEBIN_DIR/sleep"

  out=$(FM_FAKE_PENDING_LAUNCH="$pending" FM_FAKE_WORKER_START_LOG="$started" \
    FM_FAKE_CANCEL_KEY_FAIL=1 FM_FAKE_ENDPOINT_RETIRE_LOG="$retired" \
    FM_FAKE_ENDPOINT_RETIRE_FAIL=1 FM_FAKE_ENDPOINT_SURVIVES="fm-$id" \
    run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$INITIAL_SHA")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched after cancellation and endpoint retirement failed"
  [ -e "$pending" ] || fail "fixture did not retain the staged launch in the surviving endpoint"
  [ ! -e "$started" ] || fail "failed cancellation submitted the staged launch"
  assert_grep 'kill-window' "$retired" "spawn did not attempt to retire the new endpoint"
  assert_grep "expected_head=$INITIAL_SHA" "$HOME_DIR/state/$id.meta" \
    "spawn removed the durable record naming the surviving endpoint"
  assert_grep "task=$id" "$SLOT_CLAIM" \
    "spawn released the surviving endpoint's Treehouse slot claim"
  assert_contains "$out" "retaining its task record and any Treehouse slot claim for teardown" \
    "spawn did not report the preserved cleanup ownership"
  pass "expected-head refusal preserves ownership when endpoint retirement is unproven"
}

test_expected_head_ignores_cleanliness_hiding_config() {
  local rec id out status exclude
  id=pool-expected-hidden-untracked-r11
  rec=$(make_case expected-hidden-untracked "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" config status.showUntrackedFiles no
  printf 'unreviewed source\n' > "$POOL_DIR/hidden-source.txt"
  [ -z "$(git -C "$POOL_DIR" status --porcelain)" ] \
    || fail "fixture did not hide the untracked source through repository config"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$INITIAL_SHA")
  status=$?
  [ "$status" -ne 0 ] || fail "expected-head spawn ignored hidden untracked source"
  assert_grep 'unreviewed source' "$POOL_DIR/hidden-source.txt" \
    "expected-head refusal discarded hidden untracked source"

  id=pool-expected-hidden-submodule-r11
  rec=$(make_submodule_case expected-hidden-submodule "$id")
  read_submodule_case "$rec"
  git -C "$POOL_DIR" config submodule.ui.ignore all
  printf 'unreviewed submodule source\n' > "$POOL_DIR/ui/hidden-source.txt"
  [ -z "$(git -C "$POOL_DIR" status --porcelain)" ] \
    || fail "fixture did not hide submodule dirt through repository config"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$ADVANCED_SHA")
  status=$?
  [ "$status" -ne 0 ] || fail "expected-head spawn ignored hidden submodule source"
  assert_grep 'unreviewed submodule source' "$POOL_DIR/ui/hidden-source.txt" \
    "expected-head refusal discarded hidden submodule source"

  id=pool-expected-ignored-source-r14
  rec=$(make_case expected-ignored-source "$id")
  read_case_record "$rec"
  exclude=$(git -C "$POOL_DIR" rev-parse --git-path info/exclude)
  printf 'ignored-source.txt\n' >>"$exclude"
  printf 'unreviewed ignored source\n' >"$POOL_DIR/ignored-source.txt"
  [ -z "$(git -C "$POOL_DIR" status --porcelain --untracked-files=all)" ] \
    || fail "fixture did not hide the ignored source from ordinary status"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$INITIAL_SHA")
  status=$?
  [ "$status" -ne 0 ] || fail "expected-head spawn launched with ignored unreviewed source"
  assert_grep 'unreviewed ignored source' "$POOL_DIR/ignored-source.txt" \
    "expected-head refusal discarded ignored unreviewed source"

  id=pool-expected-ignored-submodule-source-r17
  rec=$(make_submodule_case expected-ignored-submodule-source "$id")
  read_submodule_case "$rec"
  exclude=$(git -C "$POOL_DIR/ui" rev-parse --git-path info/exclude)
  printf 'generated-source.txt\n' >>"$exclude"
  printf 'unreviewed ignored submodule source\n' >"$POOL_DIR/ui/generated-source.txt"
  [ -z "$(git -C "$POOL_DIR" status --porcelain --untracked-files=all --ignored=matching --ignore-submodules=none)" ] \
    || fail "fixture did not hide ignored submodule source from superproject status"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$ADVANCED_SHA")
  status=$?
  [ "$status" -ne 0 ] || fail "expected-head spawn launched with ignored source inside a submodule"
  assert_grep 'unreviewed ignored submodule source' "$POOL_DIR/ui/generated-source.txt" \
    "expected-head refusal discarded ignored source inside the submodule"
  pass "expected-head cleanliness overrides untracked and submodule hiding config"
}

test_expected_head_cancels_staged_launch_when_enter_fails() {
  local rec id out status pending started
  id=pool-expected-enter-fail-r15
  rec=$(make_case expected-enter-fail "$id")
  read_case_record "$rec"
  pending="$CASE_DIR/pending-launch"
  started="$CASE_DIR/worker-started"

  out=$(FM_FAKE_PENDING_LAUNCH="$pending" FM_FAKE_WORKER_START_LOG="$started" \
    FM_FAKE_ENTER_KEY_FAIL=1 \
    run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$INITIAL_SHA")
  status=$?
  [ "$status" -ne 0 ] || fail "expected-head spawn reported success after Enter delivery failed"
  [ ! -e "$pending" ] || fail "failed Enter delivery left staged launch input in the endpoint"
  [ ! -e "$started" ] || fail "failed Enter delivery started the worker"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "cancelled Enter failure left published task metadata"
  assert_contains "$out" "could not submit expected-head launch" \
    "spawn did not report failed expected-head Enter delivery"
  pass "expected-head Enter failure cancels staged launch input"
}

make_originless_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project pool fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|main"
}

test_originless_pool_launches_without_a_freshness_fetch() {
  local rec id out status before
  id='pool-originless-r6'
  rec=$(make_originless_case originless "$id")
  read_case_record "$rec"
  ! git -C "$POOL_DIR" remote get-url origin >/dev/null 2>&1 \
    || fail "fixture unexpectedly configured an origin remote"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should launch a local-only pooled worktree with no origin"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success for the origin-less pool"
  assert_not_contains "$out" "could not fetch origin" \
    "spawn attempted a freshness fetch against a nonexistent origin"
  [ ! -e "$POOL_DIR/.git/FETCH_HEAD" ] || fail "spawn fetched against a pooled worktree with no origin"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD on an origin-less pooled worktree that had nothing to refresh against"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed origin-less launch: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an origin-less pooled worktree launches as-is, skipping the freshness gate"
}

test_originless_dirty_pool_refuses_without_discarding_work() {
  local rec id out status before
  id='pool-originless-dirty-r1'
  rec=$(make_originless_case originless-dirty "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a dirty origin-less pooled worktree"
  assert_contains "$out" "is not clean" \
    "spawn did not clearly refuse a dirty origin-less pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a dirty origin-less pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "spawn discarded local work from an origin-less pool"
  pass "a dirty origin-less pooled worktree is refused without discarding its local work"
}

test_origin_config_without_url_refuses_pool() {
  local rec id out status before
  id='pool-origin-without-url-r1'
  rec=$(make_originless_case origin-without-url "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an origin configuration with no URL"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not refuse an origin configuration with no URL as unusable"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after finding an unusable origin configuration"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "an origin configuration without a URL refuses the pooled worktree"
}

test_empty_origin_config_section_refuses_pool() {
  local rec id out status before config
  id='pool-empty-origin-section-r1'
  rec=$(make_originless_case empty-origin-section "$id")
  read_case_record "$rec"
  config=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-path config)
  printf '\n[remote "origin"]\n' >> "$config"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an empty origin configuration section"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not refuse an empty origin configuration section as unusable"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after finding an empty origin configuration section"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "an empty origin configuration section refuses the pooled worktree"
}

test_empty_only_included_origin_config_section_launches_pool() {
  local rec id out status before config included
  id='pool-empty-only-included-origin-section-r1'
  rec=$(make_originless_case empty-only-included-origin-section "$id")
  read_case_record "$rec"
  config=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-path config)
  included=$(dirname "$config")/empty-origin.inc
  printf '[remote "origin"]\n' > "$included"
  git -C "$POOL_DIR" config include.path "$(basename "$included")"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should proceed when an included empty origin section is not enumerable"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success for the undetectable included section"
  assert_not_contains "$out" "could not fetch origin" \
    "spawn treated an undetectable included empty section as a configured origin"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD despite treating the included empty section as origin-less"
  pass "an empty-only included origin section documents the accepted detection boundary"
}

test_inactive_conditional_origin_include_launches_pool() {
  local rec id out status before config included
  id='pool-inactive-origin-include-r1'
  rec=$(make_originless_case inactive-origin-include "$id")
  read_case_record "$rec"
  config=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-path config)
  included=$(dirname "$config")/inactive-origin.inc
  printf '[fm-test]\n\tmarker = true\n[remote "origin"]\n' > "$included"
  git -C "$POOL_DIR" config 'includeIf.gitdir:/never/matches/this/worktree/.path' "$included"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should ignore an inactive conditional origin include"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success with an inactive origin include"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD despite having no effective origin"
  pass "an inactive conditional origin include leaves the pooled worktree origin-less"
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

test_expected_head_converges_initialized_submodules() {
  local rec id out status
  id=pool-expected-submodule-convergence-r20
  rec=$(make_submodule_case expected-submodule-convergence "$id")
  read_submodule_case "$rec"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$SUBPIN1" ] \
    || fail "fixture did not begin with the initialized submodule on the old pin"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --expected-head "$ADVANCED_SHA")
  status=$?
  expect_code 0 "$status" "expected-head spawn should converge initialized submodules"$'\n'"$out"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$ADVANCED_SHA" ] \
    || fail "expected-head spawn did not converge the superproject"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$SUBPIN2" ] \
    || fail "expected-head spawn did not converge the initialized submodule pin"
  assert_grep "expected_head=$ADVANCED_SHA" "$HOME_DIR/state/$id.meta" \
    "submodule-converged spawn did not record the exact candidate"
  pass "expected-head converges initialized submodules to reviewed pins"
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
  git -C "$POOL_DIR" remote remove origin
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
  pass "an origin-less pool with a stale submodule pin refuses while naming both pins and no remedy"
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

# Re-lay a case's pooled worktree as a managed Treehouse slot: <pool>/<slot>/<repo>
# with the pool's state file beside the slot, which is the shape fm-spawn claims
# for its task. Rewrites POOL_DIR to the relocated checkout.
lay_out_as_pool_slot() {
  local slot_root="$CASE_DIR/slots"
  mkdir -p "$slot_root/1"
  git -C "$PROJECT_DIR" worktree move "$POOL_DIR" "$slot_root/1/project"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot_root/1/project" \
    > "$slot_root/treehouse-state.json"
  POOL_DIR="$slot_root/1/project"
  SLOT_CLAIM="$slot_root/1/.fm-slot-owner"
}

# The spawn side of the slot-owner claim that bin/fm-teardown.sh later reads:
# a launched task's claim names it, a slot that cannot be claimed refuses before
# anything is published, and an abort while the allocation lock is still held
# leaves no claim naming a task with no record.
test_pool_slot_claim_follows_the_spawn_outcome() {
  local rec id out status before

  id='pool-slot-claim-r1'
  rec=$(make_case slot-claim "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "spawn from a Treehouse slot should launch"$'\n'"$out"
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" \
    "spawn did not publish the relocated slot as its worktree"
  [ -f "$SLOT_CLAIM" ] || fail "spawn left its Treehouse slot unclaimed: $out"
  grep -Fxq -- "task=$id" "$SLOT_CLAIM" \
    || fail "the slot claim does not name the spawned task: $(cat "$SLOT_CLAIM")"
  grep -Fxq -- "home=$HOME_DIR" "$SLOT_CLAIM" \
    || fail "the slot claim does not name the spawning home: $(cat "$SLOT_CLAIM")"

  id='pool-slot-unclaimable-r1'
  rec=$(make_case slot-unclaimable "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  mkdir -p "$SLOT_CLAIM"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  out=$(run_spawn "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched a worker on a slot it could not claim"
  assert_contains "$out" "could not claim Treehouse pool slot" \
    "spawn did not name the unclaimable slot as the reason"
  [ -d "$SLOT_CLAIM" ] || fail "spawn replaced the directory blocking its slot claim"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "spawn published a record for an unclaimable slot"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved the slot's HEAD after failing to claim it"

  id='pool-slot-claim-aborted-r1'
  rec=$(make_originless_case slot-claim-aborted "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  git -C "$POOL_DIR" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unusable origin on the slot"
  assert_contains "$out" "could not fetch origin" \
    "the aborted spawn did not refuse on its unusable origin"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the aborted spawn published task metadata"
  [ ! -e "$SLOT_CLAIM" ] && [ ! -L "$SLOT_CLAIM" ] \
    || fail "the aborted spawn left a slot claim naming a task with no record: $(cat "$SLOT_CLAIM")"
  pass "a Treehouse slot claim names the launched task, refuses when unclaimable, and is dropped by a locked abort"
}

test_remote_seeded_home_spawns_from_treehouse_pool
test_pool_slot_claim_follows_the_spawn_outcome
test_linked_spawning_home_rejects_primary_before_refresh
test_stale_pool_base_refreshes_before_branching
test_non_main_default_branch_refreshes_before_branching
test_expected_head_launches_exact_origin_commit
test_expected_head_hashes_in_candidate_object_format
test_expected_head_ignores_replacement_objects
test_expected_head_refuses_non_origin_commit_and_invalid_input
test_expected_head_ignores_ambient_git_redirection
test_expected_head_ignores_ambient_git_config_overrides
test_expected_head_refuses_unsupported_lifecycle_shapes
test_expected_head_is_reverified_immediately_before_launch
test_expected_head_rejects_submodule_index_suppression
test_expected_head_rejects_hidden_file_mode_changes
test_expected_head_rejects_filtered_worktree_bytes
test_expected_head_retires_endpoint_when_cancel_fails
test_expected_head_preserves_ownership_when_endpoint_survives
test_expected_head_ignores_cleanliness_hiding_config
test_expected_head_cancels_staged_launch_when_enter_fails
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base
test_originless_pool_launches_without_a_freshness_fetch
test_originless_dirty_pool_refuses_without_discarding_work
test_origin_config_without_url_refuses_pool
test_empty_origin_config_section_refuses_pool
test_empty_only_included_origin_config_section_launches_pool
test_inactive_conditional_origin_include_launches_pool
test_expected_head_converges_initialized_submodules
test_stale_submodule_pin_explains_itself
test_unpushed_submodule_commit_is_still_uncommitted_work
test_work_inside_submodule_is_still_uncommitted_work
test_stale_pin_carrying_real_work_is_not_called_stale
test_stale_pin_beside_other_dirt_reports_one_verdict

echo "# all fm-spawn-pool-base-freshen tests passed"
