#!/usr/bin/env bash
# Goal records, authority, projection, bounded presentation and quiet marks.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-goal)
H='' ITEMS=''
fixture() {
  H=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  mkdir -p "$H/state" "$H/data"
  ITEMS="$H/items"
  printf '%s\n' \
    'item [id=a] [owner=terp] [task=child]: first step' \
    'item [id=b] [owner=main] [after=a]: verify' \
    'item [id=c] [owner=captain] [class=captain]: captain step' > "$ITEMS"
}
goal() {
  FM_ROOT_OVERRIDE="$H" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" \
    bash "$ROOT/bin/fm-goal.sh" "$@"
}
start() {
  goal start "${1-I1}" --title 'Production goal' --done-when 'small e2e passes' \
    --named-by 'finish I1' --plan plan.md --items-file "$ITEMS"
}
project() {
  FM_ROOT_OVERRIDE="$H" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" \
    bash -c '. "$1/bin/fm-goal.sh"; fm_goal_project "$2"' _ "$ROOT" "${1:-I1}"
}
expect_rc() {
  local want=$1 got=0; shift
  "$@" > "$TMP_ROOT/out" 2>&1 || got=$?
  assert_equals "$want" "$got" "exit code: $* ($(head -c 300 "$TMP_ROOT/out"))"
}
mark_line() {
  printf 'goal [goal=I1] [item=%s] [state=%s] [at=%s]: %s\n' "$1" "$2" "$3" "${4:-progress}"
}
local_mate() {
  M=$(mktemp -d "$TMP_ROOT/mate.XXXXXX")
  mkdir -p "$M/state" "$M/data"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$H" > "$M/.fm-secondmate-parent"
  printf 'terp\n' > "$M/.fm-secondmate-home"
}
mate_goal() {
  FM_ROOT_OVERRIDE="$M" FM_HOME="$M" FM_STATE_OVERRIDE="$M/state" FM_DATA_OVERRIDE="$M/data" \
    bash "$ROOT/bin/fm-goal.sh" "$@"
}

test_start() {
  fixture
  expect_rc 1 goal active
  assert_equals '' "$(goal brief)" 'no brief without a goal'
  start >/dev/null
  expect_rc 0 goal exists I1
  assert_equals I1 "$(goal active)" 'active id'
  assert_grep 'version: 1' "$H/state/goals/I1.goal" 'versioned record'
  assert_grep 'named_by: finish I1' "$H/state/goals/I1.goal" 'captain words'
  assert_contains "$(project)" 'item a owner=terp class=drive state=open' 'valid projection'
  assert_equals '' "$(find "$H/state/goals" -name '.goal.*')" 'no staged record left'
  expect_rc 1 start
  pass 'start installs a valid record atomically and refuses duplicate active ids'
}

test_validation() {
  fixture
  local id
  for id in '../x' '.x' ''; do expect_rc 2 start "$id"; done
  printf '%s\n' 'item [id=a] [owner=main]: one' 'item [id=a] [owner=main]: two' > "$ITEMS"
  expect_rc 2 start
  printf '%s\n' 'item [id=a] [owner=main] [after=missing]: one' > "$ITEMS"
  expect_rc 2 start
  printf '%s\n' 'item [id=a] [owner=main] [after=b]: one' 'item [id=b] [owner=main] [after=a]: two' > "$ITEMS"
  expect_rc 2 start
  printf '%s\n' 'item [id=a] [owner=main] [after=a]: self cycle' > "$ITEMS"
  expect_rc 2 start
  printf '%s\n' 'item [id=a] [owner=main] [class=unsafe]: one' > "$ITEMS"
  expect_rc 2 start
  assert_absent "$H/state/goals/I1.goal" 'invalid inputs publish no record'
  pass 'unsafe ids, duplicate items, unknown dependencies, cycles and classes fail closed'
}

