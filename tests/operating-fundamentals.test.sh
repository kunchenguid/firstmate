#!/usr/bin/env bash
# Contract tests for operating fundamentals and related behavioral guardrails.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/operating-fundamentals/SKILL.md"
CREW_SKILL="$ROOT/.agents/skills/crew-steering/SKILL.md"
LAVISH_SKILL="$ROOT/.agents/skills/lavish-decisions/SKILL.md"
AGENTS="$ROOT/AGENTS.md"

test_agent_only_folded_frontmatter_and_size() {
  local frontmatter line_count delimiter_count

  assert_present "$SKILL" "skill missing"
  frontmatter=$(awk 'NR == 1 && $0 == "---" { capture=1; next } capture && $0 == "---" { exit } capture' "$SKILL")
  assert_contains "$frontmatter" "name: operating-fundamentals" "canonical name missing"
  assert_contains "$frontmatter" "description: >-" "folded YAML required"
  assert_contains "$frontmatter" "user-invocable: false" "agent-only required"
  assert_contains "$frontmatter" "metadata:" "metadata missing"
  assert_contains "$frontmatter" "  internal: true" "internal flag missing"
  assert_contains "$frontmatter" "before making or relaying a consequential claim about success, failure, a blocker, or a capability" "claim trigger missing"

  delimiter_count=$(grep -c '^---$' "$SKILL")
  [ "$delimiter_count" -eq 2 ] || fail "invalid frontmatter delimiters"
  line_count=$(wc -l < "$SKILL" | tr -d '[:space:]')
  [ "$line_count" -le 90 ] || fail "skill exceeds the 90-line limit: $line_count"
  pass "operating-fundamentals metadata and size"
}

test_seven_ordered_principles() {
  local headings expected principle_seven contract_text
  headings=$(sed -nE 's/^## ([0-9]+\. .*)$/\1/p' "$SKILL")
  principle_seven=$(awk '/^## 7\./ { capture=1; next } capture && /^## / { exit } capture' "$SKILL")
  contract_text=$(git -C "$ROOT" ls-files 'AGENTS.md' '.agents/**/*.md' | sed "s#^#$ROOT/#" | xargs cat)
  expected=$(printf '%s\n' \
    "1. Orchestrate; never work inline" \
    "2. Saturate every available lane" \
    "3. Route around blockers" \
    "4. Decouple validation from worker budgets" \
    "5. Reap continuously" \
    "6. Obey explicit orders decisively" \
    "7. Prove each consequential claim at the scope you report")
  [ "$headings" = "$expected" ] || fail "seven principles out of order"

  assert_grep "every captain ask" "$SKILL" "intake missing"
  assert_grep "durable backlog item" "$SKILL" "backlog missing"
  assert_grep "tracked crewmate assignment" "$SKILL" "owner missing"
  assert_grep "never perform project investigation, planning, implementation, or deliverable production inline" "$SKILL" "inline ban missing"
  assert_grep "every healthy lane" "$SKILL" "saturation missing"
  assert_grep "blocker as a routing problem" "$SKILL" "routing missing"
  assert_grep "shared validation" "$SKILL" "validation missing"
  assert_grep "single exhaustible budget" "$SKILL" "budget isolation missing"
  assert_grep "On every terminal wake" "$SKILL" "reaping missing"
  assert_grep "Fill released capacity" "$SKILL" "refill missing"
  assert_grep "explicit captain order as the governing objective" "$SKILL" "order priority missing"
  assert_grep "non-overridable safety and instruction constraints" "$SKILL" "safety boundary missing"
  assert_not_contains "$contract_text" "shallowest level" "shallow shortcut remains"
  assert_not_contains "$contract_text" "one load-bearing assumption" "one-assumption shortcut remains"
  for proof in "every leg covered" "neighboring pass" "single failure" "blocks the claim until reproduced and resolved or proven out-of-scope" "unresolved, report observations only" "direct end-to-end evidence" "unverified" "authoritative reference" "materially independent safe in-scope route" "narrowest supported result"; do assert_contains "$principle_seven" "$proof" "missing '$proof'"; done
  for bypass_contract in "target outcome" "critical path" "record the target outcome and critical-path rationale" "operation failing, not noise"; do assert_contains "$principle_seven" "$bypass_contract" "missing '$bypass_contract'"; done
  pass "seven principles preserved"
}

