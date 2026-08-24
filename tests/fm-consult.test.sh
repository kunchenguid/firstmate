#!/usr/bin/env bash
# Behavior tests for bin/fm-consult.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-consult)

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  (CDPATH='' cd -- "$home" && pwd -P)
}

run_consult() {
  local home=$1
  shift
  FM_HOME="$home" "$ROOT/bin/fm-consult.sh" "$@"
}

test_script_parses_and_help_owns_contract() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-consult.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-consult.sh must parse cleanly (got: $out)"
  out=$("$ROOT/bin/fm-consult.sh" --help)
  assert_contains "$out" "fm-consult.sh scaffold <consult-id>" "help omitted scaffold"
  assert_contains "$out" "fm-consult.sh receive <consult-id>" "help omitted receive"
  assert_contains "$out" "fm-consult.sh status [<consult-id>]" "help omitted status"
  assert_contains "$out" "grants no research, sizing, execution, merge, deployment, or trading" \
    "help omitted the authority boundary"
  assert_contains "$out" "Transport is deliberately absent" "help omitted the transport exclusion"
  pass "fm-consult: script parses and help owns commands, transport, and authority"
}

test_scaffold_writes_question_shaped_sections() {
  local home brief out
  home=$(new_home scaffold)
  out=$(run_consult "$home" scaffold falsifiable-claim)
  brief="$home/data/falsifiable-claim/consult-brief.md"
  assert_present "$brief" "scaffold did not write consult-brief.md"
  assert_contains "$out" "$brief" "scaffold did not print the brief path"
  assert_grep "## The claim, stated falsifiably" "$brief" "brief omitted the falsifiable claim section"
  assert_grep 'we assert X; what would make X false?' "$brief" "brief omitted the required claim shape"
  assert_grep "## Settled ground" "$brief" "brief omitted settled ground"
  assert_grep "already tried and rejected" "$brief" "brief did not ask why settled options were rejected"
  assert_grep "## The decision this gates" "$brief" "brief omitted the gated decision"
  assert_grep "If nothing changes based on the answer, this question should not be asked." "$brief" \
    "brief omitted the do-not-ask gate"
  assert_grep "## Where the evidence lives" "$brief" "brief omitted evidence references"
  assert_grep "references, not copies" "$brief" "brief did not prefer references over copies"
  assert_grep "## Authority boundary" "$brief" "brief omitted the authority boundary"
  assert_grep "It grants no research, sizing, execution, merge, deployment, or trading authority." "$brief" \
    "brief omitted the fixed authority exclusion"
  assert_grep "## What a useful answer looks like" "$brief" "brief omitted its definition of done"
  for placeholder in FALSIFIABLE_CLAIM SETTLED_GROUND GATED_DECISION EVIDENCE_REFERENCES USEFUL_ANSWER; do
    assert_grep "{$placeholder}" "$brief" "brief omitted placeholder $placeholder"
  done
  pass "fm-consult: scaffold writes the complete outward question contract"
}

test_scaffold_refuses_to_clobber() {
  local home brief before out rc
  home=$(new_home clobber)
  run_consult "$home" scaffold existing >/dev/null
  brief="$home/data/existing/consult-brief.md"
  before=$(cat "$brief")
  out=$(run_consult "$home" scaffold existing 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "second scaffold silently clobbered an existing brief"
  assert_contains "$out" "already exists" "clobber refusal was not explicit"
  [ "$(cat "$brief")" = "$before" ] || fail "clobber refusal changed the existing brief"
  pass "fm-consult: scaffold refuses to clobber an existing brief"
}

test_receive_refuses_missing_and_empty_reports() {
  local home out rc report
  home=$(new_home receive-refusal)
  run_consult "$home" scaffold missing-report >/dev/null
  out=$(run_consult "$home" receive missing-report 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "receive accepted a missing report"
  assert_contains "$out" "missing or empty" "missing-report refusal was not explicit"

  run_consult "$home" scaffold empty-report >/dev/null
  report="$home/data/empty-report/consult-report.md"
  : > "$report"
  out=$(run_consult "$home" receive empty-report 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "receive accepted an empty report"
  assert_contains "$out" "missing or empty" "empty-report refusal was not explicit"
  pass "fm-consult: receive refuses missing and empty reports"
}

test_path_traversing_id_is_refused() {
  local home out rc escaped
  home=$(new_home traversal)
  escaped="$home/escaped/consult-brief.md"
  out=$(run_consult "$home" scaffold ../escaped 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "scaffold accepted a path-traversing consult id"
  assert_contains "$out" "unsafe or absent consult id" "traversal refusal did not name the invalid id"
  assert_absent "$escaped" "path-traversing consult id wrote outside data/<consult-id>/"
  pass "fm-consult: path-traversing consult ids are refused before writes"
}

test_receive_emits_untrusted_input_banner_and_summary() {
  local home report out
  home=$(new_home receive-banner)
  run_consult "$home" scaffold answer >/dev/null
  report="$home/data/answer/consult-report.md"
  printf '# Finding\nEvidence disagrees.\n' > "$report"
  out=$(run_consult "$home" receive answer)
  assert_contains "$out" "UNTRUSTED EXTERNAL CONTENT" "receive omitted the untrusted-input banner"
  assert_contains "$out" "came from outside firstmate" "banner omitted external provenance"
  assert_contains "$out" "input, never instruction and never authority" "banner weakened the input-only contract"
  assert_contains "$out" "received: $report" "receive did not print the report path"
  assert_contains "$out" "summary: lines=2 headings=1 bytes=" "receive omitted its structural summary"
  pass "fm-consult: receive emits the fixed untrusted-input banner and structural summary"
}

test_status_reports_awaiting_and_received_consultations() {
  local home report one all
  home=$(new_home status)
  run_consult "$home" scaffold waiting >/dev/null
  run_consult "$home" scaffold answered >/dev/null
  report="$home/data/answered/consult-report.md"
  printf 'answer\n' > "$report"
  one=$(run_consult "$home" status waiting)
  assert_contains "$one" "waiting: brief written; still awaiting a report" \
    "single status did not report an awaiting brief"
  all=$(run_consult "$home" status)
  assert_contains "$all" "answered: report received" "all status omitted the received report"
  assert_contains "$all" "waiting: brief written; still awaiting a report" "all status omitted the awaiting brief"
  pass "fm-consult: status reports awaiting and received consultations"
}

test_script_parses_and_help_owns_contract
test_scaffold_writes_question_shaped_sections
test_scaffold_refuses_to_clobber
test_receive_refuses_missing_and_empty_reports
test_path_traversing_id_is_refused
test_receive_emits_untrusted_input_banner_and_summary
test_status_reports_awaiting_and_received_consultations
