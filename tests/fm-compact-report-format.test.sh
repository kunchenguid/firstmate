#!/usr/bin/env bash
# Static regression tests for the compact internal-report contract owned by
# .agents/skills/compact-report-format/SKILL.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/compact-report-format/SKILL.md"
DOC="$ROOT/docs/compact-report-format.md"
AGENTS="$ROOT/AGENTS.md"
BRIEF="$ROOT/bin/fm-brief.sh"
NARRATIVE="$ROOT/docs/examples/compact-report-narrative.md"
COMPACT="$ROOT/docs/examples/compact-report-compact.md"

first_line_of() {  # <needle> <file>
  grep -Fn -- "$1" "$2" | head -1 | cut -d: -f1
}

assert_order() {  # <file> <needle1> <needle2> <msg>
  local file=$1 a=$2 b=$3 msg=$4 la lb
  la=$(first_line_of "$a" "$file")
  lb=$(first_line_of "$b" "$file")
  [ -n "$la" ] || fail "$msg (missing: '$a')"
  [ -n "$lb" ] || fail "$msg (missing: '$b')"
  [ "$la" -lt "$lb" ] || fail "$msg ('$a' at line $la does not precede '$b' at line $lb)"
}

test_skill_declares_single_owner_and_triggers() {
  assert_present "$SKILL" "compact-report-format skill is missing"
  assert_grep "name: compact-report-format" "$SKILL" "skill metadata has the wrong name"
  assert_grep "user-invocable: false" "$SKILL" "skill must not be user-invocable"
  assert_grep "  internal: true" "$SKILL" "skill must be internal"
  assert_grep "Load before writing a report's Definition-of-done content, before reading or relaying a" "$SKILL" \
    "skill metadata lost its precise load trigger"
  assert_grep "single owner of the structured format for a crewmate's internal report artifact" "$SKILL" \
    "skill does not declare itself the owner of the report format"
  pass "compact-report-format skill declares itself the single owner with the required trigger metadata"
}

test_skill_owns_required_sections_in_order() {
  for header in "## Outcome" "## Findings" "## Evidence" "## Verification performed" \
    "## Recommendation" "## Unresolved captain decisions"; do
    assert_grep "$header" "$SKILL" "skill is missing the required section header '$header'"
  done
  assert_order "$SKILL" "## Outcome" "## Findings" "skill section order broken: Outcome must precede Findings"
  assert_order "$SKILL" "## Findings" "## Evidence" "skill section order broken: Findings must precede Evidence"
  assert_order "$SKILL" "## Evidence" "## Verification performed" \
    "skill section order broken: Evidence must precede Verification performed"
  assert_order "$SKILL" "## Verification performed" "## Recommendation" \
    "skill section order broken: Verification performed must precede Recommendation"
  assert_order "$SKILL" "## Recommendation" "## Unresolved captain decisions" \
    "skill section order broken: Recommendation must precede Unresolved captain decisions"
  assert_grep "One finding per compact record" "$SKILL" "skill lost the one-finding-per-record rule"
  assert_grep "key=<slug>" "$SKILL" "skill lost the decision-key convention"
  pass "compact-report-format skill owns every required fixed section in order"
}

test_skill_owns_escape_hatch() {
  for phrase in \
    "a security finding" \
    "an irreversible or destructive action" \
    "a credential or secret exposure" \
    "a legal or compliance concern" \
    "a captain decision whose nuance a one-line record would misrepresent" \
    "Full detail:" \
    "(see Full detail)" \
    "Compact form: not used"; do
    assert_grep "$phrase" "$SKILL" "escape hatch is missing '$phrase'"
  done
  pass "compact-report-format skill owns the full-detail escape hatch and its named risk categories"
}

test_skill_preserves_status_line_protocol() {
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  for verb in '`working:`' '`done:`' '`blocked:`' '`needs-decision:`' '`resolved:`' '`paused:`' '`failed:`'; do
    assert_grep "$verb" "$SKILL" "skill dropped the preserved status verb $verb"
  done
  assert_grep "stay exactly as \`bin/fm-classify-lib.sh\` and the brief scaffold define them, unchanged" "$SKILL" \
    "skill does not state that the status-line protocol is unaffected"
  pass "compact-report-format skill preserves the keyed status-line protocol byte-for-byte"
}

