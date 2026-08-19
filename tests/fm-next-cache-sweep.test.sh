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

# Fixture commits pass -c commit.gpgsign=false explicitly rather than relying on
# the harness to neutralize it, so a host that signs commits by default cannot
# make these cases depend on a personal signing key.
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
  git -C "$wt" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm "next app at $sub"
}

# A firstmate home with a project clone, a fake treehouse pool, and a fakebin.
# Echoes the case dir. Args: name
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" \
    "$case_dir/projects" "$case_dir/fakebin" "$case_dir/pool"
  : > "$case_dir/data/secondmates.md"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf '# app\n' > "$case_dir/_seed/README.md"
  git -C "$case_dir/_seed" add README.md
  git -C "$case_dir/_seed" -c commit.gpgsign=false -c user.email=t@t -c user.name=t \
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

install_stat_failure_stub() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
last=
for arg in "$@"; do last=$arg; done
if [ "$last" = "${FM_FAKE_STAT_FAIL:-}" ]; then exit 1; fi
exec "$FM_REAL_STAT" "$@"
SH
  chmod +x "$case_dir/fakebin/stat"
}

install_stat_empty_stub() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
last=
for arg in "$@"; do last=$arg; done
if [ "$last" = "${FM_FAKE_STAT_EMPTY:-}" ]; then exit 0; fi
exec "$FM_REAL_STAT" "$@"
SH
  chmod +x "$case_dir/fakebin/stat"
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
  git -C "$wt" -c commit.gpgsign=false -c user.email=t@t -c user.name=t stash -q
  printf '1 available\n' > "$case_dir/pool-status"

  out=$(run_sweep "$case_dir" 2>&1)

  assert_present "$wt/packages/frontend/.next" \
    "stashed: a stash is unlanded work a clean tree does not show"
  assert_contains "$out" "has stashed work" "stashed: reason must be reported"
  pass "sweep never touches a copy holding stashed work"
}

# --- sweep: incomplete ownership refuses its whole scope ---------------------
#
# The reclaim is a deletion, so the interesting question is not what happens
# when the proof succeeds - it is what happens when the proof cannot be made.
# Each case below breaks one input the sweep relies on and asserts the build
# output SURVIVES, because incomplete evidence can never authorize deletion.

test_sweep_refuses_project_with_unknown_pool_status() {
  local case_dir wt out rc
  case_dir=$(make_case unknown-status)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  # A status this version of the sweep does not know: not `available`, so not
  # proven free, even though it is not the familiar `in-use` either.
  printf '1 reserved-by-something-new\n' > "$case_dir/pool-status"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  assert_present "$wt/packages/frontend/.next" \
    "unknown-status: an unrecognized pool status is not proof the copy is free"
  expect_code 1 "$rc" \
    "unknown-status: incomplete pool ownership must refuse the project"
  assert_contains "$out" "the pool did not report it available" \
    "unknown-status: the skip reason must name what was not established"
  pass "an unrecognized pool status refuses the whole project"
}

test_sweep_skips_whole_project_when_pool_is_unreadable() {
  local case_dir wt out rc
  case_dir=$(make_case pool-unreadable)
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  # treehouse answers `status --json` with something that is not pool JSON. An
  # unparseable pool is not an empty pool and is certainly not a pool of
  # unowned copies, so no copy in this project may be swept.
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then printf 'panic: pool state corrupt
'; exit 0; fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  assert_present "$wt/packages/frontend/.next" \
    "pool-unreadable: an unreadable pool must leave every copy alone"
  assert_contains "$out" "cannot read the worktree pool" \
    "pool-unreadable: the sweep must report the project it could not read"
  [ "$rc" -ne 0 ] || fail "pool-unreadable: an unreadable pool must not report a clean sweep"
  pass "an unreadable pool sweeps nothing in that project and reports it"
}

test_sweep_skips_project_when_pool_lookup_fails() {
  local case_dir wt out rc
  case_dir=$(make_case pool-failing)
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
echo "treehouse: cannot open pool" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  assert_present "$wt/packages/frontend/.next" \
    "pool-failing: a failed pool lookup must leave every copy alone"
  [ "$rc" -ne 0 ] || fail "pool-failing: a failed pool lookup must not report a clean sweep"
  pass "a failing pool lookup sweeps nothing in that project"
}

test_sweep_skips_project_when_pool_prints_json_then_fails() {
  local case_dir wt out rc
  case_dir=$(make_case pool-json-then-failing)
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '[{"name":"1","status":"available","path":"%s/1"}]\n' "$FM_FAKE_POOL_DIR"
exit 1
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  assert_present "$wt/packages/frontend/.next" \
    "pool-json-then-failing: a failed authoritative lookup must leave every copy alone"
  [ "$rc" -ne 0 ] \
    || fail "pool-json-then-failing: a failed lookup must not report a clean sweep"
  assert_contains "$out" "cannot read the worktree pool" \
    "pool-json-then-failing: the failed lookup must be reported"
  pass "valid pool JSON cannot mask a failed treehouse lookup"
}

