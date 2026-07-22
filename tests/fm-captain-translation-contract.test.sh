#!/usr/bin/env bash
# Static regression tests for the Jay-facing plain-English translation
# contract owned by AGENTS.md section 9.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
BOOTSTRAP="$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md"
AFK="$ROOT/.agents/skills/afk/SKILL.md"
DECISION="$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md"
RECOVERY="$ROOT/.agents/skills/stuck-crewmate-recovery/SKILL.md"
HARNESS="$ROOT/.agents/skills/harness-adapters/SKILL.md"
CODEXAPP="$ROOT/.agents/skills/firstmate-codexapp/SKILL.md"
FMX="$ROOT/.agents/skills/fmx-respond/SKILL.md"
UPDATE="$ROOT/.agents/skills/updatefirstmate/SKILL.md"
PROJECT_MANAGEMENT="$ROOT/.agents/skills/project-management/SKILL.md"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
AFK_LAUNCH="$ROOT/bin/fm-afk-launch.sh"
HERDR_BACKEND="$ROOT/bin/backends/herdr.sh"

section_9() {
  awk '
    /^## 9\. Escalation and communication with Jay$/ { found = 1 }
    found && /^## 10\. / { exit }
    found { print }
  ' "$AGENTS"
}

test_identity_and_natural_address_contract() {
  assert_grep "Navi is Jay's helper and guide through the digital world." "$AGENTS" \
    "AGENTS.md does not establish Navi's identity"
  assert_grep 'Refer to the user as Jay whenever a direct name or form of address is useful, and never call Jay "captain."' "$AGENTS" \
    "AGENTS.md does not establish the natural-address rule"
  assert_grep "Do not force Jay's name into every message." "$AGENTS" \
    "AGENTS.md does not prohibit forced direct address"
  assert_not_contains "$(cat "$AGENTS")" 'Address the user as "captain"' \
    "AGENTS.md retains the old mandatory captain address"
  pass "AGENTS.md establishes Navi's identity and Jay's natural-address rule"
}

test_user_facing_identity_surfaces_use_jay_language() {
  local bearings decision fmx afk_return project_management teardown afk_launch herdr_backend
  bearings=$(cat "$ROOT/.agents/skills/bearings/SKILL.md")
  decision=$(sed 's/captain-held//g' "$DECISION")
  fmx=$(cat "$FMX")
  afk_return=$(cat "$ROOT/bin/fm-afk-return.sh")
  project_management=$(cat "$PROJECT_MANAGEMENT")
  teardown=$(cat "$TEARDOWN")
  afk_launch=$(cat "$AFK_LAUNCH")
  herdr_backend=$(cat "$HERDR_BACKEND")
  assert_not_contains "$bearings" "Captain's Call" \
    "Bearings retains the old user-facing heading"
  assert_contains "$bearings" "**Your Call**" \
    "Bearings lacks the Jay-facing decision heading"
  assert_not_contains "$decision" "captain" \
    "decision lifecycle prose still calls Jay captain"
  assert_not_contains "$fmx" "captain" \
    "X-mode prose still calls Jay captain"
  assert_not_contains "$afk_return" "ordinary captain work" \
    "away-return output still calls Jay captain"
  assert_not_contains "$afk_return" "the captain request" \
    "away-return output still calls Jay captain"
  assert_not_contains "$project_management" "captain" \
    "project-management instructions still call Jay captain"
  assert_not_contains "$teardown" "the captain's explicit OK" \
    "teardown output still calls Jay captain"
  assert_not_contains "$teardown" "the captain approves" \
    "teardown approval output still calls Jay captain"
  assert_not_contains "$afk_launch" 'fm_afk_launch_log "could not resolve the captain' \
    "away-launch resolution output still calls Jay captain"
  assert_not_contains "$afk_launch" 'fm_afk_launch_log "cannot derive herdr session from captain target' \
    "away-launch target output still calls Jay captain"
  assert_not_contains "$herdr_backend" 'echo "warning: herdr presentation cleanup target is the captain' \
    "Herdr cleanup output still calls Jay captain"
  pass "user-facing identity surfaces consistently use Jay language"
}

