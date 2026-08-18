#!/usr/bin/env bash
# Behavior tests for Next.js build-cache reclamation.
#
# The leak this pins: a pooled task copy returns to the pool still holding its
# Next.js build output. `treehouse return` resets tracked content and leaves
# gitignored output alone, so nothing ever removes it and it accumulates copy by
# copy until the volume fills. Measured 2026-08-18: 15 GB in one idle Artemis
# copy on a volume with 11 GB free.
#
# Two surfaces, one discovery rule (bin/fm-next-cache-lib.sh):
#   bin/fm-teardown.sh          reclaims a copy on its way back to the pool.
#   bin/fm-next-cache-sweep.sh  reclaims copies already sitting idle in it.
#
# The cases that matter most are the refusals. A live dev server rewrites the
# output the moment it is deleted, and deleting mid-build is worse than leaving
# it alone, so every ownership proof gets its own case asserting the directory
# SURVIVES.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SWEEP="$ROOT/bin/fm-next-cache-sweep.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-next-cache-sweep)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# --- fixture builders -------------------------------------------------------

# Give <worktree> a Next.js app at <subpath> holding build output, and make that
# output gitignored the way a real project does. Args: worktree subpath
add_next_app() {
  local wt=$1 sub=$2 app="$1/$2"
  mkdir -p "$app/.next/server" "$app/.next/static"
  printf 'export default {}\n' > "$app/next.config.ts"
  printf '{"name":"app","dependencies":{"next":"16.3.0"}}\n' > "$app/package.json"
  printf 'build-id\n' > "$app/.next/BUILD_ID"
  head -c 4096 /dev/zero > "$app/.next/static/chunk.js"
  printf '%s/.next\n' "$sub" >> "$wt/.gitignore"
  git -C "$wt" add -A >/dev/null 2>&1
  git -C "$wt" -c user.email=t@t -c user.name=t commit -qm "next app at $sub"
}

# A firstmate home with a project clone, a fake treehouse pool, and a fakebin.
# Echoes the case dir. Args: name
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" \
    "$case_dir/projects" "$case_dir/fakebin" "$case_dir/pool"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf '# app\n' > "$case_dir/_seed/README.md"
  git -C "$case_dir/_seed" add README.md
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/projects/app"
  git -C "$case_dir/projects/app" remote set-head origin main 2>/dev/null || true

  printf '%s\n' "$case_dir"
}

# Add a pool worktree named <n> to <case_dir>, on branch fm/task-<n>.
# Echoes its path. Args: case_dir n
add_pool_worktree() {  # <case-dir> <n>
  local case_dir=$1 n=$2 wt="$1/pool/$2"
  git -C "$case_dir/projects/app" worktree add -q -b "fm/task-$n" "$wt" main
  printf '%s\n' "$wt"
}

# Install a treehouse stub whose `status --json` answers the pool description in
# $case_dir/pool-status (lines of "<name> <status>"). `return --force` succeeds.
install_treehouse_stub() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  python3 - "$FM_FAKE_POOL_STATUS" "$FM_FAKE_POOL_DIR" <<'PY'
import json, sys
entries = []
with open(sys.argv[1]) as handle:
    for line in handle:
        line = line.split()
        if len(line) == 2:
            entries.append({"name": line[0], "status": line[1],
                            "path": "%s/%s" % (sys.argv[2], line[0])})
print(json.dumps(entries))
PY
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

run_sweep() {  # <case-dir> [args...]
  local case_dir=$1; shift
  FM_HOME="$case_dir" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_PROJECTS_OVERRIDE="$case_dir/projects" \
  FM_FAKE_POOL_STATUS="$case_dir/pool-status" \
  FM_FAKE_POOL_DIR="$case_dir/pool" \
  PATH="$case_dir/fakebin:$PATH" \
    "$SWEEP" "$@"
}

# --- sweep: it reclaims a genuinely unowned copy -----------------------------

test_sweep_reclaims_available_copy() {
  local case_dir wt out rc
  case_dir=$(make_case reclaim)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 0 "$rc" "reclaim: sweep should succeed"
  assert_absent "$wt/packages/frontend/.next" "reclaim: build output should be gone"
  assert_present "$wt/packages/frontend/next.config.ts" "reclaim: source must survive"
  assert_present "$wt/README.md" "reclaim: tracked content must survive"
  assert_contains "$out" "reclaimed" "reclaim: sweep must report what it reclaimed"
  assert_contains "$out" "$wt/packages/frontend/.next" "reclaim: report must name the directory"
  pass "sweep reclaims Next.js build output from an available, unowned copy"
}

