#!/usr/bin/env bash
# Behavior tests for the fleet prose skills graduated from fleet-lab DEC-001
# (pavani06/fleet-lab experiments/prose-skills, merged 2026-09-20).
#
# The graduation contract: the two vendored skills stay inert to installer
# discovery (user-invocable: false, metadata.internal: true), keep their MIT
# license and upstream attribution with the source commit hashes, keep the
# eval.md self-check that generated briefs point at, and stay declared at
# AGENTS.md section 11, the trigger owner the reference line relies on.
# The tests pin the graduation boundary, not the vendored prose itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

frontmatter() {  # <file>
  awk '/^---$/{n++; next} n==1{print} n==2{exit}' "$1"
}

test_prose_skill_frontmatter_is_internal() {
  local skill file
  for skill in no-ai-slop i-have-adhd; do
    file="$ROOT/.agents/skills/$skill/SKILL.md"
    assert_present "$file" "$skill SKILL.md is missing"
    frontmatter "$file" | grep -q '^user-invocable: false$' \
      || fail "$skill must stay user-invocable: false so installer discovery never adopts it"
    frontmatter "$file" | grep -q 'internal: true' \
      || fail "$skill must carry metadata.internal: true"
    frontmatter "$file" | grep -q '^license: MIT$' \
      || fail "$skill must keep its MIT license field"
  done
  pass "prose-skills: both skills carry the firstmate internal frontmatter"
}

test_prose_skill_attribution_survives() {
  local file
  file="$ROOT/.agents/skills/no-ai-slop/SKILL.md"
  assert_grep 'https://github.com/petergyang/no-ai-slop' "$file" \
    "no-ai-slop lost its upstream source attribution"
  assert_grep '000650b156983f5159695b441477f4e63b25dc85' "$file" \
    "no-ai-slop lost its pinned upstream commit"
  assert_grep 'fleet-lab experiment DEC-001' "$file" \
    "no-ai-slop lost its fleet-lab DEC-001 provenance"
  file="$ROOT/.agents/skills/no-ai-slop/eval.md"
  assert_present "$file" "no-ai-slop eval.md is missing"
  assert_grep 'petergyang/no-ai-slop' "$file" \
    "no-ai-slop eval.md lost its upstream attribution"
  file="$ROOT/.agents/skills/i-have-adhd/SKILL.md"
  assert_grep 'https://github.com/ayghri/i-have-adhd' "$file" \
    "i-have-adhd lost its upstream source attribution"
  assert_grep '839872f9d1cd634fed642b4589ce7226199cc15f' "$file" \
    "i-have-adhd lost its pinned upstream commit"
  assert_grep 'fleet-lab experiment DEC-001' "$file" \
    "i-have-adhd lost its fleet-lab DEC-001 provenance"
  pass "prose-skills: upstream credits, commits, and DEC-001 provenance survive"
}

test_prose_skill_trigger_is_declared_inline() {
  assert_grep '.agents/skills/i-have-adhd/' "$ROOT/AGENTS.md" \
    "AGENTS.md lost the i-have-adhd trigger declaration"
  assert_grep '.agents/skills/no-ai-slop/' "$ROOT/AGENTS.md" \
    "AGENTS.md lost the no-ai-slop trigger declaration"
  pass "prose-skills: the trigger declaration stays declared inline in AGENTS.md"
}

test_prose_skill_owner_line_names_both_skills() {
  local line
  line=$(. "$ROOT/bin/fm-dod-lib.sh" && FM_ROOT="$ROOT" fm_prose_skills_line)
  printf '%s\n' "$line" | grep -q 'i-have-adhd/SKILL.md' \
    || fail "fm_prose_skills_line stopped naming the i-have-adhd skill"
  printf '%s\n' "$line" | grep -q 'no-ai-slop/SKILL.md' \
    || fail "fm_prose_skills_line stopped naming the no-ai-slop skill"
  pass "prose-skills: fm_prose_skills_line still points at both skills"
}

test_prose_skill_frontmatter_is_internal
test_prose_skill_attribution_survives
test_prose_skill_trigger_is_declared_inline
test_prose_skill_owner_line_names_both_skills
