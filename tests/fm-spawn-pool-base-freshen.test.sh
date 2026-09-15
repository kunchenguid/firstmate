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
  pool="$case_dir/slots/1/project"
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

    out=$(FM_FAKE_POOL_STATUS='[]' run_spawn "$id" --scout)
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
      case "$out" in
        *"outside the selected native pool"*) assert_contains "$out" "$POOL_DIR" 'pool refusal did not name the unexpected slot' ;;
        *)
          assert_contains "$out" "isolated worktree" "spawn did not explain its isolation refusal"
          assert_contains "$out" "resolved" "refusal did not name the path the pane reported"
          ;;
      esac
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
  lay_out_as_pool_slot

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
  # A second task needs a second free copy; the first task still owns its lease.
  POOL_DIR="$CASE_DIR/slots/2/project"
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR" "$current"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "repeating the base refresh should be idempotent: $out"
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
  pool="$case_dir/slots/1/project"
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
  pool="$case_dir/slots/1/project"
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
  # The first task now retains its lease. Recreate that proven Git/submodule
  # snapshot in a second free slot to exercise the independent freshness gate.
  POOL_DIR="$CASE_DIR/slots/2/project"
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR" "$ADVANCED_SHA"
  git -C "$POOL_DIR" -c protocol.file.allow=always submodule --quiet update --init
  git -C "$POOL_DIR/ui" checkout --quiet "$SUBPIN1"

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
  if [ "$POOL_DIR" != "$slot_root/1/project" ]; then
    git -C "$PROJECT_DIR" worktree move "$POOL_DIR" "$slot_root/1/project"
  fi
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot_root/1/project" \
    > "$slot_root/treehouse-state.json"
  POOL_DIR="$slot_root/1/project"
  SLOT_CLAIM="$slot_root/1/.fm-slot-owner"
}

# The spawn side of the slot-owner claim that bin/fm-teardown.sh later reads:
# a launched task's claim names it, a slot that cannot be claimed refuses before
# anything is published, and an abort while the allocation lock is still held
# preserves the exact claim even when no task record was published.
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
  assert_contains "$out" "retained owner claim" \
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
  [ -f "$SLOT_CLAIM" ] || fail "aborted spawn lost its exact reservation claim"
  before=$(cat "$SLOT_CLAIM")
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a retry reused an interrupted acquisition"
  assert_contains "$out" "retained Treehouse acquisition" "retry did not identify the prior reservation"
  [ "$(cat "$SLOT_CLAIM")" = "$before" ] || fail "retry replaced the earlier claim"
  pass "a Treehouse slot claim names the launched task, refuses when unclaimable, and survives abort plus retry"
}

# The acquisition receipt is written in the selected state directory, so its
# completion must look there too; otherwise an overridden state directory keeps
# a spent receipt that refuses every later acquisition for that task id.
test_acquisition_receipt_follows_state_override() {
  local rec id='pool-state-override-r1' state out status
  rec=$(make_case state-override "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  state="$CASE_DIR/override-state"
  mkdir -p "$state" "$HOME_DIR/user-home"
  touch "$state/.last-watcher-beat"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$POOL_DIR" TMUX="${TMUX:-fake,1,0}" \
    PATH="$FAKEBIN_DIR:$PATH" "$ROOT/bin/fm-spawn.sh" "$id" "$PROJECT_DIR" --scout 2>&1); status=$?
  expect_code 0 "$status" "spawn with an overridden state directory should launch"$'\n'"$out"
  assert_grep "worktree=$POOL_DIR" "$state/$id.meta" \
    "spawn did not publish its record in the overridden state directory"
  [ ! -e "$state/$id.treehouse-acquisition" ] \
    || fail "published spawn retained its acquisition receipt in the overridden state directory"
  [ ! -e "$HOME_DIR/state/$id.treehouse-acquisition" ] \
    || fail "spawn wrote an acquisition receipt outside its selected state directory"
  pass "a published acquisition clears its receipt from the overridden state directory"
}

# A retained record whose managed copy vanished cannot prove its pool, so
# allocation still refuses; the refusal must name the record, the recorded
# copy, the resolver's reason and the guarded route rather than only the error.
# The subshell body keeps this test's exported pool and home environment isolated.
# shellcheck disable=SC2030,SC2031
test_unprovable_retained_record_names_its_record_and_route() (
  set -u
  local rec id='pool-unprovable-r1' fakebin root pool slot out status before
  rec=$(make_case unprovable "$id")
  read_case_record "$rec"
  fakebin=$(fm_fakebin "$CASE_DIR/native")
  fm_test_fake_treehouse "$fakebin"
  root="$CASE_DIR/root"
  export TREEHOUSE_ROOT="$root"
  pool=$(python3 "$ROOT/bin/fm-treehouse-identity.py" "$PROJECT_DIR" | jq -er '.pool') \
    || fail "the real resolver could not name the fixture pool"
  mkdir -p "$pool/1"
  slot="$pool/1/project"
  git -C "$PROJECT_DIR" worktree move "$POOL_DIR" "$slot"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot" > "$pool/treehouse-state.json"
  fm_write_meta "$HOME_DIR/state/vanished.meta" \
    "window=isolated:fm-vanished" "endpoint_task_id=vanished" "harness=codex" \
    "kind=ship" "project=$PROJECT_DIR" "worktree=$pool/2/project"
  before=$(cat "$pool/treehouse-state.json")
  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_FAKE_PANE_PATH="$slot" \
    PATH="$fakebin:$PATH" bash -c '
      . "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-backend.sh"; . "$1/bin/fm-wake-lib.sh"
      fm_treehouse_acquire_preflight "$2" "$3"' _ "$ROOT" "$PROJECT_DIR" "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "preflight offered the pool while a retained record could not be proven"
  assert_contains "$out" "$HOME_DIR/state/vanished.meta" "refusal did not name the unprovable record"
  assert_contains "$out" "$pool/2/project" "refusal did not name the recorded copy"
  assert_contains "$out" "recorded native copy is unavailable" "refusal did not carry the resolver reason"
  assert_contains "$out" "restore that copy and project at their recorded paths" "refusal did not name the working remedy"
  assert_contains "$out" "$HOME_DIR/state" "refusal did not name the owning home's record location"
  case "$out" in *fm-teardown.sh*) fail "refusal presented teardown as a route for a missing copy" ;; esac
  assert_contains "$out" "do not delete ownership records" "refusal did not warn against deleting the record"
  [ "$(cat "$pool/treehouse-state.json")" = "$before" ] || fail "refusal changed native pool state"
  pass "an unprovable retained record refuses allocation and names its record, copy, reason and route"
)

