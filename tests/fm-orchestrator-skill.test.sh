#!/usr/bin/env bash
# Static contract tests for the captain-invoked orchestrator skill: its
# captain-facing trigger, its launch pin, the two-file split that keeps the
# session's own contract out of firstmate's context, and the AGENTS.md wiring
# that must survive with no skill loaded.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/orchestrator/SKILL.md"
CONTRACT="$ROOT/.agents/skills/orchestrator/CONTRACT.md"
PROGRAM="$ROOT/.agents/skills/program-orchestration/SKILL.md"
BRIEF="$ROOT/bin/fm-brief.sh"
AGENTS="$ROOT/AGENTS.md"

test_orchestrator_is_captain_invocable_with_one_trigger() {
  local count
  assert_present "$SKILL" "orchestrator skill is missing"
  assert_grep "name: orchestrator" "$SKILL" "orchestrator skill metadata has the wrong name"
  assert_grep "user-invocable: true" "$SKILL" "orchestrator must be captain-invocable"
  assert_grep "  internal: true" "$SKILL" "orchestrator skill must be internal"
  assert_grep "Use when the captain invokes /orchestrator" "$SKILL" \
    "orchestrator metadata lost its captain trigger"

  count=$(grep -Fc -- '- **Orchestrator** drives an already captain-authorized spec' "$AGENTS")
  [ "$count" -eq 1 ] \
    || fail "AGENTS.md must classify the orchestrator deliverable exactly once, found $count"
  assert_grep 'load `orchestrator` when the captain invokes it or asks to run or take over such a programme' \
    "$AGENTS" "AGENTS.md lost the orchestrator load trigger"
  pass "orchestrator is captain-invocable and has exactly one AGENTS.md intake trigger"
}

test_input_is_authorized_work_rather_than_the_backlog() {
  assert_grep 'Its input is that authorized work rather than the backlog.' "$AGENTS" \
    "AGENTS.md lost the authorized-work-not-backlog input boundary"
  assert_grep 'already captain-authorized spec, ticket set, or GitHub issues' "$AGENTS" \
    "AGENTS.md lost the prior-authorization requirement"
  assert_grep 'the backlog stays firstmate' "$SKILL" \
    "orchestrator skill lost the backlog ownership boundary"
  assert_grep "the captain's word is what makes it startable" "$SKILL" \
    "orchestrator may open on evidence alone, with no captain authorization"
  pass "the orchestrator consumes authorized work and leaves the backlog to firstmate"
}

test_direct_conversation_exception_is_always_loaded() {
  assert_grep 'an `orchestrator` session, which the captain talks to directly under that same lifecycle-only limit' \
    "$AGENTS" "AGENTS.md lost the orchestrator direct-conversation exception"
  assert_grep "three narrow exceptions" "$AGENTS" \
    "AGENTS.md no longer enumerates a closed set of crewmate-communication exceptions"
  assert_grep 'alive, waiting, finished, or failed' "$SKILL" \
    "orchestrator skill lost the lifecycle-only monitoring limit"
  pass "the direct-conversation exception stays closed, enumerated, and lifecycle-only"
}

test_launch_profile_pin() {
  assert_grep '**Default: the claude runtime, model `claude-opus-5`, effort `xhigh`.**' "$SKILL" \
    "orchestrator lost its default Claude Opus 5 xhigh pin"
  assert_grep 'a dispatch profile leaves it alone' "$SKILL" \
    "orchestrator pin can be silently rerouted by a dispatch profile"
  assert_grep '`data/captain-shared.md` still binds' "$SKILL" \
    "orchestrator no longer defers to the shared captain model preference"
  pass "orchestrator pins Claude Opus 5 at xhigh and no dispatch profile reroutes it"
}

test_contract_is_disclosed_to_its_own_file() {
  assert_present "$CONTRACT" "orchestrator CONTRACT.md is missing"
  assert_grep '[`CONTRACT.md`](CONTRACT.md)' "$SKILL" \
    "SKILL.md does not point at the session contract"
  assert_grep 'orchestrator/CONTRACT.md' "$SKILL" \
    "the brief does not name the contract by path for the session to read"

  # Progressive disclosure across a real branch boundary: firstmate reads
  # SKILL.md, the session reads CONTRACT.md. Inlining the session's judgment
  # back into SKILL.md would charge every firstmate turn for it.
  assert_no_grep 'A report is a claim about the source' "$SKILL" \
    "SKILL.md inlined the session contract firstmate never runs"
  assert_no_grep 'Integration is yours alone' "$SKILL" \
    "SKILL.md inlined the session's integration rule"
  pass "the session contract stays in CONTRACT.md and costs firstmate a pointer"
}

test_reuses_existing_dispatch_mechanics() {
  local phrase
  for phrase in \
    'bin/fm-brief.sh <programme-id> <project> --scout' \
    '`harness-adapters`' \
    '`decision-hold-lifecycle`' \
    'report.md'; do
    assert_grep "$phrase" "$SKILL" "orchestrator does not reuse existing mechanics: $phrase"
  done
  assert_grep '--scout' "$BRIEF" "fm-brief.sh no longer offers the scaffold the skill scaffolds with"
  assert_no_grep 'bin/fm-orchestrator' "$SKILL" "orchestrator invented a parallel runtime script"
  assert_absent "$ROOT/bin/fm-orchestrator.sh" "orchestrator must not add a parallel launcher"
  pass "orchestrator launches through the ordinary brief, scout, and cleanup mechanics"
}

