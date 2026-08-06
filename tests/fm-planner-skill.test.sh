#!/usr/bin/env bash
# Static contract tests for the captain-invoked planner skill, its bundled
# planning disciplines, and the ownership split for the scope envelope and the
# test contract across planner, program-orchestration, paired-review, and
# bin/fm-brief.sh.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLANNER="$ROOT/.agents/skills/planner/SKILL.md"
BUNDLE="$ROOT/.agents/skills/planner/matt"
PROVENANCE="$BUNDLE/PROVENANCE.md"
PROGRAM="$ROOT/.agents/skills/program-orchestration/SKILL.md"
PAIRED="$ROOT/.agents/skills/paired-review/SKILL.md"
BRIEF="$ROOT/bin/fm-brief.sh"
AGENTS="$ROOT/AGENTS.md"

test_planner_is_captain_invocable_with_one_trigger() {
  local count
  assert_present "$PLANNER" "planner skill is missing"
  assert_grep "name: planner" "$PLANNER" "planner skill metadata has the wrong name"
  assert_grep "user-invocable: true" "$PLANNER" "planner must be captain-invocable"
  assert_grep "  internal: true" "$PLANNER" "planner skill must be internal"
  assert_grep "Use when the captain invokes /planner" "$PLANNER" \
    "planner metadata lost its captain trigger"

  count=$(grep -Fc -- '- **Planner** produces a captain-approved spec or tickets' "$AGENTS")
  [ "$count" -eq 1 ] || fail "AGENTS.md must classify the planner deliverable exactly once, found $count"
  assert_grep 'load `planner` when the captain invokes it or asks to plan, scope, spec, or break down work before implementation is authorized' \
    "$AGENTS" "AGENTS.md lost the planner load trigger"
  assert_grep 'Its artifact never authorizes implementation' "$AGENTS" \
    "AGENTS.md lost the planning-does-not-authorize-implementation boundary"
  pass "planner is captain-invocable and has exactly one AGENTS.md intake trigger"
}

test_direct_conversation_exception_is_always_loaded() {
  assert_grep 'a `planner` session, which the captain talks to directly after firstmate opens it' "$AGENTS" \
    "AGENTS.md lost the planner direct-conversation exception"
  assert_grep 'monitors only whether the session is alive, waiting, finished, or failed' "$AGENTS" \
    "AGENTS.md lost the lifecycle-only monitoring limit"
  assert_grep "three narrow exceptions" "$AGENTS" \
    "AGENTS.md no longer enumerates a closed set of crewmate-communication exceptions"
  pass "the narrowed direct-conversation exception survives with no skill loaded"
}

test_launch_profile_pins() {
  assert_grep '**Default: the pi runtime, model `cx/gpt-5.6-sol`, effort `high`.**' "$PLANNER" \
    "planner lost its default pi Sol high pin"
  assert_grep '**The explicit alternative: the claude runtime, model `claude-opus-5`, effort `high`**' "$PLANNER" \
    "planner lost its explicit Claude Opus 5 alternative"
  assert_grep 'a dispatch profile does not silently reroute a planner session' "$PLANNER" \
    "planner pin can be silently overridden by a dispatch profile"
  pass "planner pins the default Sol profile and the explicit Claude Opus 5 alternative"
}

test_reuses_existing_dispatch_mechanics() {
  for phrase in \
    'bin/fm-brief.sh <task-id> <project> --scout' \
    'bin/fm-spawn.sh' \
    '`harness-adapters`' \
    'data/<task-id>/report.md'; do
    assert_grep "$phrase" "$PLANNER" "planner does not reuse existing mechanics: $phrase"
  done
  assert_no_grep 'bin/fm-planner' "$PLANNER" "planner invented a parallel runtime script"
  assert_absent "$ROOT/bin/fm-planner.sh" "planner must not add a parallel launcher"
  pass "planner launches through the ordinary brief, spawn, and scout-report mechanics"
}