test_sweep_refuses_unreadable_secondmate_state() {
  local case_dir wt out rc sub
  case_dir=$(make_case unreadable-secondmate-state)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  sub="$case_dir/secondmate"
  mkdir -p "$sub/state"
  fm_write_meta "$sub/state/task-s1.meta" \
    "endpoint_task_id=task-s1" "worktree=$wt" "kind=ship" "mode=no-mistakes"
  printf -- '- helper - Helps. (home: %s; scope: things; projects: app; added 2026-08-18)\n' \
    "$sub" > "$case_dir/data/secondmates.md"
  chmod 000 "$sub/state"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e
  chmod 700 "$sub/state"

  assert_present "$wt/packages/frontend/.next" \
    "unreadable-secondmate-state: unbounded task ownership must prevent every deletion"
  expect_code 2 "$rc" \
    "unreadable-secondmate-state: an unreadable task-record source must refuse the sweep"
  assert_contains "$out" "$sub/state" \
    "unreadable-secondmate-state: the refusal must name the unreadable state directory"
  pass "an unreadable registered state directory refuses the whole sweep"
}

test_sweep_refuses_malformed_secondmate_registry() {
  local case_dir wt out rc
  case_dir=$(make_case malformed-secondmate-registry)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  printf '%s\n' '- helper - malformed registry entry' > "$case_dir/data/secondmates.md"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  assert_present "$wt/packages/frontend/.next" \
    "malformed-secondmate-registry: unbounded task ownership must prevent every deletion"
  expect_code 2 "$rc" \
    "malformed-secondmate-registry: malformed ownership input must refuse the sweep"
  assert_contains "$out" "$case_dir/data/secondmates.md" \
    "malformed-secondmate-registry: the refusal must name the malformed registry"
  pass "a malformed secondmate record refuses the whole sweep"
}

test_sweep_refuses_absent_secondmate_home() {
  local case_dir wt out rc absent
  case_dir=$(make_case absent-secondmate-home)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  absent="$case_dir/absent-secondmate"
  printf -- '- helper - Helps. (home: %s; scope: things; projects: app; added 2026-08-18)\n' \
    "$absent" > "$case_dir/data/secondmates.md"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 2 "$rc" \
    "absent-secondmate-home: an absent ownership source must refuse the sweep"
  assert_present "$wt/packages/frontend/.next" \
    "absent-secondmate-home: strict completeness must preserve the build output"
  assert_contains "$out" "$absent" \
    "absent-secondmate-home: the refusal must name the absent home"
  pass "an absent registered local home refuses the whole sweep"
}

test_sweep_refuses_relative_secondmate_home() {
  local case_dir wt out rc
  case_dir=$(make_case relative-secondmate-home)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  printf '%s\n' \
    '- helper - Helps. (home: relative-home; scope: things; projects: app; added 2026-08-18)' \
    > "$case_dir/data/secondmates.md"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 2 "$rc" \
    "relative-secondmate-home: an unsafe ownership source must refuse the sweep"
  assert_present "$wt/packages/frontend/.next" \
    "relative-secondmate-home: an unresolved registry home must prevent deletion"
  assert_contains "$out" "relative-home" \
    "relative-secondmate-home: the refusal must name the unsafe home"
  pass "a relative registered local home refuses the whole sweep"
}

test_sweep_refuses_unreadable_secondmate_registry() {
  local case_dir wt out rc registry
  case_dir=$(make_case unreadable-secondmate-registry)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  registry="$case_dir/data/secondmates.md"
  chmod 000 "$registry"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e
  chmod 600 "$registry"

  expect_code 2 "$rc" \
    "unreadable-secondmate-registry: unreadable global ownership must refuse the sweep"
  assert_present "$wt/packages/frontend/.next" \
    "unreadable-secondmate-registry: unreadable ownership must prevent deletion"
  assert_contains "$out" "$registry" \
    "unreadable-secondmate-registry: the refusal must name the registry"
  pass "an unreadable secondmate registry refuses the whole sweep"
}

test_sweep_refuses_absent_secondmate_registry() {
  local case_dir wt out rc registry
  case_dir=$(make_case absent-secondmate-registry)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  registry="$case_dir/data/secondmates.md"
  rm -f "$registry"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 2 "$rc" \
    "absent-secondmate-registry: absent global ownership must refuse the sweep"
  assert_present "$wt/packages/frontend/.next" \
    "absent-secondmate-registry: absent ownership input must prevent deletion"
  assert_contains "$out" "$registry" \
    "absent-secondmate-registry: the refusal must name the missing registry"
  pass "an absent secondmate registry refuses the whole sweep"
}

test_sweep_skips_symlink_aliased_task_worktree() {
  local case_dir wt out alias
  case_dir=$(make_case symlink-task-alias)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  alias="$case_dir/pool-alias"
  ln -s "$case_dir/pool" "$alias"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "endpoint_task_id=task-x1" "worktree=$alias/1" \
    "project=$case_dir/projects/app" "kind=ship" "mode=no-mistakes"

  out=$(run_sweep "$case_dir" 2>&1)

  assert_present "$wt/packages/frontend/.next" \
    "symlink-task-alias: an aliased task path must protect the same worktree"
  assert_contains "$out" "still claimed by a task record" \
    "symlink-task-alias: the filesystem identity match must be reported as owned"
  pass "task ownership follows filesystem identity through a symlinked prefix"
}

test_sweep_skips_final_symlink_aliased_task_worktree() {
  local case_dir wt out alias
  case_dir=$(make_case final-symlink-task-alias)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  alias="$case_dir/task-worktree-link"
  ln -s "$wt" "$alias"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "endpoint_task_id=task-x1" "worktree=$alias" \
    "project=$case_dir/projects/app" "kind=ship" "mode=no-mistakes"

  out=$(run_sweep "$case_dir" 2>&1)

  assert_present "$wt/packages/frontend/.next" \
    "final-symlink-task-alias: task ownership must follow the final symlink"
  assert_contains "$out" "still claimed by a task record" \
    "final-symlink-task-alias: resolved filesystem identity must be reported as owned"
  pass "task ownership resolves a final symlink to its worktree"
}

