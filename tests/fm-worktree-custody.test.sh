#!/usr/bin/env bash
# Regression tests for single-owner custody of a pooled working copy.
#
# Treehouse keys a worktree pool by the repository, not by the checkout, and
# re-leases a slot as soon as the shell that held it is gone. Two firstmate
# homes that clone the same project therefore draw from ONE pool while neither
# can see the other's task records, so a slot one home's task still names gets
# handed to the other home - and whichever task is cleaned up first hard-resets
# the copy the other is working in.
#
# Three guarantees close that, and each is pinned here:
#   (a) every home leases from its OWN pool root (bin/fm-pool-root.sh, wired
#       into bin/fm-spawn.sh before the slot is acquired);
#   (b) a spawn refuses a copy another task in this home already claims
#       (bin/fm-spawn.sh), before the base refresh touches it;
#   (c) cleanup refuses when the project's own custody check reports the copy
#       is not this task's to discard (bin/fm-teardown.sh);
#   (d) a spawn asks the project to release its delivered copies before leasing,
#       so a pool exhausted by copies nobody handed back does not block dispatch
#       (bin/fm-spawn.sh) - capacity, so a failure warns and the spawn continues.
#
# (a) is proven twice: portably against the configuration firstmate writes, and
# - where the real binary is installed - against treehouse itself allocating
# two clones of one origin, which is the vendor fact the whole class rests on.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

POOL_ROOT_BIN="$ROOT/bin/fm-pool-root.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-custody)

# --- (a) one pool root per home ---------------------------------------------

pool_root_for_home() {  # <home> <base> <project>
  FM_HOME="$1" FM_POOL_ROOT_BASE="$2" "$POOL_ROOT_BIN" "$3"
}

configured_root_of() {  # <clone>
  sed -n 's/^root[[:space:]]*=[[:space:]]*"\(.*\)"$/\1/p' "$1/treehouse.toml" | head -1
}

make_two_homes_one_project() {  # <name>
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/homeA" "$case_dir/homeB" "$case_dir/base"
  fm_git_init_commit "$case_dir/upstream"
  git clone --quiet --bare "$case_dir/upstream" "$case_dir/origin.git"
  git clone --quiet "$case_dir/origin.git" "$case_dir/homeA/project"
  git clone --quiet "$case_dir/origin.git" "$case_dir/homeB/project"
  printf '%s\n' "$case_dir"
}

test_two_homes_configure_distinct_pool_roots() {
  local case_dir root_a root_b
  case_dir=$(make_two_homes_one_project distinct-roots)

  root_a=$(pool_root_for_home "$case_dir/homeA" "$case_dir/base" "$case_dir/homeA/project") \
    || fail "fm-pool-root.sh failed for the first home"
  root_b=$(pool_root_for_home "$case_dir/homeB" "$case_dir/base" "$case_dir/homeB/project") \
    || fail "fm-pool-root.sh failed for the second home"

  [ -n "$root_a" ] && [ -n "$root_b" ] || fail "fm-pool-root.sh printed no pool root"
  [ "$root_a" != "$root_b" ] \
    || fail "two homes cloning one project resolved the SAME pool root ($root_a)"
  [ -d "$root_a" ] && [ -d "$root_b" ] || fail "fm-pool-root.sh did not create the pool roots"
  [ "$(configured_root_of "$case_dir/homeA/project")" = "$root_a" ] \
    || fail "the first home's clone does not carry its own pool root"
  [ "$(configured_root_of "$case_dir/homeB/project")" = "$root_b" ] \
    || fail "the second home's clone does not carry its own pool root"
  pass "two homes cloning one project configure distinct treehouse pool roots"
}

