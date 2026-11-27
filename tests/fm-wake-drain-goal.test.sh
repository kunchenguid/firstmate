#!/usr/bin/env bash
# tests/fm-wake-drain-goal.test.sh - behavior tests for the GOAL section
# bin/fm-wake-drain.sh prints on every drain (the section bin/fm-branch-prompt.sh
# "Drive goals" and the drive-goal skill promise), and for the session-start
# digest that carries it. The section is wiring around `bin/fm-goal.sh brief`,
# which owns the rendering; these tests run the real drain over a lab home with
# real goal records and assert on what it prints.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
CONTRACT="$ROOT/bin/fm-afk-contract.sh"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
GOAL="$ROOT/bin/fm-goal.sh"
PACE="$ROOT/bin/fm-goal-pace.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-goal-tests)

# One lab home: state/ and data/ under the case dir, with FM_HOME pointing at it
# so fm-goal.sh and the contract resolve the same records the drain reads.
lab_home() {
  local name=$1 dir
  dir=$(make_case "$name")
  mkdir -p "$dir/data"
  printf '%s\n' "$dir"
}

lab_env() {  # <dir> <command...>
  local dir=$1; shift
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" "$@"
}

start_goal() {  # <dir> <id>
  local dir=$1 id=$2
  printf '%s\n' \
    'item [id=build] [owner=main]: build the thing' \
    'item [id=verify] [owner=main] [after=build]: verify the thing' \
    'item [id=sign] [owner=captain] [class=captain]: captain signs off' > "$dir/items.$id"
  lab_env "$dir" bash "$GOAL" start "$id" --title "Goal $id" --done-when "$id is live" \
    --named-by "finish $id" --plan plan.md --items-file "$dir/items.$id" >/dev/null \
    || fail "could not start goal $id"
}

test_no_goal_prints_no_goal_section() {
  local dir out
  dir=$(lab_home no-goal)
  out="$dir/drain.out"
  lab_env "$dir" "$DRAIN" > "$out" 2>&1 || fail "drain failed with no goal: $(cat "$out")"
  if grep -q 'GOAL' "$out"; then
    fail "a home with no goal printed a GOAL section: $(cat "$out")"
  fi
  pass "a home with no goal prints no GOAL section"
}

test_active_goal_prints_state_and_duty_on_an_empty_queue() {
  local dir out
  dir=$(lab_home empty-queue)
  start_goal "$dir" I1
  out="$dir/drain.out"
  lab_env "$dir" "$DRAIN" > "$out" 2>&1 || fail "drain failed: $(cat "$out")"
  grep -Fq 'GOAL I1 (active since' "$out" || fail "no GOAL section for an active goal: $(cat "$out")"
  grep -Fq 'startable, nobody on it: build [main]' "$out" || fail "the startable item was not named: $(cat "$out")"
  grep -Fq 'GOAL DUTY: the pusher drives ON goals; main uses PACE to steer what it cannot.' "$out" || fail "the main GOAL DUTY line is missing: $(cat "$out")"
  pass "an active goal prints its live state and the GOAL DUTY line on an empty queue"
}

test_goal_section_follows_queued_wake_rows() {
  local dir out
  dir=$(lab_home queued-rows)
  start_goal "$dir" I1
  append_wake "$dir/state" signal some-task.status 'signal: some-task.status' || fail "could not queue a wake"
  out="$dir/drain.out"
  lab_env "$dir" "$DRAIN" > "$out" 2>/dev/null || fail "drain failed with a queued wake"
  grep -Fq 'some-task.status' "$out" || fail "the queued wake was not presented: $(cat "$out")"
  grep -Fq 'GOAL I1 (active since' "$out" || fail "the goal section is missing beside a queued wake: $(cat "$out")"
  local wake_line goal_line
  wake_line=$(grep -nF 'some-task.status' "$out" | head -1 | cut -d: -f1)
  goal_line=$(grep -nF 'GOAL I1 (active since' "$out" | head -1 | cut -d: -f1)
  [ "$wake_line" -lt "$goal_line" ] || fail "the goal section printed before the wake rows it follows"
  pass "the GOAL section follows the wake rows on a non-empty queue"
}

