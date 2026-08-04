#!/usr/bin/env bash
# Behavioral contract for the lavish-repair skill's routing, diagnosis order,
# process-safety guard, and durable recovery boundaries.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SKILL="$ROOT/.agents/skills/lavish-repair/SKILL.md"
AGENTS="$ROOT/AGENTS.md"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

assert_grep() {
  local pattern=$1
  local file=$2
  local message=$3
  grep -Fq -- "$pattern" "$file" || fail "$message"
}

test_internal_skill_and_trigger() {
  local section global_count section_count

  [ -f "$SKILL" ] || fail "lavish-repair SKILL.md is missing"
  assert_grep "name: lavish-repair" "$SKILL" "skill name is missing"
  assert_grep "user-invocable: false" "$SKILL" "skill must not be captain-invocable"
  assert_grep "metadata:" "$SKILL" "skill is missing internal metadata"
  assert_grep "internal: true" "$SKILL" "skill is not marked internal"

  section=$(awk '/^## 13\. Agent-only reference skills$/ { capture=1; next } capture && /^## / { exit } capture' "$AGENTS")
  global_count=$(grep -Fc "\`lavish-repair\`" "$AGENTS")
  section_count=$(printf '%s\n' "$section" | grep -Fc "\`lavish-repair\`")
  [ "$global_count" -eq 1 ] || fail "AGENTS.md must reference lavish-repair exactly once"
  [ "$section_count" -eq 1 ] || fail "lavish-repair trigger must live in section 13"
  assert_grep "self-contained Lavish board fails preflight, browser launch, interaction, submission pickup, or collection" \
    "$AGENTS" "trigger must cover every self-contained board failure stage"
  assert_grep "before touching its state artifacts or isolated Chrome session" \
    "$AGENTS" "trigger must fire before state or browser repair"
  pass "lavish-repair is internal and has one route-complete conditional trigger"
}

test_route_order_and_owners() {
  local preflight_line browser_line interaction_line pickup_line collection_line

  preflight_line=$(grep -nF '### 1. Answerability preflight' "$SKILL" | cut -d: -f1) ||
    fail "answerability-preflight diagnosis stage is missing"
  browser_line=$(grep -nF '### 2. Browser launch' "$SKILL" | cut -d: -f1) ||
    fail "browser-launch diagnosis stage is missing"
  interaction_line=$(grep -nF '### 3. Board interaction' "$SKILL" | cut -d: -f1) ||
    fail "board-interaction diagnosis stage is missing"
  pickup_line=$(grep -nF '### 4. Submission pickup' "$SKILL" | cut -d: -f1) ||
    fail "submission-pickup diagnosis stage is missing"
  collection_line=$(grep -nF '### 5. Collection' "$SKILL" | cut -d: -f1) ||
    fail "collection diagnosis stage is missing"
  [ "$preflight_line" -lt "$browser_line" ] || fail "preflight must precede browser diagnosis"
  [ "$browser_line" -lt "$interaction_line" ] || fail "browser launch must precede interaction diagnosis"
  [ "$interaction_line" -lt "$pickup_line" ] || fail "interaction must precede pickup diagnosis"
  [ "$pickup_line" -lt "$collection_line" ] || fail "pickup must precede collection diagnosis"

  assert_grep "Read \`bin/fm-lavish-board.sh\`'s header and \`--help\` output" \
    "$SKILL" "board helper ownership is missing"
  assert_grep "Read \`tools/lavish/README.md\` for the durable decision and payload protocol" \
    "$SKILL" "durable protocol ownership is missing"
  assert_grep "Load \`lavish-decisions\` before completing the normal collect and consume workflow" \
    "$SKILL" "normal workflow handoff is missing"
  assert_grep "The Lavish fork has no server, session URL, live channel, listener, or poller to repair" \
    "$SKILL" "self-contained route boundary is missing"
  assert_grep "Never invoke upstream serve, poll, or server-lifecycle commands" \
    "$SKILL" "upstream server lifecycle must remain forbidden"
  pass "lavish-repair diagnoses the self-contained route in owner-defined order"
}

