#!/usr/bin/env bash
# Behavior tests for the dispatch-time ChatGPT consultation gate
# (bin/fm-consult-gate-lib.sh, enforced by bin/fm-spawn.sh on every ship and
# scout launch).
#
# A stubbed loopback bridge answers the health probe, so both gate branches are
# hermetic on any machine: every probe verdict refuses a launch that has no
# stored prompt - healthy, unreachable, unhealthy, misconfigured, and
# unconfigured alike - and only an explicit --consult-waived <reason> passes.
# Every case drives fm-spawn's executable interface and asserts exit codes,
# recorded state, and launch side effects, never source bytes. bin/fm-lint.sh
# owns the lint gate.
#
# The relaunch half of the gate - bin/fm-control.sh refusing before it stops a
# running agent - lives with its transaction in tests/fm-control-relaunch.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-consult-gate)

# --- launch world ------------------------------------------------------------

# make_case <name> <id>: a firstmate home, a project with a linked copy, a fake
# tmux/treehouse toolchain, and the task's brief - with NO consultation record,
# so each case decides exactly what the gate must read. Echoes the case dir.
make_case() {
  local name=$1 id=$2 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$case_dir/home" claude
  fm_git_worktree "$case_dir/project" "$case_dir/wt" "wt-$name"
  fm_test_spawn_brief "$case_dir/home" "$id"
  rm -f "$case_dir/home/data/$id/chatgpt-loop.json"
  printf '%s\n' "$case_dir"
}

# write_record <case-dir> <id> <phase> <audit-prompt> <plan>: the exact stored
# artifact shape, written directly so a case can hold an empty stage prompt too.
write_record() { # <case-dir> <id> <phase> <audit-prompt> <plan> [worker-task]
  local dir=$1 id=$2
  mkdir -p "$1/home/data/$2"
  jq -n --arg t "$id" --arg p "$3" --arg a "$4" --arg pl "$5" --arg w "${6:-}" \
    '{task_id: $t, phase: $p, audit_prompt: $a, plan: $pl, worker_task: $w, updated_at: "2026-10-12T00:00:00Z"}' \
    >"$dir/home/data/$id/chatgpt-loop.json"
}

# seed_backlog <case-dir> <id>: a real markdown backlog row for the task, so a
# waiver has a note to land in.
seed_backlog() { # <case-dir> <id>
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    >"$1/home/data/backlog.md"
  tasks-axi add "$2" "consultation gate case" --kind ship --file "$1/home/data/backlog.md" >/dev/null
}

# run_case <case-dir> <fm-spawn args...>: the ordinary ship spawn, with the
# fixture seeder off so this suite owns every record it lets the gate read.
# The fake toolchain lives at <case-dir>/fake/fakebin (fm_fakebin's layout).
run_case() {
  local dir=$1
  shift
  : >"$dir/launch.log"
  FM_TEST_SEED_CONSULT=0 FM_FAKE_LAUNCH_LOG="$dir/launch.log" \
    fm_test_run_spawn "$dir/home" "$dir/wt" "$dir/fake/fakebin" "$@" 2>&1
}

# run_ship <case-dir> <id> [extra flags...]: the standard delivery contract.
run_ship() {
  local dir=$1 id=$2
  shift 2
  run_case "$dir" "$id" "$dir/project" claude --mode no-mistakes --yolo off "$@"
}

# The stub bridge is the only background process this suite owns, so it stops
# on every exit path while lib.sh's own cleanup still runs.
gate_test_cleanup() {
  fm_test_stop_bridge_stub
  fm_test_cleanup
}

trap gate_test_cleanup EXIT

test_ship_without_a_record_refuses_on_a_healthy_channel() {
  local dir id out status record
  id=gate-healthy-c1
  dir=$(make_case gate-healthy "$id")
  record="$dir/home/data/$id/chatgpt-loop.json"
  fm_test_start_bridge_stub "$dir" healthy

  out=$(run_ship "$dir" "$id"); status=$?
  expect_code 1 "$status" "a healthy channel must refuse a launch with no stored prompt"$'\n'"$out"
  assert_contains "$out" "$record" "the refusal must name the exact missing artifact"
  assert_contains "$out" "bin/fm-chatgpt-loop.sh init --task $id" \
    "the refusal must print the init command that creates it"
  assert_contains "$out" "--stage audit|plan --task $id" \
    "the refusal must print the consult command that creates the prompt"
  assert_contains "$out" "--consult-waived <reason>" "the refusal must mention the waiver"
  assert_absent "$dir/home/state/$id.meta" "a refused launch must write no task record"
  [ ! -s "$dir/launch.log" ] || fail "a refused launch must not launch a worker"
  fm_test_stop_bridge_stub
  pass "fm-spawn: a healthy channel refuses a ship launch with no stored prompt"
}