test_sweep_reports_nothing_found() {
  local case_dir out
  case_dir=$(make_case empty)
  install_treehouse_stub "$case_dir"
  add_pool_worktree "$case_dir" 1 >/dev/null
  printf '1 available\n' > "$case_dir/pool-status"

  out=$(run_sweep "$case_dir" 2>&1)

  assert_contains "$out" "nothing to reclaim" \
    "empty: a sweep that found nothing must say so rather than print nothing"
  pass "sweep reports plainly when no idle copy holds build output"
}

test_sweep_dry_run_removes_nothing() {
  local case_dir wt out
  case_dir=$(make_case dry-run)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"

  out=$(run_sweep "$case_dir" --dry-run 2>&1)

  assert_present "$wt/packages/frontend/.next" "dry-run: build output must survive"
  assert_contains "$out" "would reclaim" "dry-run: must report what it would reclaim"
  pass "--dry-run reports the reclaim without performing it"
}

# --- sweep: every ownership proof refuses ------------------------------------

test_sweep_skips_in_use_copy() {
  local case_dir wt out
  case_dir=$(make_case in-use)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 in-use\n' > "$case_dir/pool-status"

  out=$(run_sweep "$case_dir" 2>&1)

  assert_present "$wt/packages/frontend/.next" \
    "in-use: a leased copy may be mid-build; its output must survive"
  assert_contains "$out" "in use by the pool" "in-use: the skip reason must be reported"
  pass "sweep never touches a copy the pool still reports in use"
}

test_sweep_skips_copy_claimed_by_task_record() {
  local case_dir wt out
  case_dir=$(make_case claimed)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "endpoint_task_id=task-x1" "worktree=$wt" "project=$case_dir/projects/app" \
    "kind=ship" "mode=no-mistakes"

  out=$(run_sweep "$case_dir" 2>&1)

  assert_present "$wt/packages/frontend/.next" \
    "claimed: a copy a task still records must keep its output"
  assert_contains "$out" "still claimed by a task record" "claimed: reason must be reported"
  pass "sweep never touches a copy a task record still claims"
}

test_sweep_skips_copy_claimed_by_secondmate_task_record() {
  local case_dir wt out sub
  case_dir=$(make_case claimed-secondmate)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  # The pool is shared across firstmate homes, so a copy owned by another home's
  # task must be as untouchable as one owned by this home's.
  sub="$case_dir/secondmate"
  mkdir -p "$sub/state"
  fm_write_meta "$sub/state/task-s1.meta" \
    "endpoint_task_id=task-s1" "worktree=$wt" "kind=ship" "mode=no-mistakes"
  printf -- '- helper - Helps. (home: %s; scope: things; projects: app; added 2026-08-18)\n' \
    "$sub" > "$case_dir/data/secondmates.md"

  out=$(run_sweep "$case_dir" 2>&1)

  assert_present "$wt/packages/frontend/.next" \
    "claimed-secondmate: another home's task record must protect the copy"
  assert_contains "$out" "still claimed by a task record" \
    "claimed-secondmate: reason must be reported"
  pass "sweep honours task records in registered secondmate homes"
}

test_sweep_skips_dirty_copy() {
  local case_dir wt out
  case_dir=$(make_case dirty)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf 'unfinished\n' > "$wt/packages/frontend/edit.ts"
  printf '1 available\n' > "$case_dir/pool-status"

  out=$(run_sweep "$case_dir" 2>&1)

  assert_present "$wt/packages/frontend/.next" \
    "dirty: uncommitted work means the copy is not finished with"
  assert_contains "$out" "has uncommitted changes" "dirty: reason must be reported"
  pass "sweep never touches a copy with uncommitted changes"
}

test_sweep_skips_stashed_copy() {
  local case_dir wt out
  case_dir=$(make_case stashed)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf 'work in progress\n' >> "$wt/README.md"
  git -C "$wt" -c user.email=t@t -c user.name=t stash -q
  printf '1 available\n' > "$case_dir/pool-status"

  out=$(run_sweep "$case_dir" 2>&1)

  assert_present "$wt/packages/frontend/.next" \
    "stashed: a stash is unlanded work a clean tree does not show"
  assert_contains "$out" "has stashed work" "stashed: reason must be reported"
  pass "sweep never touches a copy holding stashed work"
}

