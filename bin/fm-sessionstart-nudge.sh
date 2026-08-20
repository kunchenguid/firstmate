#!/usr/bin/env bash
# Print the one-line session-start instruction only for a genuine firstmate
# primary whose current harness session has not already acquired the home lock.
# Ownership is the shared session-lock predicate's decision, not a local one, so
# an owner that survived process reparenting is never nudged to take the helm it
# already holds.
# Every silence and error path exits 0 because Claude SessionStart exit 2 blocks
# session initialization.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# Ownership of state/.lock has ONE owner, bin/fm-session-lock-lib.sh, so this
# wrapper asks the same question fm-lock.sh and the Stop auto-arm ask instead of
# re-deciding it: a session whose pid moved under an identity-matched reparenting
# still owns its home and must not be told to take the helm again.
# fm-wake-lib.sh comes first because that reparenting refresh shares fm-lock.sh's
# acquisition lock. Both are sourced only AFTER the eligibility gates above,
# because fm-wake-lib.sh materializes the state directory on source and this
# wrapper must leave a checkout it does not own byte-for-byte untouched.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

fm_session_lock_owned_by_self "$STATE" 2>/dev/null && exit 0
nudge=
fm_operational_input_encode session-start \
  "Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions." \
  nudge || exit 0
printf '%s\n' "$nudge"
exit 0
