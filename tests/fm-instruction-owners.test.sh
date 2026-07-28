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
CLOSE="$ROOT/.agents/skills/session-close/SKILL.md"
SECONDMATE="$ROOT/.agents/skills/secondmate-provisioning/SKILL.md"
CONFIG="$ROOT/docs/configuration.md"
AGENTS="$ROOT/AGENTS.md"
BRIEF="$ROOT/bin/fm-brief.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"

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
    'Default it off' \
    'Creating a GitHub repository is outward-facing.' \
    "captain's explicit consent" \
    'Never issue a raw removal command from Firstmate.' \
    'no-mistakes init && no-mistakes doctor'; do
    assert_grep "$phrase" "$PROJECT" "project-management owner is missing '$phrase'"
  done
  pass "project-management owns registry, delivery posture, consent, initialization, and removal safety"
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

test_agent_owned_quota_array_dispatch_contract() {
  local phrase
  for phrase in \
    'Firstmate alone resolves a matched profile array' \
    'run `quota-axi --json` at that intake' \
    'evaluate every configured candidate against that current output' \
    'choose the candidate with the most real headroom' \
    'if any harness/model/provider relationship, applicable quota data, or interpretation cannot be established, stop and report that candidate' \
    'instead of omitting it, guessing, falling back, or calling the result quota-informed' \
    'Preserve malformed profile configuration as an actionable error' \
    "preserve the captain's strongest-reasoning class rather than silently downgrading it" \
    'Break genuine headroom ties without array-order or harness bias' \
    '`quota-axi` owns how model or product windows relate to bounding account windows'; do
    assert_grep "$phrase" "$AGENTS" "array-dispatch contract lost '$phrase'"
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
  assert_grep '`AGENTS.md` section 4 owns the dispatch and array-selection procedure.' "$CONFIG" \
    "configuration docs do not point to the agent-owned array procedure"
  assert_grep 'quota-axi is required for the' "$BOOTSTRAP" \
    "bootstrap docs lost the quota-axi dependency pointer"
  assert_grep 'agent-owned dispatch-profile array procedure in AGENTS.md section 4.' "$BOOTSTRAP" \
    "bootstrap docs do not point to the agent-owned array procedure"
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

test_session_close_owner_branches_and_hands_off() {
  local stub count
  assert_present "$CLOSE" "session-close skill is missing"
  assert_grep "name: session-close" "$CLOSE" "session-close skill metadata has the wrong name"
  assert_grep "user-invocable: true" "$CLOSE" "session-close must stay captain-invocable"
  assert_grep "  internal: true" "$CLOSE" "session-close must be internal"

  # The close instruction is conditional: an empty fleet closes straight away,
  # live work must pass the handoff first.
  for phrase in \
    'Check whether work is under way in this home' \
    'No work under way means branch 1; anything under way means branch 2.' \
    '## Branch 1 - fleet empty: straight close' \
    'No handoff is needed.' \
    '## Branch 2 - work under way: handoff before close' \
    'Complete every step below before treating the session as closable.'; do
    assert_grep "$phrase" "$CLOSE" "session-close lost the conditional branch phrase '$phrase'"
  done

  # A registered secondmate is a permanent record, so it must not make the
  # straight-close branch unreachable in every secondmate-bearing home.
  assert_grep 'any `state/<id>.meta` for an ordinary task exists' "$CLOSE" \
    "session-close branch check must count only ordinary-task meta records as work under way"
  assert_grep 'A `kind=secondmate` meta record is a permanent registration' "$CLOSE" \
    "session-close lost the secondmate-registration exclusion from the branch check"

  # Away mode is checked before closing on either branch; the away daemon does
  # not survive its pane going away.
  for phrase in \
    '## Away mode at close' \
    'Check for an active `state/.afk` before closing' \
    'That daemon does not recover on its own from a gone target' \
    'Exit away mode through `bin/fm-afk-launch.sh stop`' \
    'Away mode is a separate check that applies on either branch' \
    'An active `state/.afk` also applies on this branch'; do
    assert_grep "$phrase" "$CLOSE" "session-close lost the away-mode close phrase '$phrase'"
  done

  # Running work and how the next session finds it again.
  for phrase in \
    'never stop, tear down, or discard work because the session is ending, and never kill the monitoring' \
    'Events the monitoring captures wait in the durable wake queue' \
    'the next session start reads every task' \
    'Update the backlog for every in-flight and queued item' \
    'tasks-axi hold <id> --reason "<reason>" --kind captain' \
    'Do not invent a separate handoff file or checkpoint document'; do
    assert_grep "$phrase" "$CLOSE" "session-close handoff lost '$phrase'"
  done

  # Lock release: described, never a manual step.
  for phrase in \
    'There is deliberately no manual release step and no unconditional clear command; never hand-delete `state/.lock`' \
    'A numeric owner becomes provably stale when this session' \
    'atomically reclaims the lock on its own' \
    'A codex-thread owner cannot be proven dead from the process table' \
    'the next session may ask them to confirm that window is closed'; do
    assert_grep "$phrase" "$CLOSE" "session-close lock section lost '$phrase'"
  done

  # What the captain is told at close.
  for phrase in \
    'State what is still under way and its current state' \
    'what awaits their decision' \
    'nothing responds to its reports or questions' \
    'State where it resumes: opening the next session replays the queued events'; do
    assert_grep "$phrase" "$CLOSE" "session-close closing summary lost '$phrase'"
  done

  # Close versus /afk stays an explicit contrast, not an alias.
  for phrase in \
    '## Close versus /afk' \
    '`/afk` keeps this session and its supervision live while the captain is away' \
    'Closing ends this session' \
    'offer `/afk` instead of closing'; do
    assert_grep "$phrase" "$CLOSE" "session-close lost the /afk distinction phrase '$phrase'"
  done

  # One owner: AGENTS.md carries a minimal trigger stub only, and no public or
  # neighbouring skill grows a second close procedure.
  count=$(grep -c 'session-close' "$AGENTS")
  [ "$count" -eq 1 ] || fail "AGENTS.md must reference session-close exactly once, found $count"
  stub=$(awk '
    /^### Session-close stub$/ { found = 1; next }
    found && /^### / { exit }
    found && NF { print }
  ' "$AGENTS")
  count=$(printf '%s\n' "$stub" | grep -c .)
  [ "$count" -eq 3 ] || fail "AGENTS.md session-close stub must stay three lines, found $count"
  assert_contains "$stub" 'Load `session-close` when the captain says they are closing or ending the session' \
    "AGENTS.md lost the session-close load trigger"
  assert_contains "$stub" 'never stop, tear down, or unmonitor running work merely because the session is ending' \
    "AGENTS.md session-close stub lost the running-work safety fact"
  assert_contains "$stub" 'away mode keeps supervision live, while closing ends it until the next session start' \
    "AGENTS.md session-close stub lost the /afk contrast"
  assert_absent "$ROOT/skills/session-close/SKILL.md" \
    "session-close must not become a public installer-facing skill"
  assert_no_grep 'closing or ending the session' "$ROOT/.agents/skills/stow/SKILL.md" \
    "stow grew a competing session-close instruction"
  assert_no_grep 'closing or ending the session' "$ROOT/.agents/skills/afk/SKILL.md" \
    "afk grew a competing session-close instruction"
  assert_grep '| `/session-close`' "$ROOT/README.md" \
    "README built-in skills table does not list /session-close"
  assert_grep '".agents/skills/session-close/SKILL.md"' "$ROOT/docs/documentation-audiences.json" \
    "session-close is missing from the documentation audience inventory"
  pass "session-close owns a conditional close with a lock-safe, captain-facing handoff"
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

test_intake_reuses_evidence_and_parallelizes_safe_work() {
  for phrase in \
    'consult existing reports and established evidence' \
    'remaining bounded research inside it' \
    'unresolved uncertainty could materially change whether or what to build' \
    'relay it without a design-only scout' \
    'ask one concise implementation question when useful' \
    'Never both present a likely-enough solution' \
    'overlap as a risk signal rather than an automatic reason to wait' \
    'independently implemented and validated' \
    'selected delivery path can reconcile ordinary rebases or conflicts' \
    'Serialize only for a true semantic dependency' \
    'shared mutable external state' \
    'incompatible concurrent migration' \
    'same-file editing alone is insufficient' \
    'genuine blockers remain durable'; do
    assert_grep "$phrase" "$AGENTS" "intake contract lost '$phrase'"
  done
  assert_grep 'dispatch isolated work immediately with no concurrency cap' "$AGENTS" \
    "intake contract lost unbounded safe parallel dispatch"
  assert_grep 'captain explicitly requests a separate knowledge or design deliverable' "$AGENTS" \
    "intake contract lost captain-requested separate scouts"
  assert_grep 'When implementation is separately authorized, promote the existing scout' "$AGENTS" \
    "intake contract lost genuine scout promotion"
  pass "intake reuses evidence, reserves scouts for uncertainty, and parallelizes safe work"
}

test_compressed_agents_retains_authority_and_supervision_safety() {
  for phrase in \
    'Only a proven `LIVE_OTHER` lock outcome means another active session is managing the fleet and puts this session in read-only mode.' \
    '`STALE_RECLAIMABLE`, `IDENTITY_UNAVAILABLE`, and `RECLAIM_BUSY` are separate outcomes: do not claim another live owner, and do not mutate fleet state until the same session has acquired or atomically reclaimed the lock.' \
    'On `LIVE_OTHER`, the queue is left untouched for the proven live owner, and the guard'\''s tangle/watcher-liveness alarms still print in read-only advisory mode without drain, supervision repair, or checkout repair commands.' \
    'On any other non-owned outcome, the queue is also left untouched without assuming that another session owns it.' \
    'A session that has not acquired or atomically reclaimed the lock must not spawn, steer, merge, drain the wake queue' \
    'A diagnostic request, report, recommendation, or implementation-ready finding is evidence, not authorization to change code.' \
    'The selected delivery path owns its own rigor.' \
    'When no-mistakes is selected, no-mistakes alone owns review, fixes, tests, documentation, push, PR, and CI; otherwise follow the faster path without adding an independent reviewer.' \
    'Never hold work outside no-mistakes for a manual clean verdict, stack serial manual reviews, or infer authority for one from security, architecture, or risk alone.' \
    'A separate review or audit is allowed only when the captain explicitly requests that deliverable or the authorized task is a knowledge-only review; one named question remains scoped to that question.' \
    'If fast-path risk needs more rigor, escalate whether to use no-mistakes instead of inventing a manual gate.' \
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
test_generic_effort_fallback_respects_precedence
test_agent_owned_quota_array_dispatch_contract
test_shared_authoring_requirements_are_owned
test_secondmate_registry_contract_stays_concise
test_session_close_owner_branches_and_hands_off
test_state_startup_and_ordinary_recovery_placement
test_compressed_agents_owner_map
test_intake_reuses_evidence_and_parallelizes_safe_work
test_compressed_agents_retains_authority_and_supervision_safety