test_stored_prompt_launches_unchanged_and_pays_no_probe() {
  local dir id out status
  id=gate-stored-c1
  dir=$(make_case gate-stored "$id")
  fm_test_start_bridge_stub "$dir" healthy
  fm_test_seed_consult_record "$dir/home" "$id"

  out=$(run_ship "$dir" "$id"); status=$?
  expect_code 0 "$status" "a stored prompt must leave the launch unaffected"$'\n'"$out"
  assert_present "$dir/home/state/$id.meta" "the launch wrote no task record"
  assert_grep "kind=ship" "$dir/home/state/$id.meta" "the launch record is wrong"
  assert_no_grep "consult_waived=" "$dir/home/state/$id.meta" \
    "an unwaived launch must leave its record free of a waiver line"
  assert_present "$dir/launch.log" "the launch sent no worker command"
  fm_test_stop_bridge_stub
  assert_absent "$dir/hits" \
    "a launch with a stored prompt must not pay the channel probe"
  pass "fm-spawn: a stored prompt leaves the launch unchanged and never probes the channel"
}

test_waiver_with_an_empty_reason_refuses() {
  local dir id out status reason
  id=gate-emptywaiver-c1
  dir=$(make_case gate-emptywaiver "$id")
  fm_test_start_bridge_stub "$dir" healthy

  for reason in '' '   ' $'\t'; do
    out=$(run_ship "$dir" "$id" --consult-waived "$reason"); status=$?
    expect_code 1 "$status" "an empty waiver reason must refuse (got '$reason')"$'\n'"$out"
    assert_contains "$out" "--consult-waived needs a non-empty reason" \
      "the refusal must explain that the reason is missing"
    assert_absent "$dir/home/state/$id.meta" "a refused waiver must write no task record"
    [ ! -s "$dir/launch.log" ] || fail "a refused waiver must not launch a worker"
  done
  fm_test_stop_bridge_stub
  pass "fm-spawn: a waiver with an empty or whitespace-only reason is refused"
}

test_waiver_reason_lands_in_the_record_and_the_backlog_note() {
  local dir id out status reason meta body
  id=gate-waiver-c1
  reason='captain approved dispatching before the consultation'
  dir=$(make_case gate-waiver "$id")
  seed_backlog "$dir" "$id"
  fm_test_start_bridge_stub "$dir" healthy

  out=$(run_ship "$dir" "$id" --consult-waived "$reason"); status=$?
  expect_code 0 "$status" "an explicit waiver must let the launch proceed"$'\n'"$out"
  meta="$dir/home/state/$id.meta"
  assert_grep "consult_waived=$reason" "$meta" "the waiver reason must be recorded in the task record"
  body=$(tasks-axi show "$id" --full --file "$dir/home/data/backlog.md")
  assert_contains "$body" "$reason" "the waiver reason must be recorded in the backlog note"
  assert_present "$dir/launch.log" "the waived launch must still launch"
  fm_test_stop_bridge_stub
  pass "fm-spawn: a waiver reason is recorded in the task record and the backlog note"
}

test_scout_is_gated_the_same_way() {
  local dir id out status
  id=gate-scout-c1
  dir=$(make_case gate-scout "$id")
  fm_test_start_bridge_stub "$dir" healthy

  out=$(run_case "$dir" "$id" "$dir/project" claude --scout); status=$?
  expect_code 1 "$status" "a scout launch with no stored prompt must refuse"$'\n'"$out"
  assert_contains "$out" "$dir/home/data/$id/chatgpt-loop.json" \
    "the scout refusal must name the missing artifact"
  assert_absent "$dir/home/state/$id.meta" "a refused scout launch must write no task record"
  [ ! -s "$dir/launch.log" ] || fail "a refused scout launch must not launch a worker"

  fm_test_seed_consult_record "$dir/home" "$id"
  out=$(run_case "$dir" "$id" "$dir/project" claude --scout); status=$?
  expect_code 0 "$status" "a scout launch with a stored prompt must proceed"$'\n'"$out"
  assert_grep "kind=scout" "$dir/home/state/$id.meta" "the scout record is wrong"
  assert_no_grep "consult_waived=" "$dir/home/state/$id.meta" \
    "an unwaived scout launch must leave its record free of a waiver line"
  fm_test_stop_bridge_stub
  pass "fm-spawn: a scout launch is gated exactly like a ship"
}

