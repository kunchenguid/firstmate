#!/usr/bin/env bash
# Behavior tests for provider-outage continuity.
#
# Two public interfaces are covered, both driven without contacting any real
# provider: bin/fm-provider-continuity.sh (classification, qualification,
# cooldown, candidate filtering, and the cross-provider handoff license) and
# bin/fm-spawn.sh --resume-worktree (relaunching one task into the isolated copy
# it already owns, transactionally). Time is injected through
# FM_CONTINUITY_NOW so cooldown expiry is deterministic instead of slept out.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONT="$ROOT/bin/fm-provider-continuity.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-provider-continuity)

# --- continuity record fixtures ---------------------------------------------

# make_state <name>: a bare state directory for one continuity case.
make_state() {
  local dir="$TMP_ROOT/$1/state"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# cont <state> <now> <args...>: run the continuity script against <state> with a
# pinned clock, capturing output and exit code in CONT_OUT / CONT_STATUS.
cont() {
  local state=$1 now=$2
  shift 2
  set +e
  CONT_OUT=$(FM_STATE_OVERRIDE="$state" FM_CONTINUITY_NOW="$now" "$CONT" "$@" 2>&1)
  CONT_STATUS=$?
  set -e
}

test_single_transient_failure_does_not_activate_outage_handling() {
  local state
  state=$(make_state single-failure)

  cont "$state" 1000 record vendor-one provider-5xx --detail 'retry-exhausted 503'
  expect_code 0 "$CONT_STATUS" "recording one qualifying observation should succeed"
  assert_contains "$CONT_OUT" "state: eligible" \
    "one qualifying observation already reported the provider unavailable"
  assert_contains "$CONT_OUT" "qualifying: 1/3" \
    "the reconciled line did not report the observation count against the threshold"

  cont "$state" 1000 eligible vendor-one
  expect_code 0 "$CONT_STATUS" "one qualifying observation must not make a provider ineligible"
  assert_contains "$CONT_OUT" "eligible" "a single failure changed provider eligibility"
  pass "one transient provider failure never activates outage handling"
}

test_repeated_qualifying_failures_activate_outage_handling() {
  local state
  state=$(make_state repeated-failures)

  cont "$state" 1000 record vendor-one provider-5xx
  cont "$state" 1100 record vendor-one provider-connection
  cont "$state" 1200 record vendor-one provider-stream
  expect_code 0 "$CONT_STATUS" "recording the third qualifying observation should succeed"
  assert_contains "$CONT_OUT" "state: unavailable" \
    "three qualifying provider-level observations did not qualify an outage"
  assert_contains "$CONT_OUT" "until: 3000" \
    "the reconciled line did not publish an inspectable cooldown boundary"

  cont "$state" 1200 eligible vendor-one
  expect_code 1 "$CONT_STATUS" "a qualified outage must make the provider ineligible"
  assert_contains "$CONT_OUT" "unavailable until 3000" \
    "the ineligible verdict did not name when eligibility returns"
  pass "repeated qualifying provider failures activate outage handling with a bounded cooldown"
}

test_isolated_failures_outside_the_window_never_qualify() {
  local state
  state=$(make_state spread-failures)

  cont "$state" 1000 record vendor-one provider-5xx
  cont "$state" 5000 record vendor-one provider-5xx
  cont "$state" 9000 record vendor-one provider-5xx
  assert_contains "$CONT_OUT" "state: eligible" \
    "three observations spread far outside the window were treated as one outage burst"
  assert_contains "$CONT_OUT" "qualifying: 1/3" \
    "the burst count did not reset across a gap longer than the window"
  pass "qualifying observations separated by more than the window never accumulate into an outage"
}

test_auth_config_and_task_failures_never_qualify() {
  local state cls
  state=$(make_state non-qualifying)

  for cls in auth config task transient; do
    cont "$state" 1000 record vendor-one "$cls"
    cont "$state" 1010 record vendor-one "$cls"
    cont "$state" 1020 record vendor-one "$cls"
    cont "$state" 1030 record vendor-one "$cls"
    assert_contains "$CONT_OUT" "state: eligible" \
      "repeated $cls failures were misclassified as a provider outage"
  done
  cont "$state" 1030 eligible vendor-one
  expect_code 0 "$CONT_STATUS" "non-provider failures must never make a provider ineligible"
  assert_contains "$CONT_OUT" "eligible" "non-provider failures changed provider eligibility"
  pass "authentication, configuration, task, and transient failures never qualify an outage"
}

test_quota_pressure_is_recorded_separately_and_never_qualifies() {
  local state
  state=$(make_state quota-pressure)

  cont "$state" 1000 record vendor-one quota --detail 'weekly window exhausted'
  cont "$state" 1010 record vendor-one quota
  cont "$state" 1020 record vendor-one quota
  cont "$state" 1030 record vendor-one quota
  assert_contains "$CONT_OUT" "state: eligible" \
    "quota exhaustion was folded into outage detection instead of staying a separate concern"
  assert_contains "$CONT_OUT" "non-qualifying: quota=4" \
    "quota pressure was not recorded as its own inspectable evidence"
  assert_contains "$CONT_OUT" "qualifying: 0/3" \
    "quota observations were counted toward the outage threshold"
  pass "quota and rate-limit pressure is recorded separately and never qualifies an outage"
}

test_cooldown_expiry_restores_eligibility_deterministically() {
  local state
  state=$(make_state cooldown-expiry)

  cont "$state" 1000 record vendor-one provider-5xx
  cont "$state" 1100 record vendor-one provider-5xx
  cont "$state" 1200 record vendor-one provider-5xx

  cont "$state" 2999 eligible vendor-one
  expect_code 1 "$CONT_STATUS" "eligibility returned one second before the cooldown boundary"
  cont "$state" 3000 eligible vendor-one
  expect_code 0 "$CONT_STATUS" "eligibility did not return exactly at the cooldown boundary"
  assert_contains "$CONT_OUT" "eligible" "the cooldown boundary did not restore eligibility"

  # Deterministic means repeatable: the same clock always yields the same verdict.
  cont "$state" 2999 eligible vendor-one
  expect_code 1 "$CONT_STATUS" "the same clock produced a different verdict on a second read"
  pass "cooldown expiry restores eligibility deterministically from the recorded evidence"
}

test_new_task_selection_excludes_only_the_unavailable_provider() {
  local state
  state=$(make_state selection)

  cont "$state" 1000 record vendor-one provider-5xx
  cont "$state" 1100 record vendor-one provider-5xx
  cont "$state" 1200 record vendor-one provider-5xx
  cont "$state" 1200 record vendor-two quota
  cont "$state" 1200 record vendor-two auth

  cont "$state" 1200 filter vendor-one vendor-two vendor-three
  expect_code 0 "$CONT_STATUS" "candidates remained available, so filtering must not defer"
  assert_contains "$CONT_OUT" "vendor-one excluded outage until 3000" \
    "the unavailable provider was not excluded with an inspectable reason"
  assert_contains "$CONT_OUT" "vendor-two eligible" \
    "a provider with only quota and auth evidence lost its capability to take new work"
  assert_contains "$CONT_OUT" "vendor-three eligible" \
    "a provider with no evidence at all was excluded"
  pass "new-task selection excludes only the unavailable provider and preserves the rest"
}

test_configured_fallback_is_consulted_only_during_an_outage() {
  local state
  state=$(make_state fallback-tier)

  # Healthy primary: the configured fallback stays unused, so an outage
  # fallback can never quietly act as a second quota choice.
  cont "$state" 1000 filter --fallback vendor-two vendor-one
  expect_code 0 "$CONT_STATUS" "an available primary must not defer"
  assert_contains "$CONT_OUT" "vendor-one eligible primary" \
    "the available primary candidate was not selected"
  assert_contains "$CONT_OUT" "fallback: not consulted" \
    "the outage fallback was consulted while the primary was available"
  assert_not_contains "$CONT_OUT" "vendor-two eligible" \
    "the outage fallback was offered alongside an available primary"

  cont "$state" 1000 record vendor-one provider-5xx
  cont "$state" 1100 record vendor-one provider-connection
  cont "$state" 1200 record vendor-one provider-stream

  cont "$state" 1200 filter --fallback vendor-two vendor-one
  expect_code 0 "$CONT_STATUS" "a configured fallback must keep the work dispatchable"
  assert_contains "$CONT_OUT" "vendor-one excluded outage until 3000 (primary)" \
    "the unavailable primary was not reported with its tier"
  assert_contains "$CONT_OUT" "vendor-two eligible fallback" \
    "the configured outage fallback was not selected once the primary went down"

  # Both tiers down: the work waits rather than routing somewhere unqualified.
  cont "$state" 1200 record vendor-two provider-5xx
  cont "$state" 1210 record vendor-two provider-5xx
  cont "$state" 1220 record vendor-two provider-5xx
  cont "$state" 1220 filter --fallback vendor-two vendor-one
  expect_code 3 "$CONT_STATUS" "both tiers unavailable must defer"
  assert_contains "$CONT_OUT" "defer:" "an exhausted fallback chain did not defer"
  pass "a configured outage fallback is consulted only when every primary candidate is unavailable"
}

test_review_independence_defers_when_no_independent_provider_remains() {
  local state
  state=$(make_state independence)

  cont "$state" 1000 record vendor-one provider-5xx
  cont "$state" 1100 record vendor-one provider-5xx
  cont "$state" 1200 record vendor-one provider-5xx

  # The work under review came from vendor-two, so vendor-two cannot review it
  # and vendor-one is unavailable: the review waits rather than reviewing itself.
  cont "$state" 1200 filter --exclude vendor-two vendor-one vendor-two
  expect_code 3 "$CONT_STATUS" "an unmeetable independence requirement must defer, not select"
  assert_contains "$CONT_OUT" "vendor-two excluded independence" \
    "the family that produced the work was allowed to review itself"
  assert_contains "$CONT_OUT" "defer:" "the unmeetable independence requirement did not defer"

  # A third independent family keeps the same review dispatchable.
  cont "$state" 1200 filter --exclude vendor-two vendor-one vendor-two vendor-three
  expect_code 0 "$CONT_STATUS" "an available independent provider must keep the review dispatchable"
  assert_contains "$CONT_OUT" "vendor-three eligible" \
    "an available independent provider was not offered for the review"
  pass "review independence is preserved and defers instead of letting a family review its own work"
}

test_no_configured_continuity_state_leaves_selection_unchanged() {
  local state
  state=$(make_state no-policy)

  cont "$state" 1000 status
  expect_code 0 "$CONT_STATUS" "reading status with no records must succeed"
  assert_contains "$CONT_OUT" "provider: none" \
    "an unconfigured home did not report an empty continuity record"

  cont "$state" 1000 filter vendor-one vendor-two vendor-three
  expect_code 0 "$CONT_STATUS" "an unconfigured home must never exclude a candidate"
  assert_not_contains "$CONT_OUT" "excluded" \
    "an unconfigured home excluded a dispatch candidate"
  assert_absent "$state/provider-continuity" \
    "a read-only continuity query created durable state in an unconfigured home"
  pass "a home with no recorded provider evidence leaves existing dispatch selection unchanged"
}

test_unknown_evidence_classes_and_provider_tokens_are_refused() {
  local state
  state=$(make_state refusals)

  cont "$state" 1000 record vendor-one mystery-failure
  expect_code 2 "$CONT_STATUS" "an unknown evidence class must be refused"
  assert_contains "$CONT_OUT" "unknown evidence class" \
    "the refusal did not name the unknown evidence class"

  cont "$state" 1000 record ../escape provider-5xx
  expect_code 2 "$CONT_STATUS" "an unsafe provider token must be refused"

  cont "$state" 1000 record vendor-one
  expect_code 2 "$CONT_STATUS" "recording without an evidence class must be refused"
  pass "unclassified evidence and unsafe provider tokens are refused rather than guessed"
}

# --- handoff license fixtures -----------------------------------------------

# make_handoff_case <name> <crew-state> <tmux-mode> builds a state dir with one
# recorded task, a stubbed current-state reader, and a fake tmux that reports the
# requested endpoint shape. Echoes "<state>|<fakebin>|<crewbin>".
#
# tmux-mode: `present` keeps the recorded window in the inventory (so the
# endpoint cannot be proved gone), `gone` reports the session missing, and
# `broken` fails the inventory read in a way that stays unreadable.
make_handoff_case() {
  local name=$1 crew_state=$2 tmux_mode=$3 case_dir state fakebin crewbin
  case_dir="$TMP_ROOT/$name"
  state="$case_dir/state"
  mkdir -p "$state"
  fakebin=$(fm_fakebin "$case_dir")
  crewbin="$case_dir/fm-crew-state-stub.sh"
  fm_write_meta "$state/handoff-task.meta" \
    'window=firstmate:fm-handoff-task' \
    'endpoint_task_id=handoff-task' \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    'harness=claude' \
    'kind=ship' \
    'mode=no-mistakes' \
    'yolo=off'
  cat > "$crewbin" <<SH
#!/usr/bin/env bash
printf 'state: %s · source: run-step · stub\n' "$crew_state"
SH
  chmod +x "$crewbin"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
mode='$tmux_mode'
case "\${1:-}" in
  list-windows)
    case "\$mode" in
      present) printf 'fm-handoff-task\n'; exit 0 ;;
      gone) printf "can't find session: firstmate\n" >&2; exit 1 ;;
      *) printf 'unexpected tmux failure\n' >&2; exit 1 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s|%s|%s\n' "$state" "$fakebin" "$crewbin"
}

