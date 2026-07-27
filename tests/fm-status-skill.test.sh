#!/usr/bin/env bash
# Static regression tests for the internal /status skill contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATUS="$ROOT/.agents/skills/status/SKILL.md"
README="$ROOT/README.md"

skill_body() {
  awk 'BEGIN { seen = 0 } /^---$/ { seen += 1; next } seen >= 2 { print }' "$STATUS"
}

test_status_metadata_and_internal_placement() {
  assert_present "$STATUS" "status skill is missing"
  assert_grep 'name: status' "$STATUS" "status skill metadata has the wrong name"
  assert_grep 'user-invocable: true' "$STATUS" "status skill is not user-invocable"
  assert_grep 'metadata:' "$STATUS" "status skill lacks metadata"
  assert_grep '  internal: true' "$STATUS" "status skill is not internal"
  assert_absent "$ROOT/skills/status" "status must not exist in the public installer-facing skills directory"
  assert_absent "$ROOT/skills/status/SKILL.md" "status must not exist as a public installer-facing skill"
  pass "status is internal, user-invocable, and absent from public skills"
}

test_status_trigger_is_explicit_slash_only() {
  assert_grep 'description: Give a quick fresh read-only fleet update only when the captain explicitly invokes /status' "$STATUS" \
    "status description does not require an explicit /status invocation"
  assert_grep 'Use this skill only for an explicit `/status` invocation.' "$STATUS" \
    "status body does not pin the explicit slash trigger"
  for excluded in \
    'ordinary uses of the word status' \
    'requests for `/bearings`' \
    'morning briefs' \
    'full catch-up reports' \
    '"where did I leave off" requests' \
    '"what'"'"'s in the works" requests' \
    '`/ahoy` session recaps'; do
    assert_grep "$excluded" "$STATUS" "status trigger hygiene is missing exclusion: $excluded"
  done
  pass "status trigger is explicit slash-only"
}

test_status_uses_fresh_bearings_snapshot_owner() {
  local body count
  body=$(skill_body)
  assert_contains "$body" 'Run `bin/fm-bearings-snapshot.sh --json` at invocation time and use that fresh structured snapshot as the only fleet-state source.' \
    "status does not gather a fresh structured snapshot"
  assert_contains "$body" 'The command'"'"'s header and `--help` output own its invocation, fields, bounds, secondmate provenance, structured captain-held decisions, and output contract.' \
    "status does not point to the snapshot owner for fields and provenance"
  assert_contains "$body" 'Registered secondmates and structured captain-held decisions use the authoritative provenance already defined by Bearings' \
    "status does not delegate secondmates and captain-held decisions to Bearings provenance"
  assert_contains "$body" 'Do not infer current work from raw status-event tails or from the visible conversation history.' \
    "status may infer stale current state"
  count=$(grep -cF 'fm-bearings-snapshot.sh' "$STATUS")
  [ "$count" = 1 ] || fail "status should reference the bearings snapshot owner exactly once, found $count"
  assert_no_grep 'fm-fleet-snapshot.sh' "$STATUS" "status creates a second canonical snapshot path"
  assert_no_grep 'fm-crew-state.sh' "$STATUS" "status creates an extra current-state reader"
  pass "status uses the fresh bounded Bearings snapshot owner"
}

test_status_chat_headings_are_exact_and_ordered() {
  local headings
  headings=$(awk '/^\*\*(Now|Needs you|Just finished|Next)\*\*$/ { print }' "$STATUS")
  [ "$headings" = $'**Now**\n**Needs you**\n**Just finished**\n**Next**' ] || \
    fail "status headings are not exact and ordered: $headings"
  assert_grep 'Render exactly these four short headings in this order, with no title, preamble, report link, table, or persisted artifact.' "$STATUS" \
    "status does not forbid extra chat structure"
  pass "status has the exact four-heading chat contract"
}

test_status_empty_states_and_bounded_sections() {
  assert_grep 'If empty, write one sentence: "Captain, nothing is progressing or waiting externally right now."' "$STATUS" \
    "status Now empty state is missing"
  assert_grep 'If empty, write one sentence: "Nothing needs your action right now."' "$STATUS" \
    "status Needs you empty state is missing"
  assert_grep 'If empty, write one sentence: "No recent completions are in the current baseline."' "$STATUS" \
    "status Just finished empty state is missing"
  assert_grep 'If empty, write one sentence: "Nothing is queued or gated."' "$STATUS" \
    "status Next empty state is missing"
  assert_grep 'List every live direct report that is currently progressing or waiting externally, one captain-facing outcome line each.' "$STATUS" \
    "status Now section can hide active work"
  assert_grep 'Do not hide active work behind a count.' "$STATUS" \
    "status Now section lacks no-count-hiding rule"
  assert_grep 'List at most the two most recent completed outcomes from the bounded structured baseline.' "$STATUS" \
    "status Just finished section is not bounded to two completions"
  assert_grep 'List at most the three highest-priority queued or gated items, including the concrete blocker or date when present.' "$STATUS" \
    "status Next section is not bounded to three items with blocker/date"
  pass "status empty states and bounded sections are explicit"
}

test_status_is_read_only_and_captain_facing() {
  assert_grep 'Create no report file, data file, backlog update, state update, or other persisted artifact.' "$STATUS" \
    "status read-only boundary does not forbid artifacts and local record changes"
  assert_grep 'Do not dispatch work, steer a worker, merge a PR, clean up work, answer a queued decision, or change fleet state as a side effect of `/status`.' "$STATUS" \
    "status read-only boundary does not forbid lifecycle actions"
  assert_grep 'leave the action to the normal lifecycle' "$STATUS" \
    "status may take action instead of reporting it"
  for forbidden in \
    'data/status-report-' \
    'Write the dated report file' \
    'tasks-axi' \
    'fm-spawn' \
    'fm-send' \
    'fm-pr-merge' \
    'fm-merge-local' \
    'fm-teardown' \
    'no-mistakes axi respond'; do
    assert_no_grep "$forbidden" "$STATUS" "status contains a mutation or report instruction: $forbidden"
  done
  assert_grep 'follow `AGENTS.md` section 9'"'"'s captain-facing translation contract' "$STATUS" \
    "status does not point to the captain-facing translation owner"
  assert_grep 'Include a full `https://...` URL whenever a PR must be mentioned.' "$STATUS" \
    "status does not require full PR URLs"
  pass "status is read-only and captain-facing"
}

test_readme_lists_status() {
  assert_grep '| `/status`          | Give a quick fresh read-only four-part chat update from the bounded Bearings snapshot without writing the full report artifact |' "$README" \
    "README built-in skills table does not list /status"
  pass "README lists status"
}

test_status_metadata_and_internal_placement
test_status_trigger_is_explicit_slash_only
test_status_uses_fresh_bearings_snapshot_owner
test_status_chat_headings_are_exact_and_ordered
test_status_empty_states_and_bounded_sections
test_status_is_read_only_and_captain_facing
test_readme_lists_status