test_preflight_and_browser_contracts() {
  assert_grep "read its named missing components" "$SKILL" \
    "preflight failure must report missing answerability components"
  assert_grep "Do not bypass the preflight, arm pickup by hand, or substitute hand-authored HTML" \
    "$SKILL" "preflight bypasses must remain forbidden"
  assert_grep "has not opened Chrome or armed pickup when this check fails" \
    "$SKILL" "preflight failure boundary is missing"
  assert_grep "exact terminal fallback emitted by \`lavish-axi create\`" \
    "$SKILL" "preflight terminal fallback is missing"
  assert_grep "The helper removes the armed check on an open failure" \
    "$SKILL" "browser-open cleanup boundary is missing"
  assert_grep "inspect only the helper's named isolated session" \
    "$SKILL" "browser diagnosis is not scoped to the isolated session"
  assert_grep "Never attach the board to the captain's main Chrome profile" \
    "$SKILL" "main-profile isolation guard is missing"
  assert_grep "inspect that page in the named isolated session before reloading or reopening it" \
    "$SKILL" "visible interaction diagnosis is missing"
  assert_grep "Protect any unsubmitted captain input before a page-level repair" \
    "$SKILL" "unsubmitted-input guard is missing"
  assert_grep "return to the answerability-preflight branch" \
    "$SKILL" "missing controls must route back through preflight"
  pass "lavish-repair preserves preflight and isolated-browser boundaries"
}

test_pickup_and_collection_contracts() {
  assert_grep "browser-profile record is the authoritative pickup route" \
    "$SKILL" "authoritative browser-profile pickup is missing"
  assert_grep "matching download is optional corroboration" \
    "$SKILL" "download corroboration boundary is missing"
  assert_grep "Keep the helper's existing one-shot check armed" \
    "$SKILL" "existing bounded pickup path is missing"
  assert_grep "Do not add another storage bridge, filesystem watcher, timer sweep, long poll, or resident process" \
    "$SKILL" "duplicate pickup machinery is not forbidden"
  assert_grep "Confirm receipt only after \`lavish-axi collect\` validates and saves the answer" \
    "$SKILL" "validated collection boundary is missing"
  assert_grep "Treat a named \`lavish-axi collect\` validation error as a payload or immutable-request mismatch" \
    "$SKILL" "collection-error classification is missing"
  assert_grep "do not weaken the schema, key, option, annotation, or request-digest checks" \
    "$SKILL" "collection validation must remain fail-closed"
  pass "lavish-repair preserves the existing pickup and collection contracts"
}

test_process_safety_and_recovery_contracts() {
  assert_grep "Never use \`pkill -f\` or signal a process selected only by a tool-name pattern" \
    "$SKILL" "fleet-wide process-name signaling is not forbidden"
  assert_grep "inspect every candidate's PID, parent, elapsed time, and full command" \
    "$SKILL" "explicit process identity proof is missing"
  assert_grep "Never pipe unfiltered process-search output into \`kill\`" \
    "$SKILL" "unfiltered process signaling is not forbidden"
  assert_grep "A surface failure does not erase the durable decision, a downloaded payload, or a collected answer" \
    "$SKILL" "durable-state survival boundary is missing"
  assert_grep "Use \`lavish show\` and \`lavish inbox\` with the explicit Firstmate home" \
    "$SKILL" "durable-state inspection sequence is missing"
  assert_grep "Reopen a board only when no submitted payload exists" \
    "$SKILL" "safe reopen gate is missing"
  assert_grep "the exact \`lavish answer ... --home ...\` creation fallback keeps the decision answerable" \
    "$SKILL" "browser-independent answer fallback is missing"
  pass "lavish-repair retains process safety and durable recovery boundaries"
}

test_internal_skill_and_trigger
test_route_order_and_owners
test_preflight_and_browser_contracts
test_pickup_and_collection_contracts
test_process_safety_and_recovery_contracts