test_pool_root_is_idempotent_and_preserves_other_keys() {
  local case_dir clone before after root
  case_dir=$(make_two_homes_one_project idempotent)
  clone="$case_dir/homeA/project"
  printf 'max_trees = 20\nroot = ""\n\n# keep this comment\n' > "$clone/treehouse.toml"

  root=$(pool_root_for_home "$case_dir/homeA" "$case_dir/base" "$clone") \
    || fail "fm-pool-root.sh failed on an existing treehouse.toml"
  [ "$(configured_root_of "$clone")" = "$root" ] || fail "an existing empty root was not replaced"
  assert_grep 'max_trees = 20' "$clone/treehouse.toml" "max_trees was dropped"
  assert_grep 'keep this comment' "$clone/treehouse.toml" "an unrelated line was dropped"

  before=$(cksum < "$clone/treehouse.toml")
  pool_root_for_home "$case_dir/homeA" "$case_dir/base" "$clone" >/dev/null \
    || fail "a repeat run of fm-pool-root.sh failed"
  after=$(cksum < "$clone/treehouse.toml")
  [ "$before" = "$after" ] || fail "a repeat run rewrote an already-correct treehouse.toml"

  grep -qxF 'treehouse.toml' "$clone/.git/info/exclude" \
    || fail "the pool config was not excluded from the clone"
  [ -z "$(git -C "$clone" status --porcelain)" ] \
    || fail "writing the pool root left the clone dirty"
  pass "the pool root is written idempotently, preserves other keys, and never dirties the clone"
}

test_pool_root_refuses_a_tracked_config() {
  local case_dir clone out status
  case_dir=$(make_two_homes_one_project tracked-config)
  clone="$case_dir/homeA/project"
  printf 'max_trees = 20\nroot = "/somewhere/shared"\n' > "$clone/treehouse.toml"
  git -C "$clone" add treehouse.toml
  git -C "$clone" commit -qm "track treehouse.toml"

  out=$(pool_root_for_home "$case_dir/homeA" "$case_dir/base" "$clone" 2>&1)
  status=$?
  expect_code 1 "$status" "a tracked treehouse.toml should refuse, not be rewritten"
  assert_contains "$out" "tracks treehouse.toml" "the refusal did not name the tracked config"
  assert_grep '/somewhere/shared' "$clone/treehouse.toml" "a tracked config was rewritten anyway"
  [ -z "$(git -C "$clone" status --porcelain)" ] || fail "the refusal left project content modified"
  pass "a project that tracks treehouse.toml is refused rather than rewritten"
}