test_marks() {
  fixture; start >/dev/null
  goal mark I1 a running --task actual-child -- 'working now' >/dev/null
  assert_grep 'goal [goal=I1] [item=a] [state=running] [task=actual-child] [at=' "$H/state/goals/I1.marks" 'main mark appended'
  assert_contains "$(project)" 'task=actual-child' 'mark binds actual child task'
  local now; now=$(date +%s)
  mark_line a 'done' "$((now - 10))" > "$H/state/goals/I1.marks"
  mark_line a blocked "$((now - 20))" >> "$H/state/goals/I1.marks"
  assert_contains "$(project)" 'state=done' 'newest timestamp wins'
  mark_line a waiting "$((now - 10))" >> "$H/state/goals/I1.marks"
  assert_contains "$(project)" 'state=waiting' 'later line wins a tie'
  printf '%s\n' 'goal [goal=I1] [item=a] [state=done]: no epoch' \
    'goal [item=a] [state=done] [at=1]: no goal tag' \
    'goal [goal=I1] [item=a] [state=bogus] [at=1]: bad state' >> "$H/state/goals/I1.marks"
  mark_line a 'done' "$((now + 1000))" >> "$H/state/goals/I1.marks"
  assert_contains "$(goal show I1)" 'ignored marks: 4' 'malformed and future marks counted'
  assert_contains "$(project)" 'state=waiting' 'bad marks cannot alter state'
  pass 'main marks append, newest timestamp and line win, malformed/future marks are counted'
}

test_local_mate() {
  fixture; start >/dev/null; local_mate
  mate_goal mark I1 a 'done' -- landed >/dev/null
  mate_goal mark I1 a 'done' -- landed >/dev/null
  assert_equals 1 "$(wc -l < "$H/state/terp.status" | tr -d ' ')" 'retry idempotent'
  assert_grep 'goal [goal=I1] [item=a] [state=done]' "$H/state/terp.status" 'local parent channel'
  expect_rc 1 mate_goal mark I1 missing 'done' -- unknown
  assert_absent "$M/state/goals/I1.marks" 'mate never writes its own goal'
  assert_contains "$(project)" 'state=done' 'parent folds routed mark'
  pass 'local mate validates and publishes exactly once on the parent channel'
}

test_remote_mate() {
  fixture; local_mate
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=fixture\n' > "$M/.fm-secondmate-parent"
  mate_goal mark I1 unknown 'done' -- landed >/dev/null
  assert_grep 'goal [goal=I1] [item=unknown]' "$M/state/parent-replies.status" 'remote route allows unvalidated mark'
  assert_contains "$(mate_goal brief)" 'remote' 'remote parent brief unavailable'
  pass 'remote mate publishes to parent-replies without reading parent state'
}

test_projection() {
  fixture; start >/dev/null
  local now out; now=$(date +%s)
  out=$(project)
  assert_contains "$out" 'task=child startable=yes' 'root drive item startable'
  assert_contains "$out" 'task=- startable=no waiting_on=a' 'dependent waits for after item'
  mark_line a 'done' "$((now - 20))" > "$H/state/terp.status"
  printf 'done [key=merged-child] [at=%s]: merged child\n' "$((now - 10))" >> "$H/state/terp.status"
  out=$(project)
  assert_contains "$out" 'item b owner=main class=drive state=open since=- task=- startable=yes' 'dependencies satisfied'
  assert_contains "$out" 'item c owner=captain class=captain state=open since=- task=- startable=no' 'captain never startable'
  assert_contains "$out" 'landing_hint=yes' 'newer landing visible'
  mark_line a 'done' "$now" >> "$H/state/terp.status"
  assert_not_contains "$(project)" 'landing_hint=yes' 'newer mark clears landing hint'
  mkdir -p "$H/data/terp"
  mv "$H/state/terp.status" "$H/data/terp/status.log"
  assert_contains "$(project)" 'item a owner=terp class=drive state=done' 'archive fallback'
  pass 'projection honors dependencies, captain class, owner streams, teardown fallback and landings'
}

test_main_landing() {
  fixture; start >/dev/null
  local now; now=$(date +%s)
  printf 'pr=https://github.com/example/fixture/pull/1\n' > "$H/state/child.meta"
  bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_poll_merge_mark_notified "$2/state" child github github.com example/fixture 1' _ "$ROOT" "$H"
  assert_contains "$(project)" 'landing_hint=yes' 'main-home merge marker detected'
  mark_line a running "$((now + 1))" > "$H/state/goals/I1.marks"
  assert_not_contains "$(project)" 'landing_hint=yes' 'newer goal mark clears main-home landing'
  pass 'main-home landing hints validate the merge marker and compare its epoch'
}