test_sweep_refuses_broken_task_worktree_symlink() {
  local case_dir wt out rc alias
  case_dir=$(make_case broken-task-worktree-link)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  alias="$case_dir/broken-task-worktree-link"
  ln -s "$case_dir/missing-task-worktree" "$alias"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "endpoint_task_id=task-x1" "worktree=$alias" \
    "project=$case_dir/projects/app" "kind=ship" "mode=no-mistakes"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 2 "$rc" \
    "broken-task-worktree-link: unresolved global task identity must refuse the sweep"
  assert_present "$wt/packages/frontend/.next" \
    "broken-task-worktree-link: unresolved task identity must prevent deletion"
  assert_contains "$out" "$alias" \
    "broken-task-worktree-link: the refusal must name the unresolved task path"
  pass "a broken task-worktree symlink refuses the whole sweep"
}

test_sweep_skips_case_aliased_task_worktree() {
  local case_dir wt out alias
  case_dir=$(make_case case-task-alias)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  if [ ! -d "$case_dir/POOL/1" ]; then
    pass "SKIP (case-sensitive filesystem): case-aliased task ownership"
    return 0
  fi
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  alias="$case_dir/POOL/1"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "endpoint_task_id=task-x1" "worktree=$alias" \
    "project=$case_dir/projects/app" "kind=ship" "mode=no-mistakes"

  out=$(run_sweep "$case_dir" 2>&1)

  assert_present "$wt/packages/frontend/.next" \
    "case-task-alias: differently cased spelling must protect the same worktree"
  assert_contains "$out" "still claimed by a task record" \
    "case-task-alias: the filesystem identity match must be reported as owned"
  pass "task ownership follows filesystem identity across case aliases"
}

