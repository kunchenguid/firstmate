#!/usr/bin/env bash
# Behavior tests for the generic war-room skill and its brief templates.
set -u

export LC_ALL=C

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/war-room/SKILL.md"
TEMPLATES="$ROOT/.agents/skills/war-room/templates"
TMP_ROOT=$(fm_test_tmproot fm-skill-war-room)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

test_slice1_canonical_contract() {
  local canonical old_close flake_clause all_text canonical_count flake_count
  local file rules brief expected
  canonical="A joint verdict stays provisional until every contribution the ordering authority required has been answered, or that authority explicitly records a substitute or waiver; a seat that reaches its time limit with a required input pending reports the missing input under the existing paused-vs-blocked rule instead of closing."
  old_close="close only when every seat reports its counts"
  flake_clause="Before a baseline failure is relied on as shared or inherited evidence, re-run that failing oracle on comparable conditions within the declared budget; a pass on re-run marks it flaky, context-dependent, unconfirmed and it never enters shared evidence; a repeated failure is confirmed, not proven deterministic; nothing here waives a red HEAD."

  for file in "$SKILL" "$TEMPLATES/lead.md" "$ROOT/.agents/skills/planning-room/SKILL.md"; do
    assert_no_grep "$old_close" "$file" "old close rule is still present in $file"
  done
  all_text=$(for file in "$SKILL" "$TEMPLATES/lead.md" "$ROOT/.agents/skills/planning-room/SKILL.md"; do sed 's/^- //' "$file" | tr '\n' ' '; printf ' '; done | tr -s ' ')
  canonical_count=$(printf '%s' "$all_text" | grep -F -o "$canonical" | wc -l | tr -d ' ')
  [ "$canonical_count" -eq 1 ] || fail "canonical sentence appears $canonical_count times across the three files"
  assert_grep 'canonical joint-verdict sentence' "$TEMPLATES/lead.md" \
    "lead template does not point to the canonical paragraph"
  assert_grep 'canonical joint-verdict sentence' "$ROOT/.agents/skills/planning-room/SKILL.md" \
    "planning-room does not point to the canonical sentence"
  assert_no_grep "$canonical" "$TEMPLATES/lead.md" \
    "lead template repeats the canonical sentence"
  assert_no_grep "$canonical" "$ROOT/.agents/skills/planning-room/SKILL.md" \
    "planning-room repeats the canonical sentence"
  flake_count=$(printf '%s' "$all_text" | grep -F -o "$flake_clause" | wc -l | tr -d ' ')
  [ "$flake_count" -eq 1 ] || fail "flake clause appears $flake_count times across the three files"

  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" slice1-rules-baseline firstmate --scout \
    >/dev/null 2>&1 || fail "fm-brief.sh failed to generate the Rules baseline"
  brief="$BRIEF_HOME/data/slice1-rules-baseline/brief.md"
  rules="$TMP_ROOT/generated-rules"
  expected="$TMP_ROOT/golden-rules"
  # Capture exactly the Rules section: from its own heading up to, but not
  # including, the next section heading, whichever section that turns out to be.
  awk '/^# Rules$/ {capture=1; print; next} capture && /^# / {exit} capture {print}' \
    "$brief" | sed 's|slice1-rules-baseline.status|access-writer-w1.status|g' > "$rules"
  awk '/^# Rules$/ {capture=1; print; next} capture && /^# / {exit} capture {print}' \
    "$ROOT/tests/fixtures/fm-brief-writer-scout.golden" | \
    sed "s|{{FM_HOME}}|$BRIEF_HOME|g; s|{{FM_ROOT}}|$ROOT|g" > "$expected"
  cmp -s "$expected" "$rules" || fail "generated fm-brief.sh Rules section changed from its baseline"
  pass "war-room slice 1: canonical close, pointer, flake, and generated Rules contracts are present"
}

test_skill_contract() {
  local owner
  assert_present "$SKILL" "war-room skill is missing"
  assert_grep "Ask at program start: MERGE POLICY" "$SKILL" \
    "skill does not ask the merge-policy question at intake"
  assert_grep "human-only merge (the default for company projects such as Artemis)" "$SKILL" \
    "skill is missing the human-only merge option"
  assert_grep "merge on an independent reviewer's literal LGTM at the exact head by a named seat" "$SKILL" \
    "skill is missing the independent-reviewer merge option"
  assert_grep "merge on a driver's merge order executed by the guarded merge script" "$SKILL" \
    "skill is missing the driver-order merge option"
  assert_grep "The skill never merges by itself." "$SKILL" \
    "skill does not state that it never merges"
  assert_grep "root-cause diagnosis" "$SKILL" \
    "skill intake does not name root-cause diagnosis"
  assert_grep "Phase 2 is optional for root-cause diagnosis." "$SKILL" \
    "skill does not make build work optional for diagnosis"
  assert_grep "Read the lane triage in \`data/captain.md\`" "$SKILL" \
    "skill does not reference the lane-triage owner"
  assert_no_grep "class 0 is owner by hand, class 1 is a micro-op, class 2 is a reader scout, class 3 is a ship, and class 4 is a swarm" "$SKILL" \
    "skill duplicates the lane-triage class list"
  assert_grep "Classes 3 and 4 enter the room, and classes 0 through 2 do not." "$SKILL" \
    "skill omits the lane triage boundary"
  for owner in \
    "bin/fm-room.sh" \
    "planning-room" \
    "crewmate-briefing" \
    "bin/fm-brief.sh" \
    "bin/fm-spawn.sh" \
    "bin/fm-send.sh" \
    "captain-hold-lifecycle" \
    "delivery-completion" \
    "harness-adapters"; do
    assert_grep "\`$owner\`" "$SKILL" "skill does not reference $owner as its existing owner"
  done
  pass "war-room: intake, diagnosis, lane, and owner contracts are present"
}

