#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's memory guard.
#
# The guard runs before argument parsing, so these tests drive the real
# fm-spawn.sh with no arguments against an isolated firstmate home and read the
# process result. A refusal prints "refusing to spawn:" and exits 1; passing the
# guard falls through to the ordinary "--mode" argument error, so reaching that
# message is the positive signal that the guard allowed the spawn. Neither
# outcome starts a backend, so no endpoint or metadata is ever created.
#
# FM_SPAWN_NO_GUARD=1 skips the unrelated watcher guard only; the memory guard
# has no such skip and still runs, exactly as it does for each pair of a batch.
#
# The crew-count cases pin FM_MIN_FREE_MB=1 and the memory cases pin a high
# FM_MAX_CREWS so each test exercises one branch and never depends on how much
# memory the host running the suite happens to have free.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-memory-guard)

REFUSAL='refusing to spawn:'
PASSED_GUARD='ship spawns require --mode'

# make_home <name> <live-crew-count>: isolated home with N live task metas.
make_home() {
  local home=$TMP_ROOT/$1 count=$2 i
  mkdir -p "$home/state"
  for ((i = 1; i <= count; i++)); do
    : > "$home/state/task$i.meta"
  done
  printf '%s\n' "$home"
}

# run_spawn <home>: run fm-spawn with the guard reachable, echo output, return code.
run_spawn() {
  local home=$1
  FM_SPAWN_NO_GUARD=1 FM_HOME="$home" bash "$SPAWN" 2>&1
}

test_cap_refuses_when_live_crews_reach_the_cap() {
  local home out rc
  home=$(make_home cap-at 8)
  out=$(FM_MIN_FREE_MB=1 run_spawn "$home"); rc=$?
  expect_code 1 "$rc" 'cap at limit must refuse'
  assert_contains "$out" "$REFUSAL" 'cap at limit must refuse the spawn'
  assert_contains "$out" '8 crews already live (cap 8)' 'refusal must name the live count and cap'
  pass 'cap refuses when live crews reach the cap'
}

test_cap_refuses_above_the_cap() {
  local home out rc
  home=$(make_home cap-above 9)
  out=$(FM_MIN_FREE_MB=1 run_spawn "$home"); rc=$?
  expect_code 1 "$rc" 'cap above limit must refuse'
  assert_contains "$out" '9 crews already live (cap 8)' 'refusal must count every live crew'
  pass 'cap refuses above the cap'
}

test_cap_allows_below_the_cap() {
  local home out
  home=$(make_home cap-below 7)
  out=$(FM_MIN_FREE_MB=1 run_spawn "$home")
  assert_not_contains "$out" "$REFUSAL" 'a normal spawn below the cap must not be refused'
  assert_contains "$out" "$PASSED_GUARD" 'a normal spawn must reach ordinary argument handling'
  pass 'cap allows below the cap'
}

test_empty_home_is_unaffected() {
  local home out
  home=$(make_home cap-empty 0)
  out=$(FM_MIN_FREE_MB=1 run_spawn "$home")
  assert_not_contains "$out" "$REFUSAL" 'a home with no live crews must not be refused'
  assert_contains "$out" "$PASSED_GUARD" 'a home with no live crews must reach ordinary argument handling'
  pass 'empty home is unaffected'
}

test_explicit_cap_is_honoured() {
  local home out rc
  home=$(make_home cap-explicit 2)
  out=$(FM_MIN_FREE_MB=1 FM_MAX_CREWS=1 run_spawn "$home"); rc=$?
  expect_code 1 "$rc" 'explicit FM_MAX_CREWS must refuse'
  assert_contains "$out" '2 crews already live (cap 1)' 'refusal must report the explicit cap'
  pass 'explicit FM_MAX_CREWS is honoured'
}

test_raised_cap_allows_the_spawn() {
  local home out
  home=$(make_home cap-raised 9)
  out=$(FM_MIN_FREE_MB=1 FM_MAX_CREWS=50 run_spawn "$home")
  assert_not_contains "$out" "$REFUSAL" 'a deliberately raised cap must allow the spawn'
  assert_contains "$out" "$PASSED_GUARD" 'a raised cap must reach ordinary argument handling'
  pass 'a raised cap allows the spawn'
}