test_complete_instruction_and_document_surface_uses_jay_language() {
  local residue
  residue=$(
    git grep -n -i captain -- \
      AGENTS.md README.md CONTRIBUTING.md .agents/skills skills docs bin 2>/dev/null \
      | awk -F: '{
          text = $0
          sub(/^[^:]*:[0-9]+:/, "", text)
          if ($1 !~ /^bin\// || text !~ /^[[:space:]]*#/) print
        }' \
      | sed \
        -e 's/[[:alnum:]_]*_captain[[:alnum:]_]*/ /Ig' \
        -e 's/[[:alnum:]_]*captain_[[:alnum:]_]*/ /Ig' \
        -e 's/captain-shared\.md//Ig' \
        -e 's/\.fm-captain-shared//Ig' \
        -e 's/captain\.md//Ig' \
        -e 's/shared-captain//Ig' \
        -e 's/captain-held//Ig' \
        -e 's/captain_decision//Ig' \
        -e 's/captain-hold//Ig' \
        -e 's/captain-relevant//Ig' \
        -e 's/FM_CAPTAIN_RE//g' \
        -e 's/FM_SHARED_CAPTAIN_FILE//g' \
        -e 's/--kind captain//Ig' \
        -e 's/kind `captain`//Ig' \
        -e 's/kind captain//Ig' \
        -e 's/hold-kind: `captain`//Ig' \
        -e 's/hold-kind: captain//Ig' \
        -e 's/= captain/= /Ig' \
        -e 's/hold_kind == "captain"//Ig' \
        -e 's/hold_kind != "captain"//Ig' \
        -e 's/kind == "captain"//Ig' \
        -e 's/kind != "captain"//Ig' \
        -e 's/\.kind == "captain"//Ig' \
        -e 's/\.kind != "captain"//Ig' \
        -e 's/\.hold_kind == "captain"//Ig' \
        -e 's/\.hold_kind != "captain"//Ig' \
        -e 's/"captain"//Ig' \
        -e "s/'captain'//Ig" \
        -e 's/`captain` file//Ig' \
        -e 's/never call Jay "captain\."//Ig' \
        -e 's/`ABSENT` `captain`//Ig' \
      | grep -i captain || true
  )
  [ -z "$residue" ] || fail "user-facing instruction or documentation prose still calls Jay captain: $residue"
  pass "complete instruction and documentation surface uses Jay language"
}

test_section_9_owns_positive_translation_contract() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "Every message to Jay must translate internal state into the project outcome, consequence, and next decision." \
    "section 9 does not own the positive Jay-facing translation contract"
  assert_contains "$contract" "Use plain-language nouns Jay will recognize:" \
    "section 9 does not require familiar plain-language nouns"
  assert_contains "$contract" "When evidence uses an internal label, rewrite it before sending:" \
    "section 9 does not own the rewrite mapping list"
  pass "section 9 owns the positive Jay-facing translation contract"
}

test_scout_remains_allowed_house_vocabulary() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "Scout and second mate are accepted Firstmate nautical house vocabulary and do not need translation" \
    "section 9 does not preserve scout as allowed Firstmate vocabulary"
  assert_not_contains "$contract" "scout -> investigation" \
    "section 9 must not map scout to investigation"
  assert_not_contains "$contract" "scout, ship" \
    "section 9 must not add scout to the internal-vocabulary ban"
  assert_not_contains "$contract" "secondmate -> domain supervisor" \
    "section 9 must not map secondmate to domain supervisor"
  pass "scout remains allowed in private chat with Jay"
}

test_compressed_safety_labels_have_plain_renderings() {
  local contract
  contract=$(section_9)
  for phrase in \
    "fail-closed" \
    "fails closed" \
    "fail-open" \
    "fails open" \
    "fail loudly"; do
    assert_contains "$contract" "$phrase" "section 9 does not cover compressed safety label '$phrase'"
  done
  assert_contains "$contract" "stops safely when something goes wrong" \
    "fail-closed behavior lacks a concrete plain rendering"
  assert_contains "$contract" "refuses rather than proceeding" \
    "fail-closed behavior lacks refusal wording"
  assert_contains "$contract" "steps aside and lets work continue when the check cannot complete" \
    "fail-open behavior lacks a concrete plain rendering"
  pass "compressed safety labels require concrete plain renderings"
}

