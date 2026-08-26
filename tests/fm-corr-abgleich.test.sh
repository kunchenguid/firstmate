#!/usr/bin/env bash
# Behavior tests for the child-side corr turn-end reconciliation
# (bin/fm-corr-abgleich.sh) and its wiring into bin/fm-turnend-guard.sh.
#
# Reproduces the missed-booking experience behind L58: a marked request is
# delivered to an officer home, the work is done, but the correlated corr=
# booking line is never written - instead a self-report or an unrelated key.
# The turn end must name every received-but-unbooked corr id loudly, and must
# stay silent when every mark is booked.
#
# Coverage:
#   1. Red case: delivered open expectation without a corr= line blocks the
#      turn naming that exact corr id
#   2. Green case: the booking line written keeps the check silent
#   3. Several marks in one home: only the missing ones are named
#   4. Another mate's expectation is never attributed to this home
#   5. Undelivered and already-resolved records are never named
#   6. An escalation line (pending-reply-id=) does not read as the booking
#   7. Blocking is bounded: same session names a set once, then stays quiet;
#      a new session or set speaks again; no session id never blocks
#   8. Homes without a local parent binding silently skip
#   9. An answer in any file but the recorded parent_status still reads missing
#  10. Guard wiring: the hook gate surfaces the difference and honors the
#      once-per-session bound
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ABGLEICH="$ROOT/bin/fm-corr-abgleich.sh"
TMP_ROOT=$(fm_test_tmproot fm-corr-abgleich)

CORR_RED=0e4c6d7121ba1a39
CORR_BOOKED=ab12cd34ef567890
CORR_OTHER=fedcba9876543210

# --- fixtures ---------------------------------------------------------------

make_parent_home() {  # <dir>
  mkdir -p "$1/state/pending-replies"
  printf '%s\n' "$1"
}

make_officer_home() {  # <dir> <parent-home> [no-binding|remote]
  local dir=$1 parent=$2 mode=${3:-}
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  printf 'sm-corr-test\n' > "$dir/.fm-secondmate-home"
  case "$mode" in
    no-binding) ;;
    remote)
      {
        printf 'schema=fm-secondmate-parent.v1\n'
        printf 'route=remote\n'
        printf 'parent_host=sm-host\n'
      } > "$dir/.fm-secondmate-parent"
      ;;
    *)
      {
        printf 'schema=fm-secondmate-parent.v1\n'
        printf 'route=local\n'
        printf 'parent_home=%s\n' "$parent"
      } > "$dir/.fm-secondmate-parent"
      ;;
  esac
  printf '%s\n' "$dir"
}

write_expectation() {  # <parent-state> <corr> <task> <phase> <delivered> [status-file]
  local state=$1 corr=$2 task=$3 phase=$4 delivered=$5 status_file=${6:-}
  local rec="$state/pending-replies/$corr"
  {
    printf 'schema=fm-pending-reply.v1\n'
    printf 'corr_id=%s\n' "$corr"
    printf 'task_id=%s\n' "$task"
    if [ -n "$status_file" ]; then
      printf 'parent_status=%s\n' "$status_file"
    else
      printf 'parent_status=%s/%s.status\n' "$state" "$task"
    fi
    printf 'phase=%s\n' "$phase"
    printf 'delivered_epoch=%s\n' "$delivered"
    printf 'resolved_via=\n'
  } > "$rec"
}

write_task_meta() {  # <parent-state> <task> <home>
  printf 'kind=secondmate\nhome=%s\n' "$3" > "$1/$2.meta"
}

run_abgleich() {  # <officer-home> [session]
  local home=$1 session=${2:-}
  FM_HOME="$home" FM_CORR_ABGLEICH_SESSION="$session" bash "$ABGLEICH" 2>&1
}

# --- 1+2+3: red, green, multi ----------------------------------------------

