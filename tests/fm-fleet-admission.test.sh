#!/usr/bin/env bash
# tests/fm-fleet-admission.test.sh - the opt-in fleet-wide worker ceiling.
#
# Every case drives the real bin/fm-spawn.sh, bin/fm-teardown.sh, bin/fm-control.sh,
# and bin/fm-fleet-admission.sh as subprocesses against a primary home and two
# local secondmate homes bound to it through their durable parent records. Only
# the terminal multiplexer is faked. Nothing reads implementation source.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
CONTROL="$ROOT/bin/fm-control.sh"
ADMISSION="$ROOT/bin/fm-fleet-admission.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-admission)

# make_fleet <name> <limit|none>
# Builds <case>/primary plus secondmate homes <case>/sm-a and <case>/sm-b whose
# parent records bind them to the primary, and a shared fake-tmux fakebin.
make_fleet() {
  local name=$1 limit=$2 case_dir sm
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fm_test_spawn_home "$case_dir/primary" codex
  for sm in sm-a sm-b; do
    fm_test_spawn_home "$case_dir/$sm" codex
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' \
      "$case_dir/primary" > "$case_dir/$sm/.fm-secondmate-parent"
  done
  [ "$limit" = none ] || printf '%s\n' "$limit" > "$case_dir/primary/config/fleet-crew-limit"
  fm_test_make_spawn_fakebin "$case_dir/fake" >/dev/null
  add_failable_tmux "$case_dir/fake/fakebin"
  CASE=$case_dir
  FAKEBIN=$case_dir/fake/fakebin
}

# The spawn tmux stub, wrapped so a case can fail endpoint creation
# (FM_FAKE_NEW_WINDOW_FAIL=1) or park inside it until a release file appears
# (FM_FAKE_NEW_WINDOW_PARK=<file>), all without touching a real tmux server.
add_failable_tmux() {  # <fakebin>
  mv "$1/tmux" "$1/tmux.spawn"
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  new-window|new-session)
    [ "${FM_FAKE_NEW_WINDOW_FAIL:-0}" != 1 ] || exit 1
    if [ -n "${FM_FAKE_NEW_WINDOW_PARK:-}" ]; then
      while [ ! -e "$FM_FAKE_NEW_WINDOW_PARK" ]; do sleep 0.05; done
    fi
    ;;
esac
exec "$(dirname "$0")/tmux.spawn" "$@"
SH
  chmod +x "$1/tmux"
}

# prep_task <home> <id>: an isolated project worktree and brief for one task.
prep_task() {
  local home=$1 id=$2
  fm_git_worktree "$CASE/proj-$id" "$CASE/wt-$id" "wt-$id"
  fm_test_spawn_brief "$home" "$id"
}

# spawn_task <home> <id>: the real spawn for a prepared task, in the foreground.
spawn_task() {
  fm_test_run_spawn "$1" "$CASE/wt-$2" "$FAKEBIN" "$2" "$CASE/proj-$2" \
    --mode no-mistakes --yolo off
}

admission() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE='' "$ADMISSION" "$@" 2>&1
}

held() {  # <home>
  admission "$1" status | sed -n 's/^held: //p'
}

teardown_task() {  # <home> <id>
  mkdir -p "$1/user-home"
  FM_HOME="$1" FM_ROOT_OVERRIDE='' HOME="$1/user-home" PATH="$FAKEBIN:$PATH" \
    FM_SPAWN_NO_GUARD=1 "$TEARDOWN" "$2" 2>&1
}

test_default_off_is_unchanged() {
  local id out
  make_fleet default-off none
  for id in off-p1 off-p2 off-p3; do prep_task "$CASE/primary" "$id"; done
  prep_task "$CASE/sm-a" off-a1
  for id in off-p1 off-p2 off-p3; do
    out=$(spawn_task "$CASE/primary" "$id") || fail "spawn $id without a ceiling should succeed: $out"
  done
  out=$(spawn_task "$CASE/sm-a" off-a1) || fail "secondmate spawn without a ceiling should succeed: $out"
  [ ! -e "$CASE/primary/state/fleet-admission" ] \
    || fail "a fleet with no ceiling configured must keep no admission ledger"
  out=$(admission "$CASE/sm-a" status) || fail "status without a ceiling should succeed: $out"
  assert_contains "$out" 'fleet worker ceiling: off' "status names the ceiling as off"
  pass "without config/fleet-crew-limit every spawn behaves as before and no ledger exists"
}

