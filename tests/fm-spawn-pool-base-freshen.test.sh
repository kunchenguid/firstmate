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

fill_spawn_brief_placeholders() {
  local brief=$1
  perl -i -pe 's/\{TASK\}/Named-base spawn coverage./g; s/\{FIRSTMATE_SPEC\}/Exercise the named base./g' "$brief"
}

add_base_contract_decoy() {
  local brief=$1
  perl -0pi -e 's/\n(# Setup\n)/\nBase branch contract: base_branch=main\n# Definition of done\nCrew branch: branch=wrong\n$1/' "$brief"
}

add_task_contract_marker_decoy() {
  local brief=$1
  perl -0pi -e 's/Named-base spawn coverage\./Named-base spawn coverage.\n<!-- fm-generated-contract -->\nBase branch contract: base_branch=main/' "$brief"
}

scaffold_ship_brief() {
  local id=$1 mode=$2 base_branch=${3:-} branch_name=${4:-}
  local -a args=("$id" test-project --mode "$mode")
  [ -z "$base_branch" ] || args+=(--base-branch "$base_branch")
  [ -z "$branch_name" ] || args+=(--branch-name "$branch_name")
  rm -f "$HOME_DIR/data/$id/brief.md"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "${args[@]}" >/dev/null \
    || fail "fm-brief.sh could not scaffold the $id ship brief"
  fill_spawn_brief_placeholders "$HOME_DIR/data/$id/brief.md"
}