test_red_case_names_missing_corr() {
  local parent officer out status
  parent=$(make_parent_home "$TMP_ROOT/red/parent")
  officer=$(make_officer_home "$TMP_ROOT/red/officer" "$parent")
  write_task_meta "$parent/state" sm-task-1 "$officer"
  write_expectation "$parent/state" "$CORR_RED" sm-task-1 awaiting_report 1700000000
  printf 'working: started on it\n' >> "$parent/state/sm-task-1.status"
  out=$(run_abgleich "$officer" sess-red); status=$?
  expect_code 2 "$status" "missing corr booking must block the turn"
  case "$out" in
    *"$CORR_RED"*) ;;
    *) fail "banner must name the missing corr id verbatim"; ;;
  esac
  pass "red case: unbooked corr $CORR_RED named loudly at turn end"
}

test_green_case_stays_silent() {
  local parent officer out status
  parent=$(make_parent_home "$TMP_ROOT/green/parent")
  officer=$(make_officer_home "$TMP_ROOT/green/officer" "$parent")
  write_task_meta "$parent/state" sm-task-2 "$officer"
  write_expectation "$parent/state" "$CORR_BOOKED" sm-task-2 awaiting_report 1700000000
  printf 'done corr=%s: audit clean\n' "$CORR_BOOKED" >> "$parent/state/sm-task-2.status"
  out=$(run_abgleich "$officer" sess-green); status=$?
  expect_code 0 "$status" "booked corr must not block"
  [ -z "$out" ] || fail "booked corr must stay silent, got: $out"
  pass "green case: booked corr keeps the turn end silent"
}

test_multi_marks_name_only_missing() {
  local parent officer out status
  parent=$(make_parent_home "$TMP_ROOT/multi/parent")
  officer=$(make_officer_home "$TMP_ROOT/multi/officer" "$parent")
  write_task_meta "$parent/state" sm-task-3 "$officer"
  write_task_meta "$parent/state" sm-task-4 "$officer"
  write_expectation "$parent/state" "$CORR_BOOKED" sm-task-3 awaiting_report 1700000000
  write_expectation "$parent/state" "$CORR_RED" sm-task-4 awaiting_report 1700000001
  printf 'done corr=%s: answered\n' "$CORR_BOOKED" >> "$parent/state/sm-task-3.status"
  printf 'done: shipped the fix without the token\n' >> "$parent/state/sm-task-4.status"
  out=$(run_abgleich "$officer" sess-multi); status=$?
  expect_code 2 "$status" "one missing booking among several must still block"
  case "$out" in
    *"$CORR_RED"*) ;;
    *) fail "the genuinely missing corr id must be named"; ;;
  esac
  case "$out" in
    *"$CORR_BOOKED"*) fail "the booked corr id must not be named again"; ;;
  esac
  pass "multi-mark case: exactly the missing bookings are named"
}

# --- 4+5: attribution and lifecycle filters ---------------------------------

test_other_mates_record_not_attributed() {
  local parent officer other out status
  parent=$(make_parent_home "$TMP_ROOT/attribution/parent")
  officer=$(make_officer_home "$TMP_ROOT/attribution/officer" "$parent")
  other="$TMP_ROOT/attribution/other-mate"
  mkdir -p "$other"
  write_task_meta "$parent/state" sm-theirs "$other"
  write_expectation "$parent/state" "$CORR_OTHER" sm-theirs awaiting_report 1700000000
  out=$(run_abgleich "$officer" sess-other); status=$?
  expect_code 0 "$status" "another mate's open expectation must not block this home"
  [ -z "$out" ] || fail "another mate's corr must stay unnamed, got: $out"
  pass "attribution: only this home's expectations count"
}