test_investigation_precedes_grilling_and_runs_nothing() {
  for phrase in \
    'Current state' \
    'Target direction' \
    'that conflict is a finding' \
    'no tests, no builds, no services, no browser checks, no validation commands'; do
    assert_grep "$phrase" "$PLANNER" "planner investigation contract is missing '$phrase'"
  done
  assert_grep 'You **read** tests as evidence' "$PLANNER" \
    "planner lost the read-tests-as-evidence rule"
  pass "planner reconstructs current and target state, flags conflicts, and runs nothing"
}

test_grilling_disciplines() {
  for phrase in \
    '**One question at a time.**' \
    '**Every question carries your recommended answer.**' \
    '**Facts are yours; decisions are the captain'"'"'s.**' \
    'a fact you verified, an inference you drew, or a preference you hold' \
    '**Debate a weak premise.**' \
    '**simplest workable** case' \
    '**best-practice** case' \
    'which you recommend, with the reason'; do
    assert_grep "$phrase" "$PLANNER" "planner grilling contract is missing '$phrase'"
  done
  pass "grilling debates one question at a time with recommendations and both ends of each choice"
}

test_crystallize_gate_is_the_captains_alone() {
  assert_grep '**Do not produce a plan in this phase.**' "$PLANNER" \
    "planner may emit a plan during grilling"
  assert_grep '**The captain opens this gate, in words, and nobody else.**' "$PLANNER" \
    "the crystallize gate is not exclusively the captain's"
  assert_grep 'Your own sense that the conversation is finished does not open it' "$PLANNER" \
    "planner may self-open the crystallize gate"
  pass "no plan before the captain opens the crystallize gate"
}

test_publication_and_write_boundary() {
  assert_grep 'matt/to-spec.md' "$PLANNER" "planner cannot reach the spec workflow"
  assert_grep 'matt/to-tickets.md' "$PLANNER" "planner cannot reach the tickets workflow"
  assert_grep 'Resolve the tracker and conventions by reading, never by configuring.' "$PLANNER" \
    "planner lost the read-only tracker resolution rule"
  assert_grep 'Consult it - never execute its loop. You write no tests and run no tests.' "$PLANNER" \
    "planner may execute the TDD loop"
  assert_grep 'You do not edit product code, implement, run validation, commit product changes, open an implementation pull request, create workers, or widen the captain'"'"'s scope.' \
    "$PLANNER" "planner lost its write boundary"
  assert_grep '**Planning never authorizes implementation.**' "$PLANNER" \
    "planner lost the no-implementation-authority boundary"
  pass "planner publishes only approved artifacts and never implements"
}

test_artifacts_land_somewhere_that_outlives_the_session() {
  assert_grep '**Publish somewhere that outlives you.**' "$PLANNER" \
    "planner may write its artifact into a copy that is about to be discarded"
  assert_grep 'Publishing issues there is expected of you and is not a push or a pull request.' "$PLANNER" \
    "planner cannot tell tracker publication apart from the push and PR it is forbidden"
  assert_grep 'committing files into the project is a project change and belongs to the ordinary delivery lifecycle' \
    "$PLANNER" "planner may commit ticket files into the project"
  assert_grep 'Write those files under `data/<task-id>/` instead' "$PLANNER" \
    "a local-file tracker artifact has no durable home"
  pass "artifacts survive cleanup without becoming an unauthorized project change"
}

test_quiet_session_is_declared_not_stale() {
  assert_grep 'paused: grilling with the captain' "$PLANNER" \
    "planner does not declare its conversational wait"
  assert_grep 'Routine conversational turns are not status events' "$PLANNER" \
    "planner may wake firstmate on routine conversation"
  pass "a quiet planner session is a declared wait rather than a suspected wedge"
}

test_scope_envelope_fields_and_single_owner() {
  local field
  assert_grep '## The scope envelope' "$PLANNER" "planner does not own the scope envelope"
  for field in \
    'Current-state and target-state boundary' \
    'Owning module or layer' \
    'Out of scope' \
    'Contracts consumed and contracts changed' \
    'Callers not to disturb' \
    'Acceptance seam and evidence' \
    'Unresolved decisions'; do
    assert_grep "$field" "$PLANNER" "scope envelope is missing the '$field' field"
  done
  assert_grep '## Scope and seams' "$PLANNER" \
    "ticket-level block does not reuse the generated brief heading"
  assert_grep '# Scope and seams' "$BRIEF" \
    "fm-brief.sh no longer generates the heading the ticket block mirrors"

  # One owner: the field list lives in planner only.
  for field in 'Contracts consumed and contracts changed' 'Callers not to disturb'; do
    assert_no_grep "$field" "$PROGRAM" "program-orchestration duplicated the envelope schema"
    assert_no_grep "$field" "$PAIRED" "paired-review duplicated the envelope schema"
    assert_no_grep "$field" "$AGENTS" "AGENTS.md duplicated the envelope schema"
  done
  pass "planner is the single owner of the scope envelope fields"
}