test_custom_crew_branch_never_targets_default() {
  local rec id out status
  id='pool-crew-default-collision-r11'
  rec=$(make_case crew-default-collision "$id")
  read_case_record "$rec"
  scaffold_ship_brief "$id" direct-PR '' "$DEFAULT_BRANCH"

  out=$(run_spawn "$id" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a custom crew branch equal to the project default"
  assert_contains "$out" "which is the project default branch" \
    "default-branch crew collision did not explain the unsafe target"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "default-branch crew collision published task metadata"
  pass "spawn refuses a custom crew branch equal to the project default"
}

test_custom_crew_branch_never_targets_requested_base() {
  local rec id out status
  id='pool-crew-base-collision-r1'
  rec=$(make_case crew-base-collision "$id")
  read_case_record "$rec"
  git -C "$PROJECT_DIR" branch develop "$INITIAL_SHA"
  git -C "$PROJECT_DIR" push --quiet origin refs/heads/develop:refs/heads/develop
  scaffold_ship_brief "$id" direct-PR '' develop

  out=$(run_spawn "$id" --mode direct-PR --yolo off --base-branch develop)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a custom crew branch equal to the requested base"
  assert_contains "$out" "which is the requested base branch" \
    "requested-base crew collision did not explain the unsafe target"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "requested-base crew collision published task metadata"
  pass "spawn refuses a custom crew branch equal to the requested base"
}

test_implicit_crew_branch_never_targets_requested_base() {
  local rec id out status
  id='pool-implicit-crew-base-collision-r2'
  rec=$(make_case implicit-crew-base-collision "$id")
  read_case_record "$rec"
  git -C "$PROJECT_DIR" branch "fm/$id" "$INITIAL_SHA"
  git -C "$PROJECT_DIR" push --quiet origin "refs/heads/fm/$id:refs/heads/fm/$id"

  out=$(run_spawn "$id" --mode direct-PR --yolo off --base-branch "fm/$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted the implicit crew branch equal to the requested base"
  assert_contains "$out" "uses crew branch fm/$id, which is the requested base branch" \
    "implicit crew-base collision did not explain the unsafe target"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "implicit crew-base collision published task metadata"
  pass "spawn refuses the implicit crew branch equal to the requested base"
}

scaffold_scout_brief() {
  local id=$1 base_branch=${2:-}
  local -a args=("$id" test-project --scout)
  [ -z "$base_branch" ] || args+=(--base-branch "$base_branch")
  rm -f "$HOME_DIR/data/$id/brief.md"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "${args[@]}" >/dev/null \
    || fail "fm-brief.sh could not scaffold the scout brief"
  fill_spawn_brief_placeholders "$HOME_DIR/data/$id/brief.md"
}

fail_named_ref_fetch() {
  local fakebin=$1 branch=$2 real_git
  real_git=$(command -v git)
  cat > "$fakebin/git" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" != "+refs/heads/$branch:refs/remotes/origin/$branch" ] || exit 1
done
exec "$real_git" "\$@"
EOF
  chmod +x "$fakebin/git"
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

test_base_branch_resets_to_named_origin_tip() {
  local rec id out status current_main current_develop branch_head
  id='pool-base-branch-origin-r6'
  rec=$(make_case base-branch-origin "$id")
  read_case_record "$rec"
  git -C "$CASE_DIR/publisher" checkout --quiet -b develop
  printf 'only on develop\n' > "$CASE_DIR/publisher/develop-only.txt"
  git -C "$CASE_DIR/publisher" add develop-only.txt
  git -C "$CASE_DIR/publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm develop-tip
  git -C "$CASE_DIR/publisher" push --quiet origin develop
  git -C "$POOL_DIR" tag origin/develop "$INITIAL_SHA"
  scaffold_ship_brief "$id" no-mistakes develop

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --base-branch develop)
  status=$?
  expect_code 0 "$status" "spawn --base-branch should refresh to the named origin tip"
  current_main=$(git -C "$POOL_DIR" rev-parse --verify --quiet refs/remotes/origin/main || true)
  current_develop=$(git -C "$POOL_DIR" rev-parse --verify --quiet refs/remotes/origin/develop)
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ -n "$current_develop" ] || fail "spawn --base-branch develop left origin/develop unresolved"
  [ "$branch_head" = "$current_develop" ] || fail "spawn --base-branch develop did not reset to origin/develop"
  [ "$branch_head" != "$(git -C "$POOL_DIR" rev-parse refs/tags/origin/develop)" ] \
    || fail "spawn --base-branch develop selected a colliding tag"
  [ -z "$current_main" ] || [ "$branch_head" != "$current_main" ] || fail "spawn --base-branch develop reset to origin/main"
  assert_grep 'only on develop' "$POOL_DIR/develop-only.txt" \
    "spawn --base-branch develop omitted the named-branch tip content"
  assert_grep 'base_branch=develop' "$HOME_DIR/state/$id.meta" \
    "spawn --base-branch did not record base_branch= for PR targeting"
  pass "spawn --base-branch resets the pooled worktree to the named origin tip"
}

test_absent_base_branch_leaves_default_freshen_and_meta() {
  local rec id out status current meta
  id='pool-base-branch-absent-r6'
  rec=$(make_case base-branch-absent "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn without --base-branch should keep today's default freshen"
  current=$(git -C "$POOL_DIR" rev-parse origin/main)
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
    || fail "spawn without --base-branch did not reset to origin/main"
  meta=$HOME_DIR/state/$id.meta
  assert_no_grep 'base_branch=' "$meta" \
    "spawn without --base-branch recorded a PR-target base_branch="
  pass "omitting --base-branch keeps default-branch freshen and does not record a PR target"
}

test_local_only_and_scout_base_branch_use_local_when_origin_lacks_it() {
  local rec id out status local_sha
  id='pool-base-branch-local-r7'
  rec=$(make_case base-branch-local "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" checkout --quiet -B local-only
  printf 'only local\n' > "$POOL_DIR/local-only.txt"
  git -C "$POOL_DIR" add local-only.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm local-only
  local_sha=$(git -C "$POOL_DIR" rev-parse HEAD)
  git -C "$POOL_DIR" checkout --quiet --detach "$INITIAL_SHA"
  scaffold_ship_brief "$id" local-only local-only

  out=$(run_spawn "$id" --mode local-only --yolo off --base-branch local-only)
  status=$?
  expect_code 0 "$status" "local-only spawn --base-branch should use a local branch when origin lacks it"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$local_sha" ] \
    || fail "spawn --base-branch local-only did not reset to the local branch tip"
  if git -C "$POOL_DIR" rev-parse --verify --quiet origin/main >/dev/null; then
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" != "$(git -C "$POOL_DIR" rev-parse origin/main)" ] \
      || fail "spawn --base-branch local-only fell back to origin/main"
  fi
  pass "local-only spawn --base-branch uses a local branch when origin lacks it"

  id='pool-base-branch-local-scout-r8'
  rec=$(make_case base-branch-local-scout "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" checkout --quiet -B local-scout
  printf 'only local scout\n' > "$POOL_DIR/local-scout.txt"
  git -C "$POOL_DIR" add local-scout.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm local-scout
  local_sha=$(git -C "$POOL_DIR" rev-parse HEAD)
  git -C "$POOL_DIR" checkout --quiet --detach "$INITIAL_SHA"
  scaffold_scout_brief "$id" local-scout

  out=$(run_spawn "$id" --scout --base-branch local-scout)
  status=$?
  expect_code 0 "$status" "scout --base-branch should use a local branch when origin lacks it"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$local_sha" ] \
    || fail "scout --base-branch did not reset to the local branch tip"
  assert_grep 'base_branch=local-scout' "$HOME_DIR/state/$id.meta" \
    "scout did not record its local named base"
  pass "scout --base-branch uses a local branch when origin lacks it"
}

test_local_only_base_branch_prefers_local_over_origin() {
  local rec id out status local_sha remote_sha
  id='pool-base-branch-local-preferred-r8'
  rec=$(make_case base-branch-local-preferred "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" checkout --quiet -B develop "$INITIAL_SHA"
  printf 'local develop\n' > "$POOL_DIR/local-develop.txt"
  git -C "$POOL_DIR" add local-develop.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm local-develop
  local_sha=$(git -C "$POOL_DIR" rev-parse HEAD)
  git -C "$CASE_DIR/publisher" checkout --quiet -b develop
  printf 'remote develop\n' > "$CASE_DIR/publisher/remote-develop.txt"
  git -C "$CASE_DIR/publisher" add remote-develop.txt
  git -C "$CASE_DIR/publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm remote-develop
  git -C "$CASE_DIR/publisher" push --quiet origin develop
  remote_sha=$(git -C "$CASE_DIR/publisher" rev-parse HEAD)
  git -C "$POOL_DIR" checkout --quiet --detach "$INITIAL_SHA"
  scaffold_ship_brief "$id" local-only develop

  out=$(run_spawn "$id" --mode local-only --yolo off --base-branch develop)
  status=$?
  expect_code 0 "$status" "local-only spawn should use its local named base when origin also has it"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$local_sha" ] \
    || fail "local-only spawn did not reset to the local named base"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" != "$remote_sha" ] \
    || fail "local-only spawn reset to the remote named base"
  assert_grep 'local develop' "$POOL_DIR/local-develop.txt" \
    "local-only spawn omitted content from the local named base"
  pass "local-only spawn prefers the local named base over origin"
}

test_pr_modes_refuse_base_missing_from_origin() {
  local rec id out status before mode slug
  for mode in no-mistakes direct-PR; do
    case "$mode" in
      no-mistakes) slug=no-mistakes ;;
      direct-PR) slug=direct-pr ;;
    esac
    id="pool-base-branch-pr-refuse-${slug}-r7"
    rec=$(make_case "base-branch-pr-refuse-$slug" "$id")
    read_case_record "$rec"
    git -C "$POOL_DIR" checkout --quiet -B local-only
    printf 'only local\n' > "$POOL_DIR/local-only.txt"
    git -C "$POOL_DIR" add local-only.txt
    git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
      commit -qm local-only
    git -C "$POOL_DIR" checkout --quiet --detach "$INITIAL_SHA"
    scaffold_ship_brief "$id" "$mode" local-only
    before=$(git -C "$POOL_DIR" rev-parse HEAD)

    out=$(run_spawn "$id" --mode "$mode" --yolo off --base-branch local-only)
    status=$?
    [ "$status" -ne 0 ] || fail "$mode spawn accepted a --base-branch missing from origin"
    assert_contains "$out" "does not exist on origin" \
      "$mode spawn did not identify the missing remote base"
    assert_contains "$out" "$mode delivery requires a remote base" \
      "$mode spawn did not explain why a local base is insufficient"
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
      || fail "$mode spawn moved HEAD after refusing its missing remote base"
    assert_absent "$HOME_DIR/state/$id.meta" \
      "$mode spawn recorded metadata after refusing its missing remote base"
  done
  pass "PR delivery modes refuse a named base missing from origin"
}

test_base_branch_ref_fetch_failure_refuses_local_fallback() {
  local rec id out status before
  id='pool-base-branch-fetch-failure-r6'
  rec=$(make_case base-branch-fetch-failure "$id")
  read_case_record "$rec"
  git -C "$CASE_DIR/publisher" checkout --quiet -b develop
  printf 'remote develop\n' > "$CASE_DIR/publisher/remote-develop.txt"
  git -C "$CASE_DIR/publisher" add remote-develop.txt
  git -C "$CASE_DIR/publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm remote-develop
  git -C "$CASE_DIR/publisher" push --quiet origin develop
  git -C "$POOL_DIR" checkout --quiet -B develop "$INITIAL_SHA"
  printf 'local develop\n' > "$POOL_DIR/local-develop.txt"
  git -C "$POOL_DIR" add local-develop.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm local-develop
  git -C "$POOL_DIR" checkout --quiet --detach "$INITIAL_SHA"
  scaffold_ship_brief "$id" no-mistakes develop
  fail_named_ref_fetch "$FAKEBIN_DIR" develop
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --base-branch develop)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn fell back to local develop after its remote ref fetch failed"
  assert_contains "$out" "could not fetch 'origin/develop'" \
    "spawn did not clearly refuse an unverifiable remote base"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn changed the pooled worktree after a remote ref fetch failure"
  pass "a failed remote base fetch refuses instead of falling back to local"
}

test_missing_base_branch_refuses_without_default_fallback() {
  local rec id out status before
  id='pool-base-branch-missing-r6'
  rec=$(make_case base-branch-missing "$id")
  read_case_record "$rec"
  scaffold_ship_brief "$id" no-mistakes no-such-branch
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --base-branch no-such-branch)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded with a nonexistent --base-branch"
  assert_contains "$out" "does not exist on origin" \
    "PR delivery spawn did not clearly refuse a missing remote --base-branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after refusing a missing --base-branch"
  pass "a nonexistent --base-branch refuses without falling back to the default"
}