test_undelivered_and_resolved_skipped() {
  local parent officer out status
  parent=$(make_parent_home "$TMP_ROOT/lifecycle/parent")
  officer=$(make_officer_home "$TMP_ROOT/lifecycle/officer" "$parent")
  write_task_meta "$parent/state" sm-t5 "$officer"
  write_task_meta "$parent/state" sm-t6 "$officer"
  write_expectation "$parent/state" "$CORR_OTHER" sm-t5 awaiting_report "" \
    "$parent/state/sm-t5.status"
  write_expectation "$parent/state" "$CORR_BOOKED" sm-t6 resolved 1700000000
  out=$(run_abgleich "$officer" sess-lifecycle); status=$?
  expect_code 0 "$status" "undelivered and resolved records must never block"
  [ -z "$out" ] || fail "lifecycle-skipped corrs must stay silent, got: $out"
  pass "lifecycle: undelivered and resolved expectations are skipped"
}

# --- 6: escalation lines are not answers ------------------------------------

test_escalation_line_is_not_a_booking() {
  local parent officer out status
  parent=$(make_parent_home "$TMP_ROOT/escalation/parent")
  officer=$(make_officer_home "$TMP_ROOT/escalation/officer" "$parent")
  write_task_meta "$parent/state" sm-task-7 "$officer"
  write_expectation "$parent/state" "$CORR_RED" sm-task-7 escalated 1700000000
  printf 'blocked [key=pending-reply-%s]: pending-reply-missed: task=sm-task-7 pending-reply-id=%s request=please look\n' \
    "$CORR_RED" "$CORR_RED" >> "$parent/state/sm-task-7.status"
  out=$(run_abgleich "$officer" sess-esc); status=$?
  expect_code 2 "$status" "an escalation echo must not settle the debt"
  case "$out" in
    *"$CORR_RED"*) ;;
    *) fail "the escalation-covered corr id must still be named as missing"; ;;
  esac
  pass "escalation echo: pending-reply-id line does not read as the booking"
}

# --- 7: bounded blocking -----------------------------------------------------

test_blocking_bounded_per_session_and_set() {
  local parent officer out status
  parent=$(make_parent_home "$TMP_ROOT/bounded/parent")
  officer=$(make_officer_home "$TMP_ROOT/bounded/officer" "$parent")
  write_task_meta "$parent/state" sm-task-8 "$officer"
  write_expectation "$parent/state" "$CORR_RED" sm-task-8 awaiting_report 1700000000
  out=$(run_abgleich "$officer" sess-a); status=$?
  expect_code 2 "$status" "first sighting for a session must block"
  out=$(run_abgleich "$officer" sess-a); status=$?
  expect_code 0 "$status" "unchanged set must go quiet for the same session"
  [ -z "$out" ] || fail "repeated unchanged debt must be fully quiet, got: $out"
  out=$(run_abgleich "$officer" sess-b); status=$?
  expect_code 2 "$status" "a new session must hear the unchanged debt once"
  printf 'done corr=%s: booked now\n' "$CORR_RED" >> "$parent/state/sm-task-8.status"
  out=$(run_abgleich "$officer" sess-b); status=$?
  expect_code 0 "$status" "booking the line must silence even a new-session key"
  out=$(run_abgleich "$officer" ""); status=$?
  expect_code 0 "$status" "without a session id the check must never block"
  pass "bounded blocking: one loud naming per session per distinct set"
}

# --- 8: scope -----------------------------------------------------------------

test_out_of_scope_homes_skip_silently() {
  local parent officer out status
  parent=$(make_parent_home "$TMP_ROOT/scope/parent")
  officer=$(make_officer_home "$TMP_ROOT/scope/plain" "$parent" no-binding)
  write_task_meta "$parent/state" sm-task-9 "$officer"
  write_expectation "$parent/state" "$CORR_RED" sm-task-9 awaiting_report 1700000000
  out=$(run_abgleich "$officer" sess-scope1); status=$?
  expect_code 0 "$status" "a home without a parent binding must skip"
  remote=$(make_officer_home "$TMP_ROOT/scope/remote" "$parent" remote)
  out=$(run_abgleich "$remote" sess-scope2); status=$?
  expect_code 0 "$status" "a remote-route home must skip (parent guard owns it)"
  pass "scope: non-local homes silently leave the field to the parent guard"
}

# --- 9: wrong surface ---------------------------------------------------------