test_symlinks() {
  fixture; start >/dev/null; local_mate
  ln -s "$ITEMS" "$H/state/goals/I1.marks"
  local before; before=$(cksum "$ITEMS")
  expect_rc 1 goal mark I1 a running -- unsafe
  assert_equals "$before" "$(cksum "$ITEMS")" 'marks symlink target untouched'
  mv "$H/state/goals/I1.goal" "$H/saved.goal"
  ln -s "$H/saved.goal" "$H/state/goals/I1.goal"
  expect_rc 1 mate_goal mark I1 a running -- unsafe
  assert_contains "$(mate_goal brief)" 'GOAL SKIPPED:' 'mate refuses symlinked goal'
  printf 'broken record\n' > "$H/broken.goal"
  mv "$H/broken.goal" "$H/state/goals/I1.goal"
  assert_contains "$(goal brief)" 'GOAL SKIPPED:' 'corrupt goal is visible without failing brief'
  pass 'writes and cross-home reads refuse symlinked goal records and marks'
}

test_edit() {
  fixture; start >/dev/null
  goal mark I1 a 'done' -- landed >/dev/null
  printf '%s\n' 'item [id=b] [owner=main]: changed plan' > "$ITEMS"
  goal edit I1 --items-file "$ITEMS" --title Revised --done-when 'new check' >/dev/null
  assert_grep 'title: Revised' "$H/state/goals/I1.goal" 'edit changes title'
  assert_grep 'done_when: new check' "$H/state/goals/I1.goal" 'edit changes done condition'
  assert_contains "$(goal show I1)" 'unplanned items (marked but not in the record): a (done)' 'removed marked item is drift'
  assert_grep 'goal [goal=I1] [item=a]' "$H/state/goals/I1.marks" 'edit keeps marks'
  pass 'edit atomically updates the plan without discarding marked drift'
}

test_brief() {
  fixture
  local i out first
  for i in I1 I2 I3; do start "$i" >/dev/null; done
  assert_equals $'I1\nI2\nI3' "$(goal active)" 'multiple goals in start order'
  printf 'drive_goals: I3 I1\n' > "$H/state/.afk-contract"
  out=$(goal brief); first=${out%%$'\n'*}
  assert_contains "$first" 'GOAL I3 ' 'named goals first'
  assert_contains "$out" 'GOAL I2 (active since' 'unnamed goal listed'
  assert_contains "$out" 'driven while away: yes, active goal' 'unnamed active goal drives while away'
  assert_not_contains "$out" 'not driven while away' 'no goal is left undriven while away'
  [ "$(printf '%s\n' "$out" | wc -c)" -le 3072 ] || fail 'total brief byte cap'
  local_mate
  out=$(mate_goal brief)
  assert_contains "$out" 'PARENT GOAL I3' 'mate parent goal'
  assert_not_contains "$out" 'needs the captain: c' 'mate filters other owners'
  assert_contains "$out" 'after every landing or item change' 'mate progress duty'
  printf 'drive_goals: Missing\n' > "$H/state/.afk-contract"
  assert_contains "$(goal brief)" 'GOAL Missing: named by the away record but no goal record exists' 'missing named record visible'
  pass 'brief bounds three goals, preserves named order and filters mate ownership'
}

test_large_brief() {
  fixture
  local i
  : > "$ITEMS"
  for i in $(seq 1 40); do printf 'item [id=i%s] [owner=terp] [class=captain]: %s\n' "$i" "$(printf '%0300d' 0)" >> "$ITEMS"; done
  for i in I1 I2 I3; do start "$i" >/dev/null; done
  local out; out=$(goal brief)
  [ "$(printf '%s\n' "$out" | wc -c)" -le 3072 ] || fail 'large brief byte cap'
  assert_contains "$out" 'GOAL DUTY:' 'bounded output keeps duty'
  pass 'large goal briefs remain bounded including the duty'
}