# Three homes race for two slots. Every interleaving must admit exactly two.
test_concurrent_homes_never_exceed_the_ceiling() {
  local round home id pids ok refused rc i out
  for round in 1 2 3; do
    make_fleet "race-$round" 2
    prep_task "$CASE/primary" "race$round-p"
    prep_task "$CASE/sm-a" "race$round-a"
    prep_task "$CASE/sm-b" "race$round-b"
    pids=()
    i=0
    for home in primary sm-a sm-b; do
      case "$home" in primary) id="race$round-p" ;; sm-a) id="race$round-a" ;; sm-b) id="race$round-b" ;; esac
      spawn_task "$CASE/$home" "$id" > "$CASE/out-$i" 2>&1 &
      pids+=("$!")
      i=$((i + 1))
    done
    ok=0
    refused=0
    i=0
    for rc in "${pids[@]}"; do
      if wait "$rc"; then
        ok=$((ok + 1))
      elif grep -q 'fleet worker ceiling of 2 is reached' "$CASE/out-$i"; then
        refused=$((refused + 1))
      else
        fail "race round $round: a spawn failed for a reason other than the ceiling: $(cat "$CASE/out-$i")"
      fi
      i=$((i + 1))
    done
    assert_equals 2 "$ok" "race round $round: exactly two of three concurrent spawns may be admitted"
    assert_equals 1 "$refused" "race round $round: the third concurrent spawn must be refused at the ceiling"
    assert_equals 2 "$(held "$CASE/sm-b")" "race round $round: the shared ledger holds exactly two claims"
    for home in sm-a sm-b; do
      [ ! -e "$CASE/$home/state/fleet-admission" ] \
        || fail "race round $round: secondmate home $home must use the primary's ledger, not its own"
    done
    out=$(admission "$CASE/primary" status)
    assert_equals 2 "$(printf '%s\n' "$out" | grep -c '^live ship ')" \
      "race round $round: both admitted workers read live from the primary"
  done
  pass "concurrent spawns from the primary and two secondmate homes never exceed a ceiling of two"
}

test_blocked_third_release_and_supervisors_free() {
  local out status
  make_fleet block-release 2
  prep_task "$CASE/primary" blk-p1
  prep_task "$CASE/sm-a" blk-a1
  prep_task "$CASE/sm-b" blk-b1
  out=$(spawn_task "$CASE/primary" blk-p1) || fail "first worker should be admitted: $out"
  out=$(spawn_task "$CASE/sm-a" blk-a1) || fail "second worker should be admitted: $out"

  # A persistent secondmate's own record is a supervisor, never a worker.
  printf 'window=fm:fm-sm-a\nkind=secondmate\nhome=%s\n' "$CASE/sm-a" > "$CASE/primary/state/sm-a.meta"
  out=$(admission "$CASE/primary" adopt) || fail "adopt should succeed: $out"
  assert_equals 2 "$(held "$CASE/primary")" "a secondmate record must never take a worker slot"
  rm -f "$CASE/primary/state/sm-a.meta"

  out=$(spawn_task "$CASE/sm-b" blk-b1)
  status=$?
  [ "$status" -ne 0 ] || fail "a third worker must be refused at a ceiling of two"
  assert_contains "$out" 'fleet worker ceiling of 2 is reached' "the refusal names the ceiling"
  [ ! -e "$CASE/sm-b/state/blk-b1.meta" ] || fail "a refused spawn must leave no task record"
  assert_equals 2 "$(held "$CASE/primary")" "a refused spawn must not take a slot"

  out=$(teardown_task "$CASE/sm-a" blk-a1) || fail "teardown of a finished worker should succeed: $out"
  assert_equals 1 "$(held "$CASE/primary")" "teardown returns the worker's slot"
  out=$(spawn_task "$CASE/sm-b" blk-b1) || fail "the queued worker should be admitted once a slot frees: $out"
  assert_equals 2 "$(held "$CASE/primary")" "the freed slot is taken by the next worker"
  pass "a third worker is refused, supervisors hold no slot, and teardown frees a slot for the next worker"
}

test_launch_failure_returns_slot_and_retry_is_idempotent() {
  local out status
  make_fleet launch-fail 2
  prep_task "$CASE/primary" lf-p1
  prep_task "$CASE/sm-a" lf-a1
  out=$(spawn_task "$CASE/primary" lf-p1) || fail "first worker should be admitted: $out"
  out=$(FM_FAKE_NEW_WINDOW_FAIL=1 spawn_task "$CASE/sm-a" lf-a1)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose endpoint cannot be created must fail: $out"
  [ ! -e "$CASE/sm-a/state/lf-a1.meta" ] || fail "a failed launch must leave no task record"
  assert_equals 1 "$(held "$CASE/primary")" "a launch that failed before its record existed returns its slot"
  out=$(spawn_task "$CASE/sm-a" lf-a1) || fail "retrying the failed launch should be admitted: $out"
  assert_equals 2 "$(held "$CASE/primary")" "the retried launch holds exactly one slot"
  pass "a failed launch returns its slot and a retry takes exactly one"
}

