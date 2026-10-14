#!/usr/bin/env bash
# tests/fm-action-ledger.test.sh - the per-task action ledger
# (bin/fm-action-lib.sh, bin/fm-action.sh).
#
# The steering inbox proves a message was queued and acknowledged; it cannot
# prove the acknowledged work ever started, produced a concrete refusal, or was
# accepted. These tests drive the executable surface with an injected clock and
# pin the failures observed in fleet operation:
#   1. ready-but-unstarted: an admitted authorized action past its start bound
#      with no start and no refusal is an incident; before the bound it is not.
#   2. handled-but-unexecuted: a steering-inbox acknowledgement alone never
#      satisfies the action; the incident names the acknowledged state.
#   3. concrete refusal and native start both satisfy the start bound, and a
#      long-running started action is never an incident (healthy long run).
#   4. legitimate holds (safe boundary, resource wait) suppress the incident
#      only until their finite deadline, then the incident returns.
#   5. a blocked action (human decision, external gate) stays visible with its
#      question and never suppresses an independent ready action.
#   6. no blanket grant: a generic permission word cannot admit an authorized
#      action, and a counted grant cannot be spent past its count.
#   7. the fold is read-only: it never records, closes, or answers anything.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION="$ROOT/bin/fm-action.sh"
TMP_ROOT=$(fm_test_tmproot fm-action-ledger)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

T0=1800000000

act() {  # <state> <args...>
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash "$ACTION" "$@"
}

fresh_state() {  # <name>
  local s="$TMP_ROOT/$1/state"
  mkdir -p "$s"
  printf '%s\n' "$s"
}

admit_authorized() {  # <state> <id> [extra args...]
  local state=$1 id=$2
  shift 2
  act "$state" admit t1 --id "$id" --class authorized \
    --source "captain:2026-10-14:run-e2e-one-runner" --operation "run the e2e job" \
    --owner worker --at "$T0" "$@"
}

incident_kinds() {  # <state> <now>
  act "$1" incidents t1 --now "$2" | awk -F'\t' '{print $1 ":" $4}'
}

test_ready_but_unstarted() {
  local s out
  s=$(fresh_state ready)
  admit_authorized "$s" a1 || fail "admit authorized action failed"
  out=$(incident_kinds "$s" $((T0 + 299)))
  assert_equals "" "$out" "an action inside its start bound is not an incident"
  out=$(incident_kinds "$s" $((T0 + 301)))
  assert_equals "a1:unacked-unstarted" "$out" "ready action past 300s with no start is an incident"
  pass "ready-but-unstarted becomes an incident only past the start bound"
}

test_handled_but_unexecuted() {
  local s out
  s=$(fresh_state handled)
  admit_authorized "$s" a1 --inbox 001.msg || fail "admit failed"
  mkdir -p "$s/t1.inbox/handled"
  printf 'schema=fm-task-inbox.v1\n--\nrun it\n' > "$s/t1.inbox/handled/001.msg"
  out=$(incident_kinds "$s" $((T0 + 301)))
  assert_equals "a1:acked-unexecuted" "$out" "an inbox acknowledgement must not satisfy execution"
  act "$s" ack t1 a1 --at $((T0 + 20)) || fail "explicit ack failed"
  out=$(incident_kinds "$s" $((T0 + 301)))
  assert_equals "a1:acked-unexecuted" "$out" "an explicit acknowledgement must not satisfy execution"
  pass "handled-but-unexecuted stays an incident after acknowledgement"
}

test_start_and_refusal_satisfy_the_bound() {
  local s out
  s=$(fresh_state start)
  admit_authorized "$s" a1 || fail "admit a1"
  admit_authorized "$s" a2 || fail "admit a2"
  act "$s" start t1 a1 --at $((T0 + 30)) || fail "start a1"
  act "$s" result t1 a2 refused --reason "runner pool offline" --at $((T0 + 40)) || fail "refuse a2"
  out=$(incident_kinds "$s" $((T0 + 7200)))
  assert_equals "" "$out" "a started long-running action and a concrete refusal are not incidents"
  pass "native start and concrete refusal satisfy the bound; a healthy long run is quiet"
}

test_holds_are_finite() {
  local s out
  s=$(fresh_state hold)
  admit_authorized "$s" a1 || fail "admit"
  act "$s" hold t1 a1 --kind resource-wait --until $((T0 + 900)) --reason "controller above ceiling" --at $((T0 + 100)) \
    || fail "hold"
  out=$(incident_kinds "$s" $((T0 + 600)))
  assert_equals "" "$out" "a live resource wait suppresses the incident"
  out=$(incident_kinds "$s" $((T0 + 901)))
  assert_equals "a1:unacked-unstarted" "$out" "an expired hold no longer suppresses the incident"
  if act "$s" hold t1 a1 --kind safe-boundary --reason "no deadline" --at "$T0" 2>/dev/null; then
    fail "a hold without a finite deadline must be refused"
  fi
  pass "legitimate holds suppress only until their finite deadline"
}