# handoff <record> <args...>: run a handoff subcommand against a prepared case.
handoff() {
  local record=$1 state fakebin crewbin
  shift
  IFS='|' read -r state fakebin crewbin <<EOF
$record
EOF
  set +e
  CONT_OUT=$(FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$crewbin" \
    PATH="$fakebin:$PATH" "$CONT" "$@" 2>&1)
  CONT_STATUS=$?
  set -e
}

test_handoff_refuses_while_the_recorded_worker_cannot_be_proved_gone() {
  local rec
  rec=$(make_handoff_case handoff-present unknown present)

  handoff "$rec" handoff-check handoff-task
  expect_code 1 "$CONT_STATUS" "a still-present endpoint must refuse a cross-provider handoff"
  assert_contains "$CONT_OUT" "handoff: refuse" \
    "the license allowed a handoff while the recorded worker may still own the task"
  assert_contains "$CONT_OUT" "cannot be proved gone" \
    "the refusal did not name the concrete ownership evidence"
  pass "cross-provider recovery refuses while the original worker may still be active"
}

test_handoff_refuses_while_a_validation_run_owns_the_task() {
  local rec
  rec=$(make_handoff_case handoff-working working gone)

  handoff "$rec" handoff-check handoff-task
  expect_code 1 "$CONT_STATUS" "an active validation run must refuse a cross-provider handoff"
  assert_contains "$CONT_OUT" "crew: working" \
    "the license did not report the active run it refused on"
  assert_contains "$CONT_OUT" "an active validation run still owns this task" \
    "a dead endpoint was allowed to bypass active validation ownership"

  rec=$(make_handoff_case handoff-parked parked gone)
  handoff "$rec" handoff-check handoff-task
  expect_code 1 "$CONT_STATUS" "a parked validation gate must refuse a cross-provider handoff"
  assert_contains "$CONT_OUT" "crew: parked" \
    "the license did not report the parked run it refused on"
  pass "no-mistakes ownership is never bypassed by a provider handoff"
}

test_handoff_allows_once_the_endpoint_is_authoritatively_gone() {
  local rec
  rec=$(make_handoff_case handoff-gone unknown gone)

  handoff "$rec" handoff-check handoff-task
  expect_code 0 "$CONT_STATUS" "an authoritatively missing endpoint with no active run must allow the handoff"
  assert_contains "$CONT_OUT" "handoff: allow" \
    "the license refused a handoff the evidence supports"
  assert_contains "$CONT_OUT" "endpoint: missing" \
    "the allow verdict did not name the endpoint evidence it relied on"
  pass "a cross-provider handoff is licensed only once the recorded worker is provably gone"
}

test_handoff_refuses_an_unreadable_or_unrecorded_task() {
  local rec
  rec=$(make_handoff_case handoff-unreadable unknown broken)

  handoff "$rec" handoff-check handoff-task
  expect_code 1 "$CONT_STATUS" "an unreadable endpoint must refuse rather than assume the worker is gone"
  assert_contains "$CONT_OUT" "endpoint: unreadable" \
    "an unreadable inventory was not reported as such"

  handoff "$rec" handoff-check no-such-task
  expect_code 1 "$CONT_STATUS" "a task with no record must refuse"
  assert_contains "$CONT_OUT" "no readable task record" \
    "the refusal did not name the missing task record"
  pass "an unreadable endpoint or missing task record refuses instead of licensing a handoff"
}

test_repeated_handoff_attempts_stop_and_report_the_blocker() {
  local rec state
  rec=$(make_handoff_case handoff-attempts unknown gone)
  state=${rec%%|*}

  handoff "$rec" handoff-attempt handoff-task
  expect_code 0 "$CONT_STATUS" "the first handoff attempt must be licensed"
  assert_contains "$CONT_OUT" "attempts: 1/2" "the first attempt was not recorded"

  handoff "$rec" handoff-attempt handoff-task
  expect_code 0 "$CONT_STATUS" "the second handoff attempt must still be licensed"

  handoff "$rec" handoff-attempt handoff-task
  expect_code 1 "$CONT_STATUS" "a third handoff attempt must stop instead of retrying forever"
  assert_contains "$CONT_OUT" "repeated handoff attempts exhausted" \
    "the exhausted-attempts refusal did not report the concrete blocker"

  handoff "$rec" handoff-clear handoff-task
  expect_code 0 "$CONT_STATUS" "clearing the attempt ledger must succeed"
  assert_absent "$state/provider-continuity/handoff/handoff-task.attempts" \
    "the handoff attempt ledger survived an explicit clear"
  pass "repeated handoff failures stop and report the concrete blocker"
}

# --- fm-spawn --resume-worktree fixtures ------------------------------------

# make_resume_fakebin <dir>: a fake tmux that records every send-keys payload
# and every kill-window target, and that can be told to fail the literal launch
# send (FM_FAKE_FAIL_LITERAL=1) so the post-record failure path is reachable
# without a real harness.
make_resume_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session) exit 0 ;;
  new-window) printf '@1\n'; exit 0 ;;
  kill-window)
    [ -z "${FM_FAKE_KILL_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_KILL_LOG"
    exit 0
    ;;
  send-keys)
    literal=0
    prev=
    for a in "$@"; do
      if [ "$a" = "-l" ]; then literal=1; fi
      if [ "$prev" = "-l" ] && [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
        printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
      fi
      prev=$a
    done
    # `tmux send-keys -t <target> <text> Enter`: the payload is argument four.
    if [ "$literal" = 0 ] && [ -n "${FM_FAKE_SEND_LOG:-}" ]; then
      printf '%s\n' "${4:-}" >> "$FM_FAKE_SEND_LOG"
    fi
    if [ "$literal" = 1 ] && [ "${FM_FAKE_FAIL_LITERAL:-0}" = 1 ]; then
      printf 'simulated launch send failure\n' >&2
      exit 1
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_resume_case <name> <id>: a home, a project with two real worktrees (the
# task's own copy plus a decoy standing in for a different copy), a dirty file
# and an extra commit inside the task copy, and a recorded task on the original
# harness. Echoes "<case>|<home>|<proj>|<wt>|<other>|<fakebin>".
make_resume_case() {
  local name=$1 id=$2 case_dir home proj wt other fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  other="$case_dir/other-wt"
  fakebin=$(make_resume_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  git -C "$proj" worktree add --quiet -b "decoy-$id" "$other"
  # Durable progress the resume must preserve: one commit plus one dirty file.
  printf 'landed work\n' > "$wt/implemented.txt"
  git -C "$wt" add implemented.txt
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'implement the accepted behavior'
  printf 'work in progress\n' > "$wt/scratch.txt"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$wt" \
    "project=$proj" \
    'harness=codex' \
    'kind=ship' \
    'mode=no-mistakes' \
    'yolo=off' \
    "tasktmp=/tmp/fm-$id" \
    'model=gpt-5' \
    'effort=high'
  printf '%s|%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$other" "$fakebin"
}

read_resume_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR OTHER_WT FAKEBIN_DIR <<EOF
$1
EOF
}

# run_resume_spawn <home> <fakebin> <pane-path> <args...>
run_resume_spawn() {
  local home=$1 fakebin=$2 pane=$3
  shift 3
  set +e
  SPAWN_OUT=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' GROK_HOME="$home/grok-home" \
    FM_FAKE_SEND_LOG="${FM_FAKE_SEND_LOG:-}" FM_FAKE_LAUNCH_LOG="${FM_FAKE_LAUNCH_LOG:-}" \
    FM_FAKE_KILL_LOG="${FM_FAKE_KILL_LOG:-}" FM_FAKE_FAIL_LITERAL="${FM_FAKE_FAIL_LITERAL:-0}" \
    PATH="$fakebin:$PATH" "$SPAWN" "$@" 2>&1)
  SPAWN_STATUS=$?
  set -e
}

test_resume_reuses_the_recorded_isolated_copy_and_preserves_work() {
  local rec id head_before
  id=resume-same-copy-a1
  rec=$(make_resume_case resume-same-copy "$id")
  read_resume_record "$rec"
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)

  FM_FAKE_SEND_LOG="$CASE_DIR/send.log" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    run_resume_spawn "$HOME_DIR" "$FAKEBIN_DIR" "$WT_DIR" \
      "$id" "$PROJ_DIR" --mode no-mistakes --yolo off \
      --harness claude --resume-worktree "$WT_DIR"
  expect_code 0 "$SPAWN_STATUS" "resuming into the recorded isolated copy should succeed: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "spawned $id harness=claude" \
    "the resume did not relaunch the task on the alternate harness"
  assert_contains "$SPAWN_OUT" "resumed=1" "the success line did not report a resume"
  assert_contains "$SPAWN_OUT" "worktree=$WT_DIR" \
    "the resume recorded a worktree other than the copy the task already owns"

  assert_grep "cd " "$CASE_DIR/send.log" "the resume did not enter the existing copy"
  assert_no_grep 'treehouse get' "$CASE_DIR/send.log" \
    "the resume allocated a second isolated copy through treehouse get"

  # Task identity and durable progress survive unchanged.
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "the recorded copy changed"
  assert_grep "endpoint_task_id=$id" "$HOME_DIR/state/$id.meta" "the task identity changed"
  assert_grep "harness=claude" "$HOME_DIR/state/$id.meta" "the alternate harness was not recorded"
  assert_grep "mode=no-mistakes" "$HOME_DIR/state/$id.meta" "the delivery contract changed"
  [ "$(git -C "$WT_DIR" rev-parse HEAD)" = "$head_before" ] \
    || fail "the resume moved the task branch's head"
  [ "$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD)" = "fm/$id" ] \
    || fail "the resume changed the task branch"
  assert_present "$WT_DIR/scratch.txt" "the resume discarded uncommitted work"
  assert_present "$WT_DIR/implemented.txt" "the resume discarded committed work"
  assert_absent "$HOME_DIR/state/.resume-$id.meta.bak" \
    "a successful resume left its record snapshot behind"
  pass "a provider handoff resumes in the same isolated copy and preserves its branch, commits, and dirty files"
}

test_resume_refuses_a_pane_that_settled_on_another_copy() {
  local rec id
  id=resume-wrong-copy-b2
  rec=$(make_resume_case resume-wrong-copy "$id")
  read_resume_record "$rec"

  # The pane lands in a different real worktree: valid in isolation, but not the
  # copy this task owns, so accepting it would split the task across two copies.
  run_resume_spawn "$HOME_DIR" "$FAKEBIN_DIR" "$OTHER_WT" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off \
    --harness claude --resume-worktree "$WT_DIR"
  expect_code 1 "$SPAWN_STATUS" "settling on another copy must refuse the resume"
  assert_contains "$SPAWN_OUT" "instead of the requested isolated copy" \
    "the refusal did not name the copy mismatch"
  assert_grep 'harness=codex' "$HOME_DIR/state/$id.meta" \
    "the refused resume rewrote the task's authoritative record"
  pass "a resume that would split one task across two copies is refused"
}

test_failed_relaunch_leaves_the_original_record_and_work_recoverable() {
  local rec id head_before
  id=resume-failed-launch-c3
  rec=$(make_resume_case resume-failed-launch "$id")
  read_resume_record "$rec"
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)

  FM_FAKE_FAIL_LITERAL=1 FM_FAKE_KILL_LOG="$CASE_DIR/kill.log" \
    run_resume_spawn "$HOME_DIR" "$FAKEBIN_DIR" "$WT_DIR" \
      "$id" "$PROJ_DIR" --mode no-mistakes --yolo off \
      --harness claude --resume-worktree "$WT_DIR"
  [ "$SPAWN_STATUS" != 0 ] || fail "a failed alternate launch reported success"

  # The previous authoritative record is restored byte for byte, so the task is
  # still recoverable on its original runtime.
  assert_grep 'harness=codex' "$HOME_DIR/state/$id.meta" \
    "a failed alternate launch left the task record half-rewritten"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "a failed alternate launch lost the recorded isolated copy"
  assert_absent "$HOME_DIR/state/.resume-$id.meta.bak" \
    "the restored record left its snapshot behind"
  # tmux's exact-match target form, so the cleanup can only ever name this task.
  assert_grep "=firstmate:=fm-$id" "$CASE_DIR/kill.log" \
    "the failed relaunch did not remove the exact endpoint it created"
  [ "$(wc -l < "$CASE_DIR/kill.log")" -eq 1 ] \
    || fail "the failed relaunch removed more than the one endpoint it created"

  # The work itself is untouched.
  [ "$(git -C "$WT_DIR" rev-parse HEAD)" = "$head_before" ] \
    || fail "a failed alternate launch moved the task branch's head"
  assert_present "$WT_DIR/scratch.txt" "a failed alternate launch discarded uncommitted work"
  pass "a failed alternate launch leaves the original record, branch, and work recoverable"
}

