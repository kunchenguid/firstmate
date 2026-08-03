#!/usr/bin/env bash
# Behavior tests for a task's two base references (bin/fm-task-base-lib.sh) and
# for the way bin/fm-spawn.sh and bin/fm-brief.sh carry them.
#
# The defect these guard: a dispatched worker's worktree sat at the UPSTREAM
# trunk while the fleet ran a fork trunk 33 commits ahead, so every brief citing
# a file or a line number was silently wrong - one task found a script its brief
# cited ENTIRELY ABSENT from its own base. Neither single ref fixes it: the fork
# trunk carries fleet-only commits into every upstream PR, and the upstream trunk
# lacks the code the task edits. So two refs are resolved and kept apart.
#
# The central test here is test_guard_catches_a_branch_cut_from_the_slot_base:
# it CONSTRUCTS the polluted branch and watches the guard refuse it. Correctness
# is never inferred from an empty result - every refusal is paired with the
# positive control that must still pass.
#
# The fixtures build the real diverged topology rather than a fast-forward one:
# upstream holds a commit the fork lacks AND the fork holds commits upstream
# lacks, so a merge-base test cannot pass by accident.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-base)

# shellcheck source=bin/fm-ff-lib.sh
. "$ROOT/bin/fm-ff-lib.sh"
# shellcheck source=bin/fm-task-base-lib.sh
. "$ROOT/bin/fm-task-base-lib.sh"

git_q() { git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "${@:2}"; }

commit_in() {  # <repo> <message>
  local repo=$1 msg=$2
  printf '%s\n' "$msg" >> "$repo/log.txt"
  git_q "$repo" add log.txt
  git_q "$repo" commit -qm "$msg"
}

# The real topology: a common base, an upstream-only commit, and fleet-only
# commits on the local trunk, with origin FETCHING upstream and PUSHING a fork.
# That is firstmate's own layout, and it is genuinely diverged in both
# directions. Echoes the local repo path.
make_fork_repo() {  # <name> <fleet-commits>
  local name=$1 fleet=$2 dir up fork seed scratch i
  dir="$TMP_ROOT/$name"
  up="$dir/upstream.git"; fork="$dir/fork.git"; seed="$dir/seed"; scratch="$dir/scratch"
  mkdir -p "$seed"
  git -C "$seed" init -q
  git -C "$seed" symbolic-ref HEAD refs/heads/main
  commit_in "$seed" base
  git clone --quiet --bare "$seed" "$up"
  git clone --quiet --bare "$seed" "$fork"
  # An upstream-only commit, so the two trunks diverge instead of fast-forward.
  git clone --quiet "$up" "$scratch"
  commit_in "$scratch" upstream-only
  git -C "$scratch" push --quiet origin main
  # The local checkout: fleet-only commits on the local trunk, never pushed.
  git clone --quiet "$up" "$dir/repo"
  git -C "$dir/repo" reset --hard --quiet HEAD~1 2>/dev/null || true
  i=0
  while [ "$i" -lt "$fleet" ]; do
    i=$((i + 1))
    commit_in "$dir/repo" "fleet-only-$i"
  done
  git -C "$dir/repo" fetch --quiet origin
  git -C "$dir/repo" remote set-url --push origin "$fork"
  printf '%s\n' "$dir/repo"
}

# The two references differ: the worker must read the fleet trunk and cut its
# branch from the upstream trunk.
test_resolves_two_distinct_references_on_a_fork() {
  local repo slot contrib
  repo=$(make_fork_repo distinct 3)
  task_base_resolve "$repo" || fail "distinct: resolve failed: $TASK_BASE_ERROR"
  [ "$TASK_BASE_STATE" = distinct ] \
    || fail "distinct: expected state=distinct, got '$TASK_BASE_STATE'"
  slot=$(git -C "$repo" rev-parse main)
  contrib=$(git -C "$repo" rev-parse origin/main)
  [ "$TASK_BASE_SLOT" = "$slot" ] \
    || fail "distinct: slot base must be the local trunk the fleet runs"
  [ "$TASK_BASE_CONTRIB" = "$contrib" ] \
    || fail "distinct: contribution target must be the upstream trunk"
  [ "$TASK_BASE_SLOT" != "$TASK_BASE_CONTRIB" ] \
    || fail "distinct: fixture is not diverged, so it proves nothing"
  # Proves the fixture is the hard case, not a fast-forward one.
  git -C "$repo" merge-base --is-ancestor "$TASK_BASE_CONTRIB" "$TASK_BASE_SLOT" \
    && fail "distinct: fixture upstream is an ancestor of the fork trunk; not the diverged case"
  pass "fm-task-base: a fork setup resolves a fleet slot base and a separate upstream contribution target"
}