test_away_record_drives_named_and_unnamed_goals() {
  local dir out
  dir=$(lab_home away-named)
  start_goal "$dir" I1
  start_goal "$dir" I2
  lab_env "$dir" bash "$LAUNCH" enter --words 'keep going on I2' --drive-goal I2 >/dev/null 2>&1 \
    || fail "afk entry with --drive-goal failed"
  out="$dir/drain.out"
  lab_env "$dir" "$DRAIN" > "$out" 2>&1 || fail "drain failed under an away record: $(cat "$out")"
  [ "$(grep -m1 '^GOAL I' "$out" | cut -c1-8)" = 'GOAL I2 ' ] || fail "the named goal did not come first: $(cat "$out")"
  grep -F 'GOAL I2 (active since' "$out" | grep -Fq 'driven while away: yes, named' \
    || fail "the named goal is not labeled driven: $(cat "$out")"
  grep -F 'GOAL I1 (active since' "$out" | grep -Fq 'driven while away: yes, active goal' \
    || fail "the unnamed active goal is not labeled driven while away: $(cat "$out")"
  if grep -Fq 'not driven while away' "$out"; then
    fail "a goal was left undriven while away: $(cat "$out")"
  fi
  pass "an away record drives the named goal first and every other active goal too"
}

test_mark_moves_an_item_in_the_next_drain() {
  local dir out
  dir=$(lab_home mark)
  start_goal "$dir" I1
  out="$dir/drain.out"
  lab_env "$dir" "$DRAIN" > "$out" 2>&1 || fail "first drain failed"
  grep -Fq 'startable, nobody on it: build [main]' "$out" || fail "build was not startable first: $(cat "$out")"
  grep -Fq 'waiting: verify after build' "$out" || fail "verify did not wait on build: $(cat "$out")"
  lab_env "$dir" bash "$GOAL" mark I1 build 'done' --task build-task -- 'landed https://github.com/example/fixture/pull/7' >/dev/null || fail "mark failed"
  lab_env "$dir" "$DRAIN" > "$out" 2>&1 || fail "second drain failed"
  grep -Fq 'progress: 1/3 items done or dropped' "$out" || fail "the mark did not move progress: $(cat "$out")"
  grep -Fq 'startable, nobody on it: verify [main]' "$out" || fail "verify did not become startable after the mark: $(cat "$out")"
  pass "a mark moves an item and the next drain names the next startable item"
}

test_unreadable_goal_never_fails_the_drain() {
  local dir out rc=0
  dir=$(lab_home corrupt)
  start_goal "$dir" I1
  printf 'not a goal record\n' > "$dir/state/goals/I2.goal"
  out="$dir/drain.out"
  lab_env "$dir" "$DRAIN" > "$out" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a corrupt goal record failed the drain (rc=$rc): $(cat "$out")"
  grep -Fq 'GOAL SKIPPED' "$out" || fail "the corrupt record was not made visible: $(cat "$out")"
  grep -Fq 'GOAL I1 (active since' "$out" || fail "the healthy goal vanished beside a corrupt one: $(cat "$out")"
  pass "a corrupt goal record is made visible and never fails the drain"
}