# --- discovery rule: only regenerable Next.js build output -------------------

test_sweep_leaves_tracked_next_directory() {
  local case_dir wt out
  case_dir=$(make_case tracked)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  # A committed .next beside a real Next app: tracked content is never build
  # output, so gitignore status - not the name - decides.
  mkdir -p "$wt/packages/frontend/.next"
  printf 'export default {}\n' > "$wt/packages/frontend/next.config.ts"
  printf 'checked in\n' > "$wt/packages/frontend/.next/fixture.txt"
  git -C "$wt" add -A >/dev/null 2>&1
  git -C "$wt" -c user.email=t@t -c user.name=t commit -qm "tracked .next fixture"
  printf '1 available\n' > "$case_dir/pool-status"

  out=$(run_sweep "$case_dir" 2>&1)

  assert_present "$wt/packages/frontend/.next/fixture.txt" \
    "tracked: a tracked .next is not build output and must survive"
  assert_contains "$out" "nothing to reclaim" "tracked: nothing should have been reclaimed"
  pass "a tracked .next directory is never treated as build output"
}

test_sweep_leaves_ignored_next_outside_a_next_app() {
  local case_dir wt out
  case_dir=$(make_case not-an-app)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  # Gitignored and named .next, but nothing here is a Next.js app, so it is not
  # provably regenerable and the sweep must leave it alone.
  mkdir -p "$wt/notes/.next"
  printf 'irreplaceable\n' > "$wt/notes/.next/keep.txt"
  printf 'notes/.next\n' >> "$wt/.gitignore"
  git -C "$wt" add -A >/dev/null 2>&1
  git -C "$wt" -c user.email=t@t -c user.name=t commit -qm "ignored non-app .next"
  printf '1 available\n' > "$case_dir/pool-status"

  out=$(run_sweep "$case_dir" 2>&1)

  assert_present "$wt/notes/.next/keep.txt" \
    "not-an-app: an ignored .next outside a Next.js app must survive"
  assert_contains "$out" "nothing to reclaim" "not-an-app: nothing should have been reclaimed"
  pass "an ignored .next that is not Next.js build output is left alone"
}

test_sweep_leaves_node_modules_and_source() {
  local case_dir wt out
  case_dir=$(make_case node-modules)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  # A gitignored node_modules holding a package that itself ships a .next.
  mkdir -p "$wt/node_modules/some-pkg/.next"
  printf 'vendored\n' > "$wt/node_modules/some-pkg/.next/vendor.js"
  printf 'export default {}\n' > "$wt/node_modules/some-pkg/next.config.js"
  printf 'node_modules\n' >> "$wt/.gitignore"
  git -C "$wt" add -A >/dev/null 2>&1
  git -C "$wt" -c user.email=t@t -c user.name=t commit -qm "ignore node_modules"
  printf '1 available\n' > "$case_dir/pool-status"

  out=$(run_sweep "$case_dir" 2>&1)

  assert_absent "$wt/packages/frontend/.next" "node-modules: the app's output should be reclaimed"
  assert_present "$wt/node_modules/some-pkg/.next/vendor.js" \
    "node-modules: nothing inside node_modules may be removed"
  assert_present "$wt/.git" "node-modules: git data must survive"
  pass "node_modules and git data are out of reach of the discovery walk"
}

test_sweep_reclaims_nested_build_output_once() {
  local case_dir wt out
  case_dir=$(make_case nested)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  # Next's standalone output nests a second .next inside the first. It must go
  # with its parent, counted once, not walked into and reported twice.
  mkdir -p "$wt/packages/frontend/.next/standalone/packages/frontend/.next"
  printf 'export default {}\n' \
    > "$wt/packages/frontend/.next/standalone/packages/frontend/next.config.ts"
  printf '1 available\n' > "$case_dir/pool-status"

  out=$(run_sweep "$case_dir" 2>&1)

  assert_absent "$wt/packages/frontend/.next" "nested: the whole tree should be gone"
  [ "$(printf '%s\n' "$out" | grep -c 'of Next.js build output from ')" = 1 ] \
    || fail "nested: a nested .next must be reclaimed with its parent, reported once"$'\n'"$out"
  pass "a nested standalone .next is reclaimed with its parent and reported once"
}

