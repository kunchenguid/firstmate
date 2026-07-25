#!/usr/bin/env bash
# Structural regressions for Firstmate's compact always-loaded contract.
# shellcheck disable=SC2016
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
SKILLS="$ROOT/.agents/skills"
HARNESS="$SKILLS/harness-adapters/SKILL.md"
TASK="$SKILLS/task-lifecycle/SKILL.md"
SUPERVISION="$SKILLS/fleet-supervision/SKILL.md"

section() {
  local heading=$1 stop=${2:-}
  awk -v heading="$heading" -v stop="$stop" '
    $0 == heading { found = 1 }
    found && stop != "" && $0 == stop { exit }
    found { print }
  ' "$AGENTS"
}

assert_regex() {
  local text=$1 regex=$2 message=$3
  printf '%s\n' "$text" | grep -Eq -- "$regex" || fail "$message"
}

test_size_ceiling() {
  local bytes
  bytes=$(wc -c < "$AGENTS" | tr -d ' ')
  [ "$bytes" -le 25000 ] || fail "AGENTS.md is $bytes bytes, above the 25000-byte ceiling"
  pass "AGENTS.md stays within the 25000-byte always-loaded ceiling ($bytes bytes)"
}

test_section_structure() {
  local actual expected
  actual=$(grep '^## ' "$AGENTS")
  expected=$(cat <<'EOF'
## 1. Identity and prime directives
## 2. Operational home and durable truth
## 3. Session start and recovery
## 4. Worker and runtime dispatch
## 5. Project and knowledge management
## 6. Intake, delegation, and routing
## 7. Task lifecycle and authority
## 8. Supervision and away mode
## 9. Escalation and captain etiquette
## 10. Backlog contract
## 11. Crewmate briefs
## 12. Skill trigger index
## 13. X mode and self-update
## Maintaining this file
EOF
)
  [ "$actual" = "$expected" ] || fail "AGENTS.md section structure changed without updating the compact-contract review"
  pass "AGENTS.md retains the reviewed section structure"
}

test_always_loaded_safety_surface() {
  local preamble prime startup intake authority supervision etiquette xmode
  preamble=$(awk '/^## 1\./ { exit } { print }' "$AGENTS")
  prime=$(section '## 1. Identity and prime directives' '## 2. Operational home and durable truth')
  startup=$(section '## 3. Session start and recovery' '## 4. Worker and runtime dispatch')
  intake=$(section '## 6. Intake, delegation, and routing' '## 7. Task lifecycle and authority')
  authority=$(section '## 7. Task lifecycle and authority' '## 8. Supervision and away mode')
  supervision=$(section '## 8. Supervision and away mode' '## 9. Escalation and captain etiquette')
  etiquette=$(section '## 9. Escalation and captain etiquette' '## 10. Backlog contract')
  xmode=$(section '## 13. X mode and self-update' '## Maintaining this file')

  assert_regex "$preamble" '^You are the first mate\.$' "identity is not immediately visible"
  assert_regex "$preamble" 'user is the captain' "captain relationship is not immediately visible"
  assert_regex "$preamble" 'Address the user as "captain" at least once in every response' "mandatory captain address is missing"

  for regex in \
    'Never write to a project' \
    'Never merge a PR without authority' \
    'destructive, irreversible, or security-sensitive action' \
    'Never discard unfinished or unlanded work' \
    'Crewmates never address the captain' \
    'Report outcomes faithfully'; do
    assert_regex "$prime" "$regex" "prime directive missing: $regex"
  done
  assert_regex "$prime" 'explicit word.*yolo|yolo.*explicit word' "merge authority and yolo boundary are disconnected"
  assert_regex "$prime" '`--force`.*captain explicitly authorized' "forced discard authority is missing"

  assert_regex "$startup" 'fm-session-start\.sh.*exactly once' "exactly-once session start is missing"
  assert_regex "$startup" 'obey the supervision instructions it emits' "emitted supervision authority is missing"
  assert_regex "$startup" 'remain read-only' "lock-refusal read-only safety is missing"

  assert_regex "$intake" 'secondmate.*scope' "secondmate scope routing is missing"
  assert_regex "$intake" '\*\*ship\*\*.*default' "ship default is missing"
  assert_regex "$intake" '\*\*scout\*\*.*report and no PR' "scout deliverable boundary is missing"
  assert_regex "$intake" 'uncertainty could materially change whether or what to build' "scout uncertainty criterion is missing"
  assert_regex "$intake" 'no concurrency cap' "safe parallel dispatch is missing"
  assert_regex "$intake" 'Serialize only for a real semantic dependency' "safe serialization boundary is missing"

  assert_regex "$authority" 'no-mistakes' "no-mistakes path is missing"
  assert_regex "$authority" 'direct-PR' "direct-PR path is missing"
  assert_regex "$authority" 'local-only' "local-only path is missing"
  assert_regex "$authority" 'within the captain.s original request and accepted task criteria' "bounded standing authority is missing"
  assert_regex "$authority" 'implementation worker never answers its own finding' "ask-user worker boundary is missing"
  assert_regex "$authority" 'fm-pr-merge\.sh.*fm-merge-local\.sh' "guarded landing paths are missing"

  assert_regex "$supervision" 'exactly one live supervision cycle' "one-cycle supervision is missing"
  assert_regex "$supervision" 'No turn ends blind' "no-blind-turn invariant is missing"
  assert_regex "$supervision" 'ordinary.*repair only when the cycle is missing or unhealthy|repair only when the cycle is missing or unhealthy' "ordinary notification and repair are not separated"
  assert_regex "$supervision" 'state/\.afk.*daemon owns supervision' "away-mode supervision ownership is missing"
  assert_regex "$supervision" 'unmarked message means the captain returned' "away-mode return boundary is missing"

  assert_regex "$etiquette" 'translate internal state into the project outcome, consequence, and next decision' "captain-facing translation rule is missing"
  assert_regex "$etiquette" 'Never relay worker reports.*verbatim' "verbatim internal evidence boundary is missing"
  assert_regex "$etiquette" 'Captain, shipshape\.' "exact routine acknowledgement is missing"
  assert_regex "$etiquette" 'full `https://\.\.\.` URL' "full PR URL requirement is missing"

  assert_regex "$xmode" 'inert unless.*FMX_PAIRING_TOKEN' "X opt-in boundary is missing"
  assert_regex "$xmode" 'never destructive, irreversible, or security-sensitive action without trusted-channel confirmation' "X trust boundary is missing"
  pass "always-loaded identity, safety, routing, supervision, and captain semantics remain visible"
}