test_pace_reports_idle_on_goals_only() {
  local dir out snapshot now
  dir=$(lab_home pace)
  start_goal "$dir" I1
  start_goal "$dir" I2
  lab_env "$dir" "$GOAL" pause I2 >/dev/null || fail 'could not switch I2 OFF'
  lab_env "$dir" "$GOAL" mark I1 build running --task abandoned -- 'lab orphan' >/dev/null || fail 'could not mark running'
  mkdir -p "$dir/config"
  printf '12\n' > "$dir/config/lane-capacity"
  now=$(date +%s)
  out="$dir/drain.out"
  FM_GOAL_PACE_NOW_EPOCH="$now" lab_env "$dir" "$DRAIN" > "$out" 2>&1 || fail 'first pace drain failed'
  grep -Fq 'GOAL I2 (active, drive off)' "$out" || fail 'OFF goal disappeared from the brief'
  [ "$(grep -c '^PACE ' "$out")" = 1 ] || fail "expected only one PACE line: $(cat "$out")"
  grep -Fq 'PACE I1: running 0 · startable idle 1 · merge-after ready 0 · waiting 1 (captain 1; oldest ' "$out" \
    || fail "incorrect first pace line: $(cat "$out")"
  snapshot="$dir/state/goal-pace.json"
  jq -e --argjson now "$now" '
    .schema == "fm-goal-pace.v1" and .host.lane_target == 12 and (.host.free_lanes | type == "number") and
    (.goals | length == 1 and .[0].id == "I1" and .[0].behind_after == ["verify"] and
      .[0].idle_minutes == 0 and (.[0].startable_idle | map([.id, .idle_since_epoch])) == [["build", $now]])
  ' "$snapshot" >/dev/null || fail "incorrect first snapshot: $(cat "$snapshot")"

  # Preload a full window, then prove the next sample keeps only the latest 2048.
  awk 'NR==1 {for(i=0;i<2048;i++) print}' "$snapshot" > "$dir/state/goal-pace.jsonl"
  FM_GOAL_PACE_NOW_EPOCH="$((now + 720))" lab_env "$dir" "$DRAIN" > "$out" 2>&1 || fail 'second pace drain failed'
  grep -Fq 'behind 1 · idle 12m' "$out" || fail "idle clock did not advance: $(cat "$out")"
  jq -es 'length == 2048 and .[-1].goals[0].idle_minutes == 12' "$dir/state/goal-pace.jsonl" >/dev/null \
    || fail 'history failed to retain the latest bounded window'

  # No OFF sample between these two switches: the drive revision still resets idle.
  lab_env "$dir" "$GOAL" pause I1 >/dev/null || fail 'pause failed'
  lab_env "$dir" "$GOAL" resume I1 >/dev/null || fail 'resume failed'
  FM_GOAL_PACE_NOW_EPOCH="$((now + 780))" lab_env "$dir" "$PACE" > "$out" || fail 'resumed pace failed'
  grep -Fq 'behind 1 · idle 0m' "$out" || fail 'resume inherited pre-pause idle time'
  lab_env "$dir" "$GOAL" pause I1 >/dev/null || fail 'could not switch final goal OFF'
  FM_GOAL_PACE_NOW_EPOCH="$((now + 840))" lab_env "$dir" "$DRAIN" > "$out" 2>&1 || fail 'OFF-only pace drain failed'
  if grep -q '^PACE ' "$out"; then fail 'an OFF goal got a PACE line'; fi
  jq -e '.goals == []' "$snapshot" >/dev/null || fail 'OFF-only drain retained stale idle rows'
  pass 'pace detects idle and hard dependencies, bounds history, and never reports OFF goals as idle'
}

