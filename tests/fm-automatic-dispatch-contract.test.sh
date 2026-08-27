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
assert_grep "Do not call \`fm-route.sh select\`, \`observe\`, \`reserve\`" "$SKILL" 'invalid policy terminal boundary is missing'
off_branch="With valid version 2 mode \`off\`, automatic-dispatch uses configured static dispatch and stops before account/candidate resolution, \`select\`, \`observe\`, \`reserve\`, or any routing ledger/state mutation."
assert_grep "$off_branch" "$SKILL" 'valid off mode terminal branch is missing or incomplete'
off_line=$(grep -nF "$off_branch" "$SKILL" | head -n 1 | cut -d: -f1)
candidate_line=$(grep -nF 'Resolve native symbolic accounts' "$SKILL" | head -n 1 | cut -d: -f1)
[ -n "$off_line" ] && [ -n "$candidate_line" ] && [ "$off_line" -lt "$candidate_line" ] \
  || fail 'valid off mode must terminate before candidate resolution'
assert_grep 'symbolic account is absent' "$SKILL" 'missing native account rule is missing'
assert_grep 'qualified Pi' "$SKILL" 'Pi continuation rule is missing'
simulate_branch="With valid simulation mode, call \`fm-route.sh observe\` after selection, launch nothing, and stop before reserve/spawn."
assert_grep "$simulate_branch" "$SKILL" 'valid simulation terminal branch is missing or incomplete'
simulate_line=$(grep -nF "$simulate_branch" "$SKILL" | head -n 1 | cut -d: -f1)
select_line=$(grep -nF "Call \`fm-route.sh select --request FILE --candidates FILE\`" "$SKILL" | head -n 1 | cut -d: -f1)
reserve_line=$(grep -nF 'Process each ready slot transactionally as select -> reserve' "$SKILL" | head -n 1 | cut -d: -f1)
first_simulate_line=$(grep -nF 'simulation' "$SKILL" | head -n 1 | cut -d: -f1)
[ -n "$simulate_line" ] && [ -n "$select_line" ] && [ -n "$reserve_line" ] \
  && [ "$simulate_line" -gt "$select_line" ] && [ "$simulate_line" -lt "$reserve_line" ] \
  && [ "$first_simulate_line" = "$simulate_line" ] \
  || fail 'valid simulation must select then observe and stop before reserve/spawn'
assert_grep 'stop immediately on unsafe or uncertain writes' "$SKILL" 'unsafe write stop is missing'
assert_grep 'quota-array-dispatch' "$SKILL" 'quota interpretation owner is missing'
assert_grep 'authoritative catalog' "$SKILL" 'catalog ownership is missing'
assert_grep 'Do not add subtask lists' "$SKILL" 'strict request schema boundary is missing'
assert_grep 'automatic-dispatch' "$ROOT/.agents/skills/quota-array-dispatch/SKILL.md" 'quota skill does not cross-reference routing ownership'

assert_grep "Every independent subtask gets a unique bounded \`taskId\`, a fresh route generation, its own exact normalized request with its own \`workType\`, and its own \`fm-route.sh select\` call." "$SKILL" 'independent subtasks can share routing identity or selection'
assert_grep "\`maxWorkers\` is only a concurrency ceiling; never reuse one selection for another subtask." "$SKILL" 'worker ceiling can be mistaken for reusable selection authority'
assert_grep "Call \`fm-route.sh select --request FILE --candidates FILE\` for that subtask only." "$SKILL" 'selector command shape is not executable'
assert_grep "Reserve with \`fm-route.sh reserve --task TASK --generation GENERATION --profile PROFILE --provider PROVIDER --lane LANE --account ACCOUNT --class CLASS --work-type WORK_TYPE --risk RISK --mode MODE --request REQUEST.json --candidates CANDIDATES.json --decision DECISION.json\`." "$SKILL" 'reservation command shape is not executable'
assert_grep "Any stale decision or policy change means stop and re-evaluate" "$SKILL" 'reservation does not fail closed on stale selector evidence'
assert_grep 'Pass the selected policy' "$SKILL" 'spawn does not carry the selected policy launch identity'
for launch_field in harness model effort; do
  assert_grep "\`--$launch_field" "$SKILL" "policy-bound spawn omits --$launch_field"
done
assert_grep 'Process each ready slot transactionally as select -> reserve -> immediately spawn before routing the next ready slot; never bulk-reserve slots for later spawn.' "$SKILL" 'slot admission is not transactionally ordered'
for route_field in generation profile provider lane account class work-type risk mode; do
  assert_grep "\`--route-$route_field\`" "$SKILL" "complete routed spawn tuple omits --route-$route_field"
done
assert_grep 'On reserve or spawn failure, use the existing exact abort cleanup or release for that task and generation, then stop and re-evaluate every remaining unspawned slot.' "$SKILL" 'failed slot cleanup can leak or stale later reservations'
assert_grep "A high-risk reviewer is a distinct review subtask with its own \`taskId\`, generation, request, selection, and \`workType=review\`; the independent reviewer from a different provider than every implementer becomes ready only after reviewable implementation artifacts exist." "$SKILL" 'review can reuse implementation lifecycle identity'

frontmatter=$(sed -n '2,/^---$/p' "$SKILL")
assert_contains "$frontmatter" 'name: automatic-dispatch' 'skill frontmatter name is invalid'
assert_contains "$frontmatter" 'description:' 'skill frontmatter description is missing'
if grep -Eq '\{[A-Z][A-Z_]*\}|TODO|TBD' "$SKILL"; then
  fail 'skill contains unfinished placeholders'
fi
words=$(wc -w < "$SKILL" | tr -d ' ')
[ "$words" -lt 500 ] || fail "skill must stay below 500 words: $words"

pass 'automatic dispatch procedure preserves routing and safety ownership'