test_close() {
  fixture; start >/dev/null
  expect_rc 1 goal close I1 --done
  goal mark I1 a 'done' -- landed >/dev/null
  goal mark I1 b 'done' -- verified >/dev/null
  local now; now=$(date +%s)
  mark_line c dropped "$now" > "$H/state/captain.status"
  FM_SUPERVISION_ACTOR=branch goal close I1 --done >/dev/null
  printf 'drive_goals: I1\n' > "$H/state/.afk-contract"
  expect_rc 1 goal active
  expect_rc 1 goal exists I1
  assert_equals '' "$(goal brief)" 'closed goal disappears from brief'
  local archive; archive=$(find "$H/state/goals/closed" -name '*.goal')
  assert_grep 'projection:' "$archive" 'projection snapshot archived'
  assert_grep 'closed_reason: done' "$archive" 'close reason'
  assert_grep '[item=c] [state=dropped]' "${archive%.goal}.marks" 'owner stream marks copied'
  assert_absent "$H/state/goals/I1.marks" 'live marks removed'
  assert_contains "$(goal window I1 --since "$((now - 60))")" 'state: closed (done)' 'closed archive readable'
  start >/dev/null
  pass 'done close refuses open work, archives all sources and snapshot, permits branch completion and id reuse'
}

test_authority() {
  fixture
  expect_rc 1 env FM_SUPERVISION_ACTOR=branch FM_HOME="$H" FM_ROOT_OVERRIDE="$H" bash "$ROOT/bin/fm-goal.sh" start I1 --title x --done-when x --named-by x --plan x --items-file "$ITEMS"
  start >/dev/null
  FM_SUPERVISION_ACTOR=branch expect_rc 1 goal edit I1 --items-file "$ITEMS"
  FM_SUPERVISION_ACTOR=branch expect_rc 1 goal close I1 --captain --words stop
  local_mate
  expect_rc 1 mate_goal start I2 --title x --done-when x --named-by x --plan x --items-file "$ITEMS"
  expect_rc 1 mate_goal edit I1 --items-file "$ITEMS"
  expect_rc 1 mate_goal close I1 --captain --words stop
  expect_rc 1 mate_goal close I1 --done
  goal close I1 --captain --words 'stop this goal' >/dev/null
  assert_contains "$(goal window I1 --since 0)" 'state: closed (captain)' 'main early close allowed'
  pass 'branch and mate cannot create/edit goals or captain-close; main can close early'
}

test_window() {
  fixture; start >/dev/null
  local now out; now=$(date +%s)
  # Multiple marks for one item matter: looking only at the final mark would
  # falsely report a 300-second gap instead of the real 100-second gaps.
  mark_line a running "$((now - 200))" > "$H/state/goals/I1.marks"
  mark_line a waiting "$((now - 100))" >> "$H/state/goals/I1.marks"
  mark_line a 'done' "$now" >> "$H/state/goals/I1.marks"
  out=$(goal window I1 --since "$((now - 300))")
  assert_contains "$out" 'items done in the window: a' 'window completions'
  assert_contains "$out" 'longest stretch with no goal progress: 1m (' 'all historical marks bound gaps'
  pass 'window reports completed items and longest gap using full progress history'
}

test_quiet_status() {
  local line='goal [goal=I1] [item=a] [state=done] [at=1794295000]: merged PR ready'
  if status_prefix_unrecognized "$line"; then fail 'goal verb recognized'; fi
  if status_is_captain_relevant "$line"; then fail 'goal never wakes'; fi
  local scan
  scan=$(printf 'done: actual landing\n%s\n' "$line" | _fm_status_event_scan)
  assert_equals $'\ndone: actual landing' "$scan" 'goal does not hide lifecycle event'
  printf 'done: actual landing\n%s\n' "$line" > "$TMP_ROOT/status"
  assert_equals 'done: actual landing' "$(status_last_meaningful_event "$TMP_ROOT/status")" 'goal not meaningful latest event'
  pass 'goal status is recognized, quiet and never the latest event'
}

# --- schema v2: project, target, stage marks, limits, ladders, probes -------

ladder() {  # <project> <line...> - write the home-local ladder for <project>
  local project=$1; shift
  mkdir -p "$H/config/stage-ladders"
  printf '%s\n' "$@" > "$H/config/stage-ladders/$project"
}
v2_items() {
  printf '%s\n' \
    'item [id=a] [owner=terp] [task=child] [project=miko] [target=deployed] [stop-on=prod-deploy-failed,spend]: ship it' \
    'item [id=b] [owner=main] [after=a]: verify' > "$ITEMS"
}

