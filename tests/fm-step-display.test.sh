#!/usr/bin/env bash
# Behavior tests for the worker step display: bin/fm-step.sh writes the step
# record, bin/fm-fleet-snapshot.sh carries it, bin/fm-fleet-view.sh renders it,
# bin/fm-brief.sh teaches it, and config/step-display turns all of it off.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STEP="$ROOT/bin/fm-step.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-step-display)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/no-mistakes"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message) printf '%%1\n' ;;
  capture-pane)
    # FM_FAKE_PANE_CHURN keeps the pane changing so the watcher never sees a
    # stale pane, which leaves the step record as the only possible wake cause.
    if [ -n "${FM_FAKE_PANE_CHURN:-}" ]; then printf 'working %s\n' "$RANDOM$RANDOM"; else printf 'idle\n> \n'; fi
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects/wt" "$home/config"
  printf '%s\n' "$home"
}

write_task() {  # <home> <id> <status-line>
  local home=$1 id=$2
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/wt" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  printf '%s\n' "$3" > "$home/state/$id.status"
}

record_step() {  # <home> <id> <n> <m> <name>
  local home=$1 id=$2
  shift 2
  FM_TASK_INBOX="$home/state/$id.inbox" "$STEP" "$@" || fail "fm-step.sh refused a valid step: $*"
}

view() {  # <home> [args...]
  local home=$1
  shift
  PATH="$FAKEBIN:$PATH" FM_HOME="$home" "$VIEW" "$@"
}

# Drop the Step column (the third cell) from every row of the Under Way table,
# which is exactly what the step display adds to the table.
strip_step_column() {
  awk '
    /^## / { in_table = ($0 == "## Under Way") }
    in_table && /^\| / {
      n = split($0, cells, " \\| ")
      out = cells[1]
      for (i = 2; i <= n; i++) if (i != 3) out = out " | " cells[i]
      print out
      next
    }
    { print }
  '
}

FAKEBIN=$(make_fakebin "$TMP_ROOT/fakebin")

test_step_write_produces_no_wake() {
  local home state out pid i before after
  home=$(make_home no-wake)
  state="$home/state"
  write_task "$home" quiet-task 'working: setup done'
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state" "$state/quiet-task.status"
  before=$(cat "$state/quiet-task.status")
  out="$home/watch.out"
  fm_test_track_watcher_state "$state"
  FM_FAKE_PANE_CHURN=1 PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  sleep 2
  kill -0 "$pid" 2>/dev/null || fail "the watcher exited before any step was written: $(cat "$out")"
  record_step "$home" quiet-task 1 3 "Write failing tests"
  sleep 1
  record_step "$home" quiet-task 2 3 "Implement the helper"
  sleep 1
  record_step "$home" quiet-task 3 3 "Run the suite"
  sleep 3
  kill -0 "$pid" 2>/dev/null || fail "a step write woke the watcher: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "a step write queued a wake: $(cat "$state/.wake-queue")"
  after=$(cat "$state/quiet-task.status")
  assert_equals "$before" "$after" "a step write changed the status log"
  [ "$(grep -c . "$state/quiet-task.step")" = 3 ] || fail "the step record does not hold the three step starts"
  # Positive control: the same watcher does wake on a real status event, so the
  # quiet result above is not a watcher that never wakes.
  printf 'needs-decision: pick an API shape\n' >> "$state/quiet-task.status"
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    fail "positive control: the watcher did not wake on a real status event"
  fi
  wait "$pid" 2>/dev/null || true
  assert_grep 'signal:' "$out" "positive control: the watcher did not print a signal reason"
  pass "a step write produces no wake, while a status event on the same task does"
}

test_helper_rejects_bad_input_without_writing() {
  local home rc
  home=$(make_home bad-input)
  for args in "3 2 Name" "0 2 Name" "x 2 Name" "1 2"; do
    # shellcheck disable=SC2086 # Each case is a deliberate word list.
    FM_TASK_INBOX="$home/state/t.inbox" "$STEP" $args >/dev/null 2>&1
    rc=$?
    expect_code 2 "$rc" "fm-step.sh accepted bad input: $args"
  done
  env -u FM_TASK_INBOX "$STEP" 1 2 Name >/dev/null 2>&1
  expect_code 2 "$?" "fm-step.sh wrote a step with no record location"
  "$STEP" --record "$home/state/t.status" 1 2 Name >/dev/null 2>&1
  expect_code 2 "$?" "fm-step.sh wrote into a file that is not a step record"
  assert_absent "$home/state/t.step" "a refused step still wrote a record"
  assert_absent "$home/state/t.status" "a refused step wrote a status file"
  pass "fm-step.sh refuses bad input and writes nothing"
}