test_gate_never_freezes_independent_work() {
  local s out show
  s=$(fresh_state gate)
  act "$s" admit t1 --id g1 --class human-decision --owner captain \
    --operation "approve production export of image X?" --due $((T0 + 3600)) \
    --ready-with a1 --at "$T0" || fail "admit gate"
  admit_authorized "$s" a1 || fail "admit independent"
  out=$(incident_kinds "$s" $((T0 + 301)))
  assert_equals "a1:unacked-unstarted" "$out" "the gate must not suppress the independent ready action"
  show=$(act "$s" show t1)
  assert_contains "$show" "approve production export of image X?" "the gate stays visible with its question"
  assert_contains "$show" "gated" "the gate reports the gated phase"
  out=$(incident_kinds "$s" $((T0 + 3601)))
  assert_contains "$out" "g1:gate-overdue" "an unanswered gate past its due time is an incident"
  if act "$s" admit t1 --id g2 --class external-gate --owner maintainer --operation "merge upstream?" --at "$T0" 2>/dev/null; then
    fail "a gate must declare its independent ready work explicitly"
  fi
  pass "a blocked action stays visible and never freezes independent ready work"
}

test_no_blanket_grant_and_counted_grant() {
  local s src
  s=$(fresh_state grant)
  for src in yolo auto standing blanket any all; do
    if act "$s" admit t1 --id g-$src --class authorized --source "$src" \
      --operation "x" --owner worker --at "$T0" 2>/dev/null; then
      fail "generic permission word '$src' must not admit an authorized action"
    fi
  done
  if act "$s" admit t1 --id g-nosrc --class authorized --operation x --owner worker --at "$T0" 2>/dev/null; then
    fail "an authorized action without an exact source must be refused"
  fi
  admit_authorized "$s" one --units 1 || fail "admit counted grant"
  act "$s" start t1 one --units 1 --at $((T0 + 5)) || fail "first unit"
  act "$s" start t1 one --units 3 --at $((T0 + 6)) || fail "recording the over-spend must itself succeed"
  assert_equals "one:over-grant" "$(incident_kinds "$s" $((T0 + 10)))" "spending past the counted grant is an incident"
  pass "no blanket grant can admit an action and counted grants cannot be exceeded"
}

test_fold_is_read_only() {
  local s before after
  s=$(fresh_state readonly)
  admit_authorized "$s" a1 || fail "admit"
  act "$s" admit t1 --id g1 --class human-decision --owner captain --operation "pick?" \
    --ready-with a1 --at "$T0" || fail "admit gate"
  before=$(cksum "$s/t1.actions")
  act "$s" incidents t1 --now $((T0 + 9000)) > /dev/null
  act "$s" show t1 > /dev/null
  after=$(cksum "$s/t1.actions")
  assert_equals "$before" "$after" "reading incidents must not write the ledger"
  pass "incident detection never records, closes, or answers anything"
}

# The loop the action-followthrough skill describes, run end to end: an incident
# appears, the owner acts, and the incident clears because of a start/result and
# not because of the acknowledgement.
test_runbook_loop() {
  local s out
  s=$(fresh_state loop)
  admit_authorized "$s" a1 --inbox 001.msg || fail "admit"
  mkdir -p "$s/t1.inbox/handled"
  : > "$s/t1.inbox/handled/001.msg"
  assert_equals "a1:acked-unexecuted" "$(incident_kinds "$s" $((T0 + 400)))" "loop: acknowledged work is an incident"
  act "$s" start t1 a1 --at $((T0 + 410)) || fail "start"
  assert_equals "" "$(incident_kinds "$s" $((T0 + 420)))" "loop: the native start clears the incident"
  act "$s" result t1 a1 ok --at $((T0 + 900)) || fail "result"
  act "$s" accept t1 a1 --receipt "run:42 head:abc" --at $((T0 + 950)) || fail "accept"
  out=$(act "$s" show t1 --now $((T0 + 1000)))
  assert_contains "$out" "accepted" "loop: acceptance is recorded with its receipt"
  if act "$s" accept t1 a1 --at "$T0" 2>/dev/null; then fail "acceptance without a native receipt must be refused"; fi
  pass "the documented follow-through loop clears incidents only through start, result and acceptance"
}

test_ready_but_unstarted
test_handled_but_unexecuted
test_start_and_refusal_satisfy_the_bound
test_holds_are_finite
test_gate_never_freezes_independent_work
test_no_blanket_grant_and_counted_grant
test_fold_is_read_only
test_runbook_loop