# reserve is an operator repair verb; records it cannot adopt must say why.
test_reserve_explains_remote_and_orca_records() {
  local rec id='pool-reserve-unsupported-r1' out status
  rec=$(make_case reserve-unsupported "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" "harness=codex" "kind=ship" \
    "worktree=$POOL_DIR" "project=$PROJECT_DIR" "remote_host=other-host"
  out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_PANE_PATH="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" "$ROOT/bin/fm-control.sh" "$id" reserve 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "reserve adopted a copy recorded on another host"
  assert_contains "$out" "remote host other-host" "reserve did not explain the remote-record refusal"
  [ ! -e "$SLOT_CLAIM" ] || fail "remote-record refusal published a claim"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "harness=codex" "kind=ship" \
    "backend=orca" "terminal=orca-terminal" "orca_worktree_id=orca-worktree" \
    "worktree=$POOL_DIR" "project=$PROJECT_DIR"
  out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_PANE_PATH="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" "$ROOT/bin/fm-control.sh" "$id" reserve 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "reserve adopted an Orca-provided worktree"
  assert_contains "$out" "orca backend" "reserve did not explain the Orca refusal"
  [ ! -e "$SLOT_CLAIM" ] || fail "Orca refusal published a claim"
  pass "reserve names the remote-host and Orca conditions it refuses"
}

# Wait for the external child to start before asking it to exit. An immediate
# TERM can hit Bash before exec and run the parent's inherited EXIT cleanup.
# The FIFO protocol proves the child occupied the copy and exited normally.
fixture_process_exits_from_copy() { # <copy> <fixture-directory>
  local copy=$1 fixture=$2 worker ready_pid
  mkfifo "$fixture/process-ready" "$fixture/process-stop"
  exec 8<>"$fixture/process-stop" 9<>"$fixture/process-ready"
  bash -c 'cd "$1" || exit; printf "%s\n" "$$" >&9; read -r -t 5 stop <&8; [ "$stop" = stop ]' _ "$copy" & worker=$!
  read -r -t 5 ready_pid <&9 || fail "fixture child did not become ready"
  [ "$ready_pid" = "$worker" ] || fail "fixture readiness named a different process"
  printf 'stop\n' >&8
  wait "$worker" || fail "fixture child did not acknowledge its normal exit"
  exec 8>&- 9>&-
}

# The reported boundary: a stopped record still owns its clean slot. The
# native lease, task claim and metadata each have an interruption window.
test_retained_records_and_interrupted_acquisitions() {
  local rec id=reserve-legacy new_id=reserve-new out status before old_slot lease foreign
  rec=$(make_case reserve-legacy "$new_id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  old_slot=$POOL_DIR
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" "harness=codex" \
    "kind=ship" "worktree=$POOL_DIR" "project=$PROJECT_DIR"
  before=$(cat "$CASE_DIR/slots/treehouse-state.json")
  out=$(run_spawn "$new_id" --scout); status=$?
  [ "$status" -ne 0 ] || fail "spawn reused a retained unleased task copy"
  assert_contains "$out" "without a durable lease" "legacy refusal did not identify the missing reservation"
  [ "$(cat "$CASE_DIR/slots/treehouse-state.json")" = "$before" ] || fail "legacy preflight changed native allocation state"

  out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_PANE_PATH="$POOL_DIR" \
    FM_FAKE_POOL_STATUS='[]' PATH="$FAKEBIN_DIR:$PATH" "$ROOT/bin/fm-control.sh" "$id" reserve 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "reserve accepted a copy outside the configured native pool"
  assert_contains "$out" "configured native pool" "reserve did not identify the pool mismatch"
  [ "$(cat "$CASE_DIR/slots/treehouse-state.json")" = "$before" ] || fail "pool mismatch changed native state"

  # Metadata-only secondmate homes participate before registry publication.
  foreign="$CASE_DIR/foreign-home"
  mkdir -p "$foreign/state"
  fm_write_meta "$HOME_DIR/state/other-home.meta" "kind=secondmate" "home=$foreign"
  fm_write_meta "$foreign/state/$id.meta" "kind=ship" "worktree=$POOL_DIR"
  out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_PANE_PATH="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" "$ROOT/bin/fm-control.sh" "$id" reserve 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "reserve adopted a copy also recorded in another home"
  assert_contains "$out" "also records" "reserve did not identify the conflicting home record"
  [ "$(cat "$CASE_DIR/slots/treehouse-state.json")" = "$before" ] || fail "duplicate-record refusal changed the native pool"
  rm "$foreign/state/$id.meta" "$HOME_DIR/state/other-home.meta"
  printf 'task=%s\nhome=%s\n' "$id" "$foreign" > "$SLOT_CLAIM"
  out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_PANE_PATH="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" "$ROOT/bin/fm-control.sh" "$id" reserve 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "same task id in a foreign home stole the claim"
  assert_contains "$out" "foreign or ambiguous claim" "reserve did not refuse the foreign home"
  [ "$(cat "$CASE_DIR/slots/treehouse-state.json")" = "$before" ] || fail "foreign-claim refusal changed the native pool"
  rm "$SLOT_CLAIM"

  # Losing the in-place lease reply leaves native exclusion in force.
  out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_PANE_PATH="$POOL_DIR" \
    FM_FAKE_LEASE_RESPONSE_FAIL=1 PATH="$FAKEBIN_DIR:$PATH" \
    "$ROOT/bin/fm-control.sh" "$id" reserve 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "lost lease response unexpectedly published a claim"
  [ ! -f "$SLOT_CLAIM" ] || fail "lost response published an unverified claim"
  before=$(cat "$CASE_DIR/slots/treehouse-state.json")
  jq '.worktrees[0].lease_holder = "another-owner"' "$CASE_DIR/slots/treehouse-state.json" > "$CASE_DIR/slots/foreign.json"
  mv "$CASE_DIR/slots/foreign.json" "$CASE_DIR/slots/treehouse-state.json"
  out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_PANE_PATH="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" "$ROOT/bin/fm-control.sh" "$id" reserve 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "reserve stole a foreign native lease"
  assert_contains "$out" "another native lease holder" "reserve did not refuse the foreign native lease"
  [ "$(jq -r '.worktrees[0].lease_holder' "$CASE_DIR/slots/treehouse-state.json")" = another-owner ] || fail "reserve replaced another native holder"
  printf '%s\n' "$before" > "$CASE_DIR/slots/treehouse-state.json"
  out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_PANE_PATH="$POOL_DIR" PATH="$FAKEBIN_DIR:$PATH" \
    "$ROOT/bin/fm-control.sh" "$id" reserve 2>&1); status=$?
  expect_code 0 "$status" "reserve must adopt the exact retained copy in place: $out"
  [ "$(cat "$CASE_DIR/slots/treehouse-state.json")" = "$before" ] || fail "reserve retry changed the interrupted native reservation"
  assert_contains "$out" "reserved $id" "reserve did not report its verified binding"
  lease=$(sed -n 's/^lease_id=//p' "$SLOT_CLAIM")
  [ -n "$lease" ] || fail "reserve did not bind the lease identity"
  before=$(cat "$CASE_DIR/slots/treehouse-state.json")
  out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_PANE_PATH="$POOL_DIR" PATH="$FAKEBIN_DIR:$PATH" \
    "$ROOT/bin/fm-control.sh" "$id" reserve 2>&1); status=$?
  expect_code 0 "$status" "repeating reserve should retain the same lease: $out"
  [ "$(cat "$CASE_DIR/slots/treehouse-state.json")" = "$before" ] || fail "repeated reserve changed native ownership"

  # A normal fixture subprocess is deliberately independent of the lease.
  fixture_process_exits_from_copy "$POOL_DIR" "$CASE_DIR"
  mkdir -p "$CASE_DIR/slots/2"
  POOL_DIR="$CASE_DIR/slots/2/project"
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR" HEAD
  out=$(run_spawn "$new_id" --scout); status=$?
  expect_code 0 "$status" "a genuinely free new copy should remain assignable: $out"
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$new_id.meta" "new task did not get the free copy"
  [ "$(sed -n 's/^lease_id=//p' "$CASE_DIR/slots/1/.fm-slot-owner")" = "$lease" ] || fail "process exit/new spawn changed the old reservation"
  [ "$(git -C "$old_slot" rev-parse HEAD)" = "$INITIAL_SHA" ] || fail "adoption or new spawn refreshed retained work"

  id=reserve-interrupted
  rec=$(make_case reserve-interrupted "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  out=$(FM_FAKE_LEASE_RESPONSE_FAIL=1 run_spawn "$id" --scout); status=$?
  [ "$status" -ne 0 ] || fail "interrupted lease response should refuse launch"
  [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "interrupted acquisition published a worker record"
  before=$(cat "$CASE_DIR/slots/treehouse-state.json")
  out=$(run_spawn "$id" --scout); status=$?
  [ "$status" -ne 0 ] || fail "retry allocated over its older interrupted acquisition"
  assert_contains "$out" "retained Treehouse acquisition" "retry did not surface the older lease"
  [ "$(cat "$CASE_DIR/slots/treehouse-state.json")" = "$before" ] || fail "retry released or replaced a prior acquisition"
  pass "retained legacy copies refuse get, reserve converges, process exit preserves ownership, and interrupted acquisition cannot be stolen by retry"
}

# Real Treehouse, ordinary subprocesses only. No backend, agent or Herdr call.
# This counterfactual remains useful on newer Treehouse versions that protect
# unlanded commits: a clean/landed task copy is still reserved by its metadata.
# The subshell body keeps this test's exported pool and home environment isolated.
# shellcheck disable=SC2030,SC2031
test_native_process_exit_vs_durable_reservation() (
  local native lab project ready get_pid='' shell_pid='' slot native_slot other_slot json n out status before
  native=${FM_TREEHOUSE_TEST_BIN:-}
  if [ -z "$native" ] || ! "$native" get --help 2>&1 | grep -q -- '--json'; then
    printf 'skip - native Treehouse lease JSON unavailable; portable reservation fixtures still run\n'
    return
  fi
  lab="$TMP_ROOT/native-reservations"
  project="$lab/project"
  ready="$lab/ready"
  mkdir -p "$lab/home/state" "$lab/home/data" "$lab/home/config"
  fm_git_init_commit "$project"
  export TREEHOUSE_ROOT="$lab/pool" FM_HOME="$lab/home"
  export FM_RESERVATION_READY="$ready"
  cat > "$lab/hold-shell" <<'HOLD'
#!/usr/bin/env bash
printf '%s\n%s\n' "$PWD" "$$" > "$FM_RESERVATION_READY"
exec sleep 120
HOLD
  chmod +x "$lab/hold-shell"
  trap '[ -z "$get_pid" ] || kill -KILL "$get_pid" 2>/dev/null || true; [ -z "$shell_pid" ] || kill -KILL "$shell_pid" 2>/dev/null || true' EXIT
  (cd "$project" && SHELL="$lab/hold-shell" exec "$native" get --no-fetch) > "$lab/plain.log" 2>&1 &
  get_pid=$!
  for n in $(seq 1 200); do [ ! -s "$ready" ] || break; sleep 0.1; done
  [ -s "$ready" ] || fail "native interactive get did not enter the fixture slot: $(cat "$lab/plain.log")"
  slot=$(sed -n '1p' "$ready")
  shell_pid=$(sed -n '2p' "$ready")
  fm_write_meta "$FM_HOME/state/retained.meta" "worktree=$slot" "project=$project" "kind=ship" \
    "window=isolated:fm-retained" "endpoint_task_id=retained" "harness=codex"
  kill -KILL "$get_pid" "$shell_pid"
  wait "$get_pid" 2>/dev/null || true
  get_pid='' shell_pid=''
  if ! "$native" lease --help 2>&1 | grep -q 'lease <name>'; then
    before=$(cat "$(dirname "$(dirname "$slot")")/treehouse-state.json")
    out=$(FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-control.sh" retained reserve 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "old Treehouse was silently used to migrate retained work"
    assert_contains "$out" "lacks in-place" "missing native adoption capability was not diagnosed"
    [ "$(cat "$(dirname "$(dirname "$slot")")/treehouse-state.json")" = "$before" ] || fail "capability refusal changed the real pool"
  fi
  json=$(cd "$project" && "$native" get --lease --no-fetch --json --lease-holder native-first) || fail "native leased get failed"
  native_slot=$(printf '%s\n' "$json" | jq -r '.path')
  [ "$native_slot" = "$slot" ] || fail "native counterfactual did not reproduce process-only reissue"
  fixture_process_exits_from_copy "$slot" "$lab"
  json=$(cd "$project" && "$native" get --lease --no-fetch --json --lease-holder native-second) || fail "native second lease failed"
  other_slot=$(printf '%s\n' "$json" | jq -r '.path')
  [ "$other_slot" != "$slot" ] || fail "native lease was reissued after subprocess exit"
  json=$(cd "$project" && "$native" status --json) || fail "native status failed"
  printf '%s\n' "$json" | jq -e --arg p "$slot" \
    'any(.[]; .path == $p and .status == "leased" and .lease_holder == "native-first" and (.processes | length == 0))' >/dev/null \
    || fail "process-free native reservation no longer names its original owner"
  out=$(cd "$project" && "$native" return "$slot" --if-lease-id wrong-lease-id 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "native conditional return accepted a different lease id"
  json=$(cd "$project" && "$native" status --json) || fail "native status failed after wrong-id return"
  printf '%s\n' "$json" | jq -e --arg p "$slot" \
    'any(.[]; .path == $p and .status == "leased" and .lease_holder == "native-first")' >/dev/null \
    || fail "wrong-id return altered native ownership"
  pass "real Treehouse: stopped process-only copy is reissued; durable reservation remains owned with zero processes while a free copy is assigned"
)


# The subshell body keeps this test's exported pool and home environment isolated.
# shellcheck disable=SC2030,SC2031
test_pinned_pool_identity_and_recovery() (
  set -eu
  local native=${FM_TREEHOUSE_TEST_BIN:-} lab="$TMP_ROOT/pinned-review" project a b c pool_a slot_a state_a before head_a meta_a json out id expected root pool slot marker state returned
  local staged_a unstaged_a status_a dirty_slot damaged_slot other_slot other_lease state_identity gitdir
  [ -n "$native" ] && [ -x "$native" ] || fail 'FM_TREEHOUSE_TEST_BIN must name the isolated pinned build'
  mkdir -p "$lab/user" "$lab/home/state" "$lab/home/config" "$lab/home/data" "$lab/fakebin"
  export HOME="$lab/user" FM_HOME="$lab/home" FM_STATE_OVERRIDE="$lab/home/state" TREEHOUSE_NO_UPDATE_CHECK=1
  export FM_ROOT_OVERRIDE="$ROOT" PATH="$lab/fakebin:$PATH" TMUX=fake,1,0 FM_SPAWN_NO_GUARD=1
  export FM_CONFIG_OVERRIDE="$FM_HOME/config" FM_DATA_OVERRIDE="$FM_HOME/data" FM_PROJECTS_OVERRIDE="$FM_HOME/projects"
  unset TREEHOUSE_VCS TREEHOUSE_ROOT
  project="$lab/project"; a="$lab/A"; b="$lab/B"; c="$lab/C"
  fm_git_init_commit "$project"
  mkdir -p "$project/bin"
  printf '# Firstmate fixture\n' > "$project/AGENTS.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$project/bin/fm-guard.sh"
  printf '/data/\n/state/\n/config/\n/projects/\n.fm-secondmate-*\n' > "$project/.gitignore"
  git -C "$project" add AGENTS.md bin .gitignore
  git -C "$project" -c user.name=test -c user.email=test@example.invalid commit -qm template
  fm_test_fake_tmux_spawn "$lab/fakebin"
  mv "$lab/fakebin/tmux" "$lab/fakebin/terminal"
  cat > "$lab/fakebin/tmux" <<'TERMINAL'
#!/usr/bin/env bash
export TREEHOUSE_ROOT="$FM_BACKEND_CONFLICT_ROOT"
printf '%s\n' "$TREEHOUSE_ROOT" >> "$FM_BACKEND_ROOT_LOG"
exec "$(dirname "$0")/terminal" "$@"
TERMINAL
  chmod +x "$lab/fakebin/tmux"
  export FM_BACKEND_CONFLICT_ROOT="$a" FM_BACKEND_ROOT_LOG="$lab/backend-roots.log"

  fm_fake_exit0 "$lab/fakebin" codex gh gh-axi no-mistakes
  cp "$native" "$lab/fakebin/treehouse"
  . "$ROOT/bin/fm-pr-lib.sh"
  . "$ROOT/bin/fm-backend.sh"
  . "$ROOT/bin/fm-wake-lib.sh"
  json=$(cd "$project" && treehouse --root "$a" get --lease --json --lease-holder setup)
  slot_a=$(printf '%s\n' "$json" | jq -r .path)
  treehouse return --force --if-lease-id "$(printf '%s\n' "$json" | jq -r .lease_id)" "$slot_a"
  git -C "$slot_a" checkout -qb retained-work
  printf 'preserved result\n' > "$slot_a/result.txt"
  git -C "$slot_a" add result.txt
  git -C "$slot_a" -c user.name=test -c user.email=test@example.invalid commit -qm preserved
  head_a=$(git -C "$slot_a" rev-parse HEAD)
  printf 'staged result\n' >> "$slot_a/result.txt"
  git -C "$slot_a" add result.txt
  printf 'unstaged result\n' >> "$slot_a/result.txt"
  printf 'untracked notes\n' > "$slot_a/notes.txt"
  staged_a=$(git -C "$slot_a" diff --cached --binary)
  unstaged_a=$(git -C "$slot_a" diff --binary)
  status_a=$(git -C "$slot_a" status --porcelain)
  [ -n "$staged_a" ] && [ -n "$unstaged_a" ] || fail 'dirty preservation fixture lacks staged or unstaged work'
  json=$(cd "$project" && treehouse --root "$a" status --json)
  printf '%s\n' "$json" | jq -e --arg p "$slot_a" 'any(.[]; .path == $p and .status == "dirty")' >/dev/null \
    || fail 'native status did not expose dirty retained work'
  pool_a=$(dirname "$(dirname "$slot_a")"); state_a="$pool_a/treehouse-state.json"
  fm_write_meta "$FM_HOME/state/preserved.meta" "window=isolated:fm-preserved" "endpoint_task_id=preserved" \
    "kind=ship" "harness=codex" "project=$project" "worktree=$slot_a"
  before=$(cat "$state_a"); meta_a=$(cat "$FM_HOME/state/preserved.meta")
  export TREEHOUSE_ROOT="$b"
  mv "$state_a" "$state_a.saved"
  if fm_treehouse_acquire_preflight "$project" missing-state > "$lab/missing-state.out" 2>&1; then fail 'unknown retained pool state was excluded'; fi
  assert_contains "$(cat "$lab/missing-state.out")" "$state_a" 'unknown-state refusal did not name the preserved pool'
  mv "$state_a.saved" "$state_a"
  [ "$(cat "$state_a")" = "$before" ] || fail 'missing-state refusal altered preserved state'

  export TREEHOUSE_ROOT="$a"
  if fm_treehouse_acquire_preflight "$project" blocked > "$lab/same.out" 2>&1; then fail 'same-pool retained copy was offered'; fi
  assert_contains "$(cat "$lab/same.out")" 'without a durable lease' 'same-pool refusal reason'
  ln -s "$a" "$lab/alias"
  export TREEHOUSE_ROOT="$lab/alias"
  if fm_treehouse_acquire_preflight "$project" alias > "$lab/alias.out" 2>&1; then fail 'root alias was accepted'; fi
  for root in "$b" "$c"; do
    id="review-$(basename "$root")"
    export TREEHOUSE_ROOT="$root"
    expected=$(python3 "$ROOT/bin/fm-treehouse-identity.py" "$project" | jq -r '.pool + "/1/project"')
    fm_test_spawn_brief "$FM_HOME" "$id"
    export FM_FAKE_PANE_PATH="$expected" FM_FAKE_LAUNCH_LOG="$lab/launch.log"
    out=$("$ROOT/bin/fm-spawn.sh" "$id" "$project" --scout --harness codex 2>&1) || fail "separate-root spawn failed: $out"
    assert_grep "worktree=$expected" "$FM_HOME/state/$id.meta" 'spawn published wrong root'
    [ ! -e "$FM_HOME/state/$id.treehouse-acquisition" ] || fail 'published spawn retained its pending acquisition receipt'
    assert_grep "$a" "$FM_BACKEND_ROOT_LOG" 'backend root conflict was not exercised'
    [ "$(cat "$state_a")" = "$before" ] && [ "$(cat "$FM_HOME/state/preserved.meta")" = "$meta_a" ] || fail 'separate-root spawn changed preserved state'
    [ "$(git -C "$slot_a" rev-parse HEAD)" = "$head_a" ] &&
      [ "$(git -C "$slot_a" diff --cached --binary)" = "$staged_a" ] &&
      [ "$(git -C "$slot_a" diff --binary)" = "$unstaged_a" ] &&
      [ "$(git -C "$slot_a" status --porcelain)" = "$status_a" ] &&
      [ "$(cat "$slot_a/notes.txt")" = 'untracked notes' ] || fail 'separate-root spawn reset retained work'
  done
  export TREEHOUSE_ROOT="$c"
  out=$("$ROOT/bin/fm-control.sh" preserved reserve 2>&1) || fail "exact-copy adoption followed ambient root: $out"
  [ "$(git -C "$slot_a" rev-parse HEAD)" = "$head_a" ] &&
    [ "$(git -C "$slot_a" diff --cached --binary)" = "$staged_a" ] &&
    [ "$(git -C "$slot_a" diff --binary)" = "$unstaged_a" ] &&
    [ "$(git -C "$slot_a" status --porcelain)" = "$status_a" ] &&
    [ "$(cat "$slot_a/notes.txt")" = 'untracked notes' ] || fail 'native in-place adoption reset the copy'
  jq -e --arg p "$slot_a" --arg h "$(fm_treehouse_lease_holder preserved "$FM_HOME")" \
    'any(.worktrees[]; .path == $p and .leased and .lease_holder == $h)' "$state_a" >/dev/null \
    || fail 'dirty adoption did not durably reserve the exact copy'
  before=$(cat "$state_a")
  "$ROOT/bin/fm-control.sh" preserved reserve >/dev/null || fail 'adoption retry failed'
  [ "$(cat "$state_a")" = "$before" ] || fail 'adoption retry replaced lease'
  pass 'pinned native dirty adoption preserves staged, unstaged and untracked work; B/C spawns preserve pool A'

  export TREEHOUSE_ROOT="$a"
  for id in dirty damaged; do
    json=$(cd "$project" && treehouse --root "$a" get --lease --json --lease-holder setup)
    slot=$(printf '%s\n' "$json" | jq -r .path)
    treehouse return --force --if-lease-id "$(printf '%s\n' "$json" | jq -r .lease_id)" "$slot"
    if [ "$id" = dirty ]; then
      dirty_slot=$slot
      printf 'keep dirty spare\n' >> "$slot/README.md"
    else
      damaged_slot=$slot
      mv "$slot/.git" "$lab/damaged.git"
    fi
  done
  json=$(cd "$project" && treehouse --root "$a" status --json)
  printf '%s\n' "$json" | jq -e --arg d "$dirty_slot" --arg broken "$damaged_slot" \
    'any(.[]; .path == $d and .status == "dirty") and any(.[]; .path == $broken and .status == "damaged")' >/dev/null \
    || fail 'native pool did not report dirty and damaged spares'
  before=$(cat "$state_a")
  "$ROOT/bin/fm-control.sh" preserved reserve >/dev/null || fail 'unrelated dirty or damaged slot prevented reserve'
  [ "$(cat "$state_a")" = "$before" ] || fail 'reserve with unavailable spares changed native ownership'
  fm_treehouse_select_pool "$project"
  (cd "$dirty_slot" && fm_treehouse_pool_status "$dirty_slot" &&
    printf '%s\n' "$FM_TREEHOUSE_POOL" | jq -e --arg p "$dirty_slot" \
      'any(.[]; .path == $p and .status == "you\u0027re here" and .leased == false)' >/dev/null) \
    || fail 'native current-directory status was not accepted as unleased'
  fm_test_spawn_brief "$FM_HOME" status-spares
  expected="$pool_a/4/project"
  export FM_FAKE_PANE_PATH="$expected"
  out=$("$ROOT/bin/fm-spawn.sh" status-spares "$project" --scout --harness codex 2>&1) || fail "spares prevented safe allocation: $out"
  assert_grep "worktree=$expected" "$FM_HOME/state/status-spares.meta" 'dirty or damaged spare was reused'
  assert_grep 'keep dirty spare' "$dirty_slot/README.md" 'dirty spare content was reset'
  [ ! -e "$damaged_slot/.git" ] || fail 'damaged spare was repaired or reset'
  for slot in "$dirty_slot" "$damaged_slot"; do
    fm_write_meta "$FM_HOME/state/retained-spare.meta" 'kind=ship' "project=$project" "worktree=$slot"
    before=$(cat "$state_a")
    if fm_treehouse_acquire_preflight "$project" retained-spare-next > "$lab/spare.out" 2>&1; then fail 'retained unleased spare allowed acquisition'; fi
    assert_contains "$(cat "$lab/spare.out")" 'without a durable lease' 'spare retention refusal was bypassed'
    [ "$(cat "$state_a")" = "$before" ] || fail 'retained spare refusal changed native state'
    rm "$FM_HOME/state/retained-spare.meta"
  done
  pass 'native status accepts current-directory, dirty and damaged slots while allocation preserves unavailable and retained copies'

  unset TREEHOUSE_ROOT
  fm_treehouse_acquire_preflight "$project" default
  [ "$FM_TREEHOUSE_ROOT" = "$HOME" ] || fail 'default root was not captured'
  json=$(cd "$project" && treehouse --root "$FM_TREEHOUSE_ROOT" get --lease --json --lease-holder default)
  fm_treehouse_selected_slot "$(printf '%s\n' "$json" | jq -r .path)" || fail 'default native pool mismatched resolver'
  mkdir -p "$HOME/.config/treehouse"
  printf 'root = "%s"\n' "$lab/config-root" > "$HOME/.config/treehouse/config.toml"
  fm_treehouse_select_pool "$project"
  [ "$FM_TREEHOUSE_ROOT" = "$lab/config-root" ] || fail 'user root config was ignored'
  printf 'root = "%s"\n' "$lab/repo-root" > "$project/treehouse.toml"
  fm_treehouse_select_pool "$project"
  [ "$FM_TREEHOUSE_ROOT" = "$lab/repo-root" ] || fail 'project root config precedence failed'
  rm "$project/treehouse.toml"
  export TREEHOUSE_ROOT="$lab/interrupted"
  fm_treehouse_acquire_preflight "$project" interrupted
  fm_treehouse_acquisition_begin interrupted
  json=$(cd "$project" && treehouse --root "$FM_TREEHOUSE_ROOT" get --lease --json --lease-holder "$(fm_treehouse_lease_holder interrupted "$FM_HOME")")
  slot=$(printf '%s\n' "$json" | jq -r .path)
  state="$(dirname "$(dirname "$slot")")/treehouse-state.json"
  before=$(cat "$state")
  for root in "$lab/interrupted" "$lab/changed-retry"; do
    export TREEHOUSE_ROOT="$root"
    if fm_treehouse_acquire_preflight "$project" interrupted > "$lab/retry.out" 2>&1; then fail 'interrupted acquisition was hidden by root change'; fi
    assert_contains "$(cat "$lab/retry.out")" 'retained Treehouse acquisition' 'retry lost prior operation'
    [ "$(cat "$state")" = "$before" ] || fail 'retry changed interrupted lease'
  done
  fm_treehouse_slot_owner_claim "$slot" interrupted "$FM_HOME"
  if fm_treehouse_acquire_preflight "$project" interrupted >/dev/null 2>&1; then fail 'claim publication hid interrupted operation'; fi
  fm_write_meta "$FM_HOME/state/missing.meta" "kind=secondmate" "home=$lab/missing-home"
  if fm_treehouse_acquire_preflight "$project" unrelated > "$lab/missing.out" 2>&1; then fail 'unavailable recorded home was ignored'; fi
  assert_contains "$(cat "$lab/missing.out")" "$lab/missing-home" 'missing-home path was omitted'
  assert_contains "$(cat "$lab/missing.out")" 'secondmate-provisioning' 'missing-home recovery route was omitted'
  rm "$FM_HOME/state/missing.meta"
  pass 'default/configured pools agree with native allocation; interrupted acquisitions and missing homes refuse safely'

  for id in returned status-refreshed other-returned uncertain replaced git-replaced foreign entry-replaced re-leased same-holder; do
    export TREEHOUSE_ROOT="$lab/$id"
    fm_treehouse_acquire_preflight "$project" "$id"
    fm_treehouse_acquisition_begin "$id"
    json=$(cd "$project" && treehouse --root "$FM_TREEHOUSE_ROOT" get --lease --json --lease-holder "$(fm_treehouse_lease_holder "$id" "$FM_HOME")")
    slot=$(printf '%s\n' "$json" | jq -r .path)
    fm_treehouse_slot_owner_claim "$slot" "$id" "$FM_HOME"
    marker=$(fm_treehouse_slot_owner_marker "$slot")
    state="$(dirname "$(dirname "$slot")")/treehouse-state.json"
    if [ "$id" = other-returned ]; then
      out=$(cd "$project" && treehouse --root "$FM_TREEHOUSE_ROOT" get --lease --json --lease-holder other)
      other_slot=$(printf '%s\n' "$out" | jq -r .path)
      other_lease=$(printf '%s\n' "$out" | jq -r .lease_id)
      [ "$other_slot" != "$slot" ] || fail 'unrelated return fixture reused leased copy'
    fi
    if [ "$id" = uncertain ]; then
      treehouse() {
        command treehouse "$@" || return $?
        [ "$1" != return ] || return 17
      }
      if fm_treehouse_guarded_return "$slot" "$id" "$FM_HOME"; then fail 'lost native return response reported success'; fi
      unset -f treehouse
      [ ! -e "$marker.returned" ] || fail 'uncertain return published success evidence'
      fm_treehouse_slot_entry "$slot" | jq -e '(.leased // false) == false' >/dev/null \
        || fail 'uncertain return fixture did not clear the native lease'
    else
      fm_treehouse_guarded_return "$slot" "$id" "$FM_HOME" || fail 'guarded return failed'
      [ -f "$marker.returned" ] || fail 'native success was not recorded'
    fi
    before=$(cat "$state")
    case "$id" in
      status-refreshed)
        state_identity=$(fm_pr_file_identity "$state")
        (cd "$project" && treehouse --root "$FM_TREEHOUSE_ROOT" status --json) > "$lab/status-refreshed.json"
        [ "$(fm_pr_file_identity "$state")" != "$state_identity" ] || fail 'native status did not republish pool state'
        [ "$(cat "$state")" = "$before" ] || fail 'status republication changed native state semantics'
        ;;
      other-returned)
        treehouse return --force --if-lease-id "$other_lease" "$other_slot"
        [ "$(cat "$state")" != "$before" ] || fail 'unrelated return did not change pool state'
        ;;
    esac
    case "$id" in
      returned|status-refreshed|other-returned)
        before=$(cat "$state")
        fm_treehouse_guarded_return "$slot" "$id" "$FM_HOME" || fail 'successful return replay refused'
        [ "$(cat "$state")" = "$before" ] || fail 'return replay called native cleanup twice'
        if fm_treehouse_require_owned_slot "$slot" "$id" "$FM_HOME" >/dev/null 2>&1; then fail 'returned success authorized relaunch'; fi
        fm_treehouse_slot_owner_release "$slot" "$id" "$FM_HOME"
        [ ! -e "$marker" ] && [ ! -e "$marker.returned" ] && [ ! -e "$FM_HOME/state/$id.treehouse-acquisition" ] || fail 'completed cleanup left operation ownership'
        continue ;;
      replaced) mv "$slot" "$slot.previous"; mkdir "$slot"; cp "$slot.previous/.git" "$slot/.git" ;;
      git-replaced)
        gitdir=$(git -C "$slot" rev-parse --absolute-git-dir)
        mv "$gitdir" "$gitdir.previous"
        mkdir "$gitdir"
        cp -R "$gitdir.previous/." "$gitdir/"
        ;;
      foreign) printf 'task=other\nhome=%s\nlease_id=other\n' "$FM_HOME" > "$marker" ;;
      entry-replaced)
        jq --arg p "$slot" '(.worktrees[] | select(.path == $p)).created_at = "2000-01-01T00:00:00Z"' "$state" > "$state.next"
        mv "$state.next" "$state"
        ;;
      re-leased|same-holder)
        returned=other
        [ "$id" != same-holder ] || returned=$(fm_treehouse_lease_holder "$id" "$FM_HOME")
        out=$(cd "$project" && treehouse --root "$FM_TREEHOUSE_ROOT" lease "$(basename "$(dirname "$slot")")" --lease-holder "$returned" --json)
        [ "$(printf '%s\n' "$out" | jq -r .lease_id)" != "$(printf '%s\n' "$json" | jq -r .lease_id)" ] || fail 're-lease retained old identity'
        ;;
    esac
    before=$(cat "$state")
    returned=$(cat "$marker")
    if fm_treehouse_guarded_return "$slot" "$id" "$FM_HOME" > "$lab/$id.out" 2>&1; then fail "$id incorrectly reused return evidence"; fi
    [ "$(cat "$state")" = "$before" ] || fail "$id refusal changed native state"
    [ "$(cat "$marker")" = "$returned" ] || fail "$id refusal changed the owner claim"
  done
  pass 'exact-slot return replay survives status republication and unrelated returns; uncertainty, replacement, re-lease and foreign claims refuse'

  export TREEHOUSE_ROOT="$lab/seed"
  mkdir -p "$FM_HOME/data/mate"
  printf '# Mate\n# Charter\nFixture home.\n# Routing scope\nFixture only.\n# Project clones\nNone. This is a project-less domain\n' > "$FM_HOME/data/mate/brief.md"
  out=$(FM_ROOT_OVERRIDE="$project" "$ROOT/bin/fm-home-seed.sh" mate - --no-projects 2>&1) || fail "native home seed failed: $out"
  slot=$(printf '%s\n' "$out" | sed -n 's/^home=//p' | tail -1)
  fm_treehouse_require_owned_slot "$slot" mate "$FM_HOME" || fail 'seed did not publish canonical ownership'
  [ "$FM_TREEHOUSE_SLOT_OWNER_LEASE" != "" ] || fail 'seed lacks exact native lease identity'
  fm_treehouse_guarded_return "$slot" mate "$FM_HOME" 1 || fail 'seed return did not use canonical holder'
  fm_treehouse_slot_owner_release "$slot" mate "$FM_HOME"
  rm "$FM_HOME/data/secondmates.md"
  export TREEHOUSE_ROOT="$lab/legacy-home"
  json=$(cd "$project" && treehouse --root "$TREEHOUSE_ROOT" get --lease --json --lease-holder legacy-mate)
  slot=$(printf '%s\n' "$json" | jq -r .path)
  printf 'legacy-mate\n' > "$slot/.fm-secondmate-home"
  if fm_treehouse_guarded_return "$slot" legacy-mate "$FM_HOME" 1 >/dev/null 2>&1; then fail 'unrecorded legacy home was released'; fi
  fm_write_meta "$FM_HOME/state/legacy-mate.meta" 'kind=secondmate' "home=$slot"
  fm_treehouse_guarded_return "$slot" legacy-mate "$FM_HOME" 1 || fail 'recorded legacy home conditional return refused'
  rm "$FM_HOME/state/legacy-mate.meta"
  cat > "$lab/fakebin/treehouse" <<'WRAPPER'
