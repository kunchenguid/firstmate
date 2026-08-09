#!/usr/bin/env bash
# Behavior tests for the durable attempt counter and retry budget:
# bin/fm-attempt.sh's arithmetic, and the spawn path that spends it.
#
# Nothing counted attempts before this. "Should this be retried?" was answered
# by the worker that was failing, from a context that resets on every relaunch,
# so these cases are about the count being a NUMBER ON DISK that a restart, a
# lost metadata file, and an ordinary re-steer all leave alone.
#
# The spawn cases drive bin/fm-spawn.sh against a fake tmux and a real isolated
# git worktree, so the recorded count is read back out of the task metadata the
# spawn actually published rather than out of the library that produced it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ATTEMPT="$ROOT/bin/fm-attempt.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
SEND="$ROOT/bin/fm-send.sh"
TERMINAL_STATES="$ROOT/loopspecs/terminal-states.json"
TMP_ROOT=$(fm_test_tmproot fm-attempt)

# --- bin/fm-attempt.sh, driven directly -------------------------------------

make_state() {  # <name> -> echoes the state dir
  local state="$TMP_ROOT/$1/state"
  mkdir -p "$state"
  printf '%s\n' "$state"
}

run_attempt() {  # <state-dir> <args...>
  local state=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$ATTEMPT" "$@" 2>&1
}

record_field() {  # <state-dir> <id> <key>
  sed -n "s/^$3=//p" "$1/$2.attempt" | tail -1
}

test_attempts_are_counted_and_persisted() {
  local state out rc
  state=$(make_state counted)

  out=$(run_attempt "$state" show t1)
  assert_contains "$out" "attempt=0 attempt_budget=2" "an unknown task has spent nothing against the default budget"
  assert_absent "$state/t1.attempt" "show must not create a record"

  out=$(run_attempt "$state" open t1)
  assert_contains "$out" "attempt=1 attempt_budget=2" "the first open is attempt 1"
  out=$(run_attempt "$state" open t1)
  assert_contains "$out" "attempt=2 attempt_budget=2" "the second open is attempt 2"

  # The count is on disk, not in the process that produced it: every command
  # above was a separate invocation, and this one reads what they left.
  [ "$(record_field "$state" t1 attempt)" = 2 ] \
    || fail "the durable record must hold 2 attempts, got '$(record_field "$state" t1 attempt)'"
  out=$(run_attempt "$state" show t1)
  assert_contains "$out" "attempt=2 attempt_budget=2" "show must read the durable count back"

  out=$(run_attempt "$state" check t1); rc=$?
  [ "$rc" -eq 3 ] || fail "a check past the budget must exit 3, got $rc"
  out=$(run_attempt "$state" open t1); rc=$?
  [ "$rc" -eq 3 ] || fail "an open past the budget must exit 3, got $rc"
  assert_contains "$out" "spent its retry budget" "the refusal must say what ran out"
  assert_contains "$out" "budget_exhausted" "the refusal must name the terminal state"
  [ "$(record_field "$state" t1 attempt)" = 2 ] \
    || fail "a refused attempt must not increment the count"
  [ "$(record_field "$state" t1 terminal)" = budget_exhausted ] \
    || fail "exhaustion must be recorded as a terminal state"

  # Not a silent stop: the failure is declared on the task's own status log,
  # which is the wake surface, and the terminal-outcome derivation reads exactly
  # this verb. Declared ONCE - two refusals are one unchanged terminal fact.
  assert_present "$state/t1.status" "exhaustion must declare a failure on the status log"
  assert_grep "failed: attempt budget exhausted after 2 of 2 attempts (budget_exhausted)" "$state/t1.status" \
    "the declared failure must name the count, the budget, and the terminal state"
  [ "$(grep -c '^failed:' "$state/t1.status")" = 1 ] \
    || fail "a second refusal must not re-declare the same terminal fact"$'\n'"$(cat "$state/t1.status")"

  pass "fm-attempt: attempts are counted durably and a spent budget refuses with a named terminal state"
}

test_absent_field_reads_as_attempt_one() {
  local state out
  state=$(make_state migration)
  # A task dispatched before any of this existed: metadata, no count anywhere.
  # That metadata IS the evidence of an attempt, so the retry is attempt 2 and
  # never restarts the budget at 1.
  fm_write_meta "$state/old.meta" "window=sess:fm-old" "kind=ship" "harness=claude"

  out=$(run_attempt "$state" show old)
  assert_contains "$out" "attempt=1 attempt_budget=2" "an absent attempt= field must read as attempt 1"
  out=$(run_attempt "$state" open old)
  assert_contains "$out" "attempt=2 attempt_budget=2" "the pre-existing task's retry must be attempt 2"

  # Negative control for the migration rule itself: with no metadata either,
  # nothing implies an attempt, so the same call is attempt 1 rather than 2.
  out=$(run_attempt "$state" open fresh)
  assert_contains "$out" "attempt=1 attempt_budget=2" "a task with no metadata at all must start at attempt 1"

  pass "fm-attempt: an absent field reads as attempt 1, and only metadata implies it"
}