# A spawn killed outright can have started a worker, so its claim is never
# reclaimed on inference: it keeps counting until the same task is retried or an
# operator releases it explicitly.
test_killed_spawn_is_never_silently_reclaimed() {
  local out claim pid status
  make_fleet killed 2
  prep_task "$CASE/primary" kill-p1
  prep_task "$CASE/sm-a" kill-a1
  prep_task "$CASE/sm-b" kill-b1
  out=$(spawn_task "$CASE/primary" kill-p1) || fail "first worker should be admitted: $out"
  FM_FAKE_NEW_WINDOW_PARK="$CASE/unpark" spawn_task "$CASE/sm-a" kill-a1 > "$CASE/parked.out" 2>&1 &
  for _ in $(seq 1 200); do
    claim=$(grep -l '^task=kill-a1$' "$CASE/primary/state/fleet-admission/"*.claim 2>/dev/null | head -1)
    [ -z "$claim" ] || break
    sleep 0.05
  done
  [ -n "$claim" ] || fail "the parked spawn never claimed a slot: $(cat "$CASE/parked.out")"
  out=$(admission "$CASE/primary" status)
  assert_contains "$out" 'spawning ship kill-a1' "a claim whose spawn is running reads spawning"
  pid=$(sed -n 's/^pid=//p' "$claim")
  out=$(admission "$CASE/primary" release kill-a1 --home "$CASE/sm-a")
  status=$?
  [ "$status" -ne 0 ] || fail "releasing a claim whose spawn is still running must refuse"
  kill -9 "$pid" 2>/dev/null || fail "could not stop the parked spawn $pid"
  touch "$CASE/unpark"
  wait 2>/dev/null || true

  out=$(admission "$CASE/primary" status)
  status=$?
  expect_code 2 "$status" "status reports an orphaned claim for a decision"
  assert_contains "$out" 'orphaned ship kill-a1' "a killed spawn's claim reads orphaned"
  if spawn_task "$CASE/sm-b" kill-b1 >/dev/null; then
    fail "an orphaned claim must keep counting against the ceiling"
  fi

  if FM_FAKE_NEW_WINDOW_FAIL=1 spawn_task "$CASE/sm-a" kill-a1 >/dev/null; then
    fail "a retry whose endpoint cannot be created must fail"
  fi
  assert_equals 2 "$(held "$CASE/primary")" "a failed retry must not drop a claim an earlier attempt may still be using"
  out=$(spawn_task "$CASE/sm-a" kill-a1) || fail "retrying the killed spawn should reuse its claim: $out"
  assert_equals 2 "$(held "$CASE/primary")" "the retried task reuses its claim rather than taking another"
  pass "a killed spawn keeps its slot until retried or explicitly released"
}

# bin/fm-control.sh relaunch drives fm-spawn --relaunch. This stub models just
# enough pane lifecycle for that transaction: the exit command leaves a bare
# shell behind and the launch literal starts the harness again.
make_relaunch_tmux() {  # <fakebin>
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) printf 'codex' > "$D/command" ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/sleep"
  chmod +x "$1/sleep"
}

relaunch_task() {  # <home> <id>
  local dir="$CASE/relaunch-$2"
  mkdir -p "$dir/fake" "$dir/fakebin" "$dir/user-home"
  make_relaunch_tmux "$dir/fakebin"
  printf 'codex' > "$dir/fake/command"
  printf '%s\n' "fm-$2" > "$dir/fake/windows"
  printf '%s' "$CASE/wt-$2" > "$dir/fake/cwd"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$1" FM_ROOT_OVERRIDE='' FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$2" relaunch --note 'replacement continues the same task' 2>&1
}

# A task recorded before the ceiling was enabled.
legacy_task_record() {  # <home> <id>
  prep_task "$1" "$2"
  {
    echo "window=fmses:fm-$2"
    echo "endpoint_task_id=$2"
    echo "worktree=$CASE/wt-$2"
    echo "project=$CASE/proj-$2"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=$CASE/tasktmp-$2"
    echo "model=default"
    echo "effort=default"
  } > "$1/state/$2.meta"
}

