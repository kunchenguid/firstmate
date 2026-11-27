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
MATE_ROOT=$(fm_test_tmproot fm-watch-goal-stall-mate)
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
  "$GOAL" mark G1 build "done" -- 'landed https://github.com/example/example/pull/1' >/dev/null
  out=$("$GOAL" startable)
  case "$out" in "G1"$'\t'"verify"$'\t'*) ;; *) fail "finishing build did not unlock verify: $out" ;; esac
  pass "fm-goal.sh startable prints one row per startable item, an orphaned-running row included, and follows marks"
}

test_drive_switch_preserves_items_and_clears_stall() {
  reset_case
  floor 1
  lane t-live "$WORKING"
  start_goal G1 'item [id=live] [owner=main] [task=t-live]: finish existing work' \
    'item [id=open] [owner=main]: do not start automatically' \
    'item [id=manual] [owner=main]: captain can start this'
  "$GOAL" mark G1 live running -- 'already running' >/dev/null
  "$GOAL" export G1 | jq -e '.goals[0].driven == true' >/dev/null || fail 'legacy default is not driven'
  drive_floor_tick 1000
  [ -f "$STATE/.goal-stall" ] || fail 'no initial stall episode'

  "$GOAL" pause G1 >/dev/null
  [ "$("$GOAL" active)" = G1 ] || fail 'paused goal disappeared from active inventory'
  [ -z "$("$GOAL" active --driven)" ] || fail 'paused goal leaked into driven inventory'
  [ -z "$("$GOAL" startable)" ] || fail 'paused goal leaked into startable'
  out=$("$GOAL" brief)
  assert_contains "$out" 'GOAL G1 (active, drive off)' 'brief shows the goal is off'
  case "$out" in *'GOAL DUTY:'*|*'startable, nobody on it:'*) fail 'brief asks to drive a paused goal' ;; esac
  assert_contains "$("$GOAL" show G1)" 'drive: off since ' 'show exposes timestamped off state'
  "$GOAL" mark G1 manual running -- 'captain started this manually' >/dev/null
  "$GOAL" export G1 | jq -e '.goals[0] | .driven == false and
    ([.items[] | .state] == ["running","open","running"]) and
    ([.items[] | .startable] | all(. == false))' >/dev/null || fail 'off altered item state or manual marks'
  drive_floor_tick 1900
  [ ! -e "$STATE/.goal-stall" ] && [ "$(count_wakes)" = 0 ] || fail 'paused item kept its stall episode'

  "$GOAL" edit G1 --items-file "$TMP_ROOT/items.G1" --title 'Edited while off' >/dev/null
  "$GOAL" export G1 | jq -e '.goals[0].driven == false' >/dev/null || fail 'edit lost the drive switch'
  "$GOAL" resume G1 >/dev/null
  "$GOAL" export G1 | jq -e '.goals[0].driven == true' >/dev/null || fail 'resume did not restore drive'
  assert_contains "$("$GOAL" startable)" $'G1\topen\tmain' 'resume restored the open item'
  drive_floor_tick 2000
  [ "$(count_wakes)" = 0 ] || fail 'resume reused the old stall timer'
  drive_floor_tick 2900
  [ "$(count_wakes)" = 1 ] || fail 'resumed item did not open a fresh stall episode'
  pass 'pause suppresses automatic drive and stall, preserves manual work, and resume restores drive'
}

