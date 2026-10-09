#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh batch dispatch (`id=repo` pairs).
#
# These exercise argument routing only: each spawn attempt fails fast at the
# missing-brief check, which is reached before any tmux/treehouse side effect, so
# the tests create no windows or worktrees. FM_SPAWN_NO_GUARD=1 keeps them off the
# live watcher guard / state. Also covers the goodnight hold and per-invocation
# override, presence predicate, and skill discovery metadata.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-batch)
export FM_BACKEND=tmux

# Clear ambient firstmate overrides so the behavior test owns its environment.
run_spawn() {
  FM_ROOT_OVERRIDE='' \
    FM_HOME='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); the
# batch path takes one shared pair of flags for every pair.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

# Every pair in a batch is dispatched even though the first one fails; the loop
# must not stop early. This is the load-bearing batch guarantee, kept explicit.
test_batch_dispatches_every_pair() {
  local out status
  out=$(run_ship_spawn nope-batch-a-z1=projects/none-a nope-batch-b-z2=projects/none-b)
  status=$?
  [ "$status" -ne 0 ] || fail "batch with missing briefs should exit non-zero"
  printf '%s\n' "$out" | grep -F 'batch: FAILED to spawn nope-batch-a-z1 (projects/none-a)' >/dev/null \
    || fail "first pair was not dispatched/reported"
  printf '%s\n' "$out" | grep -F 'batch: FAILED to spawn nope-batch-b-z2 (projects/none-b)' >/dev/null \
    || fail "second pair was not dispatched/reported (loop stopped early?)"
  pass "batch dispatch re-execs and reports every id=repo pair"
}

# Boundary cases for batch detection. Each row:
#   <label>|<batch yes/no>|<expect substring>|<args>
# batch=yes -> a 'batch:' line must appear; batch=no -> it must not.
test_batch_mode_boundaries() {
  local label batch expect args out status
  while IFS='|' read -r label batch expect args; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(run_ship_spawn $args)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected non-zero exit"
    if [ -n "$expect" ]; then
      printf '%s\n' "$out" | grep -F "$expect" >/dev/null || fail "$label: missing '$expect'"
    fi
    case "$batch" in
      yes) printf '%s\n' "$out" | grep -F 'batch:' >/dev/null || fail "$label: did not enter batch dispatch" ;;
      no)  printf '%s\n' "$out" | grep -F 'batch:' >/dev/null && fail "$label: wrongly entered batch dispatch" ;;
    esac
  done <<'ROWS'
single id=repo pair routes through batch|yes|batch: FAILED to spawn nope-batch-solo-z3 (projects/none-solo)|nope-batch-solo-z3=projects/none-solo
non-pair arg in batch is rejected|yes|batch dispatch expects every argument as id=repo; got 'bogus-no-equals'|nope-batch-mix-z5=projects/none-mix bogus-no-equals
plain '<id> <repo>' is single-task|no||nope-single-z4 projects/none-single
id part containing '/' is not a pair|no||weird/id-z6=projects/none projects/none
ROWS
  pass "batch detection: single pair batches, non-pair rejected, single-task and slash-id stay single"
}

# A projects/ path is resolved through the firstmate home, never the caller cwd,
# before the missing-brief check. One row per home-scoping override.
test_projects_path_scoping() {
  local label use_override id home projects out status expected
  while IFS='|' read -r label use_override id; do
    [ -n "$label" ] || continue
    home="$TMP_ROOT/$id home"
    projects="$TMP_ROOT/$id projects"
    mkdir -p "$home/data" "$projects/alpha"
    git -C "$projects/alpha" init -q || fail "$label: could not initialize project fixture"
    if [ "$use_override" = yes ]; then
      out=$(FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
        FM_HOME="$home" FM_PROJECTS_OVERRIDE="$projects" FM_SPAWN_NO_GUARD=1 \
        "$SPAWN" "$id" projects/alpha codex --mode no-mistakes --yolo off 2>&1)
    else
      mkdir -p "$home/projects/alpha"
      git -C "$home/projects/alpha" init -q || fail "$label: could not initialize home project fixture"
      out=$(FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
        FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
        "$SPAWN" "$id" projects/alpha codex --mode no-mistakes --yolo off 2>&1)
    fi
    status=$?
    [ "$status" -ne 0 ] || fail "$label: spawn with missing brief should fail"
    expected="error: task $id has no brief at inaccessible data path $home/data/$id/brief.md"
    printf '%s\n' "$out" | grep -F "$expected" >/dev/null \
      || fail "$label: projects/alpha was not resolved through the home before the brief check"
    printf '%s\n' "$out" | grep -F 'cd: projects/alpha' >/dev/null \
      && fail "$label: spawn resolved projects/alpha from the caller cwd"
  done <<'ROWS'
FM_HOME scopes projects/|no|nope-home-z7
FM_PROJECTS_OVERRIDE scopes projects/|yes|nope-override-z8
ROWS
  pass "projects/ paths are scoped through the firstmate home for single-task spawn"
}