test_originless_base_branch_uses_local_or_refuses() {
  local rec id out status local_sha before
  id='pool-originless-base-local-r1'
  rec=$(make_originless_case originless-base-local "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" checkout --quiet -B develop
  printf 'originless develop\n' > "$POOL_DIR/originless-develop.txt"
  git -C "$POOL_DIR" add originless-develop.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm originless-develop
  local_sha=$(git -C "$POOL_DIR" rev-parse HEAD)
  git -C "$POOL_DIR" checkout --quiet --detach "$INITIAL_SHA"
  scaffold_ship_brief "$id" local-only develop

  out=$(run_spawn "$id" --mode local-only --yolo off --base-branch develop)
  status=$?
  expect_code 0 "$status" "origin-less local-only spawn should use the local named branch"$'\n'"$out"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$local_sha" ] \
    || fail "origin-less --base-branch did not reset to the local named branch"
  assert_grep 'base_branch=develop' "$HOME_DIR/state/$id.meta" \
    "origin-less --base-branch did not record the requested base"

  id='pool-originless-base-missing-r1'
  rec=$(make_originless_case originless-base-missing "$id")
  read_case_record "$rec"
  scaffold_ship_brief "$id" local-only develop
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  out=$(run_spawn "$id" --mode local-only --yolo off --base-branch develop)
  status=$?
  [ "$status" -ne 0 ] || fail "origin-less spawn skipped a missing requested base"
  assert_contains "$out" "does not exist locally" \
    "origin-less --base-branch did not refuse a missing local base"
  assert_contains "$out" "refusing to launch without that requested base" \
    "origin-less --base-branch did not refuse a missing requested base"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "origin-less --base-branch moved HEAD after refusing a missing local base"

  id='pool-originless-base-scout-r2'
  rec=$(make_originless_case originless-base-scout "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" checkout --quiet -B develop
  printf 'originless scout develop\n' > "$POOL_DIR/originless-scout-develop.txt"
  git -C "$POOL_DIR" add originless-scout-develop.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm originless-scout-develop
  local_sha=$(git -C "$POOL_DIR" rev-parse HEAD)
  git -C "$POOL_DIR" checkout --quiet --detach "$INITIAL_SHA"
  scaffold_scout_brief "$id" develop

  out=$(run_spawn "$id" --scout --base-branch develop)
  status=$?
  expect_code 0 "$status" "origin-less scout should use its local named branch"$'\n'"$out"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$local_sha" ] \
    || fail "origin-less scout did not reset to its local named branch"
  assert_grep 'base_branch=develop' "$HOME_DIR/state/$id.meta" \
    "origin-less scout did not record its local named base"
  pass "origin-less --base-branch uses a local branch or refuses, never skips"
}

test_base_branch_refused_on_relaunch_secondmate_and_orca() {
  local rec id out status
  id='pool-base-branch-refuse-r6'
  rec=$(make_case base-branch-refuse "$id")
  read_case_record "$rec"
  scaffold_ship_brief "$id" no-mistakes develop

  out=$(run_spawn "$id" --relaunch --base-branch develop)
  status=$?
  [ "$status" -ne 0 ] || fail "--relaunch accepted --base-branch"
  assert_contains "$out" "--relaunch reuses the task's recorded worktree" \
    "--relaunch did not refuse --base-branch"

  out=$(run_spawn "$id" --secondmate --base-branch develop)
  status=$?
  [ "$status" -ne 0 ] || fail "--secondmate accepted --base-branch"
  assert_contains "$out" "applies only to ship and scout" \
    "--secondmate did not refuse --base-branch"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --backend orca --base-branch develop)
  status=$?
  [ "$status" -ne 0 ] || fail "backend=orca accepted --base-branch"
  assert_contains "$out" "cannot be combined with backend=orca" \
    "backend=orca did not refuse --base-branch"
  pass "--relaunch, --secondmate, and backend=orca refuse --base-branch"
}

test_local_only_origin_only_base_refuses() {
  local rec id out status before
  id='pool-local-only-origin-base-r1'
  rec=$(make_case local-only-origin-base "$id")
  read_case_record "$rec"
  git -C "$CASE_DIR/publisher" checkout --quiet -b develop
  printf 'only on origin develop\n' > "$CASE_DIR/publisher/develop-only.txt"
  git -C "$CASE_DIR/publisher" add develop-only.txt
  git -C "$CASE_DIR/publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm origin-only-develop
  git -C "$CASE_DIR/publisher" push --quiet origin develop
  git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/develop \
    && fail "fixture unexpectedly created a local develop on the landing project"
  scaffold_ship_brief "$id" local-only develop
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  out=$(run_spawn "$id" --mode local-only --yolo off --base-branch develop)
  status=$?
  [ "$status" -ne 0 ] || fail "local-only spawn accepted an origin-only --base-branch"
  assert_contains "$out" "cannot be combined with local-only" \
    "local-only origin-only --base-branch did not name the illegal combination"
  assert_contains "$out" "exists only on origin" \
    "local-only origin-only --base-branch did not say the base is origin-only"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "local-only origin-only refuse still freshened the pooled worktree"
  git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/develop \
    && fail "local-only origin-only refuse created a local develop on the landing project"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "local-only origin-only refuse recorded metadata"
  pass "local-only --base-branch refuses when the base exists only on origin"
}

test_scout_base_branch_contract_agrees_and_records() {
  local rec id out status current_develop current_main
  id='pool-scout-base-branch-agree-r10'
  rec=$(make_case scout-base-branch-agree "$id")
  read_case_record "$rec"
  git -C "$CASE_DIR/publisher" checkout --quiet -b develop
  printf 'only on develop\n' > "$CASE_DIR/publisher/develop-only.txt"
  git -C "$CASE_DIR/publisher" add develop-only.txt
  git -C "$CASE_DIR/publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm develop-tip
  git -C "$CASE_DIR/publisher" push --quiet origin develop
  scaffold_scout_brief "$id" develop
  add_task_contract_marker_decoy "$HOME_DIR/data/$id/brief.md"
  add_base_contract_decoy "$HOME_DIR/data/$id/brief.md"

  out=$(run_spawn "$id" --scout --base-branch develop)
  status=$?
  expect_code 0 "$status" "scout spawn --base-branch should accept a matching generated contract"
  assert_contains "$out" "spawned $id" "scout spawn did not report success with a matching base contract"
  current_develop=$(git -C "$POOL_DIR" rev-parse --verify --quiet origin/develop)
  current_main=$(git -C "$POOL_DIR" rev-parse --verify --quiet origin/main || true)
  [ -n "$current_develop" ] || fail "scout spawn --base-branch develop left origin/develop unresolved"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current_develop" ] \
    || fail "scout spawn --base-branch develop did not refresh to origin/develop"
  [ -z "$current_main" ] || [ "$(git -C "$POOL_DIR" rev-parse HEAD)" != "$current_main" ] \
    || fail "scout spawn --base-branch develop refreshed to origin/main"
  assert_grep 'base_branch=develop' "$HOME_DIR/state/$id.meta" \
    "scout spawn did not record the named analysis base"
  pass "scout spawn honors a matching --base-branch contract from Definition of done"
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
test_custom_crew_branch_never_targets_requested_base
test_implicit_crew_branch_never_targets_requested_base
test_pool_slot_claim_follows_the_spawn_outcome
test_linked_spawning_home_rejects_primary_before_refresh
test_stale_pool_base_refreshes_before_branching
test_non_main_default_branch_refreshes_before_branching
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
test_stale_submodule_pin_explains_itself
test_unpushed_submodule_commit_is_still_uncommitted_work
test_work_inside_submodule_is_still_uncommitted_work
test_stale_pin_carrying_real_work_is_not_called_stale
test_stale_pin_beside_other_dirt_reports_one_verdict
test_base_branch_resets_to_named_origin_tip
test_absent_base_branch_leaves_default_freshen_and_meta
test_local_only_and_scout_base_branch_use_local_when_origin_lacks_it
test_local_only_base_branch_prefers_local_over_origin
test_pr_modes_refuse_base_missing_from_origin
test_base_branch_ref_fetch_failure_refuses_local_fallback
test_missing_base_branch_refuses_without_default_fallback
test_originless_base_branch_uses_local_or_refuses
test_base_branch_refused_on_relaunch_secondmate_and_orca
test_local_only_origin_only_base_refuses
test_scout_base_branch_contract_agrees_and_records
test_custom_crew_branch_never_targets_default

echo "# all fm-spawn-pool-base-freshen tests passed"