test_skill_preserves_decision_hold_and_self_contained() {
  assert_grep "self-contained-report requirement is unchanged" "$SKILL" \
    "skill dropped the self-contained-report requirement"
  assert_grep "decision-hold-lifecycle completion gate is unchanged" "$SKILL" \
    "skill dropped the decision-hold-lifecycle completion gate"
  assert_grep "not a substitute for running the script" "$SKILL" \
    "skill must not let the written inventory replace bin/fm-decision-hold.sh"
  pass "compact-report-format skill preserves the decision-hold-lifecycle and self-contained-report requirements"
}

test_agents_md_has_one_precise_trigger() {
  local count
  count=$(grep -Fc -- "- \`compact-report-format\` - load before" "$AGENTS")
  [ "$count" -eq 1 ] || fail "compact-report-format must have exactly one AGENTS.md trigger entry, found $count"
  assert_no_grep "## Required sections" "$AGENTS" \
    "AGENTS.md must not restate the skill's fixed-section schema"
  pass "AGENTS.md has exactly one precise trigger for compact-report-format"
}

test_brief_points_to_skill_without_restating() {
  assert_grep "compact-report-format/SKILL.md" "$BRIEF" \
    "scout brief generator does not point crewmates at the compact report contract"
  assert_grep "report.md" "$BRIEF" "scout brief generator lost the report.md deliverable pointer"
  assert_grep "The report must stand alone" "$BRIEF" "scout brief generator lost the stand-alone requirement"
  assert_no_grep "## Required sections" "$BRIEF" \
    "scout brief generator must not restate the skill's fixed-section schema"
  assert_no_grep "Full-detail escape hatch" "$BRIEF" \
    "scout brief generator must not restate the skill's escape-hatch policy"
  pass "scout brief points crewmates at the compact report contract without restating it"
}

test_doc_points_to_skill_and_owns_worked_example() {
  assert_present "$DOC" "compact-report-format doc is missing"
  assert_grep "normative contract is owned by \`.agents/skills/compact-report-format/SKILL.md\`" "$DOC" \
    "doc must point to the skill as the normative owner rather than restating the contract"
  assert_grep "## Worked example" "$DOC" "doc is missing the worked-example section"
  assert_grep "## Measurement methodology" "$DOC" "doc is missing the measurement-methodology section"
  assert_grep "## Verification record" "$DOC" "doc is missing the verification-record section"
  assert_no_grep "## Required sections" "$DOC" "doc must not restate the skill's fixed-section schema"
  pass "compact-report-format doc points to the skill and owns the worked example and verification record"
}

test_fixture_reduction_meets_target() {
  local n1 n2
  assert_present "$NARRATIVE" "narrative fixture is missing"
  assert_present "$COMPACT" "compact fixture is missing"
  n1=$(wc -c < "$NARRATIVE")
  n2=$(wc -c < "$COMPACT")
  awk -v n1="$n1" -v n2="$n2" 'BEGIN { exit !(n1 > 0 && (n1 - n2) / n1 >= 0.40) }' \
    || fail "compact fixture ($n2 bytes) does not reduce narrative fixture ($n1 bytes) by at least 40 percent"
  pass "compact fixture reduces the narrative fixture by at least 40 percent"
}

test_fixture_preserves_semantic_categories() {
  for header in "## Outcome" "## Findings" "## Evidence" "## Verification performed" \
    "## Recommendation" "## Unresolved captain decisions"; do
    assert_grep "$header" "$COMPACT" "compact fixture is missing required section '$header'"
  done
  assert_grep "[key=widget-cache-credential-rotation]" "$COMPACT" \
    "compact fixture lost its unresolved-decision key"
  assert_grep "### Full detail:" "$COMPACT" "compact fixture does not exercise the full-detail escape hatch"
  assert_grep "(see Full detail)" "$COMPACT" "compact fixture does not point from a Findings record to its Full detail block"
  assert_no_grep "## Findings" "$NARRATIVE" \
    "narrative fixture must stay pure prose, not pre-adopt the compact schema"
  for needle in "evictor.py" "config_loader.py" "pytest tests/cache" "40MB"; do
    assert_grep "$needle" "$NARRATIVE" "narrative fixture is missing shared evidence '$needle'"
    assert_grep "$needle" "$COMPACT" "compact fixture is missing shared evidence '$needle'"
  done
  pass "compact fixture preserves every semantic category the narrative fixture has"
}

test_skill_declares_single_owner_and_triggers
test_skill_owns_required_sections_in_order
test_skill_owns_escape_hatch
test_skill_preserves_status_line_protocol
test_skill_preserves_decision_hold_and_self_contained
test_agents_md_has_one_precise_trigger
test_brief_points_to_skill_without_restating
test_doc_points_to_skill_and_owns_worked_example
test_fixture_reduction_meets_target
test_fixture_preserves_semantic_categories