# The vendor fact the class rests on: treehouse hands two clones of one origin
# slots from the SAME pool, and only `root` moves that pool. Self-skipping,
# because the pool allocator is a third-party binary CI installs only for the
# lanes that need it (bin/fm-install-treehouse.sh).
test_real_treehouse_stops_sharing_a_pool_between_homes() {
  local case_dir shared lease_a lease_b pool_a pool_b root_a root_b
  if ! command -v treehouse >/dev/null 2>&1; then
    printf 'ok - SKIP real-treehouse pool separation (treehouse not installed)\n'
    return 0
  fi
  case_dir=$(make_two_homes_one_project real-treehouse)
  shared="$case_dir/shared"
  mkdir -p "$shared"

  # Before: both clones point at one root, so treehouse pools them together.
  printf 'max_trees = 5\nroot = "%s"\n' "$shared" > "$case_dir/homeA/project/treehouse.toml"
  printf 'max_trees = 5\nroot = "%s"\n' "$shared" > "$case_dir/homeB/project/treehouse.toml"
  lease_a=$( cd "$case_dir/homeA/project" && treehouse get --lease 2>/dev/null )
  lease_b=$( cd "$case_dir/homeB/project" && treehouse get --lease 2>/dev/null )
  [ -n "$lease_a" ] && [ -n "$lease_b" ] || fail "treehouse did not lease a worktree to each clone"
  pool_a=$(dirname "$(dirname "$lease_a")")
  pool_b=$(dirname "$(dirname "$lease_b")")
  [ "$pool_a" = "$pool_b" ] \
    || fail "fixture did not reproduce the shared pool: $pool_a vs $pool_b"
  ( cd "$case_dir/homeA/project" && treehouse return --force "$lease_a" >/dev/null 2>&1 ) || true
  ( cd "$case_dir/homeB/project" && treehouse return --force "$lease_b" >/dev/null 2>&1 ) || true

  # After: each home claims its own root and the pools no longer overlap.
  root_a=$(pool_root_for_home "$case_dir/homeA" "$case_dir/base" "$case_dir/homeA/project")
  root_b=$(pool_root_for_home "$case_dir/homeB" "$case_dir/base" "$case_dir/homeB/project")
  lease_a=$( cd "$case_dir/homeA/project" && treehouse get --lease 2>/dev/null )
  lease_b=$( cd "$case_dir/homeB/project" && treehouse get --lease 2>/dev/null )
  [ -n "$lease_a" ] && [ -n "$lease_b" ] || fail "treehouse did not lease from the per-home roots"
  case "$(cd "$(dirname "$lease_a")" && pwd -P)" in "$root_a"/*) ;;
    *) fail "the first home leased outside its own pool root: $lease_a" ;;
  esac
  case "$(cd "$(dirname "$lease_b")" && pwd -P)" in "$root_b"/*) ;;
    *) fail "the second home leased outside its own pool root: $lease_b" ;;
  esac
  ( cd "$case_dir/homeA/project" && treehouse return --force "$lease_a" >/dev/null 2>&1 ) || true
  ( cd "$case_dir/homeB/project" && treehouse return --force "$lease_b" >/dev/null 2>&1 ) || true
  pass "real treehouse pools two homes together until each claims its own root"
}

# --- (b) a spawn never launches a second owner into one copy -----------------

make_spawn_case() {  # <name> <id>
  local name=$1 id=$2 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$case_dir/home/data/$id" "$case_dir/home/projects" \
    "$case_dir/home/state" "$case_dir/home/config" "$case_dir/base"
  printf 'codex\n' > "$case_dir/home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$case_dir/home/data/$id/brief.md"
  touch "$case_dir/home/state/.last-watcher-beat"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse

  fm_git_init_commit "$case_dir/upstream"
  git clone --quiet --bare "$case_dir/upstream" "$case_dir/origin.git"
  git clone --quiet "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin --auto >/dev/null 2>&1 || true
  git -C "$case_dir/project" worktree add --quiet --detach "$case_dir/pool" HEAD
  printf '%s\n' "$case_dir"
}

run_spawn_case() {  # <case-dir> <id> <args...>
  local case_dir=$1 id=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE="$case_dir/home/state" FM_DATA_OVERRIDE="$case_dir/home/data" \
    FM_PROJECTS_OVERRIDE="$case_dir/home/projects" FM_CONFIG_OVERRIDE="$case_dir/home/config" \
    FM_POOL_ROOT_BASE="$case_dir/base" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$case_dir/pool" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" "$@" 2>&1
}

test_spawn_refuses_a_copy_another_task_claims() {
  local case_dir id out status pool_head
  id='custody-claimed-r1'
  case_dir=$(make_spawn_case spawn-claimed "$id")
  # Another task of THIS home already owns that pooled copy and has unlanded work.
  fm_write_meta "$case_dir/home/state/other-task.meta" \
    "window=firstmate:fm-other-task" \
    "worktree=$case_dir/pool" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  git -C "$case_dir/pool" checkout --quiet -b fm/other-task
  git -C "$case_dir/pool" commit -q --allow-empty -m "other task's unlanded work"
  pool_head=$(git -C "$case_dir/pool" rev-parse HEAD)

  out=$(run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "spawn should refuse a copy another task already claims: $out"
  assert_contains "$out" "other-task already claims" "the refusal did not name the claiming task"
  assert_absent "$case_dir/home/state/$id.meta" "a refused spawn still published task metadata"
  [ "$(git -C "$case_dir/pool" rev-parse HEAD)" = "$pool_head" ] \
    || fail "the refused spawn reset the other task's copy before refusing"
  [ "$(git -C "$case_dir/pool" rev-parse --abbrev-ref HEAD)" = "fm/other-task" ] \
    || fail "the refused spawn moved the other task's copy off its branch"
  pass "a spawn refuses a pooled copy another task claims, leaving that copy untouched"
}

test_spawn_claims_this_homes_pool_root_before_leasing() {
  local case_dir id out status base_real
  id='custody-own-pool-r1'
  case_dir=$(make_spawn_case spawn-own-pool "$id")

  out=$(run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an unclaimed pooled copy should still spawn"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  base_real=$(cd "$case_dir/base" && pwd -P)
  grep -q "^root = \"$base_real/" "$case_dir/project/treehouse.toml" \
    || fail "spawn did not point the clone at this home's own pool root"
  pass "a spawn gives the clone this home's own pool root before asking for a slot"
}

# --- (d) delivered copies are released before a slot is requested ------------

# The project publishes the release step; the runner records that it ran, and
# reports <exit>.
add_release_step() {  # <case-dir> <exit>
  local case_dir=$1 exit_code=$2
  printf '{\n  "name": "fixture",\n  "scripts": {\n    "pool:release-delivered": "node release.js"\n  }\n}\n' \
    > "$case_dir/project/package.json"
  cat > "$case_dir/fakebin/npm" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = run ] && [ "\${2:-}" = pool:release-delivered ]; then
  printf '%s\\n' "\$*" >> "$case_dir/release.log"
  printf 'released 2 delivered copies\\n'
  exit $exit_code
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/npm"
}

test_spawn_releases_delivered_copies_before_leasing() {
  local case_dir id out status
  id='custody-release-r1'
  case_dir=$(make_spawn_case spawn-release "$id")
  add_release_step "$case_dir" 0

  out=$(run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn should proceed after releasing delivered copies: $out"
  assert_present "$case_dir/release.log" "spawn never asked the project to release delivered copies"
  grep -qF -- '--yes' "$case_dir/release.log" \
    || fail "the release step was not run non-interactively"
  pass "a spawn releases the project's delivered copies before asking for a slot"
}

test_spawn_skips_projects_that_publish_no_release_step() {
  local case_dir id out status
  id='custody-no-release-r1'
  case_dir=$(make_spawn_case spawn-no-release "$id")
  cat > "$case_dir/fakebin/npm" <<'SH'
#!/usr/bin/env bash
printf 'npm must not be invoked for a project without the release step\n' >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/npm"

  out=$(run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a project without the release step should spawn unchanged: $out"
  assert_not_contains "$out" "must not be invoked" "spawn ran a release step the project never published"
  pass "a project that publishes no release step spawns exactly as before"
}

test_spawn_continues_when_the_release_step_fails() {
  local case_dir id out status
  id='custody-release-fails-r1'
  case_dir=$(make_spawn_case spawn-release-fails "$id")
  add_release_step "$case_dir" 3

  out=$(run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "failed housekeeping must not block a dispatch: $out"
  assert_contains "$out" "pool:release-delivered failed" "a failed release step was not reported"
  assert_contains "$out" "spawned $id" "the spawn did not continue after the failed release step"
  pass "a failed release step warns loudly and never blocks the dispatch"
}

# --- (c) cleanup refuses when the project says the copy is not ours ----------

make_teardown_case() {  # <name>
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse tmux

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main >/dev/null 2>&1 || true
  git -C "$case_dir/project" worktree add -q -b fm/task-c1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-c1.meta" \
    "window=firstmate:fm-task-c1" \
    "endpoint_task_id=task-c1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$case_dir"
}

# The project publishes the check; <exit> is the verdict its runner reports.
add_custody_check() {  # <case-dir> <exit>
  local case_dir=$1 exit_code=$2
  printf '{\n  "name": "fixture",\n  "scripts": {\n    "check:worktree-custody": "node custody.js"\n  }\n}\n' \
    > "$case_dir/wt/package.json"
  # Landed, so the existing landed-work verdict passes and custody is what decides.
  git -C "$case_dir/wt" add package.json
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -qm "publish the custody check"
  git -C "$case_dir/wt" push -q origin fm/task-c1
  git -C "$case_dir/project" fetch -q origin
  cat > "$case_dir/fakebin/npm" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = run ] && [ "\${2:-}" = check:worktree-custody ]; then
  printf 'pushed-not-merged: this copy is still delivering\n'
  exit $exit_code
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/npm"
}

run_teardown_case() {  # <case-dir> <args...>
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-c1 "$@" 2>&1
}

test_teardown_refuses_a_red_custody_verdict() {
  local case_dir out status
  case_dir=$(make_teardown_case teardown-custody-red)
  add_custody_check "$case_dir" 1

  out=$(run_teardown_case "$case_dir")
  status=$?
  expect_code 1 "$status" "cleanup should refuse a red custody verdict"
  assert_contains "$out" "check:worktree-custody" "the refusal did not name the project's check"
  assert_contains "$out" "pushed-not-merged" "the refusal did not relay what the check reported"
  assert_present "$case_dir/state/task-c1.meta" "a refused cleanup removed the task record"
  [ -d "$case_dir/wt" ] || fail "a refused cleanup removed the working copy"
  pass "cleanup refuses when the project's custody check says the copy is not this task's"
}

test_teardown_proceeds_on_a_green_custody_verdict() {
  local case_dir out status
  case_dir=$(make_teardown_case teardown-custody-green)
  add_custody_check "$case_dir" 0

  out=$(run_teardown_case "$case_dir")
  status=$?
  expect_code 0 "$status" "cleanup should proceed on a green custody verdict: $out"
  assert_absent "$case_dir/state/task-c1.meta" "a completed cleanup left the task record behind"
  pass "cleanup proceeds when the project's custody check reports the copy is free"
}

test_teardown_skips_projects_that_publish_no_check() {
  local case_dir out status
  case_dir=$(make_teardown_case teardown-custody-absent)
  cat > "$case_dir/fakebin/npm" <<'SH'
#!/usr/bin/env bash
printf 'npm must not be invoked for a project without the check\n' >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/npm"

  out=$(run_teardown_case "$case_dir")
  status=$?
  expect_code 0 "$status" "a project without the check should tear down unchanged: $out"
  assert_not_contains "$out" "must not be invoked" "cleanup ran a check the project never published"
  pass "a project that publishes no custody check tears down exactly as before"
}

test_teardown_refuses_when_a_published_check_cannot_be_run() {
  local case_dir out status path_without_npm
  case_dir=$(make_teardown_case teardown-custody-unrunnable)
  add_custody_check "$case_dir" 0
  rm -f "$case_dir/fakebin/npm"
  # A PATH with no npm at all, so the published check cannot be answered.
  path_without_npm="$case_dir/fakebin"

  out=$(PATH="$path_without_npm:/usr/bin:/bin" run_teardown_case "$case_dir")
  status=$?
  expect_code 1 "$status" "an unanswerable custody check should refuse, not pass silently"
  assert_contains "$out" "REFUSED" "the unanswerable check did not refuse loudly"
  assert_present "$case_dir/state/task-c1.meta" "a refused cleanup removed the task record"
  pass "a published custody check that cannot be run refuses instead of tearing down"
}

test_two_homes_configure_distinct_pool_roots
test_pool_root_is_idempotent_and_preserves_other_keys
test_pool_root_refuses_a_tracked_config
test_real_treehouse_stops_sharing_a_pool_between_homes
test_spawn_refuses_a_copy_another_task_claims
test_spawn_claims_this_homes_pool_root_before_leasing
test_spawn_releases_delivered_copies_before_leasing
test_spawn_skips_projects_that_publish_no_release_step
test_spawn_continues_when_the_release_step_fails
test_teardown_refuses_a_red_custody_verdict
test_teardown_proceeds_on_a_green_custody_verdict
test_teardown_skips_projects_that_publish_no_check
test_teardown_refuses_when_a_published_check_cannot_be_run