test_unavailable_channel_refuses_naming_the_cause() {
  local dir id out status meta body
  id=gate-down-c1
  dir=$(make_case gate-down "$id")
  seed_backlog "$dir" "$id"
  fm_test_use_dead_bridge

  out=$(run_ship "$dir" "$id"); status=$?
  expect_code 1 "$status" "an unreachable channel must refuse a launch with no stored prompt"$'\n'"$out"
  assert_contains "$out" "$dir/home/data/$id/chatgpt-loop.json" \
    "the refusal must still name the missing artifact"
  assert_contains "$out" "the consultation channel is unavailable: unreachable" \
    "the refusal must name the real cause from the probe verdict"
  assert_contains "$out" "--consult-waived <reason>" \
    "the refusal must print the waiver command"
  assert_absent "$dir/home/state/$id.meta" "a refused launch must write no task record"
  [ ! -s "$dir/launch.log" ] || fail "a refused launch must not launch a worker"
  body=$(tasks-axi show "$id" --full --file "$dir/home/data/backlog.md")
  assert_not_contains "$body" "ChatGPT consultation gate waived" \
    "a refused launch must not write a waiver note"
  pass "fm-spawn: an unreachable channel refuses with the cause named, never a silent pass"
}

test_unhealthy_bridge_refuses_naming_the_cause() {
  local dir id out status
  id=gate-unhealthy-c1
  dir=$(make_case gate-unhealthy "$id")
  fm_test_start_bridge_stub "$dir" unhealthy

  out=$(run_ship "$dir" "$id"); status=$?
  expect_code 1 "$status" "a listening-but-broken channel must refuse a launch with no stored prompt"$'\n'"$out"
  assert_contains "$out" "$dir/home/data/$id/chatgpt-loop.json" \
    "the refusal must still name the missing artifact"
  assert_contains "$out" "the consultation channel is unavailable: unhealthy" \
    "the refusal must name the unhealthy verdict as the cause"
  assert_contains "$out" "--consult-waived <reason>" \
    "the refusal must print the waiver command"
  assert_absent "$dir/home/state/$id.meta" "a refused launch must write no task record"
  [ ! -s "$dir/launch.log" ] || fail "a refused launch must not launch a worker"
  fm_test_stop_bridge_stub
  pass "fm-spawn: a listening-but-broken channel refuses with the cause named"
}

test_a_finished_rounds_prompt_never_satisfies_the_gate() {
  local dir id out status
  id=gate-stale-c1
  dir=$(make_case gate-stale "$id")
  fm_test_use_dead_bridge
  # The exact record a finished round leaves at the next round's consult phase:
  # phase back at audit-consult with round 1's prompt still stored. The gate
  # must read it as "this round's consultation has not run", never as a stored
  # prompt.
  write_record "$dir" "$id" audit-consult "stale prompt from round 1" "stale plan from round 1"

  out=$(run_ship "$dir" "$id"); status=$?
  expect_code 1 "$status" "a consult-phase record must refuse even with a leftover prompt"$'\n'"$out"
  assert_contains "$out" "--stage audit --task $id" \
    "the refusal must point at the consultation that has not run"
  assert_contains "$out" "waiting on this round's consultation" \
    "the refusal must say this round's consultation has not run"
  assert_absent "$dir/home/state/$id.meta" "a refused launch must write no task record"
  [ ! -s "$dir/launch.log" ] || fail "a refused launch must not launch a worker"
  pass "fm-spawn: a finished round's prompt never satisfies the gate at the next round's consult phase"
}

test_loop_dispatch_record_satisfies_the_gate() {
  local dir id out status
  id=gate-loopworker-c1
  dir=$(make_case gate-loopworker "$id")
  fm_test_start_bridge_stub "$dir" healthy
  # The consultation loop keeps its record under its OWN task id and dispatches
  # a worker task that has none; the marker names that loop record, and the gate
  # accepts only because it sits at its dispatch phase with a stored prompt.
  write_record "$dir" gate-loop-task-audit audit-dispatch "the stored audit prompt" ""

  out=$(FM_CHATGPT_LOOP_DISPATCH_TASK=gate-loop-task-audit \
    run_ship "$dir" "$id"); status=$?
  expect_code 0 "$status" "the loop's own dispatch must pass the gate"$'\n'"$out"
  assert_no_grep "consult_waived=" "$dir/home/state/$id.meta" \
    "a satisfied loop dispatch must not record a waiver"
  assert_present "$dir/launch.log" "the loop dispatch must still launch"
  fm_test_stop_bridge_stub
  pass "fm-spawn: the consultation loop's own dispatch satisfies the gate"
}

test_loop_dispatch_marker_alone_proves_nothing() {
  local dir id out status
  id=gate-loopbare-c1
  dir=$(make_case gate-loopbare "$id")
  fm_test_start_bridge_stub "$dir" healthy
  # The marker points at a record that is not at its dispatch phase, so the
  # consultation it names has not reached its prompt yet.
  write_record "$dir" gate-loop-pending audit-consult "the stored audit prompt" ""

  out=$(FM_CHATGPT_LOOP_DISPATCH_TASK=gate-loop-pending \
    run_ship "$dir" "$id"); status=$?
  expect_code 1 "$status" "a marker without a dispatch-phase record must refuse"$'\n'"$out"
  assert_absent "$dir/home/state/$id.meta" "a refused launch must write no task record"
  fm_test_stop_bridge_stub
  pass "fm-spawn: the loop marker alone never satisfies the gate"
}