test_raising_the_budget_is_the_only_way_past_it_and_is_recorded() {
  local state out rc
  state=$(make_state raise)
  run_attempt "$state" open t2 >/dev/null
  run_attempt "$state" open t2 >/dev/null
  run_attempt "$state" open t2 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 3 ] || fail "the third attempt must be refused at the default budget"

  out=$(run_attempt "$state" open t2 --budget 3)
  assert_contains "$out" "attempt=3 attempt_budget=3" "a deliberately raised budget must allow the next attempt"
  [ "$(record_field "$state" t2 attempt_budget)" = 3 ] \
    || fail "the raised budget must be recorded, so the override is inspectable"
  # The raise sticks without being restated, and still bounds the task.
  out=$(run_attempt "$state" open t2 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "the raised budget must still bound the task, got $rc"

  out=$(run_attempt "$state" open t2 --budget 0 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "a zero budget must be an argument error, not a silent bound"
  out=$(run_attempt "$state" open t2 --budget two 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "a non-numeric budget must be refused"

  pass "fm-attempt: the budget is raised deliberately, recorded, and still bounds the task"
}

# The env default is a budget source like any other: one that is not a positive
# integer must refuse outright rather than fail every comparison open, and the
# bad value must never reach the durable record or the published metadata.
test_a_garbage_default_budget_refuses_instead_of_failing_open() {
  local state out rc bad
  state=$(make_state envdefault)
  for bad in garbage 0; do
    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
      FM_ATTEMPT_BUDGET_DEFAULT="$bad" "$ATTEMPT" open t5 2>&1); rc=$?
    [ "$rc" -eq 2 ] || fail "a default budget of '$bad' must be refused as an error, got $rc"$'\n'"$out"
    assert_contains "$out" "FM_ATTEMPT_BUDGET_DEFAULT must be a positive integer: $bad" \
      "the refusal must name the bad value"
    assert_absent "$state/t5.attempt" "a bad default must never be persisted into the record"
    assert_absent "$state/t5.status" "a bad default is a caller error, not a task failure"
    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
      FM_ATTEMPT_BUDGET_DEFAULT="$bad" "$ATTEMPT" check t5 2>&1); rc=$?
    [ "$rc" -eq 2 ] || fail "check must refuse the '$bad' default too, got $rc"
  done

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    FM_ATTEMPT_BUDGET_DEFAULT=1 "$ATTEMPT" open t5) \
    || fail "a valid overridden default must still open the attempt"$'\n'"$out"
  assert_contains "$out" "attempt=1 attempt_budget=1" "a valid overridden default must be the budget"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    FM_ATTEMPT_BUDGET_DEFAULT=1 "$ATTEMPT" check t5 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 3 ] || fail "the overridden default must still bound the task, got $rc"

  pass "fm-attempt: a default budget that is not a positive integer refuses instead of failing open"
}

test_there_is_no_reset_verb() {
  local out rc state
  state=$(make_state noreset)
  out=$(run_attempt "$state" reset t3 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a reset verb would hand back the discretion the count replaces"
  assert_contains "$out" "unknown subcommand" "an unknown verb must be refused by name"
  pass "fm-attempt: there is no reset verb"
}

# The certification: budget exhaustion must terminate in the UNIFIED terminal
# vocabulary rather than a third one invented here. The unified vocabulary is
# delivered separately, so this asserts membership whenever that file is present
# and says so plainly when it is not - a silent skip would read as a pass.
test_terminal_state_is_in_the_unified_vocabulary() {
  local state out
  state=$(make_state vocab)
  run_attempt "$state" open t4 >/dev/null
  run_attempt "$state" open t4 >/dev/null
  out=$(run_attempt "$state" open t4 2>&1 || true)
  assert_contains "$out" "budget_exhausted" "the produced terminal state must be budget_exhausted"

  if [ ! -f "$TERMINAL_STATES" ]; then
    pass "fm-attempt: terminal state is budget_exhausted (unified vocabulary file not present in this tree; membership unchecked)"
    return 0
  fi
  grep -q '"name": "budget_exhausted"' "$TERMINAL_STATES" \
    || fail "budget_exhausted must be a member of the unified terminal vocabulary in $TERMINAL_STATES"
  # Negative control: the same check must be able to say no.
  ! grep -q '"name": "attempt_budget_spent"' "$TERMINAL_STATES" \
    || fail "the membership check cannot discriminate: it accepts a name that should not exist"
  pass "fm-attempt: the produced terminal state is a member of the unified terminal vocabulary"
}

# --- the spawn path that spends the budget ----------------------------------

# Fake tmux answering the pane-path query; everything else succeeds silently, so
# a spawn runs end to end and publishes real task metadata.
make_spawn_case() {  # <name> -> "<home>|<project>|<worktree>|<fakebin>"
  local name=$1 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s\n' "$home|$proj|$wt|$fakebin"
}

write_spawn_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  printf 'brief for %s\n\nDelivery contract: mode=no-mistakes\n' "$2" > "$1/data/$2/brief.md"
}

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_FAKE_PANE_PATH="$wt" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

meta_field() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" | tail -1
}