test_sweep_never_sweeps_the_project_clone() {
  local case_dir out
  case_dir=$(make_case clone)
  install_treehouse_stub "$case_dir"
  add_pool_worktree "$case_dir" 1 >/dev/null
  add_next_app "$case_dir/projects/app" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"

  out=$(run_sweep "$case_dir" 2>&1)

  assert_present "$case_dir/projects/app/packages/frontend/.next" \
    "clone: firstmate reads its project clones; the sweep must not write to them"
  pass "the sweep reclaims from pooled copies only, never the project clone"
}

# --- teardown: the copy is reclaimed on its way back to the pool -------------

# A minimal teardown sandbox: project clone, task worktree, stubs.
make_teardown_case() {  # <name>
  local case_dir=$1 dir
  dir="$TMP_ROOT/$case_dir"
  mkdir -p "$dir/state" "$dir/config" "$dir/fakebin"
  fm_fake_exit0 "$dir/fakebin" treehouse tmux gh gh-axi no-mistakes tasks-axi

  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/_seed" 2>/dev/null
  git -C "$dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$dir/_seed" push -q origin main
  rm -rf "$dir/_seed"
  git clone -q "$dir/origin.git" "$dir/project"
  git -C "$dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$dir/project" worktree add -q -b fm/task-x1 "$dir/wt" main
  touch "$dir/state/.last-watcher-beat"

  fm_write_meta "$dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"

  printf '%s\n' "$dir"
}

run_teardown() {  # <case-dir> [args...]
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

test_teardown_reclaims_before_returning_the_copy() {
  local case_dir out rc
  case_dir=$(make_teardown_case teardown-reclaim)
  add_next_app "$case_dir/wt" packages/frontend
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  out=$(run_teardown "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 0 "$rc" "teardown-reclaim: teardown should succeed"
  assert_absent "$case_dir/wt/packages/frontend/.next" \
    "teardown-reclaim: the copy must not return to the pool holding build output"
  assert_contains "$out" "reclaimed" "teardown-reclaim: teardown must report the reclaim"
  pass "teardown reclaims Next.js build output before returning the copy to the pool"
}

test_teardown_refusal_keeps_the_copy_intact() {
  local case_dir out rc
  case_dir=$(make_teardown_case teardown-refuse)
  add_next_app "$case_dir/wt" packages/frontend
  # Unlanded commit: teardown must refuse, and refusing means changing nothing.
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "unlanded work"

  set +e
  out=$(run_teardown "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 1 "$rc" "teardown-refuse: teardown should refuse unlanded work"
  assert_contains "$out" "REFUSED" "teardown-refuse: the refusal must be reported"
  assert_present "$case_dir/wt/packages/frontend/.next" \
    "teardown-refuse: a refused teardown must leave the copy exactly as it was"
  pass "a refused teardown reclaims nothing"
}

test_teardown_stays_quiet_without_build_output() {
  local case_dir out rc
  case_dir=$(make_teardown_case teardown-quiet)
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  out=$(run_teardown "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 0 "$rc" "teardown-quiet: teardown should succeed"
  assert_not_contains "$out" "reclaimed" \
    "teardown-quiet: a project that never builds must not get a reclaim line"
  pass "teardown says nothing about reclamation when there is nothing to reclaim"
}

test_sweep_reclaims_available_copy
test_sweep_reports_nothing_found
test_sweep_dry_run_removes_nothing
test_sweep_skips_in_use_copy
test_sweep_skips_copy_claimed_by_task_record
test_sweep_skips_copy_claimed_by_secondmate_task_record
test_sweep_skips_dirty_copy
test_sweep_skips_stashed_copy
test_sweep_leaves_tracked_next_directory
test_sweep_leaves_ignored_next_outside_a_next_app
test_sweep_leaves_node_modules_and_source
test_sweep_reclaims_nested_build_output_once
test_sweep_never_sweeps_the_project_clone
test_teardown_reclaims_before_returning_the_copy
test_teardown_refusal_keeps_the_copy_intact
test_teardown_stays_quiet_without_build_output