test_resume_refuses_shapes_that_would_split_or_misplace_a_task() {
  local rec id
  id=resume-refusals-d4
  rec=$(make_resume_case resume-refusals "$id")
  read_resume_record "$rec"

  run_resume_spawn "$HOME_DIR" "$FAKEBIN_DIR" "$WT_DIR" \
    "$id" "$PROJ_DIR" --secondmate --resume-worktree "$WT_DIR"
  expect_code 1 "$SPAWN_STATUS" "--resume-worktree must be refused for secondmate spawns"
  assert_contains "$SPAWN_OUT" "applies only to ship and scout spawns" \
    "the secondmate refusal did not explain the boundary"

  run_resume_spawn "$HOME_DIR" "$FAKEBIN_DIR" "$WT_DIR" \
    "$id=$PROJ_DIR" --mode no-mistakes --yolo off \
    --harness claude --resume-worktree "$WT_DIR"
  expect_code 1 "$SPAWN_STATUS" "--resume-worktree must be refused for batch dispatch"
  assert_contains "$SPAWN_OUT" "cannot be shared across a batch" \
    "the batch refusal did not explain the boundary"

  run_resume_spawn "$HOME_DIR" "$FAKEBIN_DIR" "$WT_DIR" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off \
    --harness claude --resume-worktree "$PROJ_DIR"
  expect_code 1 "$SPAWN_STATUS" "resuming into the primary checkout must be refused"
  assert_contains "$SPAWN_OUT" "did not yield an isolated worktree" \
    "the primary-checkout refusal did not reuse the isolation assertion"

  run_resume_spawn "$HOME_DIR" "$FAKEBIN_DIR" "$WT_DIR" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off \
    --harness claude --resume-worktree "$CASE_DIR/nowhere"
  expect_code 1 "$SPAWN_STATUS" "resuming into a nonexistent path must be refused"
  pass "resume refuses every shape that would split, misplace, or tangle a task"
}