test_brief_scaffold_names_both_contracts_absolutely() {
  assert_grep 'Fill `{TASK}`' "$SKILL" "orchestrator brief does not fill the task placeholder"
  assert_grep 'program-orchestration/SKILL.md' "$SKILL" \
    "the brief does not hand the session its procedure owner"
  assert_grep 'They are your contract for this whole programme.' "$SKILL" \
    "the brief does not bind the session to both contracts"
  assert_grep 'no `{TASK}` or `{SCOPE}` placeholder remains' "$SKILL" \
    "orchestrator may dispatch a brief with an unfilled placeholder"
  assert_grep 'every path absolute' "$SKILL" \
    "the brief may carry a relative path the session cannot resolve"
  pass "the scaffolded brief names both contracts by absolute path with no placeholder left"
}

test_home_is_isolated_and_unregistered() {
  assert_grep 'own `FM_HOME`' "$SKILL" "orchestrator session does not get its own home"
  assert_grep 'own session lock' "$SKILL" \
    "orchestrator session would contend with firstmate's supervision cycle"
  assert_grep 'Registration in `data/secondmates.md` is what turns on liveness sweeps' "$SKILL" \
    "orchestrator lost the reason registration is left out"
  assert_grep 'leaves the registry line out' "$SKILL" \
    "a temporary programme home would be registered as a persistent secondmate"
  assert_grep '`data/secondmates.md` is byte-identical to before' "$SKILL" \
    "the unregistered-home rule has no checkable completion criterion"
  pass "the programme home is isolated, unregistered, and provably leaves the registry untouched"
}

test_every_step_carries_a_completion_criterion() {
  local steps criteria
  steps=$(grep -c '^## [0-9]' "$SKILL")
  criteria=$(grep -c '^\*\*Done when:\*\*' "$SKILL")
  [ "$steps" -eq 7 ] || fail "orchestrator must keep its 7 numbered steps, found $steps"
  [ "$criteria" -eq "$steps" ] \
    || fail "each of $steps steps needs a completion criterion, found $criteria"
  pass "all 7 steps end on a checkable completion criterion"
}

test_session_contract_defers_to_program_orchestration() {
  assert_grep '`program-orchestration` is your procedure' "$CONTRACT" \
    "the session contract does not defer its procedure to program-orchestration"
  assert_grep 'This file is the judgment that procedure cannot encode.' "$CONTRACT" \
    "the session contract does not bound itself to judgment"

  # One owner: custody, routing, and host ramp stay in program-orchestration.
  assert_grep 'custody' "$PROGRAM" "program-orchestration no longer owns custody"
  assert_no_grep '## Consuming an upstream scope envelope and test contract' "$CONTRACT" \
    "the session contract duplicated the envelope-consumption owner"
  pass "the session contract points at program-orchestration rather than restating it"
}

test_session_holds_integration_and_status_discipline() {
  local phrase
  for phrase in \
    '**A report is a claim about the source. A `grep` is the source.**' \
    '**A brief states the task, the acceptance criteria, and the traps. The worker chooses the route.**' \
    'what specifically changed underneath it' \
    'is this list complete?'; do
    assert_grep "$phrase" "$CONTRACT" "session contract is missing '$phrase'"
  done
  assert_grep 'under `ask-user-authority`' "$CONTRACT" \
    "the session may decide a scope widening that belongs to the captain"
  assert_grep 'Your workers' "$CONTRACT" \
    "the session contract lost the worker-progress ownership boundary"
  pass "the session verifies at source, owns integration, and stays quiet by contract"
}

test_orchestrator_agents_md_addition_stays_small() {
  local added
  added=$(grep -c -i 'orchestrator' "$AGENTS")
  [ "$added" -le 4 ] \
    || fail "AGENTS.md carries $added orchestrator lines; the contract belongs in the skill"
  assert_no_grep 'claude-opus-5' "$AGENTS" "AGENTS.md duplicated the orchestrator launch profile"
  assert_no_grep 'initialization packet' "$AGENTS" \
    "AGENTS.md duplicated the orchestrator open procedure"
  pass "AGENTS.md keeps only the trigger and the always-loaded safety boundary"
}

test_orchestrator_is_captain_invocable_with_one_trigger
test_input_is_authorized_work_rather_than_the_backlog
test_direct_conversation_exception_is_always_loaded
test_launch_profile_pin
test_contract_is_disclosed_to_its_own_file
test_reuses_existing_dispatch_mechanics
test_brief_scaffold_names_both_contracts_absolutely
test_home_is_isolated_and_unregistered
test_every_step_carries_a_completion_criterion
test_session_contract_defers_to_program_orchestration
test_session_holds_integration_and_status_discipline
test_orchestrator_agents_md_addition_stays_small
