#!/usr/bin/env bash
# Structural regressions for Firstmate's slim always-loaded operating index.
# shellcheck disable=SC2016
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
SKILLS="$ROOT/.agents/skills"
HARNESS="$SKILLS/harness-adapters/SKILL.md"
TASK="$SKILLS/task-lifecycle/SKILL.md"
SUPERVISION="$SKILLS/fleet-supervision/SKILL.md"
CAPTAIN="$SKILLS/captain-communication/SKILL.md"
DELIVERY="$SKILLS/delivery-quality/SKILL.md"

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
  [ "$bytes" -le 17000 ] || fail "AGENTS.md is $bytes bytes, above the 17000-byte operating-index ceiling"
  pass "AGENTS.md remains a slim always-loaded operating index ($bytes bytes)"
}

test_section_structure() {
  local actual expected
  actual=$(grep '^## ' "$AGENTS")
  expected=$(cat <<'EOF'
## 1. Identity and hard boundaries
## 2. Layout and state ownership
## 3. Session start
## 4. Dispatch and worker runtimes
## 5. Recovery
## 6. Project, second-mate, and knowledge routing
## 7. Task intake, delivery, and authority
## 8. Supervision and away mode
## 9. Captain communication
## 10. Backlog
## 11. Task instructions
## 12. Self-update
## 13. Exact skill triggers
## 14. X mode
## Maintaining this file
EOF
)
  [ "$actual" = "$expected" ] || fail "AGENTS.md section structure changed without updating the operating-index review"
  pass "AGENTS.md retains the reviewed fourteen-section index"
}

test_always_loaded_boundaries() {
  local preamble hard startup dispatch recovery routing delivery supervision communication xmode
  preamble=$(awk '/^## 1\./ { exit } { print }' "$AGENTS")
  hard=$(section '## 1. Identity and hard boundaries' '## 2. Layout and state ownership')
  startup=$(section '## 3. Session start' '## 4. Dispatch and worker runtimes')
  dispatch=$(section '## 4. Dispatch and worker runtimes' '## 5. Recovery')
  recovery=$(section '## 5. Recovery' '## 6. Project, second-mate, and knowledge routing')
  routing=$(section '## 6. Project, second-mate, and knowledge routing' '## 7. Task intake, delivery, and authority')
  delivery=$(section '## 7. Task intake, delivery, and authority' '## 8. Supervision and away mode')
  supervision=$(section '## 8. Supervision and away mode' '## 9. Captain communication')
  communication=$(section '## 9. Captain communication' '## 10. Backlog')
  xmode=$(section '## 14. X mode' '## Maintaining this file')

  assert_regex "$preamble" 'first mate.*user is the captain' "identity and captain relationship are not immediately visible"
  assert_regex "$preamble" 'sole contact' "firstmate is not the captain's sole project contact"
  assert_regex "$preamble" 'Delegate project-specific.*do none yourself' "delegation boundary is missing"

  for regex in \
    'Never write to a project' \
    'Never merge without the captain.s explicit instruction' \
    'Never destroy unlanded work' \
    'destructive, irreversible, or security-sensitive' \
    'Workers never address the captain' \
    'reports outcomes faithfully and states failures plainly'; do
    assert_regex "$hard" "$regex" "hard boundary missing: $regex"
  done
  assert_regex "$hard" 'cleanup refusal is a stop-and-investigate result' "cleanup refusal safety is missing"
  assert_regex "$hard" 'Never force-push.*reset --hard.*clean -fd.*delete a branch' "destructive git boundary is missing"

  assert_regex "$startup" 'fm-session-start\.sh.*exactly once' "exactly-once startup is missing"
  assert_regex "$startup" 'It alone owns lock acquisition' "startup command ownership is missing"
  assert_regex "$startup" 'session lock.*remain read-only' "lock-refusal read-only boundary is missing"
  assert_regex "$startup" 'do not spawn, steer, merge, drain notifications, repair supervision' "lock-refusal mutation list is incomplete"

  assert_regex "$dispatch" 'genuine isolated task copy' "isolated dispatch is missing"
  assert_regex "$dispatch" 'blocks dispatch rather than authorizing a guess or silent fallback' "dispatch blocker safety is missing"
  assert_regex "$recovery" 'only this home.s recorded direct reports' "direct-report recovery scope is missing"
  assert_regex "$recovery" 'Preserve.*unlanded change' "recovery does not preserve unlanded work"

  assert_regex "$routing" 'explicit project wins.*follow-up inherits' "per-request project resolution is missing"
  assert_regex "$routing" 'second mate.s natural-language scope' "second-mate scope routing is missing"
  assert_regex "$routing" 'handles only routed or recovered work.*idles silently' "second-mate idle boundary is missing"
  assert_regex "$routing" 'never reads a second mate.s chat' "second-mate communication boundary is missing"

  assert_regex "$delivery" '\*\*ship\*\*.*default' "ship default is missing"
  assert_regex "$delivery" '\*\*scout\*\*.*report and no PR' "scout deliverable boundary is missing"
  assert_regex "$delivery" 'evidence, not authorization to change code' "implementation-authority boundary is missing"
  assert_regex "$delivery" 'no concurrency cap' "safe parallel dispatch is missing"
  assert_regex "$delivery" 'Serialize only for a real semantic dependency' "serialization boundary is missing"
  assert_regex "$delivery" 'default active delivery model is `direct-PR`' "direct delivery model is missing"
  assert_regex "$delivery" 'required CI and configured review' "review-readiness reconciliation is missing"
  assert_regex "$delivery" 'configured `local-only` path.*clean branch without push or PR' "local-only boundary is missing"
  assert_regex "$delivery" 'captain alone approves merge' "captain merge authority is missing"
  assert_regex "$delivery" 'worker never decides its own escalated finding' "worker decision boundary is missing"
  assert_regex "$supervision" 'exactly one live supervision cycle' "one-cycle supervision is missing"
  assert_regex "$supervision" 'No turn ends blind' "no-blind-turn invariant is missing"
  assert_regex "$supervision" 'drain the durable queue before' "notification ordering is missing"
  assert_regex "$supervision" 'state/\.afk.*daemon alone owns supervision' "away ownership is missing"
  assert_regex "$supervision" 'real unmarked captain message.*ambiguous input.*captain.s return' "away return boundary is missing"
  assert_regex "$supervision" 'Away mode never expands merge, destructive, irreversible, security-sensitive' "away authority boundary is missing"

  assert_regex "$communication" 'captain.*at least once in every response' "mandatory captain address is missing"
  assert_regex "$communication" 'outcomes, consequences, and decisions rather than orchestration mechanics' "outcome-language boundary is missing"
  assert_regex "$communication" 'Never relay worker reports.*verbatim' "verbatim evidence boundary is missing"
  assert_regex "$communication" 'Captain, shipshape\.' "exact routine acknowledgement is missing"
  assert_regex "$communication" 'complete `https://\.\.\.` URL' "full PR URL requirement is missing"

  assert_regex "$xmode" 'inert unless.*FMX_PAIRING_TOKEN' "X opt-in boundary is missing"
  assert_regex "$xmode" 'never destructive, irreversible, security-sensitive, or merge action' "X authority boundary is missing"
  pass "identity, safety, routing, delivery, supervision, and captain boundaries remain inline"
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
    section '## 13. Exact skill triggers' '## 14. X mode' \
      | awk '/^- `[^`]+` - load / { line=$0; sub(/^- `/, "", line); sub(/`.*/, "", line); print line }' \
      | LC_ALL=C sort
  )
  [ "$index_names" = "$skill_names" ] || {
    printf 'indexed skills:\n%s\ninternal skills:\n%s\n' "$index_names" "$skill_names" >&2
    fail "internal skill trigger index is incomplete or contains an unknown skill"
  }
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    pattern=$(printf -- '- `%s` - load ' "$name")
    count=$(grep -Fc -- "$pattern" "$AGENTS")
    [ "$count" -eq 1 ] || fail "$name has $count trigger rows instead of exactly one"
  done <<< "$skill_names"
  pass "every internal skill has exactly one discoverable trigger row"
}

