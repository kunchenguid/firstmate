#!/usr/bin/env bash
# Static contract coverage for lean delivery policy owners.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$ROOT/.agents/skills/project-management/SKILL.md"
AGENTS="$ROOT/AGENTS.md"
CONTRIBUTING="$ROOT/CONTRIBUTING.md"

assert_grep '`direct-PR` is the default' "$PROJECT" \
  "new projects do not default to direct-PR"
assert_grep 'explicit project posture' "$PROJECT" \
  "no-mistakes is not documented as opt-in"
assert_grep 'delivery mode to `direct-PR`' "$PROJECT" \
  "new remote projects do not default to direct-PR"

for phrase in \
  'fm-brief.sh --no-mistakes' \
  'Authentication or authorization.' \
  'Tenant isolation or PII or secrets.' \
  'Money or pricing or settlement.' \
  'Database schema or irreversible data migration.' \
  'Production infrastructure or deployment.' \
  'Destructive or irreversible operations.'; do
  assert_grep "$phrase" "$AGENTS" "AGENTS.md is missing lean-delivery policy '$phrase'"
done

assert_no_grep "Ship shared tracked changes through this repo's no-mistakes pipeline" "$AGENTS" \
  "AGENTS.md retained mandatory no-mistakes delivery for shared tracked changes"
assert_grep 'Record the command and outcome under `## Validation`' "$CONTRIBUTING" \
  "contribution guidance lost focused validation evidence"
assert_grep 'do not merge red or pending checks' "$CONTRIBUTING" \
  "contribution guidance lost the CI merge boundary"
assert_absent "$ROOT/.github/workflows/no-mistakes-required.yml" \
  "obsolete no-mistakes signature workflow still exists"
assert_present "$ROOT/.github/workflows/ci.yml" \
  "repository CI workflow was removed"

pass "lean delivery policy owners make direct-PR ordinary and preserve CI"
