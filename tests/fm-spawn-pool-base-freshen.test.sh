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

run_spawn() {
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
}

scaffold_ship_brief() {
  local id=$1 mode=$2 base_branch=${3:-}
  local -a args=("$id" test-project --mode "$mode")
  [ -z "$base_branch" ] || args+=(--base-branch "$base_branch")
  rm -f "$HOME_DIR/data/$id/brief.md"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "${args[@]}" >/dev/null \
    || fail "fm-brief.sh could not scaffold the $id ship brief"
}

scaffold_scout_brief() {
  local id=$1 base_branch=${2:-}
  local -a args=("$id" test-project --scout)
  [ -z "$base_branch" ] || args+=(--base-branch "$base_branch")
  rm -f "$HOME_DIR/data/$id/brief.md"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "${args[@]}" >/dev/null \
    || fail "fm-brief.sh could not scaffold the scout brief"
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
  scaffold_ship_brief "$id" no-mistakes develop

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --base-branch develop)
  status=$?
  expect_code 0 "$status" "spawn --base-branch should refresh to the named origin tip"
  current_main=$(git -C "$POOL_DIR" rev-parse origin/main)
  current_develop=$(git -C "$POOL_DIR" rev-parse origin/develop)
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current_develop" ] || fail "spawn --base-branch develop did not reset to origin/develop"
  [ "$branch_head" != "$current_main" ] || fail "spawn --base-branch develop reset to origin/main"
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

test_base_branch_uses_local_branch_when_origin_lacks_it() {
  local rec id out status local_sha
  id='pool-base-branch-local-r6'
  rec=$(make_case base-branch-local "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" checkout --quiet -B local-only
  printf 'only local\n' > "$POOL_DIR/local-only.txt"
  git -C "$POOL_DIR" add local-only.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm local-only
  local_sha=$(git -C "$POOL_DIR" rev-parse HEAD)
  git -C "$POOL_DIR" checkout --quiet --detach "$INITIAL_SHA"
  scaffold_ship_brief "$id" no-mistakes local-only

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --base-branch local-only)
  status=$?
  expect_code 0 "$status" "spawn --base-branch should use a local branch when origin lacks it"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$local_sha" ] \
    || fail "spawn --base-branch local-only did not reset to the local branch tip"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" != "$(git -C "$POOL_DIR" rev-parse origin/main)" ] \
    || fail "spawn --base-branch local-only fell back to origin/main"
  pass "spawn --base-branch uses a local branch when origin lacks it"
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
  assert_contains "$out" "does not exist locally or on origin" \
    "spawn did not clearly refuse a missing --base-branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after refusing a missing --base-branch"
  pass "a nonexistent --base-branch refuses without falling back to the default"
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

test_base_branch_contract_refuses_mismatch() {
  local rec id out status before kind
  for kind in ship scout; do
    id="pool-base-branch-contract-${kind}-r7"
    rec=$(make_case "base-branch-contract-$kind" "$id")
    read_case_record "$rec"
    if [ "$kind" = ship ]; then
      scaffold_ship_brief "$id" no-mistakes develop
      before=$(git -C "$POOL_DIR" rev-parse HEAD)
      out=$(run_spawn "$id" --mode no-mistakes --yolo off --base-branch release)
    else
      scaffold_scout_brief "$id" develop
      before=$(git -C "$POOL_DIR" rev-parse HEAD)
      out=$(run_spawn "$id" --scout --base-branch release)
    fi
    status=$?
    [ "$status" -ne 0 ] || fail "$kind spawn accepted a --base-branch that disagrees with its generated brief"
    assert_contains "$out" "base-branch mismatch" \
      "$kind spawn did not clearly refuse a base-branch contract mismatch"
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
      || fail "$kind spawn changed the pooled worktree after a base-branch contract mismatch"
    assert_absent "$HOME_DIR/state/$id.meta" \
      "$kind spawn recorded metadata after a base-branch contract mismatch"
  done
  pass "ship and scout base contracts refuse conflicting spawn flags"
}

test_base_branch_contract_uses_last_line() {
  local rec id brief out status
  id='pool-base-branch-last-line-r8'
  rec=$(make_case base-branch-last-line "$id")
  read_case_record "$rec"
  git -C "$CASE_DIR/publisher" checkout --quiet -b develop
  printf 'only on develop\n' > "$CASE_DIR/publisher/develop-only.txt"
  git -C "$CASE_DIR/publisher" add develop-only.txt
  git -C "$CASE_DIR/publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm develop-tip
  git -C "$CASE_DIR/publisher" push --quiet origin develop
  scaffold_ship_brief "$id" no-mistakes develop
  brief="$HOME_DIR/data/$id/brief.md"
  awk '
    /^# Task$/ {
      print
      print "Base branch contract: base_branch=release"
      next
    }
    { print }
  ' "$brief" > "$brief.tmp" && mv "$brief.tmp" "$brief"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --base-branch develop)
  status=$?
  expect_code 0 "$status" "spawn --base-branch should honor the last generated base contract"
  assert_contains "$out" "spawned $id" "spawn did not report success after an earlier decoy base line"
  assert_grep 'base_branch=develop' "$HOME_DIR/state/$id.meta" \
    "spawn treated an earlier Base branch mention as the contract"
  pass "ship base-contract agreement uses the last Base branch line"
}

test_base_branch_contract_ignores_progress_note() {
  local rec id brief out status
  id='pool-base-branch-progress-note-r8'
  rec=$(make_case base-branch-progress-note "$id")
  read_case_record "$rec"
  git -C "$CASE_DIR/publisher" checkout --quiet -b develop
  printf 'only on develop\n' > "$CASE_DIR/publisher/develop-only.txt"
  git -C "$CASE_DIR/publisher" add develop-only.txt
  git -C "$CASE_DIR/publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm develop-tip
  git -C "$CASE_DIR/publisher" push --quiet origin develop
  scaffold_ship_brief "$id" no-mistakes develop
  brief="$HOME_DIR/data/$id/brief.md"
  cat >> "$brief" <<'EOF'

## Progress note (2026-08-24T11:29:00Z)

This task was relaunched. Continue from here.
Base branch contract: base_branch=release
Delivery contract: mode=local-only
EOF

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --base-branch develop)
  status=$?
  expect_code 0 "$status" "spawn should ignore contract lines in a relaunch progress note"
  assert_contains "$out" "spawned $id" "spawn did not report success after a progress-note decoy"
  assert_grep 'base_branch=develop' "$HOME_DIR/state/$id.meta" \
    "spawn treated a progress-note Base branch line as the contract"
  pass "ship base-contract agreement ignores a relaunch progress note"
}

test_stale_pool_base_refreshes_before_branching
test_non_main_default_branch_refreshes_before_branching
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base
test_stale_submodule_pin_explains_itself
test_unpushed_submodule_commit_is_still_uncommitted_work
test_work_inside_submodule_is_still_uncommitted_work
test_stale_pin_carrying_real_work_is_not_called_stale
test_stale_pin_beside_other_dirt_reports_one_verdict
test_base_branch_resets_to_named_origin_tip
test_absent_base_branch_leaves_default_freshen_and_meta
test_base_branch_uses_local_branch_when_origin_lacks_it
test_base_branch_ref_fetch_failure_refuses_local_fallback
test_missing_base_branch_refuses_without_default_fallback
test_base_branch_refused_on_relaunch_secondmate_and_orca
test_base_branch_contract_refuses_mismatch
test_base_branch_contract_uses_last_line
test_base_branch_contract_ignores_progress_note

echo "# all fm-spawn-pool-base-freshen tests passed"
