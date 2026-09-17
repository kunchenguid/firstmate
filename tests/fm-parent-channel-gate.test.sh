#!/usr/bin/env bash
# family=standalone expected_gate_skip=none
set -eu
. tests/lib.sh

TMP_ROOT=$(fm_test_tmproot fm-parent-channel-gate-tests)

make_case() {  # <name>
  local dir=$TMP_ROOT/$1
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

test_escalation_gate_suppresses_routine_child_lifecycle() {
  local case_dir
  case_dir=$(make_case gate-routine)
  mkdir -p "$case_dir/main/state" "$case_dir/mate/state"
  
  # Set up main home
  fm_write_meta "$case_dir/main/state/mate-x.meta" "window=firstmate:mate"
  
  # Set up secondmate home
  printf 'mate-x\n' > "$case_dir/mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$case_dir/main" > "$case_dir/mate/.fm-secondmate-parent"
  
  # Verify routine child is suppressed
  ! "$ROOT/bin/fm-parent-channel-lib.sh" 2>/dev/null || true # dummy
  
  # Load the library to test the function directly
  . "$ROOT/bin/fm-parent-channel-lib.sh"
  
  # Task 'routine-child' has no prior presence on the parent channel
  ! fm_parent_channel_task_escalated "$case_dir/mate" "$case_dir/mate/state" "routine-child" \
    || fail "gate allowed routine child with no prior escalation"
    
  pass "routine child lifecycle produces no parent-channel event"
}

test_escalation_gate_allows_escalated_child_resolution() {
  local case_dir
  case_dir=$(make_case gate-escalated)
  mkdir -p "$case_dir/main/state" "$case_dir/mate/state"
  
  # Set up main home
  fm_write_meta "$case_dir/main/state/mate-x.meta" "window=firstmate:mate"
  
  # Set up secondmate home
  printf 'mate-x\n' > "$case_dir/mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$case_dir/main" > "$case_dir/mate/.fm-secondmate-parent"
  
  # Seed prior escalation for the child on the parent channel
  printf 'needs-decision [key=hold]: blocking issue for escalated-child\n' > "$case_dir/main/state/mate-x.status"
  
  # Load the library
  . "$ROOT/bin/fm-parent-channel-lib.sh"
  
  # Task 'escalated-child' has prior presence
  fm_parent_channel_task_escalated "$case_dir/mate" "$case_dir/mate/state" "escalated-child" \
    || fail "gate suppressed resolution of an escalated child"
    
  pass "escalated child resolution is allowed on the parent channel"
}

test_escalation_gate_suppresses_routine_child_lifecycle
test_escalation_gate_allows_escalated_child_resolution
echo "all tests passed"