test_sweep_refuses_when_candidate_identity_is_unreadable() {
  local case_dir wt out rc real_stat
  case_dir=$(make_case candidate-identity-unreadable)
  install_treehouse_stub "$case_dir"
  install_stat_failure_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  real_stat=$(command -v stat)

  set +e
  out=$(FM_REAL_STAT="$real_stat" FM_FAKE_STAT_FAIL="$wt" \
    run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  assert_present "$wt/packages/frontend/.next" \
    "candidate-identity-unreadable: unresolved candidate identity must prevent deletion"
  expect_code 1 "$rc" \
    "candidate-identity-unreadable: incomplete project ownership must return nonzero"
  assert_contains "$out" "$wt" \
    "candidate-identity-unreadable: the refusal must name the candidate"
  pass "an unreadable candidate identity refuses the whole project"
}

test_sweep_refuses_when_recorded_identity_is_unreadable() {
  local case_dir wt out rc alias real_stat
  case_dir=$(make_case recorded-identity-unreadable)
  install_treehouse_stub "$case_dir"
  install_stat_failure_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  alias="$case_dir/pool-alias"
  ln -s "$case_dir/pool" "$alias"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "endpoint_task_id=task-x1" "worktree=$alias/1" \
    "project=$case_dir/projects/app" "kind=ship" "mode=no-mistakes"
  real_stat=$(command -v stat)

  set +e
  out=$(FM_REAL_STAT="$real_stat" FM_FAKE_STAT_FAIL="$wt" \
    run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  assert_present "$wt/packages/frontend/.next" \
    "recorded-identity-unreadable: unresolved recorded identity must prevent deletion"
  expect_code 2 "$rc" \
    "recorded-identity-unreadable: incomplete global ownership must refuse the sweep"
  assert_contains "$out" "$alias/1" \
    "recorded-identity-unreadable: the refusal must name the recorded path"
  pass "an unreadable existing task path refuses the whole sweep"
}

test_sweep_preserves_task_owner_when_grep_fails() {
  local case_dir wt out real_grep
  case_dir=$(make_case task-owner-grep-failure)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "endpoint_task_id=task-x1" "worktree=$wt" "project=$case_dir/projects/app" \
    "kind=ship" "mode=no-mistakes"
  real_grep=$(command -v grep)
  cat > "$case_dir/fakebin/grep" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = -Fxq ]; then exit 2; fi
done
exec "$FM_REAL_GREP" "$@"
SH
  chmod +x "$case_dir/fakebin/grep"

  out=$(FM_REAL_GREP="$real_grep" run_sweep "$case_dir" 2>&1)

  assert_present "$wt/packages/frontend/.next" \
    "task-owner-grep-failure: a failed comparison tool must not erase task ownership"
  assert_contains "$out" "still claimed by a task record" \
    "task-owner-grep-failure: exact task ownership must remain determinate"
  pass "task ownership cannot become a no-match when grep fails"
}

test_sweep_refuses_empty_candidate_identity() {
  local case_dir wt out rc real_stat
  case_dir=$(make_case empty-candidate-identity)
  install_treehouse_stub "$case_dir"
  install_stat_empty_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  real_stat=$(command -v stat)

  set +e
  out=$(FM_REAL_STAT="$real_stat" FM_FAKE_STAT_EMPTY="$wt" \
    run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 1 "$rc" "empty-candidate-identity: empty identity output must be incomplete"
  assert_present "$wt/packages/frontend/.next" \
    "empty-candidate-identity: empty stat output must not prove the copy unowned"
  assert_contains "$out" "$wt" \
    "empty-candidate-identity: the incomplete candidate must be named"
  pass "empty filesystem identity output refuses the project"
}

test_sweep_refuses_nul_task_metadata() {
  local case_dir wt out rc meta
  case_dir=$(make_case nul-task-metadata)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  meta="$case_dir/state/task-x1.meta"
  {
    printf 'endpoint_task_id=task-x1\nworktree=%s\nkind=secondmate\n' "$wt"
    printf 'remote_host=helper\0\n'
  } > "$meta"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 2 "$rc" "nul-task-metadata: malformed global ownership must refuse"
  assert_present "$wt/packages/frontend/.next" \
    "nul-task-metadata: NUL normalization must not hide a local task owner"
  assert_contains "$out" "$meta" \
    "nul-task-metadata: the malformed ownership file must be named"
  pass "NUL-bearing task metadata refuses the whole sweep"
}

test_sweep_refuses_nul_secondmate_registry() {
  local case_dir wt out rc registry
  case_dir=$(make_case nul-secondmate-registry)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  registry="$case_dir/data/secondmates.md"
  printf 'registry\0record\n' > "$registry"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 2 "$rc" "nul-secondmate-registry: malformed global ownership must refuse"
  assert_present "$wt/packages/frontend/.next" \
    "nul-secondmate-registry: an incompletely readable registry must prevent deletion"
  assert_contains "$out" "$registry" \
    "nul-secondmate-registry: the malformed registry must be named"
  pass "a NUL-bearing secondmate registry refuses the whole sweep"
}

test_sweep_refuses_nul_pool_status() {
  local case_dir wt out rc
  case_dir=$(make_case nul-pool-status)
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
python3 - "$FM_FAKE_POOL_DIR" <<'PY'
import json, sys
print(json.dumps([{"status": "avail\x00able", "path": sys.argv[1] + "/1"}]))
PY
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 1 "$rc" "nul-pool-status: malformed pool input must return nonzero"
  assert_present "$wt/packages/frontend/.next" \
    "nul-pool-status: NUL normalization must not forge available status"
  assert_contains "$out" "worktree pool" \
    "nul-pool-status: the malformed pool must be reported"
  pass "a NUL-bearing pool field cannot forge availability"
}

test_sweep_refuses_conflicting_alias_pool_entries() {
  local case_dir wt alias out rc
  case_dir=$(make_case conflicting-alias-pool-entries)
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  alias="$case_dir/pool-copy-alias"
  ln -s "$wt" "$alias"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '[{"status":"in-use","path":"%s/1"},{"status":"available","path":"%s"}]\n' \
  "$FM_FAKE_POOL_DIR" "$FM_FAKE_POOL_ALIAS"
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  out=$(FM_FAKE_POOL_ALIAS="$alias" run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 1 "$rc" "conflicting-alias-pool-entries: ambiguous pool input must refuse"
  assert_present "$wt/packages/frontend/.next" \
    "conflicting-alias-pool-entries: available alias must not override an in-use copy"
  assert_contains "$out" "duplicate filesystem copy" \
    "conflicting-alias-pool-entries: the pool collision must be named"
  pass "conflicting pool aliases refuse the project atomically"
}

test_sweep_refuses_pathless_pool_entry_atomically() {
  local case_dir wt out rc
  case_dir=$(make_case pathless-pool-entry)
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '[{"status":"available","path":"%s/1"},{"status":"available"}]\n' \
  "$FM_FAKE_POOL_DIR"
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 1 "$rc" "pathless-pool-entry: incomplete pool input must return nonzero"
  assert_present "$wt/packages/frontend/.next" \
    "pathless-pool-entry: no earlier entry may be reclaimed from an incomplete pool"
  assert_contains "$out" "worktree pool" \
    "pathless-pool-entry: the incomplete pool must be reported"
  pass "a pathless pool entry refuses its project before any deletion"
}

test_sweep_refuses_nondirectory_pool_entry_atomically() {
  local case_dir wt out rc
  case_dir=$(make_case nondirectory-pool-entry)
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf 'not a directory\n' > "$case_dir/pool/not-a-directory"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '[{"status":"available","path":"%s/1"},{"status":"available","path":"%s/not-a-directory"}]\n' \
  "$FM_FAKE_POOL_DIR" "$FM_FAKE_POOL_DIR"
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 1 "$rc" \
    "nondirectory-pool-entry: an uninspectable pool path must return nonzero"
  assert_present "$wt/packages/frontend/.next" \
    "nondirectory-pool-entry: project preflight must precede every deletion"
  assert_contains "$out" "$case_dir/pool/not-a-directory" \
    "nondirectory-pool-entry: the refusal must name the invalid path"
  pass "a nondirectory pool entry refuses its project before any deletion"
}

test_sweep_reports_incomplete_project_count() {
  local case_dir out rc
  case_dir=$(make_case incomplete-summary)
  git clone -q "$case_dir/origin.git" "$case_dir/projects/empty"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "$(basename "$PWD")" = app ]; then exit 1; fi
printf '[]\n'
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  out=$(run_sweep "$case_dir" \
    "$case_dir/projects/app" "$case_dir/projects/empty" 2>&1); rc=$?
  set -e

  expect_code 1 "$rc" "incomplete-summary: a partial sweep must return nonzero"
  assert_not_contains "$out" "no idle copy holds Next.js build output" \
    "incomplete-summary: unreadable projects make the absolute empty claim false"
  assert_contains "$out" "1 project" \
    "incomplete-summary: the summary must count projects that could not be inspected"
  assert_contains "$out" "could not be inspected" \
    "incomplete-summary: the summary must state that the result is incomplete"
  pass "an incomplete sweep qualifies its summary with the unreadable project count"
}

test_sweep_refuses_without_treehouse() {
  local case_dir wt out rc path_dir cmd resolved
  case_dir=$(make_case no-treehouse)
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  # A PATH with the ordinary tools but no treehouse at all: without the pool's
  # lease there is no ownership signal that spans firstmate homes, so the sweep
  # must refuse rather than fall back to the checks it can still make.
  path_dir="$case_dir/path-without-treehouse"
  mkdir -p "$path_dir"
  for cmd in awk basename bash cat chmod cut dirname du env find git grep head mkdir \
    printf python3 readlink rm sed sort stat tail tr wc; do
    resolved=$(command -v "$cmd" 2>/dev/null) || continue
    case "$resolved" in /*) ln -sf "$resolved" "$path_dir/$cmd" ;; esac
  done

  set +e
  out=$(FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_PROJECTS_OVERRIDE="$case_dir/projects" \
    PATH="$path_dir" "$SWEEP" 2>&1); rc=$?
  set -e

  assert_present "$wt/packages/frontend/.next" \
    "no-treehouse: without the pool's lease the sweep must remove nothing"
  expect_code 2 "$rc" "no-treehouse: a missing ownership signal is an environment error"
  assert_contains "$out" "treehouse is not installed" \
    "no-treehouse: the refusal must name the missing requirement"
  pass "the sweep refuses outright when the pool's lease cannot be consulted"
}

test_sweep_refuses_uninspectable_worktree_project() {
  local case_dir wt out rc
  case_dir=$(make_case uninspectable)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  # The pool still names this path, but it is no longer a git worktree, so the
  # clean-tree and stash proofs cannot be made at all.
  rm -f "$wt/.git"
  rm -rf "$wt/.git"
  printf '1 available\n' > "$case_dir/pool-status"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  assert_present "$wt/packages/frontend/.next" \
    "uninspectable: a path git cannot inspect must keep its build output"
  expect_code 1 "$rc" \
    "uninspectable: incomplete project ownership must return nonzero"
  assert_contains "$out" "not an inspectable git worktree" \
    "uninspectable: the refusal reason must be reported"
  assert_contains "$out" "$wt" \
    "uninspectable: the refused copy must be named"
  pass "a copy git cannot inspect refuses the whole project"
}

test_sweep_refuses_project_when_git_inspection_fails() {
  local case_dir wt out rc gitdir
  case_dir=$(make_case git-failing)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  # The worktree still looks like a repo, but its object store is gone, so
  # `git status` cannot answer whether there is uncommitted work. Unknown is
  # not clean.
  gitdir=$(git -C "$wt" rev-parse --git-dir)
  gitdir=$(cd "$wt" && cd "$gitdir" && pwd -P)
  mv "$gitdir/index" "$gitdir/index.moved" 2>/dev/null || true
  printf 'not an index\n' > "$gitdir/index"
  printf '1 available\n' > "$case_dir/pool-status"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  assert_present "$wt/packages/frontend/.next" \
    "git-failing: an unanswerable clean-tree check must keep the build output"
  expect_code 1 "$rc" \
    "git-failing: incomplete project ownership must return nonzero"
  assert_contains "$out" "cannot inspect it" \
    "git-failing: the refusal reason must say the inspection failed"
  assert_contains "$out" "$wt" \
    "git-failing: the refused copy must be named"
  pass "an unreadable git state refuses the whole project"
}

test_sweep_refuses_implicit_project_with_unreadable_git_metadata() {
  local case_dir out rc broken
  case_dir=$(make_case implicit-project-git-failure)
  broken="$case_dir/projects/broken"
  mkdir -p "$broken/.git"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '[]\n'
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  out=$(run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 1 "$rc" \
    "implicit-project-git-failure: an uninspectable discovered project must count"
  assert_not_contains "$out" "no idle copy holds Next.js build output" \
    "implicit-project-git-failure: silently omitted projects make the clean claim false"
  assert_contains "$out" "$broken" \
    "implicit-project-git-failure: the uninspectable project must be named"
  pass "implicit discovery records projects whose Git metadata is uninspectable"
}

test_sweep_refuses_when_build_output_walk_fails() {
  local case_dir wt out rc real_find
  case_dir=$(make_case build-output-walk-failure)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  real_find=$(command -v find)
  cat > "$case_dir/fakebin/find" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "$FM_FAKE_FIND_ROOT" ]; then
  for arg in "$@"; do
    if [ "$arg" = -print0 ]; then
      printf '%s\0' "$FM_FAKE_FIND_PATH"
      exit 1
    fi
  done
  printf '%s\n' "$FM_FAKE_FIND_PATH"
  exit 1
fi
exec "$FM_REAL_FIND" "$@"
SH
  chmod +x "$case_dir/fakebin/find"

  set +e
  out=$(FM_REAL_FIND="$real_find" FM_FAKE_FIND_ROOT="$wt" \
    FM_FAKE_FIND_PATH="$wt/packages/frontend/.next" \
    run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 1 "$rc" "build-output-walk-failure: a partial walk must be incomplete"
  assert_present "$wt/packages/frontend/.next" \
    "build-output-walk-failure: partial discovery must precede no deletion"
  assert_contains "$out" "$wt" \
    "build-output-walk-failure: the incompletely walked copy must be named"
  pass "a partial build-output walk refuses the project atomically"
}

test_sweep_refuses_when_build_output_size_fails() {
  local case_dir wt out rc real_du
  case_dir=$(make_case build-output-size-failure)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  real_du=$(command -v du)
  cat > "$case_dir/fakebin/du" <<'SH'
#!/usr/bin/env bash
last=
for arg in "$@"; do last=$arg; done
if [ "$last" = "$FM_FAKE_DU_PATH" ]; then exit 1; fi
exec "$FM_REAL_DU" "$@"
SH
  chmod +x "$case_dir/fakebin/du"

  set +e
  out=$(FM_REAL_DU="$real_du" FM_FAKE_DU_PATH="$wt/packages/frontend/.next" \
    run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 1 "$rc" "build-output-size-failure: an unmeasurable cache must be incomplete"
  assert_present "$wt/packages/frontend/.next" \
    "build-output-size-failure: failed measurement must not normalize to empty"
  assert_contains "$out" "$wt" \
    "build-output-size-failure: the unmeasurable copy must be named"
  pass "an unmeasurable build-output directory refuses the project"
}

test_sweep_refuses_when_package_inspection_fails() {
  local case_dir wt app out rc real_grep
  case_dir=$(make_case package-inspection-failure)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  app="$wt/packages/frontend"
  mkdir -p "$app/.next"
  printf '{"dependencies":{"next":"16.3.0"}}\n' > "$app/package.json"
  printf 'build\n' > "$app/.next/BUILD_ID"
  printf 'packages/frontend/.next\n' >> "$wt/.gitignore"
  git -C "$wt" add -A >/dev/null 2>&1
  git -C "$wt" -c commit.gpgsign=false -c user.email=t@t -c user.name=t \
    commit -qm "package-only next app"
  printf '1 available\n' > "$case_dir/pool-status"
  real_grep=$(command -v grep)
  cat > "$case_dir/fakebin/grep" <<'SH'
#!/usr/bin/env bash
last=
for arg in "$@"; do last=$arg; done
if [ "$last" = "$FM_FAKE_GREP_PATH" ]; then exit 2; fi
exec "$FM_REAL_GREP" "$@"
SH
  chmod +x "$case_dir/fakebin/grep"

  set +e
  out=$(FM_REAL_GREP="$real_grep" FM_FAKE_GREP_PATH="$app/package.json" \
    run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 1 "$rc" "package-inspection-failure: failed app proof must be incomplete"
  assert_present "$app/.next" \
    "package-inspection-failure: a failed app proof must not read as not-an-app"
  assert_contains "$out" "$wt" \
    "package-inspection-failure: the incompletely inspected copy must be named"
  pass "a failed package inspection refuses the project"
}

test_sweep_refuses_when_gitignore_inspection_fails() {
  local case_dir wt out rc real_git
  case_dir=$(make_case gitignore-inspection-failure)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  real_git=$(command -v git)
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = check-ignore ]; then exit 2; fi
done
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$case_dir/fakebin/git"

  set +e
  out=$(FM_REAL_GIT="$real_git" run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 1 "$rc" "gitignore-inspection-failure: failed ignore proof must be incomplete"
  assert_present "$wt/packages/frontend/.next" \
    "gitignore-inspection-failure: a Git error must not read as not ignored"
  assert_contains "$out" "$wt" \
    "gitignore-inspection-failure: the incompletely inspected copy must be named"
  pass "a failed gitignore inspection refuses the project"
}

test_sweep_refuses_worktree_that_becomes_unenterable() {
  local case_dir wt out rc real_git
  case_dir=$(make_case worktree-becomes-unenterable)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  real_git=$(command -v git)
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "$FM_FAKE_UNENTERABLE_WT" ] \
  && [ "${3:-}" = stash ] && [ "${4:-}" = list ]; then
  "$FM_REAL_GIT" "$@"
  rc=$?
  chmod 000 "$FM_FAKE_UNENTERABLE_WT"
  exit "$rc"
fi
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$case_dir/fakebin/git"

  set +e
  out=$(FM_REAL_GIT="$real_git" FM_FAKE_UNENTERABLE_WT="$wt" \
    run_sweep "$case_dir" 2>&1); rc=$?
  set -e
  chmod 700 "$wt"

  expect_code 1 "$rc" "worktree-becomes-unenterable: failed entry must be incomplete"
  assert_present "$wt/packages/frontend/.next" \
    "worktree-becomes-unenterable: failed entry must not read as no build output"
  assert_not_contains "$out" "no idle copy holds Next.js build output" \
    "worktree-becomes-unenterable: no inspected copy means no clean empty claim"
  pass "a worktree that cannot be entered is reported as incomplete"
}

test_sweep_reports_human_size_without_awk() {
  local case_dir wt out real_awk
  case_dir=$(make_case human-size-without-awk)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  head -c 2097152 /dev/zero > "$wt/packages/frontend/.next/static/large.js"
  printf '1 available\n' > "$case_dir/pool-status"
  real_awk=$(command -v awk)
  cat > "$case_dir/fakebin/awk" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = -v ]; then exit 2; fi
done
exec "$FM_REAL_AWK" "$@"
SH
  chmod +x "$case_dir/fakebin/awk"

  out=$(FM_REAL_AWK="$real_awk" run_sweep "$case_dir" 2>&1)

  assert_absent "$wt/packages/frontend/.next" \
    "human-size-without-awk: healthy build output must still be reclaimed"
  assert_not_contains "$out" "reclaimed  of Next.js build output" \
    "human-size-without-awk: a formatter failure must not erase the reported size"
  pass "human-readable reclaim sizes do not depend on an unchecked formatter"
}

test_sweep_records_failed_removal() {
  local case_dir wt out rc real_rm
  case_dir=$(make_case failed-removal)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  real_rm=$(command -v rm)
  cat > "$case_dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
last=
for arg in "$@"; do last=$arg; done
if [ "$last" = "$FM_FAKE_RM_PATH" ]; then exit 1; fi
exec "$FM_REAL_RM" "$@"
SH
  chmod +x "$case_dir/fakebin/rm"

  set +e
  out=$(FM_REAL_RM="$real_rm" FM_FAKE_RM_PATH="$wt/packages/frontend/.next" \
    run_sweep "$case_dir" 2>&1); rc=$?
  set -e

  expect_code 1 "$rc" "failed-removal: a failed deletion must return nonzero"
  assert_present "$wt/packages/frontend/.next" \
    "failed-removal: failed deletion must leave the directory present"
  assert_not_contains "$out" "no idle copy holds Next.js build output" \
    "failed-removal: a retained cache makes the clean empty claim false"
  assert_contains "$out" "could not be processed" \
    "failed-removal: the summary must count the failed copy"
  pass "a failed removal is a named summary outcome"
}

test_sweep_records_dry_run_inspection_failure() {
  local case_dir wt out rc real_find counter
  case_dir=$(make_case dry-run-inspection-failure)
  install_treehouse_stub "$case_dir"
  wt=$(add_pool_worktree "$case_dir" 1)
  add_next_app "$wt" packages/frontend
  printf '1 available\n' > "$case_dir/pool-status"
  real_find=$(command -v find)
  counter="$case_dir/find-count"
  cat > "$case_dir/fakebin/find" <<'SH'
#!/usr/bin/env bash
count=0
if [ -f "$FM_FAKE_FIND_COUNT" ]; then count=$(sed -n '1p' "$FM_FAKE_FIND_COUNT"); fi
count=$(( count + 1 ))
printf '%s\n' "$count" > "$FM_FAKE_FIND_COUNT"
if [ "$count" -gt 1 ]; then exit 1; fi
exec "$FM_REAL_FIND" "$@"
SH
  chmod +x "$case_dir/fakebin/find"

  set +e
  out=$(FM_REAL_FIND="$real_find" FM_FAKE_FIND_COUNT="$counter" \
    run_sweep "$case_dir" --dry-run 2>&1); rc=$?
  set -e

  expect_code 1 "$rc" "dry-run-inspection-failure: a failed report must return nonzero"
  assert_present "$wt/packages/frontend/.next" \
    "dry-run-inspection-failure: dry run must leave build output present"
  assert_contains "$out" "could not be processed" \
    "dry-run-inspection-failure: the summary must count the failed report"
  pass "a dry-run report failure is a named summary outcome"
}

test_sweep_distinguishes_empty_pool_from_uninspected_copy() {
  local case_dir out
  case_dir=$(make_case empty-pool)
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '[]\n'
SH
  chmod +x "$case_dir/fakebin/treehouse"

  out=$(run_sweep "$case_dir" 2>&1)

  assert_not_contains "$out" "no idle copy holds Next.js build output" \
    "empty-pool: zero inspected copies must not select the copy-level clean claim"
  assert_contains "$out" "contained no copies" \
    "empty-pool: a completely read empty pool must get its own determinate summary"
  pass "an empty pool is distinct from a copy that could not be inspected"
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
  git -C "$wt" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm "tracked .next fixture"
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
  git -C "$wt" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm "ignored non-app .next"
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
  git -C "$wt" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm "ignore node_modules"
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
  git -C "$dir/_seed" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
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

test_teardown_reclaims_only_after_the_copy_is_quiet() {
  local case_dir out rc pid order
  case_dir=$(make_teardown_case teardown-order)
  add_next_app "$case_dir/wt" packages/frontend
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  order="$case_dir/order.log"

  # Teardown's answer to "what if the copy is not really finished with" is
  # ordering: the reclaim runs after every unlanded-work refusal has passed AND
  # after the worktree's processes are reaped, so nothing can still be writing
  # the directory it removes. This stub stands where the pool return happens -
  # the step right after the reclaim - and records what was true by then.
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ -e "$case_dir/wt/packages/frontend/.next" ]; then
  printf 'build-output-still-present\n' >> "$order"
else
  printf 'build-output-already-reclaimed\n' >> "$order"
fi
if kill -0 "\$(cat "$case_dir/sleeper.pid" 2>/dev/null || echo 0)" 2>/dev/null; then
  printf 'worktree-process-still-alive\n' >> "$order"
else
  printf 'worktree-process-already-reaped\n' >> "$order"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  # A live process whose working directory is the copy - exactly what teardown's
  # reap exists to clear, and exactly what would still be writing the build
  # output if the reclaim ran too early.
  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown 2>/dev/null || true
  printf '%s\n' "$pid" > "$case_dir/sleeper.pid"
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "teardown-order: setup sleeper did not start"

  set +e
  out=$(run_teardown "$case_dir" 2>&1); rc=$?
  set -e
  kill -KILL "$pid" 2>/dev/null || true

  expect_code 0 "$rc" "teardown-order: teardown should succeed"
  assert_grep "build-output-already-reclaimed" "$order" \
    "teardown-order: the reclaim must happen before the copy returns to the pool"
  assert_grep "worktree-process-already-reaped" "$order" \
    "teardown-order: nothing may still be running in the copy when its output is removed"
  pass "teardown reclaims only after the copy's processes are reaped and before it returns"
}

test_teardown_refusal_keeps_the_copy_intact() {
  local case_dir out rc
  case_dir=$(make_teardown_case teardown-refuse)
  add_next_app "$case_dir/wt" packages/frontend
  # Unlanded commit: teardown must refuse, and refusing means changing nothing.
  git -C "$case_dir/wt" -c commit.gpgsign=false -c user.email=t@t -c user.name=t \
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

run_next_cache_test() {
  if [ -z "${FM_NEXT_CACHE_TEST:-}" ] || [ "$FM_NEXT_CACHE_TEST" = "$1" ]; then
    "$1"
  fi
}

run_next_cache_test test_sweep_reclaims_available_copy
run_next_cache_test test_sweep_reports_nothing_found
run_next_cache_test test_sweep_dry_run_removes_nothing
run_next_cache_test test_sweep_skips_in_use_copy
run_next_cache_test test_sweep_skips_copy_claimed_by_task_record
run_next_cache_test test_sweep_skips_copy_claimed_by_secondmate_task_record
run_next_cache_test test_sweep_skips_dirty_copy
run_next_cache_test test_sweep_skips_stashed_copy
run_next_cache_test test_sweep_refuses_project_with_unknown_pool_status
run_next_cache_test test_sweep_skips_whole_project_when_pool_is_unreadable
run_next_cache_test test_sweep_skips_project_when_pool_lookup_fails
run_next_cache_test test_sweep_skips_project_when_pool_prints_json_then_fails
run_next_cache_test test_sweep_refuses_unreadable_secondmate_state
run_next_cache_test test_sweep_refuses_malformed_secondmate_registry
run_next_cache_test test_sweep_refuses_absent_secondmate_home
run_next_cache_test test_sweep_refuses_relative_secondmate_home
run_next_cache_test test_sweep_refuses_unreadable_secondmate_registry
run_next_cache_test test_sweep_refuses_absent_secondmate_registry
run_next_cache_test test_sweep_skips_symlink_aliased_task_worktree
run_next_cache_test test_sweep_skips_final_symlink_aliased_task_worktree
run_next_cache_test test_sweep_refuses_broken_task_worktree_symlink
run_next_cache_test test_sweep_skips_case_aliased_task_worktree
run_next_cache_test test_sweep_refuses_when_candidate_identity_is_unreadable
run_next_cache_test test_sweep_refuses_when_recorded_identity_is_unreadable
run_next_cache_test test_sweep_preserves_task_owner_when_grep_fails
run_next_cache_test test_sweep_refuses_empty_candidate_identity
run_next_cache_test test_sweep_refuses_nul_task_metadata
run_next_cache_test test_sweep_refuses_nul_secondmate_registry
run_next_cache_test test_sweep_refuses_nul_pool_status
run_next_cache_test test_sweep_refuses_conflicting_alias_pool_entries
run_next_cache_test test_sweep_refuses_pathless_pool_entry_atomically
run_next_cache_test test_sweep_refuses_nondirectory_pool_entry_atomically
run_next_cache_test test_sweep_reports_incomplete_project_count
run_next_cache_test test_sweep_refuses_without_treehouse
run_next_cache_test test_sweep_refuses_uninspectable_worktree_project
run_next_cache_test test_sweep_refuses_project_when_git_inspection_fails
run_next_cache_test test_sweep_refuses_implicit_project_with_unreadable_git_metadata
run_next_cache_test test_sweep_refuses_when_build_output_walk_fails
run_next_cache_test test_sweep_refuses_when_build_output_size_fails
run_next_cache_test test_sweep_refuses_when_package_inspection_fails
run_next_cache_test test_sweep_refuses_when_gitignore_inspection_fails
run_next_cache_test test_sweep_refuses_worktree_that_becomes_unenterable
run_next_cache_test test_sweep_reports_human_size_without_awk
run_next_cache_test test_sweep_records_failed_removal
run_next_cache_test test_sweep_records_dry_run_inspection_failure
run_next_cache_test test_sweep_distinguishes_empty_pool_from_uninspected_copy
run_next_cache_test test_sweep_leaves_tracked_next_directory
run_next_cache_test test_sweep_leaves_ignored_next_outside_a_next_app
run_next_cache_test test_sweep_leaves_node_modules_and_source
run_next_cache_test test_sweep_reclaims_nested_build_output_once
run_next_cache_test test_sweep_never_sweeps_the_project_clone
run_next_cache_test test_teardown_reclaims_before_returning_the_copy
run_next_cache_test test_teardown_reclaims_only_after_the_copy_is_quiet
run_next_cache_test test_teardown_refusal_keeps_the_copy_intact
run_next_cache_test test_teardown_stays_quiet_without_build_output