test_view_says_step_not_reported_when_absent() {
  local home out
  home=$(make_home absent)
  write_task "$home" silent-task 'working: setup done'
  out=$(view "$home") || fail "fleet view failed"
  assert_contains "$out" "| ID | Current | Step | Kind |" "the table has no Step column"
  assert_contains "$out" "| silent-task | " "the table has no row for the task"
  printf '%s\n' "$out" | grep -F '| silent-task |' | grep -Fq '| step not reported |' \
    || fail "an unreported step was not shown as step not reported: $out"
  out=$(view "$home" --steps silent-task) || fail "--steps failed"
  assert_contains "$out" "step not reported" "the checklist did not say step not reported"
  pass "the views say step not reported when no step is recorded"
}

test_view_renders_recorded_steps() {
  local home out row
  home=$(make_home recorded)
  write_task "$home" busy-task 'working: setup done'
  record_step "$home" busy-task 1 4 "Write failing tests"
  record_step "$home" busy-task 2 4 "Implement the helper"
  out=$(view "$home") || fail "fleet view failed"
  row=$(printf '%s\n' "$out" | grep -F '| busy-task |')
  assert_contains "$row" "2/4 Implement the helper" "the Step cell does not show n/m and the step name"
  assert_contains "$row" "█████░░░░░" "the Step cell does not show the progress bar"
  out=$(view "$home" --steps busy-task) || fail "--steps failed"
  assert_contains "$out" "[x] 1/4 Write failing tests" "the checklist does not mark step 1 done"
  assert_contains "$out" "[>] 2/4 Implement the helper" "the checklist does not mark step 2 current"
  assert_contains "$out" "[ ] 3/4 not started" "the checklist does not show step 3 as not started"
  assert_contains "$out" "[ ] 4/4 not started" "the checklist does not show step 4 as not started"
  assert_contains "$out" "no review run" "the checklist does not report the missing review run"
  assert_contains "$out" "working: setup done" "the checklist does not show the last note"
  pass "the table and checklist render a recorded step"
}

test_review_step_comes_from_current_state() {
  local home snap out row
  home=$(make_home review)
  write_task "$home" review-task 'needs-decision: ask-user findings'
  record_step "$home" review-task 4 4 "Hand off to review"
  snap="$home/snapshot.json"
  view "$home" --json > "$snap" || fail "snapshot failed"
  jq '(.tasks[] | select(.id == "review-task") | .current_state) |=
        (.state = "parked" | .source = "run-step"
         | .detail = "parked at test: 2 finding(s) · ask-user: authority decision")' \
    "$snap" > "$snap.tmp" && mv "$snap.tmp" "$snap"
  out=$(view "$home" --snapshot "$snap") || fail "fleet view from a saved snapshot failed"
  row=$(printf '%s\n' "$out" | grep -F '| review-task |')
  assert_contains "$row" "in review: parked at test: 2 finding(s)" "the Step cell does not show the review step"
  assert_contains "$row" "needs you" "a row waiting on a human decision is not marked"
  assert_not_contains "$row" "Hand off to review" "the Step cell shows the build step during review"
  out=$(view "$home" --steps review-task --snapshot "$snap") || fail "--steps from a saved snapshot failed"
  assert_contains "$out" "[x] 4/4 Hand off to review" "the checklist does not show the build plan as finished in review"
  assert_contains "$out" "in review: parked at test: 2 finding(s)" "the checklist does not show the review step"
  assert_contains "$out" "needs you" "the checklist does not mark the human decision"
  pass "the review step comes from the current-state read, and a human decision is marked"
}

test_watch_redraws() {
  local home out
  home=$(make_home watch)
  write_task "$home" watch-task 'working: setup done'
  record_step "$home" watch-task 1 2 "First step"
  out=$(view "$home" --watch --interval 1 --rounds 2) || fail "--watch failed"
  [ "$(printf '%s\n' "$out" | grep -c '^# Fleet View')" = 2 ] || fail "--watch did not draw the table twice: $out"
  assert_contains "$out" "1/2 First step" "--watch did not show the step"
  out=$(view "$home" --watch --steps watch-task --interval 1 --rounds 2) || fail "--watch --steps failed"
  [ "$(printf '%s\n' "$out" | grep -c '^# Steps: watch-task')" = 2 ] || fail "--watch --steps did not draw twice: $out"
  pass "--watch redraws the table and the checklist"
}