# No distinct upstream: the two roles collapse onto one commit and nothing
# about today's single-reference behavior changes.
test_coincident_when_there_is_no_distinct_upstream() {
  local dir
  dir="$TMP_ROOT/coincident/repo"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  commit_in "$dir" base
  commit_in "$dir" second
  task_base_resolve "$dir" || fail "coincident: resolve failed: $TASK_BASE_ERROR"
  [ "$TASK_BASE_STATE" = coincident ] \
    || fail "coincident: expected state=coincident, got '$TASK_BASE_STATE'"
  [ "$TASK_BASE_SLOT" = "$TASK_BASE_CONTRIB" ] \
    || fail "coincident: the two references must be the same commit"
  [ "$TASK_BASE_SLOT" = "$(git -C "$dir" rev-parse main)" ] \
    || fail "coincident: slot base must be the trunk"
  pass "fm-task-base: a project with no distinct upstream resolves both references to one commit"
}

# An upstream relationship exists but its trunk was never fetched. Guessing here
# would cut the branch at the fork trunk and carry fleet-only commits into the
# PR, so it is refused rather than silently degraded onto the slot base.
test_unresolved_when_the_upstream_trunk_is_unreadable() {
  local dir
  dir="$TMP_ROOT/unresolved/repo"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  commit_in "$dir" base
  git -C "$dir" remote add origin "$TMP_ROOT/unresolved/never-fetched.git"
  git -C "$dir" remote set-url --push origin "$TMP_ROOT/unresolved/fork.git"
  task_base_resolve "$dir" || fail "unresolved: resolve returned a hard failure"
  [ "$TASK_BASE_STATE" = unresolved ] \
    || fail "unresolved: expected state=unresolved, got '$TASK_BASE_STATE'"
  [ -z "$TASK_BASE_CONTRIB" ] \
    || fail "unresolved: a contribution target must not be invented (got '$TASK_BASE_CONTRIB')"
  [ "$TASK_BASE_CONTRIB" != "$TASK_BASE_SLOT" ] \
    || fail "unresolved: silently degrading onto the slot base is the pollution this prevents"
  assert_contains "$TASK_BASE_ERROR" "not readable locally" \
    "unresolved: the reason must name the unreadable upstream trunk"
  pass "fm-task-base: an unreadable upstream trunk is refused, never guessed onto the slot base"
}

# THE pollution case, constructed rather than inferred. A branch cut from the
# slot base carries every fleet-only commit; the guard must refuse it.
test_guard_catches_a_branch_cut_from_the_slot_base() {
  local repo rc
  repo=$(make_fork_repo polluted 3)
  task_base_resolve "$repo" || fail "polluted: resolve failed"
  git_q "$repo" checkout -q -b fm/polluted main
  commit_in "$repo" task-work
  rc=0; task_base_verify_branch "$repo" "$TASK_BASE_CONTRIB" fm/polluted || rc=$?
  [ "$rc" -eq 1 ] \
    || fail "polluted: a branch cut from the slot base must be refused (rc=$rc)"
  assert_contains "$TASK_BASE_ERROR" "does not descend from contribution target" \
    "polluted: the refusal must say the branch left the contribution target"
  # 3 fleet-only + 1 task commit: the count must be the real pollution, not a
  # vague failure, or the message cannot be acted on.
  assert_contains "$TASK_BASE_ERROR" "carries 4 commit(s) absent" \
    "polluted: the refusal must count the commits absent from the target"
  pass "fm-task-base: the guard refuses a branch cut from the slot base and counts the fleet-only commits it carries"
}

