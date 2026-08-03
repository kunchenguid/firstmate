#!/usr/bin/env bash
# Contract tests for the supervision context-recycling split.
#
# Upstream removed its own /stow task-note assertions in favour of behavioral
# coverage. What is kept here guards a fleet adaptation with no executable seam:
# AGENTS.md must carry only the recycle trigger while the stow skill owns the
# procedure, and the safe-point test must keep refusing a reset that would drop
# in-flight work. Both halves live entirely in instruction text.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The recycling cadence is split deliberately: AGENTS.md carries only the
# always-loaded trigger, and the stow skill owns the threshold, the safe-point
# test, and the reset handoff. Guard both halves so a later edit cannot drop the
# trigger (recycling never fires) or inline the procedure back into the
# always-loaded surface (the cost this change removed).
test_agents_states_recycle_trigger_only() {
  local agents="$ROOT/AGENTS.md"

  assert_grep 'A supervision session that never resets re-reads its whole accumulated history on every wake' "$agents" \
    "AGENTS.md does not state why a long supervision session must recycle"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'finish the wake in hand and then load `stow`' "$agents" \
    "AGENTS.md does not route the recycle to the stow skill after the wake in hand"
  assert_grep 'it owns the threshold, the safe-point test, and the reset handoff' "$agents" \
    "AGENTS.md does not name stow as the owner of the recycle procedure"
  assert_grep 'Recycling never happens mid-wake, and it refuses rather than resetting while any safe-point condition fails' "$agents" \
    "AGENTS.md lost the mid-wake and refuse-on-unsafe boundaries"
  assert_no_grep 'The durable wake queue is drained and empty' "$agents" \
    "AGENTS.md duplicates the safe-point conditions the stow skill owns"
  assert_no_grep 'Reset handoff' "$agents" \
    "AGENTS.md duplicates the reset-handoff procedure the stow skill owns"
  pass "AGENTS.md keeps only the recycle trigger and points the procedure at stow"
}

test_stow_skill_owns_recycle_procedure() {
  local stow="$ROOT/.agents/skills/stow/SKILL.md"

  assert_grep "when a long-lived supervision session's remaining context falls below about a third of its window" "$stow" \
    "stow skill description does not carry the recycle trigger, so the skill would not load on it"
  assert_grep '## Context recycling' "$stow" "stow skill has no context-recycling section"
  assert_grep 'this section is the single owner of the threshold, the safe-point test, and the reset handoff' "$stow" \
    "stow skill does not claim ownership of the recycle procedure"
  assert_grep 'remaining context has fallen below about a third of its window' "$stow" \
    "stow skill does not state the recycle threshold"
  assert_grep 'Evaluate this only at the end of a wake-handling turn, never in the middle of one' "$stow" \
    "stow skill does not forbid mid-wake evaluation"

  # The captain's hard constraint: an in-flight wake, an unresolved decision, or
  # unlanded work must block the reset rather than be dropped by it.
  assert_grep 'If any condition fails, do not recycle' "$stow" \
    "stow skill does not refuse the recycle when a safe-point condition fails"
  assert_grep 'The durable wake queue is drained and empty' "$stow" \
    "safe-point test does not cover in-flight wakes"
  assert_grep 'No steer is outstanding' "$stow" "safe-point test does not cover outstanding steers"
  assert_grep 'No captain-facing escalation is unsent' "$stow" \
    "safe-point test does not cover unsent escalations"
  assert_grep 'Every unresolved decision is on disk as a backlog hold' "$stow" \
    "safe-point test does not cover unresolved decisions"
  assert_grep 'No landing is half-done' "$stow" \
    "safe-point test does not cover half-done landings and unlanded work"
  assert_grep 'A live supervision cycle is armed' "$stow" \
    "safe-point test does not require an armed supervision cycle before the gap"

  # The no-loss argument names the durable records that make a reset survivable.
  assert_grep 'A reset destroys conversation, never durable state' "$stow" \
    "stow skill does not state the no-loss guarantee"
  assert_grep 'durable wake queue on disk' "$stow" \
    "no-loss argument does not name the durable wake queue"
  assert_grep 'session-start digest drains them under the session lock' "$stow" \
    "no-loss argument does not name the drain that recovers queued wakes"

  # The handoff is honest about who can actually perform the reset.
  assert_grep 'Firstmate cannot reset its own session, so the captain performs the reset' "$stow" \
    "stow skill does not state that the captain performs the reset"
  assert_grep 'end this session before starting the replacement' "$stow" \
    "reset handoff does not warn about the session lock refusing an overlapping session"
  assert_grep 'Do not stop supervising' "$stow" \
    "reset handoff does not keep supervision live while waiting for the captain"
  pass "stow skill owns the recycle threshold, safe-point test, no-loss argument, and reset handoff"
}

test_agents_states_recycle_trigger_only
test_stow_skill_owns_recycle_procedure
