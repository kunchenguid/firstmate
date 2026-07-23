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
README="$ROOT/README.md"
CONTRIBUTING="$ROOT/CONTRIBUTING.md"
STOW="$ROOT/.agents/skills/stow/SKILL.md"
BLANKET_WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"

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
  assert_grep '`project-management` - load before adding, creating, removing, or initializing a project.' "$ROOT/AGENTS.md" \
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
    '`no-mistakes`' \
    '`direct-PR`' \
    '`local-only`' \
    'is the default when the captain does not specify a mode' \
    'selected as a standing project mode only on the captain'\''s explicit request' \
    'AGENTS.md section 7 is the single owner of the three task-level validation lanes' \
    'Default it off' \
    'Creating a GitHub repository is outward-facing.' \
    "captain's explicit consent" \
    'Never issue a raw removal command from Firstmate.' \
    'No-mistakes initialization is a project-provisioning action only.' \
    'Never delegate it to a per-task ship brief or run it from a disposable task worktree.' \
    'no-mistakes init && no-mistakes doctor'; do
    assert_grep "$phrase" "$PROJECT" "project-management owner is missing '$phrase'"
  done
  pass "project-management owns registry, delivery posture, consent, initialization, and removal safety"
}

test_risk_tiered_validation_policy_is_authoritative() {
  local tmp out rc promote_root pointer
  for phrase in \
    'Use exactly three validation lanes:' \
    '**Routine** - styling, copy, small templates, presentation-only XML, documentation, tests, CI configuration, narrow UI changes, and small bounded fixes do not invoke no-mistakes.' \
    'Run deterministic repository-native checks, authoritative exact-SHA Lab validation when the affected project has an applicable Lab path, push a direct PR, and require hosted CI before merge.' \
    '**Medium risk** - application-behavior changes run no-mistakes as review-only with `--skip=test,document,lint,push,pr,ci`.' \
    '**High risk** - security, privacy or PHI, authentication or authorization, destructive data or schema behavior, billing or payments, production deployment or infrastructure, migrations, complex workflows, and other broad or high-blast-radius changes run the full no-mistakes pipeline.' \
    'An explicit `/no-mistakes` request selects the requested pipeline.' \
    'A routine request to commit, push, ship, or validate never implies the full pipeline.' \
    'Once a no-mistakes run is intentionally started, that run alone owns its findings and fixes through a terminal state, including a review-only medium-risk run.'; do
    assert_grep "$phrase" "$AGENTS" "AGENTS.md lost risk-tiered validation phrase '$phrase'"
  done
  assert_grep 'Risk-tiered validation' "$README" \
    "README does not summarize the risk-tiered validation posture"
  assert_grep 'The three-lane validation contract in [`AGENTS.md`](AGENTS.md#selected-delivery-path-and-approval-authority) is authoritative.' "$CONTRIBUTING" \
    "CONTRIBUTING does not point to the authoritative validation contract"
  assert_grep 'branch -> risk-selected validation -> PR -> captain-merge path owned by AGENTS.md sections 1 and 7' "$STOW" \
    "stow still hard-codes a no-mistakes path for shared tracked knowledge"
  for pointer in "$README" "$CONTRIBUTING" "$PROJECT" "$STOW"; do
    assert_no_grep 'presentation-only XML' "$pointer" \
      "$pointer duplicates the authoritative routine category list"
    assert_no_grep 'destructive data or schema behavior' "$pointer" \
      "$pointer duplicates the authoritative high-risk category list"
  done
  assert_absent "$BLANKET_WORKFLOW" \
    "the blanket GitHub workflow still rejects direct PRs without a no-mistakes signature"

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-validation-policy.XXXXXX")
  mkdir -p "$tmp/data"
  out=$(FM_HOME="$tmp" "$ROOT/bin/fm-project-mode.sh" routine 2>/dev/null) || fail "missing project default failed"
  [ "$out" = "direct-PR off" ] || fail "missing project did not default to direct-PR off: $out"
  printf '%s\n' '- routine - ordinary project (added 2026-07-22)' > "$tmp/data/projects.md"
  out=$(FM_HOME="$tmp" "$ROOT/bin/fm-project-mode.sh" routine) || fail "unqualified project default failed"
  [ "$out" = "direct-PR off" ] || fail "unqualified project did not default to direct-PR off: $out"
  printf '%s\n' '- routine [mystery] - malformed project mode (added 2026-07-22)' > "$tmp/data/projects.md"
  set +e
  out=$(FM_HOME="$tmp" "$ROOT/bin/fm-project-mode.sh" routine 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unknown project mode did not require classification with exit 2: $rc"
  assert_contains "$out" "bounded validation classification required" \
    "unknown project mode did not report the classification requirement"

  mkdir -p "$tmp/state"
  printf '%s\n' 'window=fm-risky' 'worktree=/tmp/risky' 'project=/tmp/project' \
    'harness=codex' 'kind=scout' 'mode=direct-PR' 'yolo=off' > "$tmp/state/risky.meta"
  promote_root="$tmp/promote-root"
  mkdir -p "$promote_root/bin"
  cp "$ROOT/bin/fm-promote.sh" "$promote_root/bin/fm-promote.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$promote_root/bin/fm-guard.sh"
  chmod +x "$promote_root/bin/fm-promote.sh" "$promote_root/bin/fm-guard.sh"
  FM_ROOT_OVERRIDE="$promote_root" FM_HOME="$tmp" FM_STATE_OVERRIDE="$tmp/state" \
    "$promote_root/bin/fm-promote.sh" risky --validation review-only >/dev/null \
    || fail "scout promotion rejected a valid review-only lane"
  assert_grep 'kind=ship' "$tmp/state/risky.meta" "promotion did not change scout to ship"
  assert_grep 'mode=direct-PR' "$tmp/state/risky.meta" \
    "review-only promotion did not retain direct-PR landing"
  assert_grep 'validation=review-only' "$tmp/state/risky.meta" \
    "promotion did not record the review-only validation lane"
  rm -rf "$tmp"
  pass "risk-tiered policy defaults routine work to direct PR and removes blanket rejection"
}

test_generic_effort_fallback_respects_precedence() {
  local section
  section=$(awk '
    /^Effort precedence is / { found = 1 }
    found && /^The supported launch-profile flags / { exit }
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
  assert_grep "session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window" "$AGENTS" \
    "AGENTS.md does not trigger ordinary dead-report recovery"
  pass "state, startup, and ordinary recovery have focused owners and triggers"
}

test_compressed_agents_owner_map() {
  assert_grep '`docs/configuration.md` is the single owner of the top-level operational-home layout' "$AGENTS" \
    "AGENTS.md lost the state-layout owner pointer"
  assert_grep 'header is the single owner of composed commands, ordering, and digest contents' "$AGENTS" \
    "AGENTS.md lost the session-start owner pointer"
  assert_grep '`docs/configuration.md` owns dispatch-profile and runtime-backend schemas' "$AGENTS" \
    "AGENTS.md lost the dispatch-schema owner pointer"
  assert_grep 'That skill owns registry syntax, delivery-mode selection' "$AGENTS" \
    "AGENTS.md lost the project-management owner pointer"
  assert_grep 'The delivery lifecycle is an always-loaded operational contract' "$AGENTS" \
    "AGENTS.md no longer owns the delivery lifecycle"
  assert_grep 'Fleet supervision is an always-loaded operational contract' "$AGENTS" \
    "AGENTS.md no longer owns fleet supervision"
  assert_grep '`.tasks.toml`, `docs/configuration.md`, and current `tasks-axi --help` own the backlog schema' "$AGENTS" \
    "AGENTS.md lost the backlog-mechanics owner pointer"
  assert_grep '`bin/fm-brief.sh` and its help own scaffold syntax' "$AGENTS" \
    "AGENTS.md lost the brief-mechanics owner pointer"
  assert_grep '`docs/configuration.md` owns activation, generated state, cadence, wire protocol' "$AGENTS" \
    "AGENTS.md lost the X-mode mechanics owner pointer"
  pass "compressed AGENTS.md records the approved one-owner map"
}

test_compressed_agents_retains_authority_and_supervision_safety() {
  for phrase in \
    'A lock-refused session must not spawn, steer, merge, drain the wake queue' \
    'A diagnostic request, report, recommendation, or implementation-ready finding is evidence, not authorization to change code.' \
    'The selected delivery path owns its own rigor.' \
    'Once a no-mistakes run is intentionally started, that run alone owns its findings and fixes through a terminal state, including a review-only medium-risk run.' \
    'For full-pipeline work it also owns tests, documentation, lint, push, PR, and CI; otherwise follow the selected lane without adding an independent reviewer.' \
    'Never hold work outside no-mistakes for a manual clean verdict or stack serial manual reviews.' \
    'A separate review or audit is allowed only when the captain explicitly requests that deliverable or the authorized task is a knowledge-only review; one named question remains scoped to that question.' \
    '**local-only** has the worker stop with a clean ready branch, then waits for the configured merge authority' \
    'A status line is a wake event, not current state' \
    'keep exactly one live supervision cycle' \
    'Never broadly kill watchers' \
    'While `state/.afk` exists, the daemon owns supervision' \
    'post the final completion follow-up before teardown'; do
    assert_grep "$phrase" "$AGENTS" "compressed AGENTS.md lost safety phrase '$phrase'"
  done
  assert_no_grep 'Firstmate does not personally review code or deliverables' "$AGENTS" \
    "AGENTS.md retained the weaker duplicate review prohibition"
  assert_no_grep 'firstmate reviews your branch' "$AGENTS" \
    "AGENTS.md retained a personal branch-review requirement"
  assert_no_grep 'firstmate reviews, captain approves' "$BRIEF" \
    "generated brief retained a stacked personal-review requirement"
  if grep -q "$(printf '\342\200\224')" "$AGENTS"; then
    fail "AGENTS.md contains an em dash"
  fi
  pass "compressed AGENTS.md retains authority, supervision, AFK, and X safety"
}

test_new_skill_metadata_and_triggers
test_diagnostic_owner_covers_causal_procedure
test_project_management_owner_covers_guarded_operations
test_risk_tiered_validation_policy_is_authoritative
test_generic_effort_fallback_respects_precedence
test_shared_authoring_requirements_are_owned
test_secondmate_registry_contract_stays_concise
test_state_startup_and_ordinary_recovery_placement
test_compressed_agents_owner_map
test_compressed_agents_retains_authority_and_supervision_safety