# The positive control for the test above: the correctly cut branch must still
# pass, both freshly cut and after the worker commits on top of it.
test_guard_accepts_a_branch_cut_from_the_contribution_target() {
  local repo
  repo=$(make_fork_repo clean 3)
  task_base_resolve "$repo" || fail "clean: resolve failed"
  git_q "$repo" checkout -q -b fm/clean "$TASK_BASE_CONTRIB"
  task_base_verify_branch "$repo" "$TASK_BASE_CONTRIB" fm/clean \
    || fail "clean: a freshly cut contribution branch must pass (got: $TASK_BASE_ERROR)"
  commit_in "$repo" task-work
  task_base_verify_branch "$repo" "$TASK_BASE_CONTRIB" fm/clean \
    || fail "clean: the branch must still pass once the task commits on top (got: $TASK_BASE_ERROR)"
  pass "fm-task-base: a branch cut from the contribution target passes before and after the task commits"
}

# An unreadable ref is not a clean verdict. Collapsing "cannot tell" into "fine"
# at a contribution gate is the same false-green class the guard exists to stop.
test_guard_separates_unreadable_from_clean() {
  local repo rc
  repo=$(make_fork_repo unreadable 1)
  rc=0; task_base_verify_branch "$repo" main refs/heads/no-such-branch || rc=$?
  [ "$rc" -eq 2 ] || fail "unreadable: a missing branch must be distinguishable from clean (rc=$rc)"
  rc=0; task_base_verify_branch "$repo" no-such-target main || rc=$?
  [ "$rc" -eq 2 ] || fail "unreadable: a missing target must be distinguishable from clean (rc=$rc)"
  pass "fm-task-base: an unreadable ref returns its own status instead of reading as clean"
}

# --- brief statement -------------------------------------------------------

make_brief_home() {  # <name>
  local home="$TMP_ROOT/briefs/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

run_brief() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$BRIEF" "$@" 2>&1
}

# The brief is what actually prevents the failure: a worker that is never told
# the two references apart cannot get this right by default.
test_brief_states_both_references_when_they_differ() {
  local home slot contrib out
  home=$(make_brief_home differ)
  slot=$(printf '1%.0s' $(seq 40)); contrib=$(printf '2%.0s' $(seq 40))
  out=$(run_brief "$home" bd myrepo --mode no-mistakes --slot-base "$slot" --contribution-target "$contrib") \
    || fail "differ: brief scaffold failed: $out"
  out=$(cat "$home/data/bd/brief.md")
  assert_contains "$out" "Base contract: slot=$slot contribution=$contrib" \
    "differ: the brief must record a machine-readable base contract"
  assert_contains "$out" "git checkout -b fm/bd ${contrib:0:12}" \
    "differ: the branch step must cut from the contribution target, not from wherever the worktree sits"
  assert_contains "$out" "git show ${slot:0:12}:" \
    "differ: the worker must be told how to read the running fleet code after branching"
  assert_contains "$out" "Never cut or rebase your branch onto \`${slot:0:12}\`" \
    "differ: the brief must name the pollution it is preventing"
  pass "fm-brief: a brief whose two bases differ states both and cuts the branch from the contribution target"
}

# "Where the two coincide, nothing should change" - so a project with one base
# keeps today's brief exactly, with no new section and no changed branch step.
test_brief_is_unchanged_when_the_two_coincide() {
  local plain coincident same out
  same=$(printf '3%.0s' $(seq 40))
  plain=$(make_brief_home plain); coincident=$(make_brief_home coincident)
  run_brief "$plain" bc myrepo --mode no-mistakes >/dev/null \
    || fail "coincide: plain scaffold failed"
  run_brief "$coincident" bc myrepo --mode no-mistakes --slot-base "$same" --contribution-target "$same" >/dev/null \
    || fail "coincide: coincident scaffold failed"
  # Only the home path legitimately differs between the two fixtures.
  out=$(diff <(sed "s#$plain#HOME#g" "$plain/data/bc/brief.md") \
             <(sed "s#$coincident#HOME#g" "$coincident/data/bc/brief.md") || true)
  [ -z "$out" ] || fail "coincide: the brief changed when the two references are the same commit:
$out"
  assert_no_grep 'Base contract' "$coincident/data/bc/brief.md" \
    "coincide: a single-base project must not carry a base-contract section"
  pass "fm-brief: a project whose two references coincide gets a byte-identical brief"
}