test_test_contract_fields_and_single_owner() {
  local field
  assert_grep '## The test contract' "$PLANNER" "planner does not own the test contract"
  assert_grep '**You record acceptance intent, not executable test code.**' "$PLANNER" \
    "test contract does not bound itself to acceptance intent"
  for field in \
    'the system behaviors and invariants that must hold' \
    'the evidence that the composed whole works' \
    'the behavior to prove' \
    'the public seam it is proven at' \
    'representative success, failure, and boundary cases' \
    'the regression obligation' \
    'the required evidence' \
    'explicit non-goals'; do
    assert_grep "$field" "$PLANNER" "test contract is missing '$field'"
  done
  assert_grep '**The captain approves the test contract with the scope envelope, in the same breath.**' "$PLANNER" \
    "test contract is not approved together with scope"
  assert_grep 'unless one of them is materially contract-defining' "$PLANNER" \
    "test contract lost the implementer-decision boundary"

  for field in 'representative success, failure, and boundary cases' 'the regression obligation'; do
    assert_no_grep "$field" "$PROGRAM" "program-orchestration duplicated the test-contract schema"
    assert_no_grep "$field" "$PAIRED" "paired-review duplicated the test-contract schema"
  done
  pass "planner is the single owner of the test-contract fields"
}

test_downstream_consumption_owners() {
  assert_grep '## Consuming an upstream scope envelope and test contract' "$PROGRAM" \
    "program-orchestration does not own consumption"
  assert_grep '`planner` owns those artifact fields; this section owns consuming them' "$PROGRAM" \
    "program-orchestration does not defer the field list to planner"
  for phrase in \
    '**Preserve provenance.**' \
    '**Revalidate before every dispatch.**' \
    '**Narrow into the worker brief.**' \
    '**Never widen.**' \
    '**Escalate a stale, incorrect, or insufficient envelope**'; do
    assert_grep "$phrase" "$PROGRAM" "orchestrator consumption rule is missing '$phrase'"
  done
  assert_grep 'under the statement contract `bin/fm-brief.sh` owns' "$PROGRAM" \
    "orchestrator does not defer the final worker statement to fm-brief.sh"

  assert_grep 'the navigator challenges and refines it independently' "$PAIRED" \
    "paired-review lost the navigator's plan-gate challenge"
  assert_grep 'never expands it' "$PAIRED" \
    "paired-review allows the navigator to expand product scope"
  assert_grep 'The driver alone writes production and test code and runs validation' "$PAIRED" \
    "paired-review lost the driver-only implementation boundary"
  assert_grep 'A required new behavior discovered at this gate is a scope decision for the captain, not a test the navigator adds.' \
    "$PAIRED" "paired-review lost the new-behavior scope-decision rule"

  assert_grep '**`bin/fm-brief.sh`** owns the final worker scope and seam statement' "$PLANNER" \
    "planner does not name fm-brief.sh as the final statement owner"
  assert_grep '**`paired-review`** owns sharing that final statement' "$PLANNER" \
    "planner does not name paired-review as the sharing owner"
  pass "consumption, narrowing, and pair sharing each keep their own owner"
}

