#!/usr/bin/env bash
# tests/plan-approval-helpers.sh - obtain a real plan approval for a fixture.
#
# A ship spawn or a scout promotion started in a home carrying the
# .fm-secondmate-home marker refuses without the primary firstmate's signed
# approval (bin/fm-plan-approval.sh owns that contract). Any fixture that drives
# such a spawn for another reason - Herdr workspace placement, trace context,
# backend behavior - needs a valid approval as a precondition.
#
# This is deliberately its own small file rather than part of tests/lib.sh: the
# suites that need it most are the real-Herdr end-to-end scripts, which bring
# their own reporters and cleanup and must not inherit lib.sh's traps.
#
# Source it after ROOT is set:
#   # shellcheck source=tests/plan-approval-helpers.sh
#   . "$ROOT/tests/plan-approval-helpers.sh"
#
# No side effects on source. set -u / set -e safe.

# fm_test_plan_approval <primary-home> <secondmate-home> <task-id> [<plan-file>]
# Create the primary keypair on first use, approve through the real tool rather
# than hand-writing a record, and place the public half where that home verifies
# against it. <plan-file> defaults to <secondmate-home>/data/<task-id>/brief.md,
# which is what the gate hashes. A fixture that also records a
# .fm-secondmate-parent binding must point it at this same primary home, because
# a local parent binding is authoritative over the home's own copy.
# Returns non-zero without output on any failure; callers add their own `|| fail`.
fm_test_plan_approval() {
  local primary=$1 home=$2 task=$3 plan=${4:-} sid
  [ -n "${ROOT:-}" ] || return 1
  [ -n "$plan" ] || plan="$home/data/$task/brief.md"
  IFS= read -r sid < "$home/.fm-secondmate-home" || return 1
  sid=${sid//[[:space:]]/}
  [ -n "$sid" ] || return 1
  mkdir -p "$primary/config" "$primary/state" "$primary/data" "$home/config" || return 1
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$primary" \
    FM_STATE_OVERRIDE="$primary/state" FM_DATA_OVERRIDE="$primary/data" \
    FM_CONFIG_OVERRIDE="$primary/config" \
    "$ROOT/bin/fm-plan-approval.sh" approve "$sid" "$task" \
    --plan-file "$plan" --home "$home" >/dev/null || return 1
  cp "$primary/config/plan-approval-key.pub" "$home/config/plan-approval-key.pub"
}
