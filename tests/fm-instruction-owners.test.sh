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
WATCH="$ROOT/.agents/skills/watch/SKILL.md"
WATCH_LICENSE="$ROOT/.agents/skills/watch/LICENSE"
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

# The watch skill is vendored third-party material, so its redistribution terms and
# its upstream base must survive every future edit or an upstream refresh becomes
# guesswork. It is captain-invocable, so its trigger belongs in an operating
# section rather than the agent-only reference list.
test_vendored_watch_skill_keeps_license_and_upstream_pin() {
  local count script trigger pycache
  assert_present "$WATCH" "vendored watch skill is missing"
  assert_present "$WATCH_LICENSE" "vendored watch skill lost its upstream LICENSE"
  assert_grep 'MIT License' "$WATCH_LICENSE" "vendored watch LICENSE is no longer the upstream MIT terms"
  assert_grep 'name: watch' "$WATCH" "watch skill metadata has the wrong name"
  assert_grep 'user-invocable: true' "$WATCH" "watch skill must stay captain-invocable"
  assert_grep '  internal: true' "$WATCH" "watch skill must be internal"
  assert_grep '  vendored-from: "bradautomates/claude-video@' "$WATCH" \
    "watch skill lost the upstream commit pin a refresh diffs against"
  assert_grep 'To refresh: re-copy upstream skills/watch' "$WATCH" \
    "watch skill lost the vendoring banner's refresh procedure"
  # The refresh path is a re-copy from upstream, so a truncated or partial copy is
  # a realistic failure that would otherwise surface only when /watch next runs.
  # Parsing is checked instead of content so a legitimate refresh still passes.
  pycache=$(fm_test_tmproot fm-watch-pycompile)
  for script in watch.py frames.py transcribe.py whisper.py download.py setup.py config.py; do
    assert_present "$ROOT/.agents/skills/watch/scripts/$script" \
      "vendored watch skill is missing scripts/$script"
    PYTHONPYCACHEPREFIX="$pycache" python3 -m py_compile \
      "$ROOT/.agents/skills/watch/scripts/$script" ||
      fail "vendored watch scripts/$script does not parse - the upstream re-copy is truncated or partial"
  done
  [ -x "$ROOT/.agents/skills/watch/scripts/watch.py" ] || fail "scripts/watch.py is not executable"
  assert_grep 'brew install ffmpeg yt-dlp' "$WATCH" \
    "watch banner lost the macOS unattended-install disclosure"
  assert_grep 'AUDIO EGRESS:' "$WATCH" \
    "watch banner lost the third-party transcription upload disclosure"
  assert_grep 'KEY-SOURCE TRAP, DELIBERATELY NOT PATCHED:' "$WATCH" \
    "watch banner lost the working-directory .env key-source trap note"
  count=$(grep -Fc -- 'Load the `watch` skill' "$AGENTS")
  [ "$count" -eq 1 ] || fail "watch must have exactly one AGENTS.md trigger line, found $count"
  trigger=$(grep -F -- 'Load the `watch` skill' "$AGENTS")
  case "$trigger" in
    *"consent before that first run"*) ;;
    *) fail "the watch trigger line lost its first-run install and audio-egress consent gate" ;;
  esac
  assert_no_grep '- `watch` -' "$AGENTS" \
    "captain-invocable watch must not be listed among the agent-only reference skills"
  pass "vendored watch skill keeps its license, upstream pin, consent gate, and single trigger"
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
    'inspectable real headroom including quota-window pace' \
    'if any harness/model/provider relationship, applicable quota data, or interpretation cannot be established, stop and report that candidate' \
    'instead of omitting it, guessing, falling back, or calling the result quota-informed' \
    'Preserve malformed profile configuration as an actionable error' \
    "preserve the captain's strongest-reasoning class rather than silently downgrading it" \
    'Break genuine headroom ties without array-order or harness bias' \
    '`quota-axi` owns how model or product windows relate to bounding account windows' \
    'remains data-only' \
    'Load `quota-array-dispatch` before choosing among a matched profile array'; do
    assert_grep "$phrase" "$AGENTS" "array-dispatch contract lost '$phrase'"
  done

  for phrase in \
    '| claude | Open the current interactive session' \
    '| codex | Open the current interactive session' \
    '| opencode | Run `opencode models [provider]`' \
    '| pi / pi-signed | Run the selected executable as `<executable> --list-models [search]`' \
    '| grok | Run `grok models`' \
    "For an unfamiliar harness or model namespace, establish support and provider identity from that harness's authoritative CLI help, model listing, or current documentation rather than guessing" \
    'If those sources do not establish the relationship needed for dispatch, fail loudly and report the unresolved candidate.'; do
    assert_grep "$phrase" "$HARNESS" "model discovery guidance lost '$phrase'"
  done
  assert_grep 'not as a permanent namespace or provider mapping' "$HARNESS" \
    "model discovery guidance permits a fixed provider table"
  assert_grep 'load `quota-array-dispatch` for the pace-aware candidate choice' "$HARNESS" \
    "harness-adapters lost the quota-array-dispatch handoff"
  assert_grep '`quota-array-dispatch` owns the pace-aware profile-array selection procedure' "$CONFIG" \
    "configuration docs do not point to quota-array-dispatch"
  assert_grep 'quota-axi is required for the' "$BOOTSTRAP" \
    "bootstrap docs lost the quota-axi dependency pointer"
  assert_grep 'agent-owned dispatch-profile array procedure in AGENTS.md section 4' "$BOOTSTRAP" \
    "bootstrap docs do not point to the agent-owned array procedure"
  assert_grep 'quota-array-dispatch/SKILL.md' "$BOOTSTRAP" \
    "bootstrap docs do not point to quota-array-dispatch"
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
    'A lock-refused session must not spawn, steer, merge, drain the wake queue' \
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
test_vendored_watch_skill_keeps_license_and_upstream_pin
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