test_v2_schema() {
  fixture; v2_items; start >/dev/null
  assert_grep 'version: 2' "$H/state/goals/I1.goal" 'v2 fields write a version 2 record'
  assert_grep 'item [id=a] [owner=terp] [task=child] [project=miko] [target=deployed] [stop-on=prod-deploy-failed,spend]: ship it' \
    "$H/state/goals/I1.goal" 'v2 item line is stored normalized'
  assert_contains "$(goal show I1)" 'item a [owner=terp class=drive task=child project=miko]: ship it' 'show names the project'
  assert_contains "$(goal show I1)" 'stage: none yet, target: deployed' 'show prints the target before any stage'
  assert_contains "$(goal show I1)" 'limits: stop on prod-deploy-failed,spend' 'show carries stop-on'
  assert_contains "$(project)" 'item a project=miko stage=- target=deployed' 'projection carries the v2 fields'
  assert_not_contains "$(project)" 'item b project' 'a v1 item has no extra projection line'
  # a v1 record, written by hand as the old script wrote it, still works
  fixture
  mkdir -p "$H/state/goals"
  printf '%s\n' 'version: 1' 'id: OLD' 'title: old' 'state: active' 'started: 2026-01-01T00:00:00Z' \
    'started_epoch: 1767225600' 'named_by: me' 'plan: p' 'done_when: d' 'items:' \
    '  item [id=a] [owner=main]: only' > "$H/state/goals/OLD.goal"
  assert_contains "$(goal show OLD)" 'item a [owner=main class=drive]: only' 'a version 1 record still shows'
  assert_contains "$(goal startable)" 'OLD	a	main' 'a version 1 record still lists startable items'
  goal mark OLD a stage=merged -- 'late stage' >/dev/null
  assert_contains "$(goal show OLD)" 'stage: merged' 'a version 1 item can still carry a stage mark'
  fixture
  printf '%s\n' 'item [id=a] [owner=main] [target=live]: target without project' > "$ITEMS"
  expect_rc 2 start
  printf '%s\n' 'item [id=a] [owner=main] [project=p] [until=soon]: bad until' > "$ITEMS"
  expect_rc 2 start
  printf '%s\n' 'item [id=a] [owner=main] [project=p] [project=q]: duplicate project' > "$ITEMS"
  expect_rc 2 start
  printf '%s\n' 'item [id=a] [owner=main] [project=../p]: unsafe project' > "$ITEMS"
  expect_rc 2 start
  printf '%s\n' 'item [id=a] [owner=main] [project=p] [stop-on=a,,b]: bad stop-on' > "$ITEMS"
  expect_rc 2 start
  assert_absent "$H/state/goals/I1.goal" 'invalid v2 fields publish no record'
  pass 'schema v2 fields round-trip, v1 records keep working, malformed v2 fields fail closed'
}

test_stage_marks() {
  fixture; v2_items; start >/dev/null
  local now; now=$(date +%s)
  goal mark I1 a running -- 'on it' >/dev/null
  goal mark I1 a stage=merged -- 'PR merged' >/dev/null
  assert_grep 'goal [goal=I1] [item=a] [stage=merged] [at=' "$H/state/goals/I1.marks" 'a stage-only mark carries no state'
  assert_contains "$(project)" 'item a owner=terp class=drive state=running' 'a stage mark leaves the state alone'
  assert_contains "$(project)" 'item a project=miko stage=merged target=deployed' 'the stage folds into the projection'
  assert_contains "$(goal show I1)" 'stage: merged since' 'show prints the stage'
  assert_contains "$(goal show I1)" ', target: deployed' 'show prints the target beside the stage'
  assert_not_contains "$(goal show I1)" '(reached)' 'a stage short of target is not reached'
  goal mark I1 a 'done' --stage deployed -- 'live on dev' >/dev/null
  assert_grep 'goal [goal=I1] [item=a] [state=done] [stage=deployed] [at=' "$H/state/goals/I1.marks" 'state and stage in one mark'
  assert_contains "$(goal show I1)" '(reached)' 'the target is reached when the stage equals it'
  mark_line a 'running' "$((now + 5))" > "$H/state/goals/I1.marks"
  printf 'goal [goal=I1] [item=a] [stage=later] [at=%s]: newest\ngoal [goal=I1] [item=a] [stage=earlier] [at=%s]: older\n' \
    "$((now + 20))" "$((now + 10))" >> "$H/state/goals/I1.marks"
  assert_contains "$(project)" 'stage=later' 'the newest stage mark wins'
  assert_contains "$(project)" 'state=running' 'the state folds on its own clock'
  expect_rc 2 goal mark I1 a stage=bad/stage -- x
  expect_rc 2 goal mark I1 a stage=x --stage y -- x
  expect_rc 2 goal mark I1 a bogus -- x
  expect_rc 1 goal mark I1 nope stage=merged -- x
  printf 'goal [goal=I1] [item=a] [at=%s]: neither\n' "$now" >> "$H/state/goals/I1.marks"
  assert_contains "$(goal show I1)" 'ignored marks: 1' 'a mark with neither state nor stage is ignored'
  fixture; v2_items; start >/dev/null; local_mate
  mate_goal mark I1 a stage=merged -- 'landed' >/dev/null
  assert_grep 'goal [goal=I1] [item=a] [stage=merged]' "$H/state/terp.status" 'a mate stage mark routes through the parent channel'
  assert_contains "$(project)" 'stage=merged' 'the parent folds a routed stage mark'
  pass 'stage marks fold on their own clock, validate their shape, and route from a secondmate'
}