test_off_restores_table_byte_for_byte() {
  local home on off
  home=$(make_home off-table)
  write_task "$home" one-task 'working: setup done'
  write_task "$home" two-task 'working: setup done'
  record_step "$home" one-task 1 3 "Write failing tests"
  on=$(view "$home") || fail "fleet view failed"
  printf 'off\n' > "$home/config/step-display"
  off=$(view "$home") || fail "fleet view failed with the display off"
  assert_not_contains "$off" "Step" "the display is off but the table still has a Step column"
  assert_equals "$(printf '%s\n' "$on" | strip_step_column)" "$off" \
    "turning the display off changed more than the Step column"
  out=$(view "$home" --steps one-task) || fail "--steps failed with the display off"
  assert_contains "$out" "step display is off" "--steps did not report that the display is off"
  out=$(view "$home" --watch --rounds 1) || fail "--watch failed with the display off"
  assert_contains "$out" "step display is off" "--watch did not report that the display is off"
  printf 'offf\n' > "$home/config/step-display"
  off=$(view "$home" 2>"$home/warn") || fail "fleet view failed with a mistyped switch"
  assert_not_contains "$off" "Step" "a mistyped switch did not fall back to the table without steps"
  assert_grep "step-display" "$home/warn" "a mistyped switch gave no warning"
  pass "with the display off the table is the table without the Step column, byte for byte"
}

test_off_restores_brief_byte_for_byte() {
  local kind on_home off_home on off line
  on_home=$(make_home brief-on)
  off_home=$(make_home brief-off)
  printf 'off\n' > "$off_home/config/step-display"
  for kind in ship scout; do
    if [ "$kind" = scout ]; then
      FM_HOME="$on_home" "$BRIEF" "b-$kind" firstmate --scout >/dev/null 2>&1 || fail "scout brief failed"
      FM_HOME="$off_home" "$BRIEF" "b-$kind" firstmate --scout >/dev/null 2>&1 || fail "scout brief failed off"
    else
      FM_HOME="$on_home" "$BRIEF" "b-$kind" firstmate --mode no-mistakes >/dev/null 2>&1 || fail "ship brief failed"
      FM_HOME="$off_home" "$BRIEF" "b-$kind" firstmate --mode no-mistakes >/dev/null 2>&1 || fail "ship brief failed off"
    fi
    on="$on_home/data/b-$kind/brief.md"
    off="$off_home/data/b-$kind/brief.md"
    [ "$(grep -c 'fm-step.sh' "$on")" = 1 ] || fail "the $kind brief does not have exactly one step line"
    line=$(grep 'fm-step.sh' "$on")
    assert_contains "$line" "numbered plan" "the $kind step line does not ask for a numbered plan"
    assert_no_grep 'fm-step.sh' "$off" "the $kind brief still has the step line with the display off"
    assert_equals "$(grep -vF "$line" "$on" | sed "s#$on_home#HOME#g")" "$(sed "s#$off_home#HOME#g" "$off")" \
      "turning the display off changed more than the step line in the $kind brief"
  done
  pass "with the display off the ship and scout briefs are the briefs without the step line, byte for byte"
}

test_plan_list_shows_every_step_name_before_the_step_starts() {
  local home snap out
  home=$(make_home plan-first)
  write_task "$home" plan-task 'working: setup done'
  record_step "$home" plan-task --plan "Read the toolbar code" "Write failing tests" "Build the panel" "Run the suite"
  snap=$(view "$home" --json) || fail "snapshot failed"
  assert_equals "Read the toolbar code|Write failing tests|Build the panel|Run the suite" \
    "$(printf '%s' "$snap" | jq -r '.tasks[] | select(.id == "plan-task") | [.step.plan[].name] | join("|")')" \
    "the snapshot does not carry every plan step name before step 1"
  out=$(view "$home" --steps plan-task) || fail "--steps failed"
  assert_contains "$out" "[ ] 4/4 Run the suite" "the checklist does not name a step before it starts"
  record_step "$home" plan-task 1 4 "Read the toolbar code"
  out=$(view "$home" --steps plan-task) || fail "--steps failed"
  assert_contains "$out" "[>] 1/4 Read the toolbar code" "the checklist does not mark step 1 current"
  assert_contains "$out" "[ ] 3/4 Build the panel" "the checklist does not name step 3 before it starts"
  assert_contains "$out" "[ ] 4/4 Run the suite" "the checklist does not name step 4 before it starts"
  pass "the plan list shows every step name before the step starts"
}

test_a_later_plan_replaces_the_earlier_plan() {
  local home names
  home=$(make_home replan)
  write_task "$home" replan-task 'working: setup done'
  record_step "$home" replan-task --plan "Old one" "Old two" "Old three"
  record_step "$home" replan-task 1 3 "Old one"
  record_step "$home" replan-task --plan "New one" "New two"
  names=$(view "$home" --json | jq -r '.tasks[] | select(.id == "replan-task") | [.step.plan[].name] | join("|")')
  assert_equals "New one|New two" "$names" "a later plan did not replace the earlier plan"
  pass "a later plan record replaces the earlier plan"
}

