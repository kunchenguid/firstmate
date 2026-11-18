#!/usr/bin/env bash
# Goal-stall wake and the goal-aware drive floor, through the watcher's real
# queue interface. Real goal records (bin/fm-goal.sh in a lab home) feed the
# tick; only the crew-state verdict and the page-host list are stubbed through
# their documented seams (FM_CREW_STATE_BIN, FM_DRIVE_FLOOR_PROCEVENT_BIN).
# No endpoint, harness process, model call, or remote host is needed.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-goal-stall)
export FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config" FM_DATA_OVERRIDE="$TMP_ROOT/data"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE" "$FM_DATA_OVERRIDE"

STUB="$TMP_ROOT/crew-state-stub.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
cat "$FM_STATE_OVERRIDE/$1.crew-state-line" 2>/dev/null || printf 'state: unknown · source: none · no metadata for %s\n' "$1"
EOF
chmod +x "$STUB"
export FM_CREW_STATE_BIN="$STUB"

# The page-host list, as `fm-procevent.sh list` prints it: a header, then one
# row per source whose owner column is task:<id>/<listening|dead|round-open>.
HOSTS="$TMP_ROOT/procevent-stub.sh"
cat > "$HOSTS" <<'EOF'
#!/usr/bin/env bash
printf 'SOURCE ADAPTER OWNER PENDING\n'
cat "$FM_STATE_OVERRIDE/.stub-hosts" 2>/dev/null || true
EOF
chmod +x "$HOSTS"
export FM_DRIVE_FLOOR_PROCEVENT_BIN="$HOSTS"

# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

DRIVE_FLOOR_SCAN_SECS=0
PAUSE_RESURFACE_SECS=10000
GOAL="$ROOT/bin/fm-goal.sh"