test_bundled_disciplines_are_present_with_provenance() {
  local f
  for f in grilling grill-me grill-with-docs domain-modeling tdd to-spec to-tickets; do
    assert_present "$BUNDLE/$f.md" "bundled discipline $f.md is missing"
  done
  for f in domain-modeling.CONTEXT-FORMAT domain-modeling.ADR-FORMAT tdd.tests tdd.mocking; do
    assert_present "$BUNDLE/$f.md" "bundled support reference $f.md is missing"
  done
  assert_present "$BUNDLE/LICENSE" "bundled MIT license is missing"
  assert_grep "MIT License" "$BUNDLE/LICENSE" "bundled license is not the upstream MIT text"
  assert_grep "Copyright (c) 2026 Matt Pocock" "$BUNDLE/LICENSE" "bundled license lost its copyright line"
  assert_grep "https://github.com/mattpocock/skills" "$PROVENANCE" "provenance lost the upstream source"
  assert_grep "2ab958093e83e0ec752e6c1c5932da465bf23e0c" "$PROVENANCE" "provenance lost the upstream commit pin"
  pass "the required disciplines are bundled with retained license and provenance"
}

test_bundle_stays_off_the_skill_index_and_cannot_shadow_local_installs() {
  local stray
  stray=$(find "$BUNDLE" -name 'SKILL.md' -print -quit)
  [ -z "$stray" ] || fail "bundled file $stray would register as a discoverable skill"

  # A tracked file at an upstream install path is silently overwritten on
  # fast-forward when that path is locally git-excluded, destroying a captain's
  # own installed copy without a conflict.
  for name in grilling grill-me grill-with-docs domain-modeling tdd to-spec to-tickets; do
    assert_absent "$ROOT/.agents/skills/$name" \
      "$name must not be restored at the top-level skill path, where it would clobber a local install"
  done
  pass "the bundle costs no context and cannot shadow or clobber a local install"
}

test_bundled_disciplines_are_self_contained() {
  local f
  # PROVENANCE.md is firstmate-authored and names the deliberately unbundled
  # upstream skills; only the vendored disciplines must be path-resolvable.
  for f in "$BUNDLE"/*.md; do
    [ "$(basename "$f")" = PROVENANCE.md ] && continue
    if grep -F -- '/setup-matt-pocock-skills' "$f" >/dev/null; then
      fail "$(basename "$f") still delegates to the unbundled setup skill"
    fi
    if grep -F -- '`/grilling`' "$f" >/dev/null; then
      fail "$(basename "$f") still delegates through a slash command that path-reading cannot resolve"
    fi
  done
  assert_grep 'read and follow `grilling.md` beside this file' "$BUNDLE/grill-me.md" \
    "grill-me no longer reaches grilling by path"
  assert_grep 'using `domain-modeling.md` beside this file' "$BUNDLE/grill-with-docs.md" \
    "grill-with-docs no longer reaches domain-modeling by path"
  assert_grep 'Never run a setup skill that writes configuration into the project.' "$BUNDLE/to-spec.md" \
    "to-spec lost the read-only tracker adaptation"
  assert_grep 'Never run a setup skill that writes configuration into the project.' "$BUNDLE/to-tickets.md" \
    "to-tickets lost the read-only tracker adaptation"
  pass "bundled disciplines resolve by path and never write project configuration"
}

test_planner_agents_md_addition_stays_small() {
  local added
  added=$(grep -c -i 'planner' "$AGENTS")
  [ "$added" -le 4 ] \
    || fail "AGENTS.md carries $added planner lines; the contract belongs in the skill"
  assert_no_grep 'crystallize' "$AGENTS" "AGENTS.md duplicated the planner phase contract"
  assert_no_grep 'cx/gpt-5.6-sol' "$AGENTS" "AGENTS.md duplicated the planner launch profile"
  pass "AGENTS.md keeps only the trigger and the always-loaded safety boundary"
}

test_planner_is_captain_invocable_with_one_trigger
test_direct_conversation_exception_is_always_loaded
test_launch_profile_pins
test_reuses_existing_dispatch_mechanics
test_investigation_precedes_grilling_and_runs_nothing
test_grilling_disciplines
test_crystallize_gate_is_the_captains_alone
test_publication_and_write_boundary
test_artifacts_land_somewhere_that_outlives_the_session
test_quiet_session_is_declared_not_stale
test_scope_envelope_fields_and_single_owner
test_test_contract_fields_and_single_owner
test_downstream_consumption_owners
test_bundled_disciplines_are_present_with_provenance
test_bundle_stays_off_the_skill_index_and_cannot_shadow_local_installs
test_bundled_disciplines_are_self_contained
test_planner_agents_md_addition_stays_small