test_a_step_record_without_a_plan_still_reads_the_same() {
  local home rec cur
  home=$(make_home old-record)
  write_task "$home" old-task 'working: setup done'
  rec="$home/state/old-task.step"
  printf '100\t1\t3\tFirst\n200\t2\t3\tSecond\n' > "$rec"
  cur=$(bash -c '. "$1"; fm_step_record_json "$2" 300' _ "$ROOT/bin/fm-step-lib.sh" "$rec" | jq -c '{current, history}')
  assert_equals '{"current":{"n":2,"m":3,"name":"Second","started_at":200,"age_seconds":100},"history":[{"n":1,"m":3,"name":"First","started_at":100},{"n":2,"m":3,"name":"Second","started_at":200}]}' \
    "$cur" "a step record from before plan lines existed reads differently"
  record_step "$home" old-task --scenario pass "Log in as admin"
  record_step "$home" old-task --plan "A" "B" "C"
  cur=$(bash -c '. "$1"; fm_step_record_json "$2" 300' _ "$ROOT/bin/fm-step-lib.sh" "$rec" | jq -c '.current | {n, name}')
  assert_equals '{"n":2,"name":"Second"}' "$cur" "a plan or scenario line changed the current step"
  pass "a step record without a plan still reads the same, and new line shapes never change the current step"
}

test_scenario_results_keep_the_last_result_per_name() {
  local home out
  home=$(make_home scenarios)
  write_task "$home" scen-verify 'working: setup done'
  record_step "$home" scen-verify --scenario run "Log in as admin"
  record_step "$home" scen-verify --scenario run "Viewer cannot edit"
  record_step "$home" scen-verify --scenario pass "Log in as admin"
  out=$(view "$home" --json | jq -c '[.tasks[] | select(.id == "scen-verify") | .step.scenarios[] | [.name, .result]]')
  assert_equals '[["Log in as admin","pass"],["Viewer cannot edit","run"]]' "$out" \
    "the scenario list does not keep the last result for each name in first-recorded order"
  pass "scenario results keep the last result for each name"
}

test_brief_step_line_records_the_full_plan_first() {
  local home line plan_at step_at verify
  home=$(make_home brief-plan)
  FM_HOME="$home" "$BRIEF" plan-ship firstmate --mode no-mistakes >/dev/null 2>&1 || fail "ship brief failed"
  line=$(grep 'fm-step.sh' "$home/data/plan-ship/brief.md")
  assert_contains "$line" "--plan" "the step line does not record the full plan"
  plan_at=${line%%--plan*}
  step_at=${line%%<n> <m>*}
  [ "${#plan_at}" -lt "${#step_at}" ] || fail "the step line does not record the plan before each step start: $line"
  assert_no_grep '--scenario' "$home/data/plan-ship/brief.md" "a ship brief asks for scenario records"
  FM_HOME="$home" "$BRIEF" plan-ship-verify firstmate --scout >/dev/null 2>&1 || fail "verifier brief failed"
  verify="$home/data/plan-ship-verify/brief.md"
  assert_grep '--scenario run' "$verify" "a verifier brief does not ask for scenario records"
  pass "the brief step line records the full plan first, and only a verifier records scenarios"
}

test_helper_rejects_bad_plan_and_scenario_without_writing() {
  local home
  home=$(make_home bad-plan)
  FM_TASK_INBOX="$home/state/t.inbox" "$STEP" --plan >/dev/null 2>&1
  expect_code 2 "$?" "fm-step.sh accepted an empty plan"
  FM_TASK_INBOX="$home/state/t.inbox" "$STEP" --plan "A" "  " >/dev/null 2>&1
  expect_code 2 "$?" "fm-step.sh accepted a plan step with no name"
  FM_TASK_INBOX="$home/state/t.inbox" "$STEP" --scenario maybe "Log in" >/dev/null 2>&1
  expect_code 2 "$?" "fm-step.sh accepted an unknown scenario result"
  FM_TASK_INBOX="$home/state/t.inbox" "$STEP" --scenario pass >/dev/null 2>&1
  expect_code 2 "$?" "fm-step.sh accepted a scenario with no name"
  assert_absent "$home/state/t.step" "a refused plan or scenario still wrote a record"
  pass "fm-step.sh refuses a bad plan or scenario and writes nothing"
}

test_step_write_produces_no_wake
test_helper_rejects_bad_input_without_writing
test_view_says_step_not_reported_when_absent
test_view_renders_recorded_steps
test_review_step_comes_from_current_state
test_watch_redraws
test_off_restores_table_byte_for_byte
test_off_restores_brief_byte_for_byte
test_plan_list_shows_every_step_name_before_the_step_starts
test_a_later_plan_replaces_the_earlier_plan
test_a_step_record_without_a_plan_still_reads_the_same
test_scenario_results_keep_the_last_result_per_name
test_brief_step_line_records_the_full_plan_first
test_helper_rejects_bad_plan_and_scenario_without_writing
