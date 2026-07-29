#!/usr/bin/env bash
# Static regression tests for the internal /bearings skill contract.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEARINGS_SKILL="$ROOT/.agents/skills/bearings/SKILL.md"
README="$ROOT/README.md"
AUDIENCES="$ROOT/docs/documentation-audiences.json"

skill_body() {
  awk 'BEGIN { seen = 0 } /^---$/ { seen += 1; next } seen >= 2 { print }' "$BEARINGS_SKILL"
}

chat_contract() {
  awk '/^## Chat-response contract$/{capture=1; next} capture && /^## /{exit} capture' "$BEARINGS_SKILL"
}

test_status_skill_is_absent() {
  assert_absent "$ROOT/.agents/skills/status" "internal status skill directory must be removed"
  assert_absent "$ROOT/.agents/skills/status/SKILL.md" "internal status skill file must be removed"
  assert_absent "$ROOT/skills/status" "public status skill directory must not exist"
  assert_no_grep '.agents/skills/status/SKILL.md' "$AUDIENCES" "documentation audience inventory still lists status"
  assert_no_grep '| `/status`' "$README" "README still lists /status"
  pass "/status is absent from the skill and documentation surfaces"
}

test_plain_bearings_is_chat_only_by_default() {
  assert_grep 'Plain `/bearings` returns only the concise four-section chat digest.' "$BEARINGS_SKILL" \
    "plain bearings default is not chat-only"
  assert_grep 'Plain `/bearings` gathers a fresh bounded snapshot and renders the four-section chat digest without creating, deleting, reading, or replacing `data/status-report-<YYYY-MM-DD>.md`.' "$BEARINGS_SKILL" \
    "plain bearings does not forbid dated report writes"
  assert_grep 'Plain mode stops here and writes no report artifact.' "$BEARINGS_SKILL" \
    "plain bearings can continue into report writing"
  pass "plain /bearings is chat-only and forbids report artifacts"
}

test_file_mode_owns_prior_report_artifact_behavior() {
  assert_grep 'Only `/bearings file` writes the dated markdown report artifact and then returns the concise four-section chat digest linked to that report.' "$BEARINGS_SKILL" \
    "file mode is not the only report-writing mode"
  assert_grep 'Write the full report to `data/status-report-<YYYY-MM-DD>.md` using today'"'"'s date.' "$BEARINGS_SKILL" \
    "file mode does not write the dated report"
  assert_grep 'If today'"'"'s file already exists, delete it first, then create a new file from scratch.' "$BEARINGS_SKILL" \
    "file mode does not replace today's report from scratch"
  assert_grep 'This is the only write allowed by the skill.' "$BEARINGS_SKILL" \
    "file mode write boundary is missing"
  assert_grep 'After writing the file, return the concise four-section chat digest and include the report path or link without adding a fifth section.' "$BEARINGS_SKILL" \
    "file mode does not return the linked four-section digest"
  pass "/bearings file owns the prior dated-report behavior"
}

test_file_option_is_explicit_and_prs_compose() {
  assert_grep 'Treat `file` only as an explicit invocation option in the slash command.' "$BEARINGS_SKILL" \
    "file is not pinned to an explicit slash option"
  assert_grep 'Do not treat natural-language requests such as "write a report", "save this", "persist it", or "make a file" as file mode unless the invocation explicitly includes the standalone `file` option.' "$BEARINGS_SKILL" \
    "file mode can be triggered fuzzily"
  assert_grep 'When the captain asks to include PRs, pass the snapshot command'"'"'s live-PR opt-in.' "$BEARINGS_SKILL" \
    "live PR opt-in is missing"
  assert_grep '`/bearings include PRs` remains chat-only and makes the live-PR opt-in.' "$BEARINGS_SKILL" \
    "include PRs does not compose with chat-only mode"
  assert_grep '`/bearings file include PRs` writes the dated report and makes the live-PR opt-in.' "$BEARINGS_SKILL" \
    "include PRs does not compose with file mode"
  pass "file is explicit and live PR enrichment composes with both modes"
}