test_single_conditional_agents_trigger() {
  local section blocker_section global_count section_count
  section=$(awk '/^## 13\. Agent-only reference skills$/ { capture=1; next } capture && /^## / { exit } capture' "$AGENTS")
  blocker_section=$(awk '/^## 9\./ { capture=1; next } capture && /^## / { exit } capture' "$AGENTS")
  global_count=$(grep -Fc "\`operating-fundamentals\`" "$AGENTS")
  section_count=$(printf '%s\n' "$section" | grep -Fc "\`operating-fundamentals\`")
  [ "$global_count" -eq 1 ] || fail "duplicate skill reference"
  [ "$section_count" -eq 1 ] || fail "skill route misplaced"
  assert_contains "$section" "before making or relaying a consequential claim about success, failure, a blocker, or a capability" "claim route missing"
  assert_contains "$blocker_section" "applies equally to firstmate-owned and relayed claims" "symmetry missing"
  assert_not_contains "$blocker_section" "directing the crewmate" "old blocker bar remains"
  assert_not_contains "$blocker_section" "get it working through the crewmate first" "old stopping rule remains"
  pass "claim route and blocker symmetry"
}

test_crew_steering_contract_and_trigger() {
  local section headings expected

  assert_present "$CREW_SKILL" "crew-steering SKILL.md is missing"
  assert_grep "name: crew-steering" "$CREW_SKILL" "crew-steering skill is missing its canonical name"
  headings=$(sed -nE 's/^## ([1-6]\. .*)$/\1/p' "$CREW_SKILL")
  expected=$(printf '%s\n' \
    "1. Demand ownership" \
    "2. Reject vague or optimistic claims" \
    "3. Fact-check the load-bearing premise" \
    "4. Prefer quality and robustness" \
    "5. Preserve goal fidelity" \
    "6. Be direct and early")
  [ "$headings" = "$expected" ] || fail "crew-steering must retain all six captain-standard guardrails"

  assert_grep "name the outcome, constraint, evidence, and next action" "$CREW_SKILL" "crew steering must keep briefs and steers proportional"
  assert_grep "expected result, authority boundaries, verification, and definition of done" "$CREW_SKILL" "crew briefs must define their result, scope, proof, and completion bar"
  assert_grep "smallest load-bearing mistake early" "$CREW_SKILL" "live steering must correct the load-bearing mistake early"
  assert_grep "carry the fix through implementation and proof" "$CREW_SKILL" "live steering must require implementation and proof"
  assert_grep "preserve the captain's actual goal" "$CREW_SKILL" "crew steering must preserve the captain's actual goal"
  assert_grep "use the existing owner for detail instead of copying its contract" "$CREW_SKILL" "crew steering must preserve contract ownership"
  assert_grep "solve and implement the task" "$CREW_SKILL" "crews must own both solution and implementation"
  assert_grep "never stops solely because work is hard or failing" "$CREW_SKILL" "crews must not treat difficulty as a stopping condition"
  assert_grep "preserves mandated safety" "$CREW_SKILL" "crew ownership must preserve legitimate safety stops"
  assert_grep "unsafe or non-isolated worktree placement" "$CREW_SKILL" "crew ownership must retain the worktree safety stop"
  assert_grep "exhausts its capability before following the solve-first escalation bar" "$CREW_SKILL" "crew ownership must preserve legitimate blocker escalation"
  assert_grep "Treat \`almost there\` as unfinished" "$CREW_SKILL" "crew steering must reject optimistic partial-completion claims"
  assert_grep "real evidence because work is not done until proven" "$CREW_SKILL" "crew steering must require evidence before completion"
  assert_grep "review adversarially rather than rubber-stamping" "$CREW_SKILL" "crew steering must require adversarial review"
  assert_grep "Reject a shallow-false premise without overcorrecting" "$CREW_SKILL" "premise checking must reject false premises without overreach"
  assert_grep "captain's technical-decision bias" "$CREW_SKILL" "crew steering must apply the captain's quality bar"
  assert_grep "reject preserving a leaky component merely to save development cost or sunk work" "$CREW_SKILL" "crew steering must prefer robustness over development cost or sunk work"
  assert_grep "Reject any quiet reframing of the task into a smaller win" "$CREW_SKILL" "crew steering must reject weakened goals"
  assert_grep "fixed-goal guardrail" "$CREW_SKILL" "crew steering must retain the fixed-goal authority"
  assert_grep "specific, un-bloated briefs and steers" "$CREW_SKILL" "crew steering must remain direct"
  assert_grep "correct a wrong path before it is built" "$CREW_SKILL" "crew steering must correct wrong paths early"
  assert_grep "concrete result the crewmate must produce" "$CREW_SKILL" "a steer must end with the required result"
  assert_grep "evidence that will prove it" "$CREW_SKILL" "a steer must end with required proof"
  assert_grep "next action it should take" "$CREW_SKILL" "a steer must end with the next action"
  assert_grep "Do not add motivational padding, duplicate background, or a second copy of an existing procedure" "$CREW_SKILL" "crew steering must avoid padding and duplicate contracts"

  section=$(awk '/^## 13\. Agent-only reference skills$/ { capture=1; next } capture && /^## / { exit } capture' "$AGENTS")
  assert_contains "$section" "\`crew-steering\` - load before writing or materially revising any crewmate brief and before live-steering a crewmate" "section 13 must trigger crew-steering for briefs and live steers"
  pass "crew-steering retains its behavioral guardrails and conditional trigger"
}