test_idle_startable_item_wakes_after_the_hold() {
  reset_case
  floor 2
  lane w1 "$WORKING"
  lane w2 "$WORKING"
  start_goal G1 'item [id=ship-ui] [owner=main]: ship the ui' \
    'item [id=build] [owner=main] [task=w1]: build' \
    'item [id=docs] [owner=main] [task=w2]: docs'
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

test_secondmate_task_home_and_parent_view() {
  reset_case
  floor 1
  local mate out before
  mate=$(mktemp -d "$TMP_ROOT/mate.XXXXXX")
  mkdir -p "$mate/state" "$mate/data" "$mate/config"
  printf 'terp\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$FM_HOME" > "$mate/.fm-secondmate-parent"
  printf -- '- terp - lab mate (home: %s; scope: lab; projects: lab; added 2026-11-27)\n' "$mate" \
    > "$FM_DATA_OVERRIDE/secondmates.md"
  printf 'kind=ship\n' > "$mate/state/alive.meta"
  printf '%s\n' "$WORKING" > "$mate/state/alive.crew-state-line"
  printf 'kind=ship\n' > "$mate/state/dead.meta"
  printf 'state: failed · source: status-log · the task died\n' > "$mate/state/dead.crew-state-line"
  start_goal G1 'item [id=live] [owner=terp] [task=alive]: live mate lane' \
    'item [id=lost] [owner=terp] [task=ghost]: missing mate lane' \
    'item [id=failed] [owner=terp] [task=dead]: failed mate lane' \
    'item [id=parent] [owner=main]: parent work' \
    'item [id=next] [owner=terp] [after=parent]: blocked by parent work'
  "$GOAL" mark G1 live running -- 'on it' >/dev/null
  "$GOAL" mark G1 lost running -- 'on it' >/dev/null
  "$GOAL" mark G1 failed running -- 'on it' >/dev/null
  before=$(cksum "$STATE/goals/G1.goal" "$STATE/goals/G1.marks")

  out=$("$GOAL" startable)
  assert_not_contains "$out" $'G1\tlive\t' 'live mate item is not startable in parent'
  assert_contains "$out" $'G1\tlost\tterp\tghost\t' 'missing mate task is startable'
  assert_contains "$out" $'G1\tfailed\tterp\tdead\t' 'failed mate task is startable'
  out=$("$GOAL" show G1)
  assert_equals 2 "$(grep -c 'orphaned running, no live task' <<< "$out")" 'show labels only missing and failed tasks as orphaned'
  out=$(FM_ROOT_OVERRIDE="$TMP_ROOT" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$out" 'running: live [terp, task alive' 'drain shows the running mate item'
  assert_not_contains "$out" 'live [terp] (orphaned running' 'drain does not list live task as orphaned'
  lane ghost "$WORKING" # A parent task with the same ID is not the mate's task.
  drive_floor_tick 1000
  drive_floor_tick 2000
  assert_not_contains "$GOAL_STALL" 'live (owner=terp)' 'live mate item did not open a stall'
  assert_contains "$GOAL_STALL" 'lost (owner=terp)' 'the parent namesake does not mask a true stall'
  assert_contains "$GOAL_STALL" 'failed (owner=terp)' 'the failed mate task opens a stall'

  mate_goal_command() {
    FM_HOME="$mate" FM_STATE_OVERRIDE="$mate/state" FM_DATA_OVERRIDE="$mate/data" FM_CONFIG_OVERRIDE="$mate/config" \
      "$GOAL" "$@"
  }
  out=$(mate_goal_command startable)
  assert_contains "$out" $'G1\tlost\tterp\tghost\t' 'mate sees its startable parent item'
  assert_not_contains "$out" $'G1\tlive\t' 'mate sees its running task as not startable'
  assert_not_contains "$out" $'G1\tparent\t' 'mate does not list parent-owned work'
  assert_not_contains "$out" $'G1\tnext\t' 'mate honors the dependency on parent-owned work'
  mate_goal_command export G1 | jq -e '.goals[0] | .progress.total == 4 and
    ([.items[].owner] | all(. == "terp")) and
    ([.items[] | select(.id == "live") | [.state, .startable]] == [["running", false]]) and
    ([.items[] | select(.id == "next") | .waiting_on] == [["parent"]])' >/dev/null \
    || fail 'mate export must retain folded state and dependencies, with owner-scoped counts'
  assert_equals "$before" "$(cksum "$STATE/goals/G1.goal" "$STATE/goals/G1.marks")" 'mate and parent reads did not rewrite goal records'

  "$GOAL" pause G1 >/dev/null
  assert_equals '' "$("$GOAL" startable)" 'parent startable skips the OFF goal'
  assert_equals '' "$(mate_goal_command startable)" 'mate startable skips the OFF parent goal'
  mate_goal_command export | jq -e '.goals[0] | .driven == false and ([.items[].startable] | all(. == false))' >/dev/null \
    || fail 'mate export must show the OFF switch without offering work'
  drive_floor_tick 3000
  [ ! -e "$STATE/.goal-stall" ] && [ -z "$GOAL_STALL" ] || fail 'OFF goal retained a stall episode'

  mv "$STATE/goals" "$STATE/real-goals"
  ln -s "$STATE/real-goals" "$STATE/goals"
  assert_equals '{"schema":"fm-goal-export.v1","goals":[]}' "$(mate_goal_command export)" 'mate refuses a symlinked parent goal directory'
  pass 'two homes: live mate work is not orphaned; missing and failed tasks stall; mate reads only owned work; OFF suppresses drive'
}

mate_worker_cache() {  # <generated-epoch>
  local mate="$MATE_ROOT" cache="$STATE/secondmate-summary-cache" key
  mkdir -p "$mate/state" "$mate/data" "$mate/bin" "$cache"
  printf 'miko\n' > "$mate/.fm-secondmate-home"
  printf '# mate lab\n' > "$mate/AGENTS.md"
  printf '#!/usr/bin/env bash\n' > "$mate/bin/true"
  printf '%s\n' "- miko - Fixture mate (home: $mate; scope: fixture; projects: ; added 2026-10-28)" \
    > "$FM_DATA_OVERRIDE/secondmates.md"
  key=$(printf '%s\n%s\n%s\n' miko '' "$mate" | shasum -a 256 | awk '{print $1}')
  jq -n --arg home "$mate" --argjson gen "$1" '
    {schema:"fm-live-board-input.v1", fm_home:$home, generated_epoch:$gen,
     tasks:[{id:"build-task", current_state:{state:"working"}}]}' > "$cache/$key.board-input.json"
}

test_mate_workers_meet_their_goal_floor() {
  reset_case
  floor 1
  mate_worker_cache 1000
  start_goal G1 'item [id=build] [owner=miko] [task=build-task]: build' \
    'item [id=next] [owner=miko]: build the next part'
  "$GOAL" mark G1 build running -- 'mate started it' >/dev/null
  drive_floor_tick 1000
  mate_worker_cache 1300
  drive_floor_tick 1300
  [ "$(count_wakes)" = 0 ] || fail "mate worker did not satisfy its goal floor"

  # Same task id in a different home does not satisfy this other goal or
  # suppress its waiting item. The first goal still meets the floor.
  start_goal G2 'item [id=local] [owner=main] [task=build-task]: build locally'
  drive_floor_tick 1300
  mate_worker_cache 1600
  drive_floor_tick 1600
  [ "$(count_wakes)" = 1 ] || fail 'expected one wake for the other goal only'
  [ "$DRIVE_FLOOR" = 'check: drive floor: 0 working < 1 300s (threshold 300s): idle: goal:G2/local=startable' ] \
    || fail "the mate worker was credited to the wrong home or goal: $DRIVE_FLOOR"
  pass 'the real worker table credits working mate lanes to their own ON goal, not a same-id lane in another home'
}

test_running_mate_item_is_not_waiting() {
  reset_case
  floor 8
  start_goal G1 'item [id=build] [owner=miko] [task=build-task]: build'
  "$GOAL" mark G1 build running -- 'mate started it' >/dev/null
  mate_worker_cache 1000
  drive_floor_tick 1000
  mate_worker_cache 2000
  drive_floor_tick 2000
  [ "$(count_wakes)" = 0 ] || fail 'running mate item raised a floor or stall wake'
  drive_floor_tick 2601
  drive_floor_tick 2901
  [ "$(grep -c 'drive-floor' "$FM_WAKE_QUEUE")" = 1 ] || fail 'an expired working verdict silenced the floor'
  pass 'a working mate lane suppresses a false orphan wake, but an expired cache cannot silence the floor'
}

test_goal_floor_hold_and_repeat() {
  reset_case
  floor 1
  lane unrelated "$WORKING"
  lane off-linked "$PARKED"
  start_goal G1 'item [id=ship-ui] [owner=main]: ship the ui'
  start_goal G2 'item [id=off] [owner=main] [task=off-linked]: do not drive'
  "$GOAL" pause G2 >/dev/null
  drive_floor_tick 1000
  drive_floor_tick 1299
  [ "$(count_wakes)" = 0 ] || fail 'goal floor woke before its 300s hold'
  drive_floor_tick 1300
  [ "$DRIVE_FLOOR" = 'check: drive floor: 0 working < 1 300s (threshold 300s): idle: goal:G1/ship-ui=startable' ] \
    || fail "expected the ON goal alone with no linked worker: $DRIVE_FLOOR"
  drive_floor_tick 3099
  [ "$(grep -c 'drive-floor' "$FM_WAKE_QUEUE")" = 1 ] || fail 'goal floor repeated early'
  drive_floor_tick 3100
  [ "$(grep -c 'drive-floor' "$FM_WAKE_QUEUE")" = 2 ] || fail 'goal floor did not repeat at 1800s'
  "$GOAL" pause G1 >/dev/null
  floor 8 # A generic alarm would now fire if the OFF goal's parked lane leaked.
  drive_floor_tick 4000
  drive_floor_tick 15000
  [ "$(grep -c 'drive-floor' "$FM_WAKE_QUEUE")" = 2 ] || fail 'an OFF goal or its parked lane woke the floor'
  [ ! -e "$STATE/.goal-drive-floor" ] || fail 'an OFF goal kept its floor episode'
  "$GOAL" resume G1 >/dev/null
  drive_floor_tick 15100
  drive_floor_tick 15399
  [ "$(grep -c 'drive-floor' "$FM_WAKE_QUEUE")" = 2 ] || fail 'a resumed goal reused the old hold'
  drive_floor_tick 15400
  [ "$(grep -c 'drive-floor' "$FM_WAKE_QUEUE")" = 3 ] || fail 'resumed goal did not wake on a fresh hold'
  pass 'an empty ON goal wakes at 300s and repeats at 1800s; OFF goals stay silent and reset their clocks'
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
  printf '%s\n' 'item [id=ship-ui] [owner=main]: ship the ui' \
    'item [id=worker] [owner=main] [task=worker]: keep working' > "$dir/items"
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
  test_drive_switch_preserves_items_and_clears_stall \
  test_idle_startable_item_wakes_after_the_hold \
  test_an_item_with_a_working_task_or_a_mark_is_not_stalled \
  test_an_orphaned_running_item_is_stalled_like_an_open_one \
  test_secondmate_task_home_and_parent_view test_mate_workers_meet_their_goal_floor \
  test_running_mate_item_is_not_waiting test_goal_floor_hold_and_repeat \
  test_page_hosts_never_count_as_working test_only_idle_page_hosts_stay_silent \
  test_closing_or_removing_config_drops_the_ledger test_a_home_without_goals_stays_unchanged \
  test_watcher_loop