test_ladder_targets() {
  fixture; v2_items
  start >/dev/null
  assert_contains "$(goal show I1)" 'target: deployed' 'with no ladder a target is a free word'
  ladder miko 'stage merged: true' 'stage deployed: true' 'stage live: true'
  start I2 >/dev/null
  assert_contains "$(goal show I2)" 'target: deployed' 'a target on the ladder is accepted'
  printf '%s\n' 'item [id=a] [owner=terp] [project=miko] [target=nowhere]: off the ladder' > "$ITEMS"
  expect_rc 2 start
  assert_contains "$(cat "$TMP_ROOT/out")" 'is not a stage of project miko (stages: merged deployed live)' 'the refusal names the ladder'
  ladder miko 'stage merged: true' 'stage merged: true'
  expect_rc 2 start
  assert_contains "$(cat "$TMP_ROOT/out")" 'duplicate stage merged' 'a duplicate rung fails the list closed'
  ladder miko 'stage merged' 
  expect_rc 2 start
  ladder miko 'stage merged: '
  expect_rc 2 start
  ladder miko 'stage ../x: true'
  expect_rc 2 start
  rm -f "$H/config/stage-ladders/miko"; printf 'stage nowhere: true\n' > "$H/real-ladder"
  ln -s "$H/real-ladder" "$H/config/stage-ladders/miko"
  expect_rc 2 start
  assert_contains "$(cat "$TMP_ROOT/out")" 'ladder is a symlink' 'a symlinked ladder is refused'
  rm -f "$H/config/stage-ladders/miko"
  expect_rc 0 start I3
  pass 'a target is checked against the project ladder, and a damaged ladder fails closed'
}

# shellcheck disable=SC2016  # the probes expand in the probe's own shell
probe_fixture() {  # a miko ladder whose probes read flag files in the home
  fixture; v2_items
  ladder miko \
    'stage merged: test -e "$FM_GOAL_HOME/merged.flag" && echo "https://example.test/pull/${FM_GOAL_TASK}"' \
    'stage deployed: test -e "$FM_GOAL_HOME/deployed.flag"' \
    'stage live: test -e "$FM_GOAL_HOME/live.flag"'
  start >/dev/null
}