test_live_surface_freshness_contract() {
  assert_grep "reconcile it against live fleet state" "$AGENTS" "captain-facing surfaces must reconcile against live state"
  assert_grep "removing resolved actionable or decision items" "$AGENTS" "serve-fresh removal must cover resolved actionable and decision items"
  assert_grep "Recently Landed section of \`/bearings\` and \`/reports\`" "$AGENTS" "completion-oriented surfaces must retain relevant history"
  assert_grep "Reconcile the proposed decision against live fleet state" "$LAVISH_SKILL" "Lavish decisions must use live fleet state"
  assert_grep "Do not edit \`request.md\` or \`manifest.toon\` after surfacing" "$LAVISH_SKILL" "surfaced decision contracts must be immutable"
  assert_grep "The answer file is authoritative; the wake record is only a pointer" "$LAVISH_SKILL" "durable answers must outrank wake pointers"
  assert_grep "Never start a server, create or share a session URL, poll, long-poll" "$LAVISH_SKILL" "the disqualified served and polling lifecycle must stay prohibited"
  assert_grep "The sole browser exception is \`bin/fm-lavish-board.sh\`" "$LAVISH_SKILL" "the browser allowance must stay limited to the self-contained board wrapper"
  assert_grep "before creating, repairing, or presenting a multi-option captain choice" "$LAVISH_SKILL" "Lavish frontmatter must trigger when presenting a choice"
  assert_grep "load before creating, repairing, or presenting a multi-option captain choice" "$AGENTS" "AGENTS must route presenting a choice through Lavish"
  pass "live-surface freshness preserves completion history and in-progress answers"
}

test_provider_neutral_and_no_maintenance_boilerplate() {
  if grep -Eiq 'Claude|Codex|OpenAI|Anthropic|Gemini|Grok|Orca|Herdr|tmux|zellij|cmux|AWS|GitHub|provider|account' "$SKILL"; then
    fail "skill contains a named provider, harness, account, or incident-specific dependency"
  fi
  if grep -Eiq 'https?://|@[[:alnum:]_.-]+|[[:xdigit:]]{8}-[[:xdigit:]-]{27,}' "$SKILL"; then
    fail "skill contains an incident-specific URL, address, or identifier"
  fi
  if grep -Eiq 'maintain|maintenance|when updating|keep this file|for maintainers' "$SKILL"; then
    fail "skill contains maintenance boilerplate"
  fi
  pass "operating-fundamentals stays provider-neutral and omits incident and maintenance detail"
}

test_agent_only_folded_frontmatter_and_size
test_seven_ordered_principles
test_single_conditional_agents_trigger
test_crew_steering_contract_and_trigger
test_live_surface_freshness_contract
test_provider_neutral_and_no_maintenance_boilerplate