test_answer_in_wrong_file_still_missing() {
  local parent officer out status
  parent=$(make_parent_home "$TMP_ROOT/wrongfile/parent")
  officer=$(make_officer_home "$TMP_ROOT/wrongfile/officer" "$parent")
  write_task_meta "$parent/state" sm-task-10 "$officer"
  write_expectation "$parent/state" "$CORR_RED" sm-task-10 awaiting_report 1700000000 \
    "$parent/state/sm-task-10.status"
  printf 'done corr=%s: wrote it somewhere else\n' "$CORR_RED" \
    >> "$parent/state/other-task.status"
  out=$(run_abgleich "$officer" sess-wrong); status=$?
  expect_code 2 "$status" "an answer outside the recorded parent_status is no answer"
  pass "wrong surface: only the recorded parent_status settles the booking"
}

# --- 10: guard wiring ----------------------------------------------------------

install_guard_scripts() {  # <dir>
  local dir=$1 script
  mkdir -p "$dir/bin"
  for script in fm-turnend-guard.sh fm-turnend-guard-grok.sh \
    fm-operational-input.sh fm-supervision-instructions.sh fm-harness.sh \
    fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh \
    fm-delivery-proof-lib.sh \
    fm-hook-host-lib.sh fm-corr-abgleich.sh fm-pending-reply-lib.sh \
    fm-marker-lib.sh fm-backend.sh fm-proctree-lib.sh fm-tmux-lib.sh \
    fm-composer-lib.sh fm-cursor-lib.sh fm-classify-lib.sh fm-nm-run-lib.sh \
    fm-timeout-lib.sh fm-secondmate-parent-lib.sh; do
    cp "$ROOT/bin/$script" "$dir/bin/$script"
  done
  mkdir -p "$dir/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir"/bin/*.sh
}

test_guard_gate_blocks_and_bounds() {
  local parent officer fixture out status
  parent=$(make_parent_home "$TMP_ROOT/guard/parent")
  fixture="$TMP_ROOT/guard/home"
  officer=$(make_officer_home "$fixture" "$parent")
  install_guard_scripts "$fixture"
  write_task_meta "$parent/state" sm-task-11 "$officer"
  write_expectation "$parent/state" "$CORR_RED" sm-task-11 awaiting_report 1700000000
  out=$(printf '{"stop_hook_active":false,"session_id":"guard-sess"}' | CLAUDECODE=1 FM_HOME="$fixture" \
    bash "$fixture/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 2 "$status" "the hook must block when a corr booking is missing"
  case "$out" in
    *"$CORR_RED"*) ;;
    *) fail "hook block output must carry the missing corr id"; ;;
  esac
  out=$(printf '{"stop_hook_active":false,"session_id":"guard-sess"}' | CLAUDECODE=1 FM_HOME="$fixture" \
    bash "$fixture/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "the second stop of the same session must pass through"
  [ -z "$out" ] || fail "second stop with unchanged debt must be silent, got: $out"
  pass "guard wiring: allow path surfaces the difference once per session"
}

test_guard_gate_silent_without_debts() {
  local parent officer fixture out status
  parent=$(make_parent_home "$TMP_ROOT/guardclean/parent")
  fixture="$TMP_ROOT/guardclean/home"
  officer=$(make_officer_home "$fixture" "$parent")
  install_guard_scripts "$fixture"
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$fixture" \
    bash "$fixture/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "an officer home without debts must end its turn normally"
  [ -z "$out" ] || fail "clean home must produce no output, got: $out"
  pass "guard wiring: clean officer home stays fully silent"
}

test_red_case_names_missing_corr
test_green_case_stays_silent
test_multi_marks_name_only_missing
test_other_mates_record_not_attributed
test_undelivered_and_resolved_skipped
test_escalation_line_is_not_a_booking
test_blocking_bounded_per_session_and_set
test_out_of_scope_homes_skip_silently
test_answer_in_wrong_file_still_missing
test_guard_gate_blocks_and_bounds
test_guard_gate_silent_without_debts
