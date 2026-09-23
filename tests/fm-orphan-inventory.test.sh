#!/usr/bin/env bash
# tests/fm-orphan-inventory.test.sh - behavior tests for bin/fm-orphan-inventory.sh,
# the report-only startup inventory of Treehouse slots and processes that no
# current task record names.
#
# Pins:
#   - of four claimed slots (this home without a record, a gone home, another
#     live home, this home with a record), exactly the first two are reported,
#     each with the process whose working directory is inside it
#   - a claim naming this home through another spelling of its path still
#     matches, because both sides are canonicalized
#   - nothing is ever signaled: every fixture process is still alive afterwards
#   - an orphan claim with no process inside reports its slot instead, and a
#     claim younger than the age floor is left alone as a spawn in progress
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-orphan-inventory-tests)
INVENTORY="$ROOT/bin/fm-orphan-inventory.sh"
PIDS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  fm_test_cleanup
}
trap cleanup EXIT

command -v lsof >/dev/null 2>&1 || { pass "skipped: lsof is required"; exit 0; }

OLD_EPOCH=$(( $(date +%s) - 3600 ))

# claim_slot <pool-root> <slot> <task> <home>: a Treehouse slot with a repo copy
# and a Firstmate owner claim old enough to be past the spawn-in-progress floor.
claim_slot() {
  local pool=$1/pool slot=$1/pool/$2
  mkdir -p "$slot/repo"
  : > "$pool/treehouse-state.json"
  printf 'task=%s\nhome=%s\n' "$3" "$4" > "$slot/.fm-slot-owner"
  fm_touch_epoch "$OLD_EPOCH" "$slot/.fm-slot-owner"
}

# park_process <dir>: a sleeping process whose working directory is <dir>;
# its pid is left in PARKED so no command substitution holds its stdout open.
park_process() {
  (cd "$1" && exec sleep 300) >/dev/null 2>&1 &
  PARKED=$!
  PIDS+=("$PARKED")
}

run_inventory() {  # <home> <treehouse-root>
  env -u FM_ORPHAN_POOL_ROOT FM_HOME="$1" TREEHOUSE_ROOT="$2" "$INVENTORY" 2>&1
}

w="$TMP_ROOT/four-claims"
mkdir -p "$w/home/state" "$w/other-home"
ln -s "$w/home" "$w/home-alias"
fm_write_meta "$w/home/state/task-d.meta" id=task-d
claim_slot "$w/th" 1 task-a "$w/home-alias"
claim_slot "$w/th" 2 task-b "$w/gone-home"
claim_slot "$w/th" 3 task-c "$w/other-home"
claim_slot "$w/th" 4 task-d "$w/home"
park_process "$w/th/pool/1/repo"; pid_a=$PARKED
park_process "$w/th/pool/2/repo"; pid_b=$PARKED
park_process "$w/th/pool/3/repo"; pid_c=$PARKED
park_process "$w/th/pool/4/repo"; pid_d=$PARKED
sleep 0.5

out=$(run_inventory "$w/home" "$w/th")
assert_contains "$out" "ORPHAN_PROCESS: pid=$pid_a " "this home's slot without a record is reported"
assert_contains "$out" "task=task-a" "the unrecorded claim names its task"
assert_contains "$out" "ORPHAN_PROCESS: pid=$pid_b " "a gone home's slot is reported"
assert_contains "$out" "kill $pid_a" "the report carries the exact stop command"
assert_not_contains "$out" "pid=$pid_c " "another live home's slot is skipped"
assert_not_contains "$out" "pid=$pid_d " "a recorded task's slot is skipped"
assert_equals 2 "$(printf '%s\n' "$out" | grep -c '^ORPHAN_')" "exactly two orphan lines"
for pid in "$pid_a" "$pid_b" "$pid_c" "$pid_d"; do
  kill -0 "$pid" 2>/dev/null || fail "inventory must never signal a process (pid $pid died)"
done
pass "four claims: exactly the unrecorded and gone-home slots are reported, nothing signaled"

w="$TMP_ROOT/idle-and-fresh"
mkdir -p "$w/home/state"
claim_slot "$w/th" 1 task-idle "$w/gone-home"
claim_slot "$w/th" 2 task-fresh "$w/gone-home"
touch "$w/th/pool/2/.fm-slot-owner"
out=$(run_inventory "$w/home" "$w/th")
assert_contains "$out" "ORPHAN_SLOT: slot=$w/th/pool/1/repo " "an idle orphan claim reports its slot"
assert_contains "$out" "treehouse destroy $w/th/pool/1/repo" "the slot line carries the preview command"
assert_not_contains "$out" "task-fresh" "a claim younger than the floor is a spawn in progress"
assert_equals 1 "$(printf '%s\n' "$out" | grep -c '^ORPHAN_')" "exactly one orphan line"
pass "idle orphan claim reports its slot; a fresh claim is left alone"