# An unresolved contribution target must stop the worker BEFORE it pushes,
# rather than letting it invent a base and open a polluted PR.
test_brief_halts_before_push_when_the_contribution_base_is_unresolved() {
  local home slot out
  home=$(make_brief_home unresolved)
  slot=$(printf '4%.0s' $(seq 40))
  run_brief "$home" bu myrepo --mode no-mistakes --slot-base "$slot" --contribution-target unresolved >/dev/null \
    || fail "unresolved: scaffold failed"
  out=$(cat "$home/data/bu/brief.md")
  assert_contains "$out" "Base contract: slot=$slot contribution=unresolved" \
    "unresolved: the brief must record the unresolved target rather than a commit"
  assert_contains "$out" "blocked: contribution base unresolved" \
    "unresolved: the worker must be told to stop before pushing"
  pass "fm-brief: an unresolved contribution base stops the worker before it can push a polluted PR"
}

test_brief_refuses_incoherent_base_inputs() {
  local home out status
  home=$(make_brief_home refuse)
  out=$(run_brief "$home" br myrepo --mode no-mistakes --contribution-target "$(printf '5%.0s' $(seq 40))"); status=$?
  [ "$status" -ne 0 ] || fail "refuse: a contribution target without a slot base must be refused"
  assert_contains "$out" "requires --slot-base" "refuse: the refusal must name the missing reference"
  out=$(run_brief "$home" br myrepo --mode no-mistakes --slot-base main); status=$?
  [ "$status" -ne 0 ] || fail "refuse: a non-SHA slot base must be refused"
  assert_contains "$out" "full commit SHA" "refuse: the refusal must require a resolved commit"
  out=$(run_brief "$home" br --secondmate --no-projects --slot-base "$(printf '6%.0s' $(seq 40))"); status=$?
  [ "$status" -ne 0 ] || fail "refuse: a secondmate charter must reject base flags"
  pass "fm-brief: incoherent or inapplicable base inputs are refused instead of silently dropped"
}

# --- spawn: end to end ------------------------------------------------------

# A fake tmux that reports the task worktree and succeeds, so a spawn runs to
# completion and writes real task metadata (the shape tests/fm-spawn-worktree-settle.test.sh uses).
make_spawn_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# The whole chain on the real diverged topology: resolve, scaffold, spawn.
# Asserts the two DoD guarantees at once - the slot is placed at the code the
# fleet runs, and both references are recorded for later inspection.
test_spawn_records_both_references_and_places_the_slot_at_the_fleet_trunk() {
  local repo wt home fakebin id out status stale slot contrib
  repo=$(make_fork_repo spawn-e2e 3)
  wt="$TMP_ROOT/spawn-e2e/wt"
  home="$TMP_ROOT/spawn-e2e/home"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-e2e/fake")
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  slot=$(git -C "$repo" rev-parse main)
  contrib=$(git -C "$repo" rev-parse origin/main)
  # A pooled slot left at an OLD commit: the exact stale-base condition measured
  # live, where free slots sat behind the running trunk.
  stale=$(git -C "$repo" rev-parse main~2)
  git -C "$repo" worktree add --quiet --detach "$wt" "$stale"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$stale" ] \
    || fail "e2e: fixture slot is not at the stale commit"

  id='base-e2e-a1'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$BRIEF" "$id" fixture --mode no-mistakes --slot-base "$slot" --contribution-target "$contrib" >/dev/null \
    || fail "e2e: brief scaffold failed"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$wt" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$repo" --mode no-mistakes --yolo off 2>&1); status=$?
  expect_code 0 "$status" "e2e: spawn should succeed (got: $out)"

  assert_grep "slot_base=$slot" "$home/state/$id.meta" \
    "e2e: metadata must record the commit the worker reads"
  assert_grep "contribution_target=$contrib" "$home/state/$id.meta" \
    "e2e: metadata must record the commit the branch is cut from"
  assert_grep "base_state=distinct" "$home/state/$id.meta" \
    "e2e: metadata must record that the two references differ"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$slot" ] \
    || fail "e2e: the slot was left at a stale commit instead of the trunk the fleet runs"
  pass "fm-spawn: a spawn places the slot at the fleet trunk and records both base references"
}