# A ship batch carries one shared delivery contract. Missing flags must stop the
# whole batch before any pair is dispatched, so a batch can never launch workers
# whose delivery posture was never decided.
test_batch_requires_the_shared_delivery_contract() {
  local out status
  out=$(run_spawn nope-batch-nomode-z9=projects/none-a nope-batch-nomode-z10=projects/none-b)
  status=$?
  [ "$status" -ne 0 ] || fail "a ship batch without --mode should exit non-zero"
  printf '%s\n' "$out" | grep -F 'ship spawns require --mode' >/dev/null \
    || fail "batch refusal did not name the missing delivery mode"
  printf '%s\n' "$out" | grep -F 'batch:' >/dev/null \
    && fail "batch dispatched pairs despite an undecided delivery contract"

  out=$(run_spawn nope-batch-noyolo-z11=projects/none-a --mode direct-PR)
  status=$?
  [ "$status" -ne 0 ] || fail "a ship batch without --yolo should exit non-zero"
  printf '%s\n' "$out" | grep -F 'ship spawns require --yolo' >/dev/null \
    || fail "batch refusal did not name the missing merge posture"
  pass "batch dispatch requires the shared ship delivery contract before any pair runs"
}

# A scout batch has no delivery contract to share, so the flags are refused rather
# than accepted and ignored.
test_scout_batch_refuses_delivery_flags() {
  local out status
  out=$(run_spawn nope-batch-scout-z12=projects/none-a --scout --mode direct-PR --yolo on)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout batch carrying delivery flags should exit non-zero"
  printf '%s\n' "$out" | grep -F 'applies only to ship spawns' >/dev/null \
    || fail "scout batch did not refuse the delivery flags"
  pass "scout batch refuses ship delivery flags instead of ignoring them"
}

goodnight_spawn() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

test_goodnight_hold() {
  local home="$TMP_ROOT/goodnight" out status backend args
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects/none"
  git init -q "$home/projects/none"
  printf '2026-10-09T22:15:00Z\n' > "$home/state/.goodnight"
  # The common guard must run before every backend's allocator or probe.
  for backend in tmux herdr zellij orca cmux; do
    for args in 'ship projects/none --mode no-mistakes --yolo off' \
      'scout projects/none --scout' 'mate --secondmate' 'ship --relaunch' \
      'batch-a=projects/none batch-b=projects/none --mode direct-PR --yolo off'; do
      # shellcheck disable=SC2086 # Intentional argument table.
      out=$(goodnight_spawn "$home" $args --backend "$backend")
      status=$?
      [ "$status" -eq 76 ] || fail "goodnight $backend $args returned $status instead of 76: $out"
      assert_contains "$out" 'deferred: goodnight is active' 'hold refusal missing'
    done
  done
  [ ! -e "$home/state/ship.meta" ] || fail 'hold published worker metadata'
  [ ! -e "$home/data/ship" ] || fail 'hold created task material'

  out=$(goodnight_spawn "$home" bypass projects/none --mode no-mistakes --yolo off --goodnight-override)
  status=$?
  [ "$status" -eq 1 ] || fail "override did not reach ordinary missing-brief validation: $out"
  assert_contains "$out" 'task bypass has no brief' 'override was not accepted'
  out=$(goodnight_spawn "$home" bypass-a=projects/none bypass-b=projects/none --mode direct-PR --yolo off --goodnight-override)
  assert_contains "$out" 'task bypass-a has no brief' 'batch override not passed to first child'
  assert_contains "$out" 'task bypass-b has no brief' 'batch override not passed to second child'
  [ -e "$home/state/.goodnight" ] || fail 'override lifted global hold'
  out=$(goodnight_spawn "$home" after projects/none --scout)
  status=$?
  [ "$status" -eq 76 ] || fail 'per-spawn override leaked into next invocation'

  rm "$home/state/.goodnight"
  out=$(goodnight_spawn "$home" morning projects/none --scout)
  assert_contains "$out" 'task morning has no brief' 'lifting marker did not restore ordinary validation'
  pass 'goodnight refuses all spawn paths before backend allocation; explicit override is per invocation and carried through batches'
}

test_goodnight_presence() {
  local state="$TMP_ROOT/goodnight-presence"
  mkdir -p "$state"
  FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_goodnight_active "$2" && exit 1
    : > "$2/.goodnight"
    fm_goodnight_active "$2" || exit 1
    printf "malformed\n" > "$2/.goodnight"
    fm_goodnight_active "$2" || exit 1
    rm "$2/.goodnight"
    ln -s "$2/missing" "$2/.goodnight"
    fm_goodnight_active "$2" || exit 1
    rm "$2/.goodnight"
    fm_goodnight_active "$2" && exit 1
    exit 0
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" || fail 'goodnight presence did not fail closed'
  pass 'fm_goodnight_active holds on empty, malformed, and dangling records and clears only on absence'
}

# Skill descriptions are discovery data, the always-loaded trigger index.
test_goodnight_discovery() {
  python3 - "$ROOT/.agents/skills" <<'PY' || fail 'goodnight missing from skill discovery index'
import pathlib, sys
index = {}
for skill in pathlib.Path(sys.argv[1]).glob('*/SKILL.md'):
    fields = skill.read_text().split('---', 2)[1]
    index[skill.parent.name] = fields
entry = index['goodnight']
for trigger in ('/goodnight', '"goodnight"', '"going to bed"', 'state/.goodnight', 'session start', 'wake handling', '/goodmorning'):
    assert trigger in entry, trigger
assert 'user-invocable: true' in entry
assert 'user-invocable: true' in index['goodmorning']
PY
  pass 'goodnight and goodmorning are discoverable with the required trigger metadata'
}

test_goodnight_hold
test_goodnight_presence
test_goodnight_discovery
test_batch_dispatches_every_pair
test_batch_mode_boundaries
test_batch_requires_the_shared_delivery_contract
test_scout_batch_refuses_delivery_flags
test_projects_path_scoping
