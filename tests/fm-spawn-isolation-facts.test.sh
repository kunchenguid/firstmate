#!/usr/bin/env bash
# Behavior tests for the isolation facts bin/fm-spawn.sh writes into a ship
# brief (the fill_isolation_facts step after validate_spawn_worktree).
#
# The generated ship brief tells the worker to stop unless its own top level is
# the isolated task worktree rather than the primary checkout, but bin/fm-brief.sh
# knows neither path when it scaffolds - the worktree does not exist yet - so it
# emits {FM_WORKTREE}/{FM_PRIMARY_CHECKOUT} placeholders. Left unfilled, that
# check is a judgment call with no operands, and it has refused a correctly
# isolated worker in the live fleet: a firstmate-repo crewmate reads the primary
# checkout's absolute path several times in its own brief and its worktree path
# nowhere. fm-spawn.sh fills both in from the worktree it has already verified,
# rewrites a stale value on a later launch instead of pinning the brief to the
# first slot it used, leaves pre-contract briefs untouched, and refuses to launch
# a worker whose isolation check still holds a literal placeholder.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-isolation-facts)

# A fake tmux whose pane_current_path always reports the settled worktree, plus
# a no-op treehouse: the settle loop itself is covered by
# tests/fm-spawn-worktree-settle.test.sh and is not the subject here. The pane
# answers fm-spawn's launch-delivery protocol through the shared owner in
# tests/lib.sh, so this suite verifies real delivery rather than a local
# imitation of it.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
# shellcheck source=/dev/null
. "$(dirname "$0")/pane-shell.sh"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  capture-pane) fm_fake_pane_capture; exit 0 ;;
  send-keys)
    fm_fake_pane_send "$@"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_pane_shell "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> <id> builds a home, a primary project checkout and a real
# linked worktree of it, and returns the paths. The brief body is written by
# each test so it can carry placeholders, stale values, or neither.
make_case() {
  local name=$1 id=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  CASE_HOME="$case_dir/home"
  CASE_PROJ="$case_dir/project"
  CASE_WT="$case_dir/wt"
  CASE_FAKEBIN=$(make_fakebin "$case_dir/fake")
  mkdir -p "$CASE_HOME/data/$id" "$CASE_HOME/projects" "$CASE_HOME/state" "$CASE_HOME/config"
  printf 'codex\n' > "$CASE_HOME/config/crew-harness"
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "wt-$name"
  touch "$CASE_HOME/state/.last-watcher-beat"
  CASE_BRIEF="$CASE_HOME/data/$id/brief.md"
}

# The ship-brief isolation block as bin/fm-brief.sh renders it, with <worktree>
# and <primary> supplied by the caller so a test can seed placeholders or a
# stale already-filled value.
write_brief() {
  local brief=$1 worktree=$2 primary=$3
  cat > "$brief" <<EOF
task fixture

**Verify isolation before anything else.**

- your isolated task worktree: $worktree
- the primary checkout: $primary

If it equals the primary checkout, STOP.
EOF
}

run_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$CASE_WT" \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$CASE_PROJ" 2>&1
}

# The paths the worker will compare against must be the physically resolved ones,
# because `git rev-parse --show-toplevel` always reports the resolved path.
resolved() {
  (cd "$1" && pwd -P)
}

test_placeholders_are_filled_with_the_verified_paths() {
  local id out status wt_real proj_real
  id=isolation-facts-fill-z1
  make_case fill "$id"
  write_brief "$CASE_BRIEF" '{FM_WORKTREE}' '{FM_PRIMARY_CHECKOUT}'
  wt_real=$(resolved "$CASE_WT")
  proj_real=$(resolved "$CASE_PROJ")

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed and fill the isolation facts (got: $out)"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "- your isolated task worktree: $wt_real" "$CASE_BRIEF" \
    "brief did not receive the verified task worktree"
  assert_grep "- the primary checkout: $proj_real" "$CASE_BRIEF" \
    "brief did not receive the primary checkout"
  assert_no_grep "{FM_WORKTREE}" "$CASE_BRIEF" "brief kept an unfilled worktree placeholder"
  assert_no_grep "{FM_PRIMARY_CHECKOUT}" "$CASE_BRIEF" "brief kept an unfilled primary placeholder"
  pass "fm-spawn.sh: isolation placeholders are filled with the verified worktree and primary checkout"
}