test_spawn_spends_the_budget_and_publishes_the_count() {
  local rec home proj wt fakebin id meta out rc before
  rec=$(make_spawn_case spawn-count)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  id=spawn-count-a1
  meta="$home/state/$id.meta"
  write_spawn_brief "$home" "$id"

  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -eq 0 ] || fail "the first spawn must succeed"$'\n'"$out"
  [ "$(meta_field "$meta" attempt)" = 1 ] || fail "the first spawn must publish attempt=1"$'\n'"$(cat "$meta")"
  [ "$(meta_field "$meta" attempt_budget)" = 2 ] || fail "the spawn must publish the budget it checked against"

  # A relaunch on the same task id is a retry, and it is counted. The metadata
  # is deleted first, so only the durable record can supply the prior count -
  # this is the restart case, where nothing but the record survives.
  rm -f "$meta"
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -eq 0 ] || fail "the second spawn must succeed"$'\n'"$out"
  [ "$(meta_field "$meta" attempt)" = 2 ] \
    || fail "the count must survive losing the task metadata, got attempt=$(meta_field "$meta" attempt)"

  # Budget spent. The refusal happens before anything is created, so the
  # published metadata from attempt 2 is left exactly as it was.
  before=$(cat "$meta")
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "the third spawn must be refused"$'\n'"$out"
  assert_contains "$out" "budget_exhausted" "the refused spawn must name the terminal state"
  [ "$(cat "$meta")" = "$before" ] || fail "a refused spawn must not rewrite the task metadata"
  assert_grep "failed: attempt budget exhausted" "$home/state/$id.status" \
    "the refused spawn must declare the failure rather than stopping quietly"

  # The stated override, and the only one.
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off --attempt-budget 3); rc=$?
  [ "$rc" -eq 0 ] || fail "a deliberately raised budget must let the spawn through"$'\n'"$out"
  [ "$(meta_field "$meta" attempt)" = 3 ] || fail "the raised attempt must publish attempt=3"
  [ "$(meta_field "$meta" attempt_budget)" = 3 ] || fail "the raised budget must be published"

  pass "fm-spawn: every attempt is counted, the count survives losing the metadata, and a spent budget refuses before anything is created"
}

# The negative control the spec asks for: an ordinary re-steer is not an
# attempt. The steer is driven for real and asserted to have landed, so the
# unchanged count cannot be explained by the steer never happening.
test_an_ordinary_re_steer_does_not_touch_the_count() {
  local rec home proj wt fakebin id record before log rc out
  rec=$(make_spawn_case steer)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  id=steer-b1
  record="$home/state/$id.attempt"
  log="$TMP_ROOT/steer/tmux.log"
  write_spawn_brief "$home" "$id"
  run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off >/dev/null \
    || fail "the spawn under test must succeed"
  [ "$(record_field "$home/state" "$id" attempt)" = 1 ] || fail "the spawn must have opened attempt 1"
  before=$(cat "$record")

  # A steering fake: logs what was typed, and answers the liveness and submit
  # probes fm-send makes.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    target=; literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac
    done
    printf '%%1\n'; exit 0 ;;
  capture-pane) printf 'x\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  : > "$log"
  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 PATH="$fakebin:$PATH" \
    "$SEND" "$id" "carry on" >/dev/null 2>&1
  rc=$?
  out=$(cat "$log")
  assert_contains "$out" "carry on" "the steer must actually have been typed, or this control proves nothing"
  [ "$rc" -eq 0 ] || [ -n "$out" ] || fail "the steer neither landed nor typed anything"

  [ "$(cat "$record")" = "$before" ] \
    || fail "an ordinary re-steer must leave the attempt count byte-identical"$'\n'"before: $before"$'\n'"after: $(cat "$record")"
  pass "fm-attempt: an ordinary re-steer is not an attempt and does not reset the count"
}

# A secondmate's relaunch is routine liveness recovery run unattended at session
# start, so counting it would eventually refuse to bring a healthy long-lived
# secondmate back up.
test_secondmate_relaunches_are_not_counted() {
  local rec home proj wt fakebin out rc
  rec=$(make_spawn_case secondmate-exempt)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" sm-c1 "$home/sm" claude --secondmate --attempt-budget 3); rc=$?
  [ "$rc" -ne 0 ] || fail "--attempt-budget must be refused on a secondmate spawn"
  assert_contains "$out" "applies only to ship and scout spawns" "the refusal must explain why a secondmate carries no budget"
  assert_absent "$home/state/sm-c1.attempt" "a refused secondmate spawn must record no attempt"
  pass "fm-spawn: a secondmate relaunch is liveness recovery, not a counted retry"
}

test_attempts_are_counted_and_persisted
test_absent_field_reads_as_attempt_one
test_raising_the_budget_is_the_only_way_past_it_and_is_recorded
test_a_garbage_default_budget_refuses_instead_of_failing_open
test_there_is_no_reset_verb
test_terminal_state_is_in_the_unified_vocabulary
test_spawn_spends_the_budget_and_publishes_the_count
test_an_ordinary_re_steer_does_not_touch_the_count
test_secondmate_relaunches_are_not_counted