test_loop_worker_record_satisfies_the_gate() {
  local dir id out status
  id=gate-loopworker-rl-c1
  dir=$(make_case gate-loopworker-rl "$id")
  fm_test_start_bridge_stub "$dir" healthy
  # The loop dispatched this worker and advanced to audit-worker after handing
  # over its audit prompt. The worker task has no record of its own and no
  # dispatch marker at relaunch time, so the loop record naming it is the only
  # recoverable proof that its consultation ran.
  write_record "$dir" gate-loop-rl-task audit-worker "the delivered audit prompt" "" "$id"

  out=$(run_ship "$dir" "$id"); status=$?
  expect_code 0 "$status" "a loop record naming the launched worker must pass the gate"$'\n'"$out"
  assert_no_grep "consult_waived=" "$dir/home/state/$id.meta" \
    "a recovered loop worker record must not record a waiver"
  assert_present "$dir/launch.log" "the launch with its recovered record must launch"
  fm_test_stop_bridge_stub
  pass "fm-spawn: a loop record naming the launched worker satisfies the gate"
}

test_loop_worker_record_for_another_task_still_refuses() {
  local dir id out status
  id=gate-loopworker-other-c1
  dir=$(make_case gate-loopworker-other "$id")
  fm_test_start_bridge_stub "$dir" healthy
  # A loop record that delivered its prompt to a different worker proves nothing
  # about this task.
  write_record "$dir" gate-loop-other-task audit-worker "the delivered audit prompt" "" "some-other-worker"

  out=$(run_ship "$dir" "$id"); status=$?
  expect_code 1 "$status" "a loop record naming another worker must refuse"$'\n'"$out"
  assert_absent "$dir/home/state/$id.meta" "a refused launch must write no task record"

  # A matching worker_task at a pre-delivery phase has not proven the prompt was
  # handed over, so it refuses too.
  write_record "$dir" gate-loop-other-task audit-dispatch "the delivered audit prompt" "" "$id"
  out=$(run_ship "$dir" "$id"); status=$?
  expect_code 1 "$status" "a matching worker_task before delivery must refuse"$'\n'"$out"
  assert_absent "$dir/home/state/$id.meta" "a refused launch must write no task record"
  [ ! -s "$dir/launch.log" ] || fail "a refused launch must not launch a worker"
  fm_test_stop_bridge_stub
  pass "fm-spawn: a loop record naming another worker or a pre-delivery phase still refuses"
}

test_the_stage_in_play_decides_which_prompt_is_required() {
  local dir id out status
  id=gate-stage-c1
  dir=$(make_case gate-stage "$id")
  fm_test_start_bridge_stub "$dir" healthy
  # The plan stage is in play, so an audit prompt left over from the first half
  # of the loop does not satisfy the gate: the plan prompt is what this launch
  # would deliver.
  write_record "$dir" "$id" plan-dispatch "the stored audit prompt" "   "

  out=$(run_ship "$dir" "$id"); status=$?
  expect_code 1 "$status" "a blank plan prompt must refuse while plan is in play"$'\n'"$out"
  assert_contains "$out" "--stage plan --task $id" \
    "the refusal must point at the stage whose prompt is missing"

  write_record "$dir" "$id" plan-dispatch "the stored audit prompt" "the stored plan"
  out=$(run_ship "$dir" "$id"); status=$?
  expect_code 0 "$status" "a stored plan prompt must launch while plan is in play"$'\n'"$out"
  assert_present "$dir/launch.log" "the launch with its stage prompt must launch"
  fm_test_stop_bridge_stub
  pass "fm-spawn: the stage in play decides which stored prompt the gate requires"
}

test_ship_without_a_record_refuses_on_a_healthy_channel
test_stored_prompt_launches_unchanged_and_pays_no_probe
test_waiver_with_an_empty_reason_refuses
test_waiver_reason_lands_in_the_record_and_the_backlog_note
test_scout_is_gated_the_same_way
test_unavailable_channel_refuses_naming_the_cause
test_unhealthy_bridge_refuses_naming_the_cause
test_a_finished_rounds_prompt_never_satisfies_the_gate
test_loop_dispatch_record_satisfies_the_gate
test_loop_dispatch_marker_alone_proves_nothing
test_loop_worker_record_satisfies_the_gate
test_loop_worker_record_for_another_task_still_refuses
test_the_stage_in_play_decides_which_prompt_is_required

echo "# all fm-consult-gate tests passed"