# A brief that already carries paths - a relaunch, or a task respawned into a
# different pool slot - must be corrected to the worktree this launch verified.
# A stale path would refuse a correctly isolated worker exactly like an unfilled
# placeholder does.
test_stale_isolation_facts_are_rewritten() {
  local id out status wt_real
  id=isolation-facts-stale-z2
  make_case stale "$id"
  write_brief "$CASE_BRIEF" "$TMP_ROOT/stale/some-other-pool-slot" "$TMP_ROOT/stale/some-other-primary"
  wt_real=$(resolved "$CASE_WT")

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed on an already-filled brief (got: $out)"
  assert_grep "- your isolated task worktree: $wt_real" "$CASE_BRIEF" \
    "brief kept a stale worktree path from an earlier launch"
  assert_no_grep "some-other-pool-slot" "$CASE_BRIEF" \
    "brief still names the worktree from an earlier launch"
  assert_no_grep "some-other-primary" "$CASE_BRIEF" \
    "brief still names the primary checkout from an earlier launch"
  pass "fm-spawn.sh: a relaunch rewrites stale isolation facts instead of pinning the first slot"
}

# A placeholder the fill cannot reach - here the fact lines were removed but the
# placeholder text survives elsewhere - must stop the launch. A worker reading a
# literal {FM_WORKTREE} has no isolation check at all, so proceeding would be
# strictly worse than refusing.
test_unfillable_placeholder_refuses_to_launch() {
  local id out status
  id=isolation-facts-unfillable-z3
  make_case unfillable "$id"
  cat > "$CASE_BRIEF" <<'EOF'
task fixture

Compare your top level against {FM_WORKTREE} before starting.
EOF

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn exited 0 with an unfilled isolation placeholder in the brief"
  assert_contains "$out" "unfilled isolation placeholder" \
    "refusal did not name the unfilled isolation placeholder"
  assert_not_contains "$out" "spawned $id" "spawn reported success despite refusing"
  assert_absent "$CASE_HOME/state/$id.meta" "a refused spawn still recorded task metadata"
  pass "fm-spawn.sh: a brief with an unfillable isolation placeholder refuses to launch"
}

# Briefs scaffolded before this contract carry the old prose assertion and no
# placeholders. They must keep launching unchanged, so an in-flight task can
# still be relaunched after the fleet updates.
test_pre_contract_brief_launches_unchanged() {
  local id out status before after
  id=isolation-facts-legacy-z4
  make_case legacy "$id"
  cat > "$CASE_BRIEF" <<'EOF'
task fixture

**Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`.
EOF
  before=$(cat "$CASE_BRIEF")

  out=$(run_spawn "$id")
  status=$?
  after=$(cat "$CASE_BRIEF")
  expect_code 0 "$status" "spawn should still launch a pre-contract brief (got: $out)"
  assert_contains "$out" "spawned $id" "spawn did not report success for a pre-contract brief"
  [ "$before" = "$after" ] || fail "spawn rewrote a pre-contract brief that carries no isolation facts"
  pass "fm-spawn.sh: a pre-contract brief launches unchanged"
}

test_missing_worktree_fact_refuses_to_launch() {
  local id out status
  id=isolation-facts-missing-worktree-z5
  make_case missing-worktree "$id"
  write_brief "$CASE_BRIEF" '{FM_WORKTREE}' '{FM_PRIMARY_CHECKOUT}'
  grep -v '^- your isolated task worktree: ' "$CASE_BRIEF" > "$CASE_BRIEF.tmp"
  mv "$CASE_BRIEF.tmp" "$CASE_BRIEF"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn exited 0 with the worktree isolation fact missing"
  assert_contains "$out" "missing the '- your isolated task worktree:' isolation fact line" \
    "refusal did not name the missing worktree isolation fact"
  assert_not_contains "$out" "spawned $id" "spawn reported success despite the missing worktree fact"
  assert_absent "$CASE_HOME/state/$id.meta" "a malformed isolation block still recorded task metadata"
  pass "fm-spawn.sh: a brief missing the worktree isolation fact refuses to launch"
}

test_missing_primary_fact_refuses_to_launch() {
  local id out status
  id=isolation-facts-missing-primary-z6
  make_case missing-primary "$id"
  write_brief "$CASE_BRIEF" '{FM_WORKTREE}' '{FM_PRIMARY_CHECKOUT}'
  grep -v '^- the primary checkout: ' "$CASE_BRIEF" > "$CASE_BRIEF.tmp"
  mv "$CASE_BRIEF.tmp" "$CASE_BRIEF"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn exited 0 with the primary-checkout isolation fact missing"
  assert_contains "$out" "missing the '- the primary checkout:' isolation fact line" \
    "refusal did not name the missing primary-checkout isolation fact"
  assert_not_contains "$out" "spawned $id" "spawn reported success despite the missing primary-checkout fact"
  assert_absent "$CASE_HOME/state/$id.meta" "a malformed isolation block still recorded task metadata"
  pass "fm-spawn.sh: a brief missing the primary-checkout isolation fact refuses to launch"
}

test_placeholders_are_filled_with_the_verified_paths
test_stale_isolation_facts_are_rewritten
test_unfillable_placeholder_refuses_to_launch
test_pre_contract_brief_launches_unchanged
test_missing_worktree_fact_refuses_to_launch
test_missing_primary_fact_refuses_to_launch

echo "# all fm-spawn-isolation-facts tests passed"
