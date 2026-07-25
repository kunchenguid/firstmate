#!/usr/bin/env bash
# Static contract tests for conditional instruction owners introduced before the
# AGENTS.md reduction pass.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DIAG="$ROOT/.agents/skills/diagnostic-reasoning/SKILL.md"
PROJECT="$ROOT/.agents/skills/project-management/SKILL.md"
HARNESS="$ROOT/.agents/skills/harness-adapters/SKILL.md"
CODING="$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md"
RECOVERY="$ROOT/.agents/skills/stuck-crewmate-recovery/SKILL.md"
SECONDMATE="$ROOT/.agents/skills/secondmate-provisioning/SKILL.md"
CONFIG="$ROOT/docs/configuration.md"
AGENTS="$ROOT/AGENTS.md"
BRIEF="$ROOT/bin/fm-brief.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TASK="$ROOT/.agents/skills/task-lifecycle/SKILL.md"
SUPERVISION="$ROOT/.agents/skills/fleet-supervision/SKILL.md"

test_new_skill_metadata_and_triggers() {
  local skill name count
  for pair in "diagnostic-reasoning:$DIAG" "project-management:$PROJECT"; do
    name=${pair%%:*}
    skill=${pair#*:}
    assert_present "$skill" "$name skill is missing"
    assert_grep "name: $name" "$skill" "$name skill metadata has the wrong name"
    assert_grep "user-invocable: false" "$skill" "$name skill must not be user-invocable"
    assert_grep "  internal: true" "$skill" "$name skill must be internal"
    count=$(grep -Fc -- "- \`$name\` -" "$ROOT/AGENTS.md")
    [ "$count" -eq 1 ] || fail "$name must have exactly one AGENTS.md trigger entry, found $count"
  done
  assert_grep 'Use before scoping a reported bug and before acting on a diagnostic report.' "$DIAG" \
    "diagnostic skill metadata lost its precise load trigger"
  assert_grep '`diagnostic-reasoning` - load before scoping a reported bug and before acting on a diagnostic report.' "$ROOT/AGENTS.md" \
    "AGENTS.md lost the diagnostic-reasoning trigger"
  assert_grep 'Use before adding, creating, removing, or initializing a project.' "$PROJECT" \
    "project-management skill metadata lost its precise load trigger"
  assert_grep '`project-management` - load before adding, creating, cloning, initializing, removing, or registering a project' "$ROOT/AGENTS.md" \
    "AGENTS.md lost the project-management trigger"
  pass "new internal skills have one precise AGENTS.md trigger each"
}

test_diagnostic_owner_covers_causal_procedure() {
  assert_grep "single owner of Firstmate's bug-diagnosis reasoning procedure" "$DIAG" \
    "diagnostic skill does not declare ownership"
  for phrase in \
    "end-to-end reproduction aligned with the real user path" \
    "initiating trigger" \
    "masking condition" \
    "visible symptom" \
    "proven path" \
    "relevant history" \
    "smallest counterfactual" \
    "disconfirming evidence"; do
    assert_grep "$phrase" "$DIAG" "diagnostic owner is missing '$phrase'"
  done
  assert_grep "evidence, not authorization to change code" "$DIAG" \
    "diagnostic owner lost the diagnosis-only authority boundary"
  pass "diagnostic-reasoning owns the approved evidence procedure"
}

test_project_management_owner_covers_guarded_operations() {
  assert_grep "single owner of Firstmate's project-management procedure" "$PROJECT" \
    "project-management skill does not declare ownership"
  for phrase in \
    'bin/fm-project-mode.sh' \
    '`direct-PR` is the default' \
    '`local-only`' \
    'Default it off' \
    'Creating a GitHub repository is outward-facing.' \
    "captain's explicit consent" \
    'Preserve every repository' \
    'Never issue a raw removal command from Firstmate.'; do
    assert_grep "$phrase" "$PROJECT" "project-management owner is missing '$phrase'"
  done
  assert_no_grep 'default when the captain does not specify a mode' "$PROJECT" \
    "project-management still presents the alternate as default"
  pass "project-management owns direct-default posture, consent, and removal safety"
}

test_generic_effort_fallback_respects_precedence() {
  local section
  section=$(awk '
    /^Effort precedence is / { found = 1 }
    found && /^Load the selected runtime reference / { exit }
    found { print }
  ' "$HARNESS")
  assert_contains "$section" "explicit per-task captain instruction first" \
    "effort rubric lost per-task captain precedence"
  assert_contains "$section" "standing dispatch profile or secondmate pin" \
    "effort rubric lost standing configuration precedence"
  assert_contains "$section" 'Use `low` for well-understood work' \
    "effort rubric lost its low fallback"
  assert_contains "$section" '`xhigh` for ambiguous investigation or design' \
    "effort rubric lost its xhigh fallback"
  assert_contains "$section" "Choose intermediate levels proportionally" \
    "effort rubric lost proportional intermediate levels"
  assert_contains "$section" 'Never select `max` from this fallback' \
    "effort rubric permits max without an explicit captain preference"
  if printf '%s\n' "$section" | grep -qi sol; then
    fail "generic effort fallback must not contain Sol-specific policy"
  fi
  pass "generic effort fallback applies only below captain and standing configuration"
}

test_agent_owned_quota_array_dispatch_contract() {
  local phrase
  for phrase in \
    'Firstmate alone resolves a matched profile array' \
    'Run `quota-axi --json` at that intake' \
    'evaluate every configured candidate against that current output' \
    'choose the candidate with the most real headroom' \
    'If any harness, model, or provider relationship, applicable quota data, or interpretation cannot be established, stop and report that candidate' \
    'instead of omitting it, guessing, falling back, or calling the result quota-informed' \
    'Preserve malformed profile configuration as an actionable error' \
    "preserve the captain's strongest-reasoning class rather than silently downgrading it" \
    'Break genuine headroom ties without array-order or harness bias' \
    '`quota-axi` owns how model or product windows relate to bounding account windows' \
    'explicitly interim rule until successor `quota-axi-interpretation-hints-h3` lands' \
    '`bin/fm-dispatch-select.sh` is vestigial during this transition and must not be called'; do
    assert_grep "$phrase" "$HARNESS" "array-dispatch owner lost '$phrase'"
  done

  for phrase in \
    '| claude | Open the current interactive session' \
    '| codex | Open the current interactive session' \
    '| opencode | Run `opencode models [provider]`' \
    '| pi | Run `pi --list-models [search]`' \
    '| grok | Run `grok models`' \
    "For an unfamiliar harness or model namespace, establish support and provider identity from that harness's authoritative CLI help, model listing, or current documentation rather than guessing" \
    'If those sources do not establish the relationship needed for dispatch, fail loudly and report the unresolved candidate.'; do
    assert_grep "$phrase" "$HARNESS" "model discovery guidance lost '$phrase'"
  done
  assert_grep 'not as a permanent namespace or provider mapping' "$HARNESS" \
    "model discovery guidance permits a fixed provider table"
  assert_grep '[`harness-adapters`](../.agents/skills/harness-adapters/SKILL.md) owns the dispatch and array-selection procedure.' "$CONFIG" \
    "configuration docs do not point to the agent-owned array procedure"
  assert_grep '`bin/fm-dispatch-select.sh` is vestigial during the instruction transition and must not be called' "$CONFIG" \
    "configuration docs still permit the vestigial selector"
  assert_grep 'quota-axi is required for the' "$BOOTSTRAP" \
    "bootstrap docs lost the quota-axi dependency pointer"
  assert_grep 'agent-owned dispatch-profile array procedure in the harness-adapters skill.' "$BOOTSTRAP" \
    "bootstrap docs do not point to the agent-owned array procedure"
  assert_no_grep 'every crew-dispatch profile array calls it automatically' "$BOOTSTRAP" \
    "bootstrap docs still claim automatic selector invocation"
  assert_no_grep 'OS-backed random selection across' "$BOOTSTRAP" \
    "bootstrap docs still promise quota-unavailable random fallback"
  pass "firstmate directly compares every quota candidate with authoritative model discovery"
}

test_shared_authoring_requirements_are_owned() {
  assert_grep "review every affected supported primary harness and runtime backend" "$CODING" \
    "coding guidance lost the supported compatibility matrix review"
  assert_grep "prefer deterministic and idempotent enforcement over relying on agent memory alone" "$CODING" \
    "coding guidance lost deterministic idempotent enforcement"
  assert_grep "critical safety, routing, startup, and supervision infrastructure" "$CODING" \
    "coding guidance lost the critical infrastructure scope"
  pass "firstmate-coding-guidelines owns compatibility review and deterministic enforcement"
}

test_secondmate_registry_contract_stays_concise() {
  local guidance routing_section schema_line
  routing_section=$(awk '
    /^## Routing table$/ { found = 1 }
    found && /^## Charter and seed$/ { exit }
    found { print }
  ' "$SECONDMATE")
  guidance=$(awk '
    /^## Routing table$/ { found = 1 }
    found && /^## Backlog handoff$/ { exit }
    found { print }
  ' "$SECONDMATE")
  schema_line="- <id> - <one-sentence charter summary> (home: <absolute-home-path>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)"
  assert_contains "$routing_section" "$schema_line" \
    "secondmate routing table lost the parser-compatible single-line schema"
  assert_contains "$routing_section" "Each registry entry stays concise and single-line" \
    "secondmate routing table no longer requires concise single-line entries"
  assert_contains "$routing_section" "genuinely domain-specific hard rules" \
    "secondmate routing table no longer limits extra prose to domain-specific hard rules"
  assert_contains "$routing_section" "The home-seeded \`data/charter.md\` is the sole owner of boilerplate idle-by-default behavior, the normal delegation lifecycle, and standard escalation contracts" \
    "secondmate routing table lost the explicit charter ownership pointer"
  assert_contains "$routing_section" "no extra registry pointer field is needed" \
    "secondmate routing table no longer explains why the existing home field is the charter pointer"
  for phrase in \
    "go idle and wait silently" \
    "Act only on tasks" \
    "never spawn a survey" \
    "run normal firstmate bootstrap" \
    "escalation back to the main firstmate status file" \
    "requests-from-main-firstmate contract" \
    "waits for routed tasks, never self-initiating a survey or audit" \
    "marked supervisor requests return through status" \
    "unmarked captain messages stay conversational"; do
    if printf '%s\n' "$guidance" | grep -F "$phrase" >/dev/null; then
      fail "secondmate provisioning guidance restated charter boilerplate: $phrase"
    fi
  done
  pass "secondmate registry guidance keeps concise routes and points to the charter"
}

test_state_startup_and_ordinary_recovery_placement() {
  assert_grep "single owner of the top-level operational-home layout" "$CONFIG" \
    "configuration docs do not own the operational state layout"
  assert_grep "header is the single owner of session-start ordering" "$CONFIG" \
    "session-start mechanism is not assigned to the script header"
  assert_grep "Ordinary dead-direct-report recovery is owned by \`stuck-crewmate-recovery\`" "$CONFIG" \
    "D05 ordinary recovery placement is missing"
  assert_grep "## Session-start reconciliation for a dead ordinary direct report" "$RECOVERY" \
    "stuck-crewmate-recovery lacks the dead ordinary direct-report procedure"
  assert_grep "treehouse status" "$RECOVERY" \
    "ordinary recovery lost treehouse inventory inspection"
  assert_grep "recorded \`orca_worktree_id=\` and \`terminal=\`" "$RECOVERY" \
    "ordinary recovery lost Orca inventory inspection"
  assert_grep '`stuck-crewmate-recovery` - load for a dead or missing ordinary direct report' "$AGENTS" \
    "AGENTS.md does not trigger ordinary dead-report recovery"
  pass "state, startup, and ordinary recovery have focused owners and triggers"
}

test_compressed_agents_owner_map() {
  assert_grep '`docs/configuration.md` owns the operational-home layout' "$AGENTS" \
    "AGENTS.md lost the state-layout owner pointer"
  assert_grep 'Run `bin/fm-session-start.sh` exactly once' "$AGENTS" \
    "AGENTS.md lost the session-start behavioral owner"
  assert_grep '`harness-adapters` - load before selecting a dispatch profile' "$AGENTS" \
    "AGENTS.md lost the dispatch-procedure trigger"
  assert_grep '`project-management` - load before adding, creating, cloning, initializing, removing, or registering a project' "$AGENTS" \
    "AGENTS.md lost the project-management trigger"
  assert_grep '`task-lifecycle` owns backlog, task records, dispatch, steering, decision return, landing, cleanup, and scout promotion' "$AGENTS" \
    "AGENTS.md lost the task-lifecycle owner pointer"
  assert_grep '`delivery-quality` owns route selection, proportional validation and evidence, repository gates' "$AGENTS" \
    "AGENTS.md lost the delivery-quality owner pointer"
  assert_grep '`fleet-supervision` owns ordinary notification handling and repair' "$AGENTS" \
    "AGENTS.md lost the notification-procedure owner pointer"
  assert_grep '`.tasks.toml`, `docs/configuration.md`, and current `tasks-axi --help` own schema' "$AGENTS" \
    "AGENTS.md lost the backlog-mechanics owner pointer"
  assert_grep '`bin/fm-brief.sh` help owns scaffold mechanics and safety assertions' "$AGENTS" \
    "AGENTS.md lost the brief-mechanics owner pointer"
  assert_grep '`fmx-respond` owns classification, public-safety policy' "$AGENTS" \
    "AGENTS.md lost the X-mode owner pointer"
  pass "slim AGENTS.md records the approved one-owner map"
}

test_intake_reuses_evidence_and_parallelizes_safe_work() {
  assert_grep 'Relay established answers without speculative work' "$AGENTS" \
    "intake no longer reuses established evidence"
  assert_grep 'A **ship** is the default after implementation authorization' "$AGENTS" \
    "intake lost the ship default"
  assert_grep 'A **scout** produces a self-contained report and no PR' "$AGENTS" \
    "intake lost the scout deliverable boundary"
  assert_grep 'unresolved uncertainty could materially change whether or what to build' "$AGENTS" \
    "intake lost the scout uncertainty criterion"
  assert_grep 'Dispatch independently implementable and verifiable work immediately with no concurrency cap' "$AGENTS" \
    "intake lost safe parallel dispatch"
  assert_grep 'Serialize only for a real semantic dependency, shared mutable external state, incompatible concurrent migration' "$AGENTS" \
    "intake lost concrete serialization criteria"
  assert_grep 'Promote the existing scout through `bin/fm-promote.sh <id>` rather than creating a duplicate task.' "$TASK" \
    "task owner lost genuine scout promotion"
  pass "intake reuses evidence, reserves scouts for uncertainty, and parallelizes safe work"
}

test_compressed_agents_retains_authority_and_supervision_safety() {
  assert_grep 'remain read-only: do not spawn, steer, merge, drain notifications' "$AGENTS" \
    "lock-refusal safety is missing"
  assert_grep 'default active delivery model is `direct-PR`' "$AGENTS" \
    "direct delivery model is missing"
  assert_grep 'Do not create a second review pipeline, stack manual reviewers' "$AGENTS" \
    "single delivery-quality path is missing"
  assert_grep 'Never merge red work' "$AGENTS" \
    "red-merge prohibition is missing"
  assert_grep 'captain alone approves merge' "$AGENTS" \
    "captain merge authority is missing"
  assert_grep 'No turn ends blind while supervision is required' "$AGENTS" \
    "no-blind-turn safety is missing"
  assert_grep 'While `state/.afk` exists, the away daemon alone owns supervision' "$AGENTS" \
    "away-mode ownership is missing"
  assert_grep 'Before terminal cleanup, always post the final follow-up' "$SUPERVISION" \
    "X terminal follow-up procedure is missing"
  assert_no_grep 'pipeline -> PR' "$AGENTS" \
    "AGENTS.md retained the superseded active delivery model"
  assert_no_grep 'firstmate reviews your branch' "$AGENTS" \
    "AGENTS.md retained a personal branch-review requirement"
  assert_no_grep 'firstmate reviews, captain approves' "$BRIEF" \
    "generated brief retained a stacked personal-review requirement"
  if grep -q "$(printf '\342\200\224')" "$AGENTS"; then
    fail "AGENTS.md contains an em dash"
  fi
  pass "slim AGENTS.md retains authority, supervision, AFK, and direct-delivery safety"
}

test_new_skill_metadata_and_triggers
test_diagnostic_owner_covers_causal_procedure
test_project_management_owner_covers_guarded_operations
test_generic_effort_fallback_respects_precedence
test_agent_owned_quota_array_dispatch_contract
test_shared_authoring_requirements_are_owned
test_secondmate_registry_contract_stays_concise
test_state_startup_and_ordinary_recovery_placement
test_compressed_agents_owner_map
test_intake_reuses_evidence_and_parallelizes_safe_work
test_compressed_agents_retains_authority_and_supervision_safety