#!/usr/bin/env bash
"$FM_TREEHOUSE_TEST_BIN" "$@"
rc=$?
if [[ " $* " == *' get '* && " $* " != *' --help '* ]]; then exit 17; fi
exit "$rc"
WRAPPER
  chmod +x "$lab/fakebin/treehouse"
  export FM_TREEHOUSE_TEST_BIN="$native" TREEHOUSE_ROOT="$lab/seed-lost"
  out=$(FM_ROOT_OVERRIDE="$project" "$ROOT/bin/fm-home-seed.sh" lost-mate - --no-projects 2>&1) && fail 'lost seed response reported success'
  state=$(python3 "$ROOT/bin/fm-treehouse-identity.py" "$project" | jq -r '.pool + "/treehouse-state.json"')
  before=$(cat "$state")
  export TREEHOUSE_ROOT="$lab/seed-lost-retry"
  out=$(FM_ROOT_OVERRIDE="$project" "$ROOT/bin/fm-home-seed.sh" lost-mate - --no-projects 2>&1) && fail 'seed retry hid retained lease in different root'
  assert_contains "$out" 'retained Treehouse acquisition' 'seed retry lost interrupted acquisition'
  [ "$(cat "$state")" = "$before" ] || fail 'seed retry changed retained lease'
  pass 'native seeding and return share canonical identity; legacy and interrupted seeds preserve ownership'

  export TREEHOUSE_ROOT="$lab/wrong-response"
  fm_test_spawn_brief "$FM_HOME" wrong-response
  before=$(cat "$state_a")
  cat > "$lab/fakebin/treehouse" <<'WRAPPER'