test_probe() {
  probe_fixture
  local out
  out=$(goal probe I1)
  assert_contains "$out" 'probe I1/a [miko]: stage none, merged not reached (probe exit 1)' 'no rung reached, nothing marked'
  assert_absent "$H/state/goals/I1.marks" 'a failing probe writes no mark'
  : > "$H/merged.flag"
  out=$(goal probe I1 --dry-run)
  assert_contains "$out" 'would move none -> merged (dry run)' 'dry run reports the move'
  assert_absent "$H/state/goals/I1.marks" 'dry run writes no mark'
  out=$(goal probe I1)
  assert_contains "$out" 'probe I1/a [miko]: stage none -> merged (https://example.test/pull/child)' 'a passing probe moves the stage'
  assert_grep 'goal [goal=I1] [item=a] [stage=merged]' "$H/state/goals/I1.marks" 'the stage mark is recorded'
  assert_grep 'probe passed for merged: https://example.test/pull/child' "$H/state/goals/I1.marks" 'the mark note carries the evidence'
  assert_contains "$(goal show I1)" 'stage: merged since' 'show reads the probed stage'
  out=$(goal probe I1)
  assert_contains "$out" 'stage merged, deployed not reached' 'the next probe starts above the current stage'
  : > "$H/deployed.flag"; : > "$H/live.flag"
  out=$(goal probe)
  assert_contains "$out" 'stage merged -> deployed' 'a sweep with no id probes every active goal'
  assert_not_contains "$out" 'live' 'probing stops at the target'
  assert_contains "$(goal show I1)" '(reached)' 'the target is reached'
  out=$(goal probe I1)
  assert_contains "$out" 'nothing above it to probe' 'at the target there is nothing left to probe'
  expect_rc 1 goal probe I1 b
  expect_rc 1 goal probe I1 nope
  expect_rc 1 goal probe nope
  expect_rc 2 goal probe I1 a extra
  pass 'probe moves the stage mark rung by rung to the target and is idempotent'
}

test_probe_bounds() {
  probe_fixture
  ladder miko 'stage merged: sleep 5'
  local out
  out=$(FM_GOAL_PROBE_TIMEOUT=1 goal probe I1)
  assert_contains "$out" 'merged not reached (probe exit 124)' 'a probe past its bound is not reached'
  assert_absent "$H/state/goals/I1.marks" 'a timed-out probe writes no mark'
  ladder miko 'stage merged: echo skipped-line; exit 3'
  out=$(goal probe I1)
  assert_contains "$out" '(probe exit 3)' 'a probe error is reported with its exit code'
  assert_absent "$H/state/goals/I1.marks" 'a probe error writes no mark'
  ladder miko 'stage merged: not a ladder line'
  rm -f "$H/config/stage-ladders/miko"
  out=$(goal probe I1)
  assert_contains "$out" 'no stage ladder for the project, skipped' 'a project with no ladder is skipped'
  expect_rc 1 goal probe I1 a
  ladder miko 'garbage'
  expect_rc 1 goal probe I1
  local_mate
  expect_rc 1 mate_goal probe I1
  pass 'probe bounds a slow probe, reports errors without marking, and skips ladder-less projects'
}

test_probe_authority() {
  probe_fixture
  : > "$H/merged.flag"
  FM_SUPERVISION_ACTOR=branch expect_rc 0 goal probe I1
  assert_grep 'stage=merged' "$H/state/goals/I1.marks" 'the supervision branch may probe'
  pass 'probe is open to main and the supervision branch'
}