test_internal_skill_index_is_complete() {
  local skill name count pattern index_names skill_names
  skill_names=$(
    for skill in "$SKILLS"/*/SKILL.md; do
      grep -q '^  internal: true$' "$skill" || continue
      awk '/^name: / { print $2; exit }' "$skill"
    done | LC_ALL=C sort
  )
  index_names=$(
    section '## 12. Skill trigger index' '## 13. X mode and self-update' \
      | awk '/^- `[^`]+` - load / { line=$0; sub(/^- `/, "", line); sub(/`.*/, "", line); print line }' \
      | LC_ALL=C sort
  )
  [ "$index_names" = "$skill_names" ] || {
    printf 'indexed skills:\n%s\ninternal skills:\n%s\n' "$index_names" "$skill_names" >&2
    fail "internal skill index is incomplete or contains an unknown skill"
  }
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    pattern=$(printf -- '- `%s` - load ' "$name")
    count=$(grep -Fc -- "$pattern" "$AGENTS")
    [ "$count" -eq 1 ] || fail "$name has $count trigger entries instead of exactly one"
  done <<< "$skill_names"
  pass "every internal skill has exactly one discoverable load trigger"
}

test_conditional_owners_are_structural() {
  for owner in "$TASK" "$SUPERVISION"; do
    assert_grep 'user-invocable: false' "$owner" "$(basename "$(dirname "$owner")") must remain agent-only"
    assert_grep '  internal: true' "$owner" "$(basename "$(dirname "$owner")") must remain internal"
  done

  for heading in \
    '## Backlog intake' \
    '## Brief and spawn' \
    '## Delivery-path rigor' \
    '## No-mistakes validation' \
    '## PR readiness and landing' \
    '## Ship cleanup' \
    '## Scout completion and promotion'; do
    assert_grep "$heading" "$TASK" "task-lifecycle owner is missing $heading"
  done
  for heading in \
    '## Establish supervision' \
    '## Start every notification turn' \
    '## Handle notification types' \
    '## Cross-cutting completion actions'; do
    assert_grep "$heading" "$SUPERVISION" "fleet-supervision owner is missing $heading"
  done

  [ "$(rg -l 'Firstmate alone resolves a matched profile array' "$ROOT/AGENTS.md" "$SKILLS" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "dispatch array judgment must have exactly one runtime owner"
  assert_grep 'Firstmate alone resolves a matched profile array' "$HARNESS" \
    "harness-adapters does not own quota-array judgment"
  assert_no_grep 'Firstmate alone resolves a matched profile array' "$AGENTS" \
    "AGENTS.md duplicated the conditional quota-array procedure"
  pass "conditional task, supervision, and profile procedures each have one structural owner"
}

test_markdown_safety_style() {
  if grep -q "$(printf '\342\200\224')" "$AGENTS" "$TASK" "$SUPERVISION"; then
    fail "compact runtime instructions contain an em dash"
  fi
  pass "compact runtime instructions use plain dashes"
}

test_size_ceiling
test_section_structure
test_always_loaded_safety_surface
test_internal_skill_index_is_complete
test_conditional_owners_are_structural
test_markdown_safety_style