test_single_fresh_snapshot_source_and_authoritative_provenance() {
  local body count
  body=$(skill_body)
  count=$(grep -cF 'bin/fm-bearings-snapshot.sh' "$BEARINGS_SKILL")
  [ "$count" = 1 ] || fail "bearings should reference the snapshot owner exactly once, found $count"
  assert_contains "$body" 'Run `bin/fm-bearings-snapshot.sh` at invocation time and read its compact output.' \
    "bearings does not gather a fresh snapshot at invocation time"
  assert_contains "$body" 'It is the single bounded, deterministic fleet-state source for Bearings and renders TOON by default.' \
    "bearings does not name the single bounded source"
  assert_contains "$body" 'Do not create or consult a second fleet-state reader, parser contract, status-event-tail interpretation, visible-session recap, ad-hoc project probe, or ad-hoc `gh-axi`/`gh` query.' \
    "bearings allows a second reader or ad-hoc probe"
  assert_contains "$body" 'For registered secondmates, use the snapshot'"'"'s structured-home classification and provenance.' \
    "bearings does not use structured secondmate provenance"
  assert_contains "$body" 'Structured captain-held decisions come from `decision-hold-lifecycle` and appear under `decisions_open`.' \
    "bearings does not preserve structured captain-held decisions"
  assert_not_contains "$body" 'fm-fleet-snapshot.sh' "bearings creates a second canonical snapshot path"
  assert_not_contains "$body" 'fm-crew-state.sh' "bearings creates an extra current-state reader"
  pass "bearings keeps the fresh structured snapshot as the single source"
}

test_chat_contract_four_sections_for_both_modes() {
  local body headings expected report_headings
  body=$(chat_contract)
  headings=$(printf '%s\n' "$body" | sed -nE "s/^[0-9]+\. \*\*([^*]+)\*\*.*/\1/p")
  expected=$(printf '%s\n' "Captain's Call" "Recently Landed" "Underway" "Charted Next")
  [ "$headings" = "$expected" ] || fail "chat contract must contain exactly four numbered sections in fixed order, got: $headings"
  assert_contains "$body" "Nothing needs your action right now" "Captain's Call empty-state sentence"
  assert_contains "$body" "No recent completions are in the current baseline" "Recently Landed empty-state sentence"
  assert_contains "$body" "Nothing is underway" "Underway empty-state sentence"
  assert_contains "$body" "Nothing is queued" "Charted Next empty-state sentence"
  report_headings=$(sed -nE 's/^   - \*\*(Captain.s Call|Recently Landed|Underway|Charted Next)\*\*.*/\1/p' "$BEARINGS_SKILL")
  [ "$report_headings" = "$expected" ] || fail "detailed report contract must contain the same four complete sections, got: $report_headings"
  assert_contains "$body" "no At Anchor section" "the At Anchor exclusion must be documented"
  assert_contains "$body" "Every chat digest and file-mode report is a complete current snapshot" "both modes must be complete current snapshots"
  assert_contains "$body" "Detailed decisions, plans, full gate reasons, and evidence belong in the file only when file mode is explicit" \
    "plain chat must not depend on a detailed report file"
  assert_contains "$body" "In file mode, include the report path or link inside the four-section digest without adding another heading." \
    "file mode must link the report without a fifth section"
  pass "both Bearings modes keep the exact four-section chat contract"
}

test_readme_describes_bearings_modes() {
  assert_grep '| `/bearings`        | Generate a concise four-section chat digest from bounded local fleet and registered-secondmate state; use `/bearings file` to also replace today'"'"'s dated report in `data/`, and add `include PRs` when live PR enrichment is wanted |' "$README" \
    "README skill table does not describe chat-only default and file option"
  assert_grep '- `/bearings` returns the fresh four-section digest in chat only.' "$README" \
    "README lacks plain bearings example"
  assert_grep '- `/bearings include PRs` keeps chat-only mode and opts into live PR enrichment.' "$README" \
    "README lacks chat-only live PR example"
  assert_grep '- `/bearings file` replaces today'"'"'s `data/status-report-<YYYY-MM-DD>.md` from scratch and links it from the four-section chat digest.' "$README" \
    "README lacks file mode example"
  assert_grep '- `/bearings file include PRs` combines the dated report with live PR enrichment.' "$README" \
    "README lacks file mode live PR example"
  pass "README documents Bearings default and file mode"
}

test_status_skill_is_absent
test_plain_bearings_is_chat_only_by_default
test_file_mode_owns_prior_report_artifact_behavior
test_file_option_is_explicit_and_prs_compose
test_single_fresh_snapshot_source_and_authoritative_provenance
test_chat_contract_four_sections_for_both_modes
test_readme_describes_bearings_modes