test_mapping_list_covers_high_risk_internal_families() {
  local contract
  contract=$(section_9)
  for phrase in \
    "worktree, checkout, primary checkout, or local-main -> local copy" \
    "teardown -> cleanup" \
    "wake, watcher, heartbeat, stale, signal, or check -> notification" \
    "hold, gate, ask-user, needs-decision, blocked, or paused -> the concrete decision" \
    "done, failed, fix-review, checks-passed, cancelled, validation step, or pipeline state -> the concrete result" \
    "brief -> instructions" \
    "crewmate -> worker" \
    "harness, backend, runtime, or adapter -> worker runtime or tool" \
    "status file, metadata, state, task id, or raw path -> durable record"; do
    assert_contains "$contract" "$phrase" "section 9 mapping list is missing '$phrase'"
  done
  pass "section 9 maps high-risk internal vocabulary families"
}

test_verbatim_internal_evidence_is_rejected_from_chat() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "Never relay worker reports, status lines, tool output, validation-state labels, or decision records verbatim into messages to Jay." \
    "section 9 does not reject verbatim internal evidence in messages to Jay"
  assert_contains "$contract" "Private evidence reports may retain exact identifiers, paths, status lines, validation labels, and internal terms" \
    "section 9 does not preserve private evidence precision"
  assert_contains "$contract" "the summary for Jay that points to the report still follows this translation rule" \
    "section 9 does not keep chat summaries plain English"
  pass "messages to Jay reject verbatim internal evidence while private reports stay precise"
}

test_outward_facing_skill_points_reference_section_9_owner() {
  assert_grep "using \`AGENTS.md\` section 9's communication contract" "$BOOTSTRAP" \
    "bootstrap diagnostics do not reference section 9 at Jay handoff"
  assert_grep "Acknowledge** in \`AGENTS.md\` section 9 language" "$AFK" \
    "afk acknowledgement does not reference section 9"
  assert_grep "Jay, away mode is active; I will batch routine updates" "$AFK" \
    "afk acknowledgement lacks a local plain-English example"
  assert_grep "as decisions from Bearings' Your Call section under \`AGENTS.md\` section 9" "$DECISION" \
    "decision relay does not reference section 9"
  assert_grep "using \`AGENTS.md\` section 9; do not mention metadata, harness, window, or worktree" "$RECOVERY" \
    "stuck-worker failure does not reference section 9"
  assert_grep "under \`AGENTS.md\` section 9 that the requested worker runtime is not verified yet" "$HARNESS" \
    "runtime fallback does not reference section 9"
  assert_grep "use firstmate's own verified runtime for current work" "$HARNESS" \
    "runtime fallback does not require the current-work fallback"
  assert_grep "Do not pause current work for that future-verification choice, and never launch an unverified adapter." "$HARNESS" \
    "runtime fallback permits waiting on future verification or launching an unverified adapter"
  assert_grep "translate status prefixes and return-channel evidence through \`AGENTS.md\` section 9" "$CODEXAPP" \
    "Codex Desktop result reporting does not reference section 9"
  assert_grep "It supplements \`AGENTS.md\` section 9; apply both, and this public-channel rule wins wherever it is stricter." "$FMX" \
    "X reply safety does not state that it supplements section 9"
  assert_grep "under \`AGENTS.md\` section 9 without firstmate's internal vocabulary" "$UPDATE" \
    "Firstmate update reporting does not reference section 9"
  pass "outward-facing skill handoffs point to the section 9 owner"
}

test_section_9_owner_is_not_duplicated_into_skills() {
  local duplicate_count file
  duplicate_count=0
  for file in "$BOOTSTRAP" "$AFK" "$DECISION" "$RECOVERY" "$HARNESS" "$CODEXAPP" "$UPDATE"; do
    if grep -Fq "When evidence uses an internal label, rewrite it before sending:" "$file"; then
      duplicate_count=$((duplicate_count + 1))
    fi
  done
  [ "$duplicate_count" -eq 0 ] || fail "skills duplicated section 9's mapping owner"
  pass "skills cross-reference section 9 instead of duplicating the mapping list"
}

test_identity_and_natural_address_contract
test_user_facing_identity_surfaces_use_jay_language
test_complete_instruction_and_document_surface_uses_jay_language
test_section_9_owns_positive_translation_contract
test_scout_remains_allowed_house_vocabulary
test_compressed_safety_labels_have_plain_renderings
test_mapping_list_covers_high_risk_internal_families
test_verbatim_internal_evidence_is_rejected_from_chat
test_outward_facing_skill_points_reference_section_9_owner
test_section_9_owner_is_not_duplicated_into_skills