test_memory_refusal_fires_below_the_threshold() {
  local home out rc
  home=$(make_home mem-low 0)
  out=$(FM_MAX_CREWS=99 FM_MIN_FREE_MB=99999999 run_spawn "$home"); rc=$?
  expect_code 1 "$rc" 'memory below threshold must refuse'
  assert_contains "$out" "$REFUSAL" 'memory below threshold must refuse the spawn'
  assert_contains "$out" 'need 99999999' 'refusal must name the required free memory'
  pass 'memory refusal fires below the threshold'
}

test_memory_refusal_allows_above_the_threshold() {
  local home out
  home=$(make_home mem-ok 0)
  out=$(FM_MAX_CREWS=99 FM_MIN_FREE_MB=1 run_spawn "$home")
  assert_not_contains "$out" "$REFUSAL" 'ample free memory must not be refused'
  assert_contains "$out" "$PASSED_GUARD" 'ample free memory must reach ordinary argument handling'
  pass 'memory refusal allows above the threshold'
}

test_force_overrides_the_cap() {
  local home out
  home=$(make_home force-cap 9)
  out=$(FM_MIN_FREE_MB=1 FM_SPAWN_FORCE=1 FM_MAX_CREWS=1 run_spawn "$home")
  assert_not_contains "$out" "$REFUSAL" 'FM_SPAWN_FORCE must override the cap'
  assert_contains "$out" "$PASSED_GUARD" 'a forced spawn must reach ordinary argument handling'
  pass 'FM_SPAWN_FORCE overrides the cap'
}

test_force_overrides_the_memory_refusal() {
  local home out
  home=$(make_home force-mem 0)
  out=$(FM_SPAWN_FORCE=1 FM_MIN_FREE_MB=99999999 run_spawn "$home")
  assert_not_contains "$out" "$REFUSAL" 'FM_SPAWN_FORCE must override the memory refusal'
  assert_contains "$out" "$PASSED_GUARD" 'a forced spawn must reach ordinary argument handling'
  pass 'FM_SPAWN_FORCE overrides the memory refusal'
}

# Regression for the typo that read an undefined variable instead of the resolved
# state directory. Under `set -u` that killed only the counting subshell, leaving
# the count empty so the cap silently never fired while the spawn continued.
test_crew_count_reads_the_resolved_state_directory() {
  local home out rc
  home=$(make_home regression 9)
  out=$(FM_MIN_FREE_MB=1 run_spawn "$home"); rc=$?
  assert_not_contains "$out" 'unbound variable' 'the crew count must not read an undefined variable'
  expect_code 1 "$rc" 'the cap must fire rather than being skipped by a failed count'
  pass 'crew count reads the resolved state directory'
}

# The state directory is overridable, so the count must follow the override
# rather than any other location.
test_crew_count_follows_the_state_override() {
  local home elsewhere out rc
  home=$(make_home override-home 0)
  elsewhere=$(make_home override-state 9)
  out=$(FM_MIN_FREE_MB=1 FM_STATE_OVERRIDE="$elsewhere/state" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$home" bash "$SPAWN" 2>&1); rc=$?
  expect_code 1 "$rc" 'the override state directory must be counted'
  assert_contains "$out" '9 crews already live (cap 8)' 'the count must follow FM_STATE_OVERRIDE'
  pass 'crew count follows the state override'
}

test_cap_refuses_when_live_crews_reach_the_cap
test_cap_refuses_above_the_cap
test_cap_allows_below_the_cap
test_empty_home_is_unaffected
test_explicit_cap_is_honoured
test_raised_cap_allows_the_spawn
test_memory_refusal_fires_below_the_threshold
test_memory_refusal_allows_above_the_threshold
test_force_overrides_the_cap
test_force_overrides_the_memory_refusal
test_crew_count_reads_the_resolved_state_directory
test_crew_count_follows_the_state_override

echo "# all fm-spawn-memory-guard tests passed"