test_resume_preserves_backend_and_harness_validation() {
  local rec id
  id=resume-validation-e5
  rec=$(make_resume_case resume-validation "$id")
  read_resume_record "$rec"

  run_resume_spawn "$HOME_DIR" "$FAKEBIN_DIR" "$WT_DIR" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off \
    --harness claude --backend orca --resume-worktree "$WT_DIR"
  expect_code 1 "$SPAWN_STATUS" "resume must be refused on a backend that owns its own worktree"
  assert_contains "$SPAWN_OUT" "not supported on backend=orca" \
    "the Orca refusal did not name the concrete backend blocker"

  run_resume_spawn "$HOME_DIR" "$FAKEBIN_DIR" "$WT_DIR" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off \
    --harness claude --backend spaceship --resume-worktree "$WT_DIR"
  expect_code 1 "$SPAWN_STATUS" "an unsupported backend must still be refused during a resume"

  run_resume_spawn "$HOME_DIR" "$FAKEBIN_DIR" "$WT_DIR" \
    "$id" "$PROJ_DIR" --mode wishful --yolo off \
    --harness claude --resume-worktree "$WT_DIR"
  expect_code 1 "$SPAWN_STATUS" "an invalid delivery mode must still be refused during a resume"
  pass "resume keeps every existing backend, delivery, and isolation validation intact"
}