test_templates_fill_and_validate() {
  local template filename id intent brief token expected opening closing
  local templates=(lead.md adversary.md driver.md coder.md researcher.md opinion-seat.md)
  for filename in "${templates[@]}"; do
    template="$TEMPLATES/$filename"
    assert_present "$template" "missing war-room template $filename"
    assert_grep "{JOIN_COMMAND}" "$template" "$filename has no join-command slot"
    assert_grep "{PROGRAM}" "$template" "$filename has no program placeholder"
    assert_grep "{GOAL}" "$template" "$filename has no goal placeholder"
    if ! rg -q '\{[A-Z][A-Z0-9_-]*\}' "$template"; then
      fail "$filename has no {PLACEHOLDER} tokens"
    fi
    id="skill-template-${filename%.md}"
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode direct-PR \
      >/dev/null 2>&1 || fail "fm-brief.sh failed to scaffold $filename"
    intent="$TMP_ROOT/$filename.intent"
    {
      sed -E 's/\{[A-Z][A-Z0-9_-]*\}/filled-value/g' "$template"
    } > "$intent"
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" "$id" --fill "$intent" \
      >/dev/null 2>&1 || fail "fm-brief.sh --fill failed for $filename"
    brief="$BRIEF_HOME/data/$id/brief.md"
    expected="$TMP_ROOT/$filename.expected"
    opening="$TMP_ROOT/$filename.opening"
    closing="$TMP_ROOT/$filename.closing"
    awk 'NF { if (blank) { printf "%s", blank; blank="" } print; next } { blank=blank $0 ORS }' \
      "$intent" > "$expected"
    awk '
      /^# Task$/ { task=1; next }
      task && /^## Captain/ { capture=1; next }
      capture && /^## Firstmate spec$/ { exit }
      capture { print }
    ' "$brief" | awk 'NF { if (blank) { printf "%s", blank; blank="" } print; next } { blank=blank $0 ORS }' > "$opening"
    awk '
      /^# Load-bearing contract$/ { load=1; next }
      load && /^## Captain/ { capture=1; next }
      capture && /^## Firstmate spec$/ { exit }
      capture { print }
    ' "$brief" | awk 'NF { if (blank) { printf "%s", blank; blank="" } print; next } { blank=blank $0 ORS }' > "$closing"
    if ! cmp -s "$expected" "$opening" || ! cmp -s "$expected" "$closing"; then
      fail "$filename did not preserve the complete filled intent in both bookends"
    fi
    for token in $(rg -o '\{[A-Z][A-Z0-9_-]*\}' "$template" | sort -u); do
      if rg -qF "$token" "$brief"; then
        fail "$filename left its $token placeholder in the rendered brief"
      fi
    done
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" --validate-bookends "$brief" \
      >/dev/null 2>&1 || fail "bookend validation failed for $filename"
    pass "war-room: $filename renders through --fill and validates bookends"
  done
}

test_diagnosis_templates() {
  local filename
  for filename in lead.md adversary.md; do
    assert_grep "root-cause diagnosis" "$TEMPLATES/$filename" \
      "$filename does not cover root-cause diagnosis"
  done
  pass "war-room: planning templates cover root-cause diagnosis"
}

test_agents_trigger() {
  local section_13
  section_13=$(awk '/^## 13\./ { capture=1; next } /^## 14\./ { capture=0 } capture { print }' "$ROOT/AGENTS.md")
  assert_contains "$section_13" "\`war-room\` before starting or supervising a reusable program room." \
    "AGENTS.md section 13 does not name the war-room skill"
  pass "war-room: AGENTS.md names the load trigger"
}

test_trigger_hygiene_if_present() {
  local check check_status
  for check in \
    "$ROOT/bin/fm-skill-trigger-hygiene.sh" \
    "$ROOT/tests/fm-skill-trigger-hygiene.test.sh"; do
    [ -f "$check" ] || continue
    if [ -x "$check" ]; then
      check_status=0
      "$check" || check_status=$?
    else
      check_status=0
      bash "$check" || check_status=$?
    fi
    if [ "$check_status" -ne 0 ]; then
      fail "repository skill trigger-hygiene check failed for $check (exit $check_status)"
    fi
    pass "war-room: repository skill trigger-hygiene check passed"
    return 0
  done
  pass "war-room: no repository skill trigger-hygiene check exists"
}

test_skill_contract
test_slice1_canonical_contract
test_templates_fill_and_validate
test_diagnosis_templates
test_agents_trigger
test_trigger_hygiene_if_present