test_relaunch_keeps_or_adopts_its_claim() {
  local out status
  make_fleet relaunch 2
  legacy_task_record "$CASE/sm-a" rl-a1
  legacy_task_record "$CASE/sm-b" rl-b1
  prep_task "$CASE/primary" rl-p1
  prep_task "$CASE/primary" rl-p2
  out=$(spawn_task "$CASE/primary" rl-p1) || fail "first worker should be admitted: $out"

  out=$(relaunch_task "$CASE/sm-a" rl-a1) || fail "relaunching an unclaimed legacy task with a free slot should succeed: $out"
  assert_equals 2 "$(held "$CASE/primary")" "a relaunched legacy task takes one slot"
  out=$(relaunch_task "$CASE/sm-a" rl-a1) || fail "relaunching an already claimed task at the ceiling should succeed: $out"
  assert_equals 2 "$(held "$CASE/primary")" "a relaunch keeps its claim instead of taking another"

  out=$(relaunch_task "$CASE/sm-b" rl-b1)
  status=$?
  [ "$status" -ne 0 ] || fail "relaunching an unclaimed legacy task with no free slot must refuse"
  assert_contains "$out" 'fleet worker ceiling of 2 is reached' "the relaunch refusal names the ceiling"
  assert_equals 2 "$(held "$CASE/primary")" "a refused relaunch takes no slot"
  pass "a relaunch keeps its task's claim, and adopts one for a legacy task only when a slot is free"
}

# A replacement primary session in the same home starts from nothing but the
# durable ledger: capacity is neither reset nor rebuilt, orphaned slots need an
# explicit release, and adoption brings pre-ceiling work under the count.
test_replacement_supervisor_reconciles_without_reset() {
  local out status
  make_fleet replacement none
  legacy_task_record "$CASE/primary" rp-p0
  legacy_task_record "$CASE/sm-a" rp-a0
  printf '2\n' > "$CASE/primary/config/fleet-crew-limit"
  out=$(admission "$CASE/primary" adopt) || fail "adopt in the primary should succeed: $out"
  out=$(admission "$CASE/sm-a" adopt) || fail "adopt in a secondmate home should succeed: $out"
  assert_equals 2 "$(held "$CASE/primary")" "adoption brings every pre-ceiling worker under the count"
  out=$(admission "$CASE/sm-a" adopt) || fail "a repeated adopt should succeed: $out"
  assert_equals 2 "$(held "$CASE/primary")" "adoption is idempotent"

  # The old session is gone; the replacement reads the same durable ledger.
  out=$(admission "$CASE/primary" status)
  status=$?
  expect_code 0 "$status" "status is clean when every claim is live"
  assert_contains "$out" 'held: 2' "the replacement sees the capacity its predecessor left"
  prep_task "$CASE/sm-b" rp-b1
  if spawn_task "$CASE/sm-b" rp-b1 >/dev/null; then
    fail "a replacement session must not get fresh capacity"
  fi

  # One task's record disappears without a teardown: ambiguous, so reported.
  rm -f "$CASE/sm-a/state/rp-a0.meta"
  out=$(admission "$CASE/primary" status)
  status=$?
  expect_code 2 "$status" "status flags an orphaned claim"
  assert_contains "$out" 'orphaned ship rp-a0' "the orphaned claim is named"
  if spawn_task "$CASE/sm-b" rp-b1 >/dev/null; then
    fail "an orphaned claim is never reclaimed without an explicit release"
  fi

  if admission "$CASE/primary" release rp-p0 >/dev/null; then
    fail "releasing a live task's claim must refuse"
  fi
  out=$(admission "$CASE/primary" release rp-a0 --home "$CASE/sm-a") \
    || fail "releasing an orphaned claim should succeed: $out"
  out=$(admission "$CASE/primary" status) || fail "status is clean after the explicit release: $out"
  out=$(spawn_task "$CASE/sm-b" rp-b1) || fail "the explicitly released slot is available: $out"
  assert_equals 2 "$(held "$CASE/primary")" "the released slot was taken once"
  pass "a replacement supervisor inherits the ledger, reports orphans, and frees them only on explicit release"
}

test_invalid_ceiling_refuses() {
  local out status
  make_fleet invalid none
  printf 'two\n' > "$CASE/primary/config/fleet-crew-limit"
  prep_task "$CASE/sm-a" inv-a1
  out=$(spawn_task "$CASE/sm-a" inv-a1)
  status=$?
  [ "$status" -ne 0 ] || fail "an unreadable ceiling must refuse rather than guess"
  assert_contains "$out" 'must hold one positive integer' "the refusal names the malformed ceiling"
  [ ! -e "$CASE/sm-a/state/inv-a1.meta" ] || fail "a refused spawn must leave no task record"
  pass "a malformed ceiling refuses the spawn"
}

test_default_off_is_unchanged
test_concurrent_homes_never_exceed_the_ceiling
test_blocked_third_release_and_supervisors_free
test_launch_failure_returns_slot_and_retry_is_idempotent
test_killed_spawn_is_never_silently_reclaimed
test_relaunch_keeps_or_adopts_its_claim
test_replacement_supervisor_reconciles_without_reset
test_invalid_ceiling_refuses
