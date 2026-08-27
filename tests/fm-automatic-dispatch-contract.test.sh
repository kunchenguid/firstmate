#!/usr/bin/env bash
# Contract for the conditional automatic-dispatch procedure and its load trigger.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/automatic-dispatch/SKILL.md"

assert_grep 'automatic-dispatch' "$ROOT/AGENTS.md" 'AGENTS does not load the routing procedure'
assert_grep 'taskClass' "$SKILL" 'skill does not define classification output'
assert_grep 'independent reviewer from a different provider' "$SKILL" 'high-risk review rule is missing'
assert_grep 'never include prompts, source code, credentials' "$SKILL" 'privacy boundary is missing'
assert_grep 'visible policy diagnostic' "$SKILL" 'invalid policy diagnostic is missing'
assert_grep 'static dispatch' "$SKILL" 'invalid policy fallback is missing'
assert_grep 'no optimization state mutation' "$SKILL" 'invalid policy mutation boundary is missing'
assert_grep 'Do not call `fm-route.sh select`, `observe`, `reserve`' "$SKILL" 'invalid policy terminal boundary is missing'
assert_grep 'symbolic account is absent' "$SKILL" 'missing native account rule is missing'
assert_grep 'qualified Pi' "$SKILL" 'Pi continuation rule is missing'
assert_grep 'reserve' "$SKILL" 'reservation step is missing'
assert_grep 'before calling `fm-spawn.sh`' "$SKILL" 'reserve-before-spawn order is missing'
assert_grep 'call `fm-route.sh observe`' "$SKILL" 'simulation observation is missing'
assert_grep 'launch nothing' "$SKILL" 'simulation no-launch boundary is missing'
assert_grep 'stop immediately on unsafe or uncertain writes' "$SKILL" 'unsafe write stop is missing'
assert_grep 'quota-array-dispatch' "$SKILL" 'quota interpretation owner is missing'
assert_grep 'authoritative catalog' "$SKILL" 'catalog ownership is missing'
assert_grep 'Do not add subtask lists' "$SKILL" 'strict request schema boundary is missing'
assert_grep 'automatic-dispatch' "$ROOT/.agents/skills/quota-array-dispatch/SKILL.md" 'quota skill does not cross-reference routing ownership'

frontmatter=$(sed -n '2,/^---$/p' "$SKILL")
assert_contains "$frontmatter" 'name: automatic-dispatch' 'skill frontmatter name is invalid'
assert_contains "$frontmatter" 'description:' 'skill frontmatter description is missing'
if grep -Eq '\{[A-Z][A-Z_]*\}|TODO|TBD' "$SKILL"; then
  fail 'skill contains unfinished placeholders'
fi
words=$(wc -w < "$SKILL" | tr -d ' ')
[ "$words" -le 500 ] || fail "skill exceeds 500-word discipline: $words"

pass 'automatic dispatch procedure preserves routing and safety ownership'