test_ordinary_spawn_is_unchanged_without_the_resume_flag() {
  local rec id
  id=resume-absent-f6
  rec=$(make_resume_case resume-absent "$id")
  read_resume_record "$rec"
  rm -f "$HOME_DIR/state/$id.meta"

  FM_FAKE_SEND_LOG="$CASE_DIR/send.log" \
    run_resume_spawn "$HOME_DIR" "$FAKEBIN_DIR" "$WT_DIR" \
      "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude
  expect_code 0 "$SPAWN_STATUS" "an ordinary spawn must be unaffected: $SPAWN_OUT"
  assert_grep 'treehouse get' "$CASE_DIR/send.log" \
    "an ordinary spawn stopped allocating its own isolated copy"
  assert_not_contains "$SPAWN_OUT" "resumed=1" \
    "an ordinary spawn reported itself as a resume"
  assert_absent "$HOME_DIR/state/.resume-$id.meta.bak" \
    "an ordinary spawn created a resume snapshot"
  pass "an ordinary spawn keeps its existing behavior when no resume is requested"
}

test_single_transient_failure_does_not_activate_outage_handling
test_repeated_qualifying_failures_activate_outage_handling
test_isolated_failures_outside_the_window_never_qualify
test_auth_config_and_task_failures_never_qualify
test_quota_pressure_is_recorded_separately_and_never_qualifies
test_cooldown_expiry_restores_eligibility_deterministically
test_new_task_selection_excludes_only_the_unavailable_provider
test_configured_fallback_is_consulted_only_during_an_outage
test_review_independence_defers_when_no_independent_provider_remains
test_no_configured_continuity_state_leaves_selection_unchanged
test_unknown_evidence_classes_and_provider_tokens_are_refused
test_handoff_refuses_while_the_recorded_worker_cannot_be_proved_gone
test_handoff_refuses_while_a_validation_run_owns_the_task
test_handoff_allows_once_the_endpoint_is_authoritatively_gone
test_handoff_refuses_an_unreadable_or_unrecorded_task
test_repeated_handoff_attempts_stop_and_report_the_blocker
test_resume_reuses_the_recorded_isolated_copy_and_preserves_work
test_resume_refuses_a_pane_that_settled_on_another_copy
test_failed_relaunch_leaves_the_original_record_and_work_recoverable
test_resume_refuses_shapes_that_would_split_or_misplace_a_task
test_resume_preserves_backend_and_harness_validation
test_ordinary_spawn_is_unchanged_without_the_resume_flag

echo "# all fm-provider-continuity tests passed"
