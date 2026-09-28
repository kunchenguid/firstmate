#!/usr/bin/env bash
# tests/fm-fleet-seats.test.sh - fleet-wide seat pools across a primary home,
# its registered local secondmate homes, and a remote-parented home, driven
# through bin/fm-fleet-seats.sh and the real bin/fm-spawn.sh and
# bin/fm-teardown.sh (fake tmux, real git worktree). Holders are real
# processes. docs/configuration.md "Fleet seat pools" owns the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-seats)
SEATS="$ROOT/bin/fm-fleet-seats.sh"
HOLDER_PIDS=

cleanup_holders() {
  local pid
  for pid in $HOLDER_PIDS; do
    kill "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_holders EXIT

new_holder() {  # start a fresh live holder process; sets LAST_HOLDER
  sleep 600 >/dev/null 2>&1 &
  HOLDER_PIDS="$HOLDER_PIDS $!"
  LAST_HOLDER=$!
}

make_home() {  # <dir>
  mkdir -p "$1/state" "$1/config" "$1/data"
}

pools() {  # <home> <capacity> [models-json]
  printf '{"pools":[{"name":"john-qwen","capacity":%s,"models":%s}]}\n' \
    "$2" "${3:-[\"pool-model-a\",\"pool-model-b\"]}" > "$1/config/fleet-seats"
}

make_local_secondmate() {  # <dir> <root> <id>
  make_home "$1"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$2" > "$1/.fm-secondmate-parent"
  printf '%s\n' "$3" > "$1/.fm-secondmate-home"
  printf -- '- %s - Test mate. (home: %s; scope: tests; projects: ; added 2026-09-28)\n' "$3" "$1" \
    >> "$2/data/secondmates.md"
}

make_remote_secondmate() {  # <dir> <id>
  make_home "$1"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=primary\n' > "$1/.fm-secondmate-parent"
  printf '%s\n' "$2" > "$1/.fm-secondmate-home"
}

task_record() {  # <home> <task> <model> [kind]
  printf 'kind=%s\nmodel=%s\nharness=pi\n' "${4:-ship}" "$3" > "$1/state/$2.meta"
}

seats() {  # <home> <args...>: run the script as that home
  local home=$1
  shift
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$home" "$SEATS" "$@"
}

reserve() {  # <home> <task> <model>: reserve for the most recent holder
  seats "$1" reserve "$2" --model "$3" --holder-pid "$LAST_HOLDER"
}

test_no_pool_configured_is_off() {
  local home="$TMP_ROOT/off/primary" out status
  make_home "$home"
  new_holder
  out=$(seats "$home" reserve t1 --model pool-model-a --holder-pid "$LAST_HOLDER" 2>&1)
  status=$?
  expect_code 0 "$status" "reserve with no pool"
  assert_equals "" "$out" "reserve with no pool should print nothing"
  out=$(seats "$home" status 2>&1)
  assert_contains "$out" "no pools configured" "status with no pool"
  pass "without config/fleet-seats a reservation is a silent no-op"
}

test_one_capacity_across_homes() {
  local root="$TMP_ROOT/shared/primary" mate="$TMP_ROOT/shared/android" out status
  make_home "$root"
  pools "$root" 3
  make_local_secondmate "$mate" "$root" android
  # A worker launched before the pool existed holds a seat with no reservation,
  # and a persistent secondmate agent on the pooled model holds none.
  task_record "$root" legacy-r1 pool-model-a
  task_record "$root" android pool-model-a secondmate

  new_holder
  out=$(reserve "$mate" a1 pool-model-a 2>&1) || fail "secondmate reserve a1 failed: $out"
  assert_contains "$out" "used=2 capacity=3" "the legacy worker was not counted"
  new_holder
  out=$(reserve "$root" r2 pool-model-b 2>&1) || fail "primary reserve r2 failed: $out"
  assert_contains "$out" "used=3 capacity=3" "the secondmate's seat was not counted by the primary"

  new_holder
  out=$(reserve "$mate" a2 pool-model-a 2>&1)
  status=$?
  expect_code 4 "$status" "a fourth seat across the two homes"
  assert_contains "$out" "pool john-qwen is full (3 of 3 seats held)" "full-pool refusal"
  assert_contains "$out" "legacy-r1" "the refusal did not name the holders"

  new_holder
  out=$(reserve "$mate" a1 pool-model-a 2>&1) || fail "a holder's own relaunch was refused: $out"
  assert_contains "$out" "already held" "a relaunch did not keep its seat"
  new_holder
  out=$(reserve "$mate" a3 some-other-model 2>&1) || fail "an unpooled model was refused: $out"
  assert_equals "" "$out" "an unpooled model should reserve nothing"

  out=$(seats "$mate" status)
  assert_contains "$out" "pool john-qwen capacity=3 used=3 free=0" "status seen from the secondmate"
  pass "the primary and a local secondmate share one capacity, legacy workers count, secondmate agents do not"
}

test_stale_reservations_recover_without_preempting_live_work() {
  local root="$TMP_ROOT/stale/primary" out status crashed live
  make_home "$root"
  pools "$root" 2
  new_holder
  out=$(reserve "$root" crashed pool-model-a 2>&1) || fail "reserve crashed: $out"
  crashed=$LAST_HOLDER
  new_holder
  out=$(reserve "$root" running pool-model-a 2>&1) || fail "reserve running: $out"
  live=$LAST_HOLDER
  # The running task published its record; its spawner then exited.
  task_record "$root" running pool-model-a
  kill "$live" "$crashed"
  wait "$live" "$crashed" 2>/dev/null

  new_holder
  out=$(reserve "$root" next pool-model-a 2>&1) || fail "a crashed spawn's seat was not recovered: $out"
  assert_contains "$out" "used=2 capacity=2" "recovery count"
  new_holder
  out=$(reserve "$root" extra pool-model-a 2>&1)
  status=$?
  expect_code 4 "$status" "the running worker's seat was preempted"

  # A relaunch onto another route releases the seat through its record.
  task_record "$root" running gpt-6-sol
  new_holder
  out=$(reserve "$root" extra pool-model-a 2>&1) || fail "a relaunch onto another route kept its seat: $out"
  # Cleanup removes the record, which releases the seat with no extra step.
  rm -f "$root/state/extra.meta"
  task_record "$root" next pool-model-a
  out=$(seats "$root" status)
  assert_contains "$out" "used=2" "status after recovery"
  pass "dead reservations are reclaimed while a live task record keeps its seat"
}

test_simultaneous_reservations_never_overbook() {
  local root="$TMP_ROOT/race/primary" mate="$TMP_ROOT/race/mate" dir="$TMP_ROOT/race/out" i home granted refused racers=
  make_home "$root"
  pools "$root" 6
  make_local_secondmate "$mate" "$root" mate
  mkdir -p "$dir"
  new_holder
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    home=$root
    [ $((i % 2)) -eq 0 ] || home=$mate
    ( seats "$home" reserve "race-$i" --model pool-model-a --holder-pid "$LAST_HOLDER" \
        >"$dir/$i.out" 2>&1; echo $? > "$dir/$i.rc" ) &
    racers="$racers $!"
  done
  # shellcheck disable=SC2086 # one pid per word
  wait $racers
  granted=$(grep -lx 0 "$dir"/*.rc | wc -l | tr -d ' ')
  refused=$(grep -lx 4 "$dir"/*.rc | wc -l | tr -d ' ')
  assert_equals 6 "$granted" "granted seats under contention"
  assert_equals 6 "$refused" "refused seats under contention"
  assert_contains "$(seats "$root" status)" "used=6 free=0" "status after contention"
  pass "twelve simultaneous reservations from two homes grant exactly six seats"
}

test_unreachable_authority_is_never_a_free_seat() {
  local base="$TMP_ROOT/unreachable" remote root mate out status blocker
  remote="$base/theshop"
  make_remote_secondmate "$remote" theshop
  pools "$remote" 6
  new_holder
  out=$(reserve "$remote" r1 pool-model-a 2>&1)
  status=$?
  expect_code 5 "$status" "a pooled model on a remote-parented home"
  assert_contains "$out" "fleet root on another host" "remote refusal reason"
  new_holder
  out=$(reserve "$remote" r2 gpt-6-sol 2>&1) || fail "an unpooled model was refused on a remote home: $out"

  root="$base/primary"
  make_home "$root"
  pools "$root" 6
  # The lock library's owner is this process's pid, and exec keeps that pid for
  # the sleep, so killing the blocker releases the lock with no orphan left.
  bash -c '. "$1/bin/fm-wake-lib.sh" && fm_lock_try_acquire "$2" && : > "$3" && exec sleep 600' \
    _ "$ROOT" "$root/state/.fleet-seats.lock" "$base/locked" &
  blocker=$!
  HOLDER_PIDS="$HOLDER_PIDS $blocker"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -e "$base/locked" ] && break
    sleep 0.1
  done
  [ -e "$base/locked" ] || fail "the blocking lock holder never started"
  new_holder
  out=$(FM_FLEET_SEATS_LOCK_WAIT=1 seats "$root" reserve l1 --model pool-model-a --holder-pid "$LAST_HOLDER" 2>&1)
  status=$?
  expect_code 5 "$status" "a lock held by another live process"
  assert_contains "$out" "stayed held" "lock refusal reason"
  kill "$blocker" 2>/dev/null
  wait "$blocker" 2>/dev/null

  out=$(seats "$root" reserve l2 --model pool-model-a --holder-pid 999999 2>&1)
  expect_code 5 "$?" "a dead holder pid"

  mate="$base/mate"
  make_local_secondmate "$mate" "$root" mate
  chmod 000 "$mate/state"
  new_holder
  out=$(reserve "$root" l3 pool-model-a 2>&1)
  status=$?
  chmod 755 "$mate/state"
  if [ "$(id -u)" -ne 0 ]; then
    expect_code 5 "$status" "a registered home whose tasks cannot be listed"
  fi

  printf '{"pools":[{"name":"john-qwen","capacity":"six","models":["pool-model-a"]}]}\n' > "$root/config/fleet-seats"
  new_holder
  out=$(reserve "$root" l4 unrelated-model 2>&1)
  status=$?
  expect_code 5 "$status" "a malformed pool declaration"
  assert_contains "$out" "malformed" "malformed refusal reason"
  pass "a remote parent, a held lock, a dead holder, an unreadable home, and a malformed pool all refuse"
}

# --- spawn and cleanup ------------------------------------------------------

make_spawn_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse no-mistakes
  printf '%s\n' "$fakebin"
}

spawn_case() {  # <name>: sets HOME_DIR PROJ_DIR WT_DIR FAKEBIN TASK
  local dir="$TMP_ROOT/$1"
  HOME_DIR="$dir/home"
  PROJ_DIR="$dir/sample"
  TASK="$1-t1"
  WT_DIR="$dir/wt"
  mkdir -p "$HOME_DIR/data/$TASK" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/user-home"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  touch "$HOME_DIR/state/.last-watcher-beat"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "fm/$TASK"
  cat > "$HOME_DIR/data/$TASK/brief.md" <<EOF
# Task
## Captain's intent
Exercise fleet seats for $TASK.

## Firstmate spec
Nothing to build.
EOF
  FAKEBIN=$(make_spawn_fakebin "$dir")
}

in_home() {  # the fake tmux backend is pinned so no real terminal is ever created
  env -u FM_TRACE_CONTEXT FM_BACKEND=tmux FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    PATH="$FAKEBIN:$PATH" "$@"
}

test_spawn_refuses_a_full_pool_before_any_record() {
  local out status
  spawn_case spawn-full
  pools "$HOME_DIR" 1
  task_record "$HOME_DIR" busy pool-model-a
  out=$(in_home "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ_DIR" --mode local-only --yolo off \
    --harness claude --model pool-model-a 2>&1)
  status=$?
  expect_code 1 "$status" "spawn into a full pool"
  assert_contains "$out" "pool john-qwen is full" "spawn refusal reason"
  assert_absent "$HOME_DIR/state/$TASK.meta" "a refused spawn published a task record"

  out=$(in_home "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ_DIR" --mode local-only --yolo off \
    --harness claude --model gpt-6-sol 2>&1) || fail "an unpooled spawn was refused: $out"
  pass "a pooled spawn into a full pool refuses before any record, and another route still launches"
}

test_spawn_holds_a_seat_until_cleanup() {
  local out
  spawn_case spawn-seat
  pools "$HOME_DIR" 1
  out=$(in_home "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ_DIR" --mode local-only --yolo off \
    --harness claude --model pool-model-a 2>&1) || fail "pooled spawn failed: $out"
  out=$(in_home "$SEATS" status)
  assert_contains "$out" "used=1 free=0" "the spawned worker holds no seat"
  assert_contains "$out" "$TASK" "the seat does not name the spawned task"
  out=$(in_home "$ROOT/bin/fm-teardown.sh" "$TASK" 2>&1) || fail "cleanup failed: $out"
  out=$(in_home "$SEATS" status)
  assert_contains "$out" "used=0 free=1" "cleanup did not release the seat"
  pass "a spawned pooled worker holds its seat until cleanup removes its record"
}

test_no_pool_configured_is_off
test_one_capacity_across_homes
test_stale_reservations_recover_without_preempting_live_work
test_simultaneous_reservations_never_overbook
test_unreachable_authority_is_never_a_free_seat
test_spawn_refuses_a_full_pool_before_any_record
test_spawn_holds_a_seat_until_cleanup