# The same drift guard the delivery contract uses: a brief that names a
# different pair than the spawn resolved would hand the worker citations
# against one commit and a branch cut from another.
# A scout cuts no branch, so it has only a commit to read and cite. Its slot is
# still placed at the fleet trunk - the report-citation failure this fixes.
test_scout_gets_a_read_base_and_no_contribution_target() {
  local repo wt home fakebin id out status slot stale
  repo=$(make_fork_repo scout-e2e 3)
  wt="$TMP_ROOT/scout-e2e/wt"
  home="$TMP_ROOT/scout-e2e/home"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/scout-e2e/fake")
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  slot=$(git -C "$repo" rev-parse main)
  stale=$(git -C "$repo" rev-parse main~2)
  git -C "$repo" worktree add --quiet --detach "$wt" "$stale"
  id='base-scout-c3'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$BRIEF" "$id" fixture --scout --slot-base "$slot" >/dev/null \
    || fail "scout: brief scaffold failed"
  assert_grep "Base contract: slot=$slot contribution=n/a" "$home/data/$id/brief.md" \
    "scout: the brief must record the commit its report cites against"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$wt" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$repo" --scout 2>&1); status=$?
  expect_code 0 "$status" "scout: spawn should succeed (got: $out)"
  assert_grep "slot_base=$slot" "$home/state/$id.meta" \
    "scout: metadata must record the commit the report cites against"
  assert_grep "contribution_target=n/a" "$home/state/$id.meta" \
    "scout: a scout must record no contribution target"
  assert_grep "base_state=read-only" "$home/state/$id.meta" \
    "scout: metadata must record that a scout cuts no branch"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$slot" ] \
    || fail "scout: the slot was left stale, so the report's line citations would be wrong"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$SPAWN" scout-refuse-d4 "$repo" --scout --contribution-target "$slot" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "scout: a contribution target must be refused on a scout"
  assert_contains "$out" "applies only to ship spawns" "scout: the refusal must say why"
  pass "fm-spawn: a scout records a read base with no contribution target and still lands on the fleet trunk"
}

test_spawn_refuses_a_brief_that_names_a_different_pair() {
  local repo home fakebin id out status
  repo=$(make_fork_repo spawn-mismatch 2)
  home="$TMP_ROOT/spawn-mismatch/home"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-mismatch/fake")
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  id='base-mismatch-b2'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$BRIEF" "$id" fixture --mode no-mistakes \
    --slot-base "$(git -C "$repo" rev-parse main)" \
    --contribution-target "$(git -C "$repo" rev-parse main~1)" >/dev/null \
    || fail "mismatch: brief scaffold failed"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$repo" --mode no-mistakes --yolo off 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "mismatch: spawn should refuse a brief naming a different pair"
  assert_contains "$out" "base mismatch for $id" "mismatch: the refusal must name the drift"
  assert_absent "$home/state/$id.meta" "mismatch: a refused spawn wrote task metadata"
  pass "fm-spawn: a brief naming a different base pair is refused before any endpoint exists"
}

test_resolves_two_distinct_references_on_a_fork
test_coincident_when_there_is_no_distinct_upstream
test_unresolved_when_the_upstream_trunk_is_unreadable
test_guard_catches_a_branch_cut_from_the_slot_base
test_guard_accepts_a_branch_cut_from_the_contribution_target
test_guard_separates_unreadable_from_clean
test_brief_states_both_references_when_they_differ
test_brief_is_unchanged_when_the_two_coincide
test_brief_halts_before_push_when_the_contribution_base_is_unresolved
test_brief_refuses_incoherent_base_inputs
test_spawn_records_both_references_and_places_the_slot_at_the_fleet_trunk
test_scout_gets_a_read_base_and_no_contribution_target
test_spawn_refuses_a_brief_that_names_a_different_pair