#!/usr/bin/env bash
if [[ " $* " == *' get '* && " $* " != *' --help '* ]]; then
  "$FM_TREEHOUSE_TEST_BIN" --root "$FM_WRONG_ROOT" get --lease --json --lease-holder "firstmate:$FM_HOME:wrong-response"
else
  exec "$FM_TREEHOUSE_TEST_BIN" "$@"
fi
WRAPPER
  chmod +x "$lab/fakebin/treehouse"
  export FM_WRONG_ROOT="$lab/wrong-allocator" FM_TREEHOUSE_TEST_BIN="$native"
  out=$("$ROOT/bin/fm-spawn.sh" wrong-response "$project" --scout --harness codex 2>&1) && fail 'wrong returned pool was accepted'
  assert_contains "$out" 'outside the selected native pool' 'wrong returned pool was not diagnosed'
  [ ! -e "$FM_HOME/state/wrong-response.meta" ] && [ "$(cat "$state_a")" = "$before" ] || fail 'wrong-pool response published or changed preserved state'
  pass 'unexpected native response pool refuses before refresh or publication'
)

if [ "${FM_TREEHOUSE_REPAIR_ONLY:-0}" = 1 ]; then
  test_pinned_pool_identity_and_recovery
  exit $?
fi

test_retained_records_and_interrupted_acquisitions
test_acquisition_receipt_follows_state_override
test_unprovable_retained_record_names_its_record_and_route
test_reserve_explains_remote_and_orca_records
test_native_process_exit_vs_durable_reservation || exit $?
test_remote_seeded_home_spawns_from_treehouse_pool
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

echo "# all fm-spawn-pool-base-freshen tests passed"