test_pace_samples_the_mate_scope_without_writing_the_parent() {
  local parent mate out cache cache_dir key now
  parent=$(lab_home pace-parent)
  mate=$(lab_home pace-mate)
  printf 'terp\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$mate/.fm-secondmate-parent"
  printf '%s\n' 'item [id=mine] [owner=terp]: mate item' 'item [id=theirs] [owner=main]: parent item' > "$parent/items"
  lab_env "$parent" "$GOAL" start I1 --title 'Shared' --done-when 'Done' --named-by 'go' \
    --plan plan.md --items-file "$parent/items" >/dev/null || fail 'could not start shared goal'
  out=$(lab_env "$mate" "$PACE") || fail 'mate pace sample failed'
  [[ "$out" == 'PACE I1: running 0 · startable idle 1'* ]] || fail "wrong mate pace: $out"
  jq -e '.goals[0].startable_idle | map(.id) == ["mine"]' "$mate/state/goal-pace.json" >/dev/null \
    || fail 'mate counted the parent item or did not publish its own snapshot'
  [ ! -e "$parent/state/goal-pace.json" ] || fail 'mate published into the parent'
  pass 'a local mate reports only its own goal items and writes only its own pace files'

  # The parent learns worker state through the same cache the fleet table uses.
  mkdir -p "$mate/bin"
  printf '# lab home\n' > "$mate/AGENTS.md"
  printf '%s\n' "- terp - Lab mate (home: $mate; scope: test; projects: ; added 2026-11-27)" > "$parent/data/secondmates.md"
  cache_dir="$parent/state/secondmate-summary-cache"
  mkdir -p "$cache_dir"
  if command -v shasum >/dev/null; then
    key=$(printf 'terp\n\n%s\n' "$mate" | shasum -a 256 | awk '{print $1}')
  else
    key=$(printf 'terp\n\n%s\n' "$mate" | sha256sum | awk '{print $1}')
  fi
  cache="$cache_dir/$key.board-input.json"
  printf 'kind=ship\n' > "$mate/state/mate-lane.meta"
  lab_env "$parent" "$GOAL" mark I1 mine running --task mate-lane -- 'mate is on it' >/dev/null || fail 'could not mark mate running'
  now=$(date +%s)
  jq -nc --arg home "$mate" --argjson now "$now" '
    {schema:"fm-live-board-input.v1", fm_home:$home, generated_epoch:$now,
     tasks:[{id:"mate-lane", current_state:{state:"working"}}]}' > "$cache"
  out=$(lab_env "$parent" "$PACE") || fail 'parent fleet pace failed'
  [[ "$out" == 'PACE I1: running 1 (terp 1) · startable idle 1'* ]] || fail "cached mate worker was not counted: $out"
  jq -nc --arg home "$mate" --argjson now "$now" '
    {schema:"fm-live-board-input.v1", fm_home:$home, generated_epoch:($now+61),
     tasks:[{id:"mate-lane", current_state:{state:"parked"},
       last_meaningful_event:{verb:"needs-decision", emitted_at_epoch:($now+1)}}]}' > "$cache"
  out=$(FM_WORKER_TABLE_NOW_EPOCH="$((now + 61))" FM_GOAL_PACE_NOW_EPOCH="$((now + 61))" lab_env "$parent" "$PACE") \
    || fail 'parked fleet pace failed'
  [[ "$out" == 'PACE I1: running 0 · startable idle 1 · merge-after ready 0 · waiting 1 (fleet 1; oldest 1m)'* ]] \
    || fail "parked mate worker was not counted as waiting: $out"
  pass 'the parent distinguishes cached running mate work from a parked fleet wait and reports its age'

  mv "$mate/state/mate-lane.meta" "$mate/former-lane.meta"
  out=$(FM_WORKER_TABLE_NOW_EPOCH="$((now + 62))" FM_GOAL_PACE_NOW_EPOCH="$((now + 62))" lab_env "$parent" "$PACE") \
    || fail 'orphaned mate pace failed'
  [[ "$out" == 'PACE I1: running 0 · startable idle 2 · merge-after ready 0 · waiting 0'* ]] \
    || fail "cached mate row hid the owner-home orphan: $out"
  pass 'owner-home orphan evidence overrides a still-fresh worker cache row'
}

test_session_start_carries_the_goal_section() {
  local dir out
  dir=$(lab_home session-start)
  start_goal "$dir" I1
  out="$dir/session.out"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    bash "$ROOT/bin/fm-session-start.sh" > "$out" 2>&1 || true
  grep -Fq 'GOAL I1 (active since' "$out" || fail "the session-start digest has no GOAL section: $(head -c 2000 "$out")"
  grep -Fq 'GOAL DUTY:' "$out" || fail "the session-start digest has no GOAL DUTY line"
  pass "the session-start digest carries the GOAL section"
}

test_no_goal_prints_no_goal_section
test_active_goal_prints_state_and_duty_on_an_empty_queue
test_goal_section_follows_queued_wake_rows
test_away_record_drives_named_and_unnamed_goals
test_mark_moves_an_item_in_the_next_drain
test_unreadable_goal_never_fails_the_drain
test_pace_reports_idle_on_goals_only
test_pace_samples_the_mate_scope_without_writing_the_parent
test_session_start_carries_the_goal_section