test_probe_pr_merged() {
  fixture; v2_items
  mkdir -p "$H/bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *"number=7"*) printf "state=MERGED\nmerged=true\n" ;; *"number=8"*) printf "state=OPEN\nmerged=false\n" ;; *) exit 1 ;; esac' > "$H/bin/gh"
  chmod +x "$H/bin/gh"
  local probe="$ROOT/bin/fm-goal-probe-pr-merged.sh" out rc
  out=$(PATH="$H/bin:$PATH" bash "$probe" https://github.com/example/fixture/pull/7) || fail 'merged PR is reached'
  assert_equals https://github.com/example/fixture/pull/7 "$out" 'the probe prints the PR url as evidence'
  rc=0; PATH="$H/bin:$PATH" bash "$probe" https://github.com/example/fixture/pull/8 >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" 'an open PR is not reached'
  rc=0; PATH="$H/bin:$PATH" bash "$probe" https://github.com/example/fixture/pull/9 >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" 'an unreadable answer is unknown, never merged'
  rc=0; PATH="$H/bin:$PATH" bash "$probe" not-a-url >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" 'a non-PR argument is unknown'
  rc=0; FM_GOAL_HOME="$H" bash "$probe" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" 'no PR and no task is unknown'
  printf 'pr=https://github.com/example/fixture/pull/7\n' > "$H/state/child.meta"
  out=$(FM_GOAL_HOME="$H" FM_GOAL_TASK=child PATH="$H/bin:$PATH" bash "$probe") || fail 'the task PR is found'
  assert_equals https://github.com/example/fixture/pull/7 "$out" 'the PR is read from the task record'
  # the whole path: a ladder whose merged rung is this probe moves the stage on a merged PR
  ladder miko "stage merged: bash $probe" 'stage deployed: false'
  start >/dev/null
  out=$(PATH="$H/bin:$PATH" goal probe I1)
  assert_contains "$out" 'probe I1/a [miko]: stage none -> merged (https://github.com/example/fixture/pull/7)' 'a merged PR moves the stage mark'
  assert_contains "$(goal show I1)" 'stage: merged since' 'show prints the stage the probe set'
  pass 'the PR-merged probe answers merged, open and unknown exactly, and drives a stage mark end to end'
}

test_limits() {
  fixture
  printf '%s\n' 'item [id=a] [owner=terp] [project=p] [until=1000]: expired' 'item [id=b] [owner=main] [project=p] [until=99999999999]: open' > "$ITEMS"
  start >/dev/null
  assert_not_contains "$(goal startable)" 'I1	a	' 'an item past its until is not startable'
  assert_contains "$(goal startable)" 'I1	b	main' 'an item before its until is startable'
  assert_contains "$(goal show I1)" 'limits: until 1970-01-01T00:16:40Z (passed: not startable)' 'show says the limit passed'
  pass 'until stops an item from being startable once it passes'
}

test_target_close_and_brief() {
  probe_fixture
  goal mark I1 a 'done' -- 'merged and done' >/dev/null
  goal mark I1 b 'done' -- verified >/dev/null
  assert_contains "$(goal brief)" 'short of target: a at no stage, target deployed' 'the brief names an item short of target'
  expect_rc 1 goal close I1 --done
  assert_contains "$(cat "$TMP_ROOT/out")" 'short of their target stage: a' 'close --done refuses short of target'
  goal mark I1 a stage=deployed -- 'live on dev' >/dev/null
  assert_not_contains "$(goal brief)" 'short of target' 'the brief clears once the target is reached'
  expect_rc 0 goal close I1 --done
  fixture; v2_items; start >/dev/null
  goal mark I1 a dropped -- 'not needed' >/dev/null
  goal mark I1 b 'done' -- verified >/dev/null
  expect_rc 0 goal close I1 --done
  pass 'close --done and the brief hold an item to its target; a dropped item owes none'
}

test_export() {
  probe_fixture
  local out
  out=$(goal export)
  assert_equals fm-goal-export.v1 "$(jq -r .schema <<< "$out")" 'export names its schema'
  assert_equals I1 "$(jq -r '.goals[0].id' <<< "$out")" 'export lists the active goal'
  assert_equals '0 2 1' "$(jq -r '.goals[0].progress | "\(.closed) \(.total) \(.with_target)"' <<< "$out")" 'export counts items and targets'
  assert_equals 'miko deployed true false' \
    "$(jq -r '.goals[0].items[0] | "\(.project) \(.target) \(.startable) \(.target_reached)"' <<< "$out")" 'an item carries its project, target and projection'
  assert_equals 'a' "$(jq -r '.goals[0].items[1].waiting_on | join(",")' <<< "$out")" 'a waiting item names what it waits on'
  assert_equals 'prod-deploy-failed,spend' "$(jq -r '.goals[0].items[0].stop_on | join(",")' <<< "$out")" 'stop-on words come out as a list'
  goal mark I1 a running --stage deployed -- 'live on dev' >/dev/null
  out=$(goal export I1)
  assert_equals 'deployed true running' \
    "$(jq -r '.goals[0].items[0] | "\(.stage) \(.target_reached) \(.state)"' <<< "$out")" 'a stage mark reaches the target in the export'
  assert_equals '1' "$(jq -r '.goals[0].progress.at_target' <<< "$out")" 'progress counts items at target'
  expect_rc 1 goal export nosuch
  expect_rc 2 goal export a b
  fixture
  assert_equals '{"schema":"fm-goal-export.v1","goals":[]}' "$(goal export)" 'no active goal exports an empty list'
  pass 'export is the JSON read of the projection: items, targets, stages, progress, empty and unknown ids'
}

fm_test_run test_start test_validation test_marks test_local_mate test_remote_mate \
  test_projection test_main_landing test_symlinks test_edit test_brief test_large_brief test_close test_authority test_window test_quiet_status \
  test_v2_schema test_stage_marks test_ladder_targets test_probe test_probe_bounds test_probe_authority \
  test_probe_pr_merged test_limits test_target_close_and_brief test_export