test_conditional_owners_are_complete() {
  local owner heading
  for owner in "$TASK" "$SUPERVISION" "$CAPTAIN" "$DELIVERY"; do
    assert_grep 'user-invocable: false' "$owner" "$(basename "$(dirname "$owner")") must remain agent-only"
    assert_grep '  internal: true' "$owner" "$(basename "$(dirname "$owner")") must remain internal"
  done

  for heading in \
    '## Backlog intake' \
    '## Brief and spawn' \
    '## Direct delivery rigor' \
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
  for heading in \
    '## Translate evidence into outcomes' \
    '## Shape decisions and escalations' \
    '## Suppress non-events'; do
    assert_grep "$heading" "$CAPTAIN" "captain-communication owner is missing $heading"
  done
  for heading in \
    '## Choose and record the route' \
    '## Write a proportional quality plan' \
    '## Cross-model validation' \
    '## Browser and visual evidence' \
    '## Delivery and PR-ready reconciliation'; do
    assert_grep "$heading" "$DELIVERY" "delivery-quality owner is missing $heading"
  done

  [ "$(rg -l 'Firstmate alone resolves a matched profile array' "$ROOT/AGENTS.md" "$SKILLS" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "dispatch array judgment must have exactly one owner"
  assert_grep 'Firstmate alone resolves a matched profile array' "$HARNESS" \
    "harness-adapters does not own quota-array judgment"
  assert_no_grep 'worktree, checkout, primary checkout, or local-main ->' "$AGENTS" \
    "AGENTS.md duplicated captain translation examples"
  assert_grep 'Worktree, checkout, primary checkout, or local-main becomes' "$CAPTAIN" \
    "captain-communication does not own translation examples"
  pass "conditional task, supervision, dispatch, and communication procedures each have one owner"
}

test_markdown_safety_style() {
  if grep -q "$(printf '\342\200\224')" "$AGENTS" "$TASK" "$SUPERVISION" "$CAPTAIN"; then
    fail "runtime instructions contain an em dash"
  fi
  pass "runtime instructions use plain dashes"
}

test_size_ceiling
test_section_structure
test_always_loaded_boundaries
test_internal_skill_index_is_complete
test_conditional_owners_are_complete
test_markdown_safety_style