reset_case() {
  rm -rf -- "${STATE:?}"/* "${STATE:?}"/.[!.]* "${CONFIG:?}"/* "${FM_DATA_OVERRIDE:?}"/*
  mkdir -p "$STATE/procevent"
  DRIVE_FLOOR=
  GOAL_STALL=
}

floor() { printf '%s\n' "$1" > "$CONFIG/drive-floor"; }

lane() {  # <task> <crew-state line>
  printf 'working [at=1000]: on it\n' > "$STATE/$1.status"
  printf 'worktree=%s\nkind=ship\n' "$TMP_ROOT" > "$STATE/$1.meta"
  printf '%s\n' "$2" > "$STATE/$1.crew-state-line"
}

host() {  # <task> <listening|dead|round-open>
  printf 'src-%s lavish task:%s/%s 0\n' "$1" "$1" "$2" >> "$STATE/.stub-hosts"
}

WORKING='state: working · source: run-step · validating (running) · run: r1'
PARKED='state: parked · source: run-step · parked at rebase · run: r2'

start_goal() {  # <id> <items...>
  local id=$1; shift
  printf '%s\n' "$@" > "$TMP_ROOT/items.$id"
  "$GOAL" start "$id" --title "Goal $id" --done-when "$id is live" --named-by "finish $id" \
    --plan plan.md --items-file "$TMP_ROOT/items.$id" >/dev/null || fail "could not start goal $id"
}

count_wakes() {
  if [ -f "$FM_WAKE_QUEUE" ]; then wc -l < "$FM_WAKE_QUEUE" | tr -d ' '; else printf 0; fi
}

test_startable_command_lists_only_startable_items() {
  reset_case
  start_goal G1 'item [id=build] [owner=main] [task=t-build]: build' \
    'item [id=verify] [owner=main] [after=build]: verify' \
    'item [id=sign] [owner=captain] [class=captain]: sign'
  out=$("$GOAL" startable) || fail "startable failed"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "expected one startable item, got: $out"
  case "$out" in "G1"$'\t'"build"$'\t'"main"$'\t'"t-build"$'\t'[0-9]*) ;; *) fail "unexpected startable row: $out" ;; esac
  "$GOAL" mark G1 build running -- 'on it' >/dev/null
  case "$("$GOAL" startable)" in "G1"$'\t'"build"$'\t'"main"$'\t'"t-build"$'\t'[0-9]*) ;; *)
    fail "a running item with no task record behind it was not listed as orphaned startable" ;; esac
  lane t-build "$WORKING"
  [ -z "$("$GOAL" startable)" ] || fail "a running item with a live task stayed startable"
  "$GOAL" mark G1 build "done" -- 'landed' >/dev/null
  out=$("$GOAL" startable)
  case "$out" in "G1"$'\t'"verify"$'\t'*) ;; *) fail "finishing build did not unlock verify: $out" ;; esac
  pass "fm-goal.sh startable prints one row per startable item, an orphaned-running row included, and follows marks"
}

test_idle_startable_item_wakes_after_the_hold() {
  reset_case
  floor 2
  lane w1 "$WORKING"
  lane w2 "$WORKING"
  start_goal G1 'item [id=ship-ui] [owner=main]: ship the ui'
  drive_floor_tick 1000
  [ "$(count_wakes)" = 0 ] || fail "the stall fired at first sight"
  [ -f "$STATE/.goal-stall" ] || fail "no goal-stall episode was opened"
  drive_floor_tick 1899
  [ "$(count_wakes)" = 0 ] || fail "the stall fired one second before its hold"
  drive_floor_tick 1900
  [ "$(count_wakes)" = 1 ] || fail "the stall did not fire at its hold with the floor met"
  [ "$GOAL_STALL" = 'check: goal stalled: G1: ship-ui (owner=main) 900s (threshold 900s)' ] \
    || fail "unexpected goal-stall reason: $GOAL_STALL"
  [ -z "$DRIVE_FLOOR" ] || fail "a fleet at the floor raised a drive-floor wake: $DRIVE_FLOOR"
  grep -q 'goal-stall' "$FM_WAKE_QUEUE" || fail "the wake was queued under the wrong kind"
  drive_floor_tick 5000
  [ "$(count_wakes)" = 1 ] || fail "the stall repeated before the recheck cadence"
  drive_floor_tick 11900
  [ "$(count_wakes)" = 2 ] || fail "the stall did not repeat on the recheck cadence"
  pass "a startable goal item nobody is on wakes once past the hold, even at the floor, then repeats on the cadence"
}

test_an_item_with_a_working_task_or_a_mark_is_not_stalled() {
  reset_case
  floor 1
  lane w1 "$WORKING"
  lane t-build "$WORKING"
  lane t-docs "$WORKING"
  start_goal G1 'item [id=build] [owner=main] [task=t-build]: build' \
    'item [id=docs] [owner=main]: docs'
  drive_floor_tick 1000
  drive_floor_tick 2000
  case "$GOAL_STALL" in *'docs'*) ;; *) fail "the unowned item did not stall: $GOAL_STALL" ;; esac
  case "$GOAL_STALL" in *build*) fail "an item whose task lane is working was named: $GOAL_STALL" ;; esac
  "$GOAL" mark G1 docs running --task t-docs -- 'started' >/dev/null
  drive_floor_tick 3000
  [ ! -e "$STATE/.goal-stall" ] || fail "a running item kept its stall episode"
  pass "an item with a working task lane or a running mark is never named, and its episode drops"
}

test_an_orphaned_running_item_is_stalled_like_an_open_one() {
  reset_case
  floor 1
  lane w1 "$WORKING"
  # the exact shape of the running-with-no-live-task case: a running mark, a
  # task name that has no record at all in this home
  start_goal G1 'item [id=queue] [owner=main] [task=ghost-child]: keep the queue green'
  "$GOAL" mark G1 queue running -- 'on it' >/dev/null
  drive_floor_tick 1000
  drive_floor_tick 2000
  case "$GOAL_STALL" in *'queue'*) ;; *) fail "an orphaned-running item was not stalled: $GOAL_STALL" ;; esac
  grep -q 'goal-stall' "$FM_WAKE_QUEUE" || fail "the orphaned-running stall was not queued"
  # a dead verdict behind the mark stalls the same way
  rm -f -- "$STATE/.goal-stall"
  rm -f -- "$FM_WAKE_QUEUE"
  lane ghost-child 'state: failed · source: status-log · the task died'
  drive_floor_tick 3000
  drive_floor_tick 4000
  case "$GOAL_STALL" in *'queue'*) ;; *) fail "an item running over a dead task was not stalled: $GOAL_STALL" ;; esac
  pass "a running item with no task record or a dead one is stalled like an open item"
}

test_goal_items_count_as_work_for_the_drive_floor() {
  reset_case
  floor 8
  lane w1 "$WORKING"
  start_goal G1 'item [id=ship-ui] [owner=main]: ship the ui'
  drive_floor_tick 1000
  drive_floor_tick 1900
  [ "$DRIVE_FLOOR" = 'check: drive floor: 1 working < 8 900s (threshold 900s): idle: goal:G1/ship-ui=startable' ] \
    || fail "startable goal work did not open the floor alarm: $DRIVE_FLOOR"
  [ "$(count_wakes)" = 2 ] || fail "expected the floor and the stall wake, got $(count_wakes)"
  pass "a startable goal item is work waiting: the floor wake names it with no startable lane at all"
}

test_page_hosts_never_count_as_working() {
  reset_case
  floor 3
  lane busy "$WORKING"
  lane listening "$WORKING"
  lane parkedhost "$PARKED"
  lane deadhost "$WORKING"
  lane roundopen "$WORKING"
  host listening listening
  host deadhost dead
  host roundopen round-open
  printf '%s\n' "$TMP_ROOT/notes.md" > "$STATE/parkedhost.page-host-parked"
  drive_floor_tick 1000
  drive_floor_tick 1900
  [ "$DRIVE_FLOOR" = 'check: drive floor: 2 working < 3 900s (threshold 900s): idle: deadhost=page-host-dead' ] \
    || fail "page hosts were miscounted: $DRIVE_FLOOR"
  pass "live and parked page hosts are neither working nor startable, a dead host is startable, an open round keeps its verdict"
}

test_only_idle_page_hosts_stay_silent() {
  reset_case
  floor 5
  lane listening "$WORKING"
  lane parkedhost "$PARKED"
  host listening listening
  printf '%s\n' "$TMP_ROOT/notes.md" > "$STATE/parkedhost.page-host-parked"
  drive_floor_tick 1000
  drive_floor_tick 5000
  [ "$(count_wakes)" = 0 ] || fail "a fleet of only quiet page hosts raised a wake"
  pass "a fleet of only quiet page hosts has nothing to start and stays silent"
}

test_closing_or_removing_config_drops_the_ledger() {
  reset_case
  floor 1
  lane w1 "$WORKING"
  start_goal G1 'item [id=ship-ui] [owner=main]: ship the ui'
  drive_floor_tick 1000
  [ -f "$STATE/.goal-stall" ] || fail "no ledger was written"
  "$GOAL" close G1 --captain --words 'drop it' >/dev/null
  drive_floor_tick 2000
  [ ! -e "$STATE/.goal-stall" ] || fail "a closed goal kept its stall ledger"
  start_goal G2 'item [id=a] [owner=main]: a'
  drive_floor_tick 3000
  rm -f -- "$CONFIG/drive-floor"
  drive_floor_tick 4000
  [ ! -e "$STATE/.goal-stall" ] || fail "removing the config kept the stall ledger"
  pass "closing the goal or removing config/drive-floor drops the stall ledger"
}

test_a_home_without_goals_stays_unchanged() {
  reset_case
  floor 1
  lane w1 "$WORKING"
  drive_floor_tick 1000
  drive_floor_tick 5000
  [ "$(count_wakes)" = 0 ] || fail "a home without goals raised a wake"
  [ ! -e "$STATE/.goal-stall" ] || fail "a home without goals kept a stall ledger"
  pass "a home without goals behaves as the plain drive floor"
}

test_watcher_loop() {
  local dir="$TMP_ROOT/watcher-loop" pid i=0
  mkdir -p "$dir/state" "$dir/config" "$dir/data"
  fm_test_track_watcher_state "$dir/state"
  touch "$dir/state/home-summary.json"
  printf '1\n' > "$dir/config/drive-floor"
  printf 'working [at=1000]: on it\n' > "$dir/state/worker.status"
  printf 'worktree=%s\nkind=ship\n' "$dir" > "$dir/state/worker.meta"
  printf '%s\n' "$WORKING" > "$dir/state/worker.crew-state-line"
  printf '%s\n' 'item [id=ship-ui] [owner=main]: ship the ui' > "$dir/items"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    "$GOAL" start G1 --title t --done-when d --named-by n --plan p --items-file "$dir/items" >/dev/null \
    || fail "could not start the lab goal"
  # A ledger an earlier watcher left behind: the first-seen clock survives a restart.
  printf 'G1\tship-ui\t1000\t0\n' > "$dir/state/.goal-stall"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_DATA_OVERRIDE="$dir/data" FM_CREW_STATE_BIN="$STUB" \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/out" 2> "$dir/err" &
  pid=$!
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "real watcher failed to wake on a stalled goal item"
  fi
  wait "$pid" || fail "real watcher exited unsuccessfully: $(cat "$dir/err")"
  grep -F 'check: goal stalled: G1: ship-ui (owner=main) ' "$dir/out" >/dev/null \
    || fail "real watcher did not print the goal-stall wake: $(cat "$dir/out")"
  grep -F 'goal-stall' "$dir/state/.wake-queue" >/dev/null \
    || fail "real watcher did not durably queue the goal-stall wake"
  pass "the actual watcher wakes and exits on a stalled goal item, keeping the clock across a restart"
}

test_slow_cycle_probes_stages() {
  reset_case
  start_goal merge-goal 'item [id=ship] [owner=main] [task=ship-task] [project=miko] [target=live]: ship task'
  mkdir -p "$CONFIG/stage-ladders"
  printf 'stage merged: printf "merge evidence\\n"\nstage deployed: false\nstage live: false\n' > "$CONFIG/stage-ladders/miko"
  goal_probe_tick
  local out
  out=$(bash "$GOAL" show merge-goal)
  assert_contains "$out" 'stage: merged since' 'slow cycle advances the stage'
  assert_contains "$out" 'state: open (no mark yet)' 'merge does not finish the item'
  assert_grep 'probe passed for merged: merge evidence' "$STATE/goals/merge-goal.marks" 'merge probe evidence retained'
  goal_probe_tick
  assert_equals 1 "$(wc -l < "$STATE/goals/merge-goal.marks" | tr -d ' ')" 'repeated sweep is idempotent'
  pass 'slow cycle probes merged automatically without declaring done'
}

fm_test_run test_slow_cycle_probes_stages test_startable_command_lists_only_startable_items \
  test_idle_startable_item_wakes_after_the_hold \
  test_an_item_with_a_working_task_or_a_mark_is_not_stalled \
  test_an_orphaned_running_item_is_stalled_like_an_open_one \
  test_goal_items_count_as_work_for_the_drive_floor \
  test_page_hosts_never_count_as_working test_only_idle_page_hosts_stay_silent \
  test_closing_or_removing_config_drops_the_ledger test_a_home_without_goals_stays_unchanged \
  test_watcher_loop
