#!/usr/bin/env bash
# Behavior tests for the fleet prose skills graduated from fleet-lab DEC-001
# (pavani06/fleet-lab experiments/prose-skills, merged 2026-09-20).
#
# One contract: the MIT attribution the vendored copies owe upstream, an
# explicit license text contract rather than a proxy for behavior. That the
# generated briefs carry the prose line is covered end to end in
# tests/fm-brief.test.sh against the real generated artifacts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

test_prose_skill_attribution_survives
