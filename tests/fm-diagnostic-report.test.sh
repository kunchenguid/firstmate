#!/usr/bin/env bash
# Behavior tests for bin/fm-diagnostic-report.sh and fm-diagnostic-report-lib.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-diagnostic-report-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-diagnostic-report-lib.sh"

EVAL="$ROOT/bin/fm-diagnostic-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-diagnostic-report)
REPORT_DIR="$TMP_ROOT/reports"
mkdir -p "$REPORT_DIR"

write_report() {
  local path=$1
  shift
  printf '%s\n' "$@" > "$path"
}

valid_table() {
  cat <<'EOF'
# Investigation

| hypothesis | prediction | experiment | outcome | verdict |
| --- | --- | --- | --- | --- |
| Leading cause | Symptom appears on path A | Reproduced path A | Observed | supported |
| Competing cause | Symptom appears on path B | Reproduced path B | Not observed | refuted |
EOF
}

test_verdict_vocabulary_accepts_closed_values() {
  local verdict
  for verdict in $FM_DIAGNOSTIC_HYPOTHESIS_VERDICTS; do
    fm_diagnostic_hypothesis_verdict_valid "$verdict" \
      || fail "closed verdict vocabulary must accept $verdict"
  done
  pass "closed verdict vocabulary accepts every documented value"
}

test_verdict_vocabulary_rejects_unknown_values() {
  fm_diagnostic_hypothesis_verdict_valid plausible \
    && fail "unknown verdict plausible must be rejected"
  fm_diagnostic_hypothesis_verdict_valid confirmed \
    && fail "unknown verdict confirmed must be rejected"
  pass "closed verdict vocabulary rejects unknown values"
}

test_evaluate_accepts_every_closed_verdict() {
  local verdict report out rc
  for verdict in $FM_DIAGNOSTIC_HYPOTHESIS_VERDICTS; do
    report="$REPORT_DIR/verdict-$verdict.md"
    write_report "$report" \
      '| hypothesis | prediction | experiment | outcome | verdict |' \
      '| --- | --- | --- | --- | --- |' \
      "| Leading cause | Predict | Run | Seen | $verdict |" \
      '| Competing cause | Predict | Run | Seen | refuted |'
    out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
    expect_code 0 "$rc" "evaluator must accept verdict $verdict: $out"
  done
  pass "evaluator accepts every closed verdict value"
}

test_evaluate_accepts_valid_two_row_table() {
  local report="$REPORT_DIR/valid.md" out rc
  valid_table > "$report"
  out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
  expect_code 0 "$rc" "valid diagnostic report must evaluate cleanly: $out"
  assert_contains "$out" 'rows=2' "evaluator must confirm the two-row table"
  pass "evaluator accepts a valid two-row hypothesis table"
}

test_evaluate_rejects_unknown_verdict() {
  local report="$REPORT_DIR/unknown-verdict.md" out rc
  write_report "$report" "$(valid_table | sed 's/| refuted |/| plausible |/')"
  out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
  expect_code 1 "$rc" "unknown verdict must fail evaluation"
  assert_contains "$out" 'verdict must be one of' "evaluator must explain unknown verdict rejection"
  pass "evaluator rejects an unknown verdict"
}

test_evaluate_rejects_wrong_row_count() {
  local report="$REPORT_DIR/one-row.md" out rc
  write_report "$report" \
    '| hypothesis | prediction | experiment | outcome | verdict |' \
    '| --- | --- | --- | --- | --- |' \
    '| Only row | Predict | Run | Seen | supported |'
  out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
  expect_code 1 "$rc" "single-row table must fail evaluation"
  assert_contains "$out" 'exactly two hypothesis rows' "evaluator must require two rows"
  pass "evaluator rejects a one-row hypothesis table"
}

test_evaluate_rejects_missing_separator_with_three_rows() {
  local report="$REPORT_DIR/no-separator-three-rows.md" out rc
  write_report "$report" \
    '| hypothesis | prediction | experiment | outcome | verdict |' \
    '| ignored-first-hypothesis | p | e | o | supported |' \
    '| second-hypothesis | p | e | o | refuted |' \
    '| third-hypothesis | p | e | o | inconclusive |'
  out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
  expect_code 1 "$rc" "missing separator with three rows must fail evaluation"
  assert_contains "$out" 'separator' "evaluator must require a valid markdown separator row"
  pass "evaluator rejects a missing separator even when three rows are present"
}

test_evaluate_rejects_invalid_separator() {
  local report="$REPORT_DIR/invalid-separator.md" out rc
  write_report "$report" \
    '| hypothesis | prediction | experiment | outcome | verdict |' \
    '| not | a | valid | separator | row |' \
    '| Leading cause | Predict | Run | Seen | supported |' \
    '| Competing cause | Predict | Run | Seen | refuted |'
  out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
  expect_code 1 "$rc" "invalid separator must fail evaluation"
  assert_contains "$out" 'separator' "evaluator must reject an invalid separator row"
  pass "evaluator rejects an invalid markdown separator row"
}

test_evaluate_rejects_empty_required_fields() {
  local report="$REPORT_DIR/empty-cells.md" out rc
  write_report "$report" \
    '| hypothesis | prediction | experiment | outcome | verdict |' \
    '| --- | --- | --- | --- | --- |' \
    '| Leading cause |  | Run | Seen | supported |' \
    '| Competing cause | Predict | Run | Seen | refuted |'
  out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
  expect_code 1 "$rc" "empty required cells must fail evaluation"
  assert_contains "$out" 'empty' "evaluator must reject empty required cells"
  pass "evaluator rejects empty required hypothesis-table cells"
}

test_evaluate_rejects_table_in_fenced_code() {
  local report="$REPORT_DIR/fenced-table.md" out rc
  write_report "$report" \
    '# Investigation' \
    '' \
    '```markdown' \
    '| hypothesis | prediction | experiment | outcome | verdict |' \
    '| --- | --- | --- | --- | --- |' \
    '| Leading cause | Predict | Run | Seen | supported |' \
    '| Competing cause | Predict | Run | Seen | refuted |' \
    '```'
  out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
  expect_code 1 "$rc" "fenced-code table must not satisfy the contract"
  assert_contains "$out" 'missing a Hypothesis table' \
    "evaluator must ignore tables inside fenced code blocks"
  pass "evaluator rejects hypothesis tables that exist only inside fenced code"
}

test_evaluate_rejects_table_in_html_comment() {
  local report="$REPORT_DIR/comment-table.md" out rc
  write_report "$report" \
    '# Investigation' \
    '<!--' \
    '| hypothesis | prediction | experiment | outcome | verdict |' \
    '| --- | --- | --- | --- | --- |' \
    '| Leading cause | Predict | Run | Seen | supported |' \
    '| Competing cause | Predict | Run | Seen | refuted |' \
    '-->'
  out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
  expect_code 1 "$rc" "commented table must not satisfy the contract"
  assert_contains "$out" 'missing a Hypothesis table' \
    "evaluator must ignore tables inside HTML comments"
  pass "evaluator rejects hypothesis tables that exist only inside HTML comments"
}

test_evaluate_rejects_non_table_markdown_contexts() {
  local report out rc
  report="$REPORT_DIR/prose-gap.md"
  write_report "$report" \
    '| hypothesis | prediction | experiment | outcome | verdict |' \
    '| --- | --- | --- | --- | --- |' \
    'prose between rows' \
    '| Leading | Predict | Run | Seen | supported |' \
    '| Competing | Predict | Run | Seen | refuted |'
  out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
  expect_code 1 "$rc" "prose gap must be rejected: $out"

  report="$REPORT_DIR/tilde-fence.md"
  write_report "$report" '~~~' \
    '| hypothesis | prediction | experiment | outcome | verdict |' \
    '| --- | --- | --- | --- | --- |' \
    '| Leading | Predict | Run | Seen | supported |' \
    '| Competing | Predict | Run | Seen | refuted |' '~~~'
  out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
  expect_code 1 "$rc" "tilde fence must be rejected: $out"

  report="$REPORT_DIR/indented-code.md"
  write_report "$report" \
    '    | hypothesis | prediction | experiment | outcome | verdict |' \
    '    | --- | --- | --- | --- | --- |' \
    '    | Leading | Predict | Run | Seen | supported |' \
    '    | Competing | Predict | Run | Seen | refuted |'
  out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
  expect_code 1 "$rc" "indented code must be rejected: $out"

  report="$REPORT_DIR/width-mismatch.md"
  write_report "$report" \
    '| hypothesis | prediction | experiment | outcome | verdict |' \
    '| --- |' \
    '| Leading | Predict | Run | Seen | supported |' \
    '| Competing | Predict | Run | Seen | refuted |'
  out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
  expect_code 1 "$rc" "separator width mismatch must be rejected: $out"

  report="$REPORT_DIR/short-close.md"
  write_report "$report" \
    '````' \
    '| hypothesis | prediction | experiment | outcome | verdict |' \
    '| --- | --- | --- | --- | --- |' \
    '| Leading | Predict | Run | Seen | supported |' \
    '| Competing | Predict | Run | Seen | refuted |' \
    '```' \
    'still fenced' \
    '````'
  out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
  expect_code 1 "$rc" "short fence close must be rejected: $out"
  pass "evaluator rejects prose gaps, tilde fences, indented code, width mismatch, and short closes"
}

test_policy_scan_passes_on_repository_root() {
  local out rc
  out=$("$EVAL" policy-scan "$ROOT" 2>&1); rc=$?
  expect_code 0 "$rc" "repository must pass hypothesis-table policy scan: $out"
  assert_contains "$out" 'policy=single-declared-owner' \
    "policy scan must confirm the structural owner declaration"
  pass "policy-scan accepts the repository root through the public contract"
}

test_policy_scan_rejects_duplicate_owner_fixture() {
  local scan_root="$TMP_ROOT/policy-duplicate" owner skill out rc
  owner="$FM_DIAGNOSTIC_HYPOTHESIS_POLICY_OWNER"
  skill="$scan_root/$owner"
  mkdir -p "$(dirname "$skill")" "$scan_root/.agents/extra"
  printf '%s\n' "$FM_DIAGNOSTIC_HYPOTHESIS_POLICY_DECLARATION" > "$skill"
  printf '%s\n' "$FM_DIAGNOSTIC_HYPOTHESIS_POLICY_DECLARATION" > "$scan_root/.agents/extra/duplicate.md"
  out=$("$EVAL" policy-scan "$scan_root" 2>&1); rc=$?
  expect_code 1 "$rc" "duplicate policy owner must fail policy scan"
  assert_contains "$out" 'expected exactly one declared' "policy scan must report duplicate declarations"
  assert_contains "$out" '.agents/extra/duplicate.md' \
    "policy scan must identify the duplicate owner path"
  pass "policy-scan rejects duplicate hypothesis-table declarations in controlled fixtures"
}

test_policy_scan_rejects_missing_owner_fixture() {
  local scan_root="$TMP_ROOT/policy-missing" out rc
  mkdir -p "$scan_root"
  out=$("$EVAL" policy-scan "$scan_root" 2>&1); rc=$?
  expect_code 1 "$rc" "missing owner declaration must fail policy scan: $out"
  assert_contains "$out" 'declared hypothesis-table owner is missing' \
    "policy scan must report a missing structural owner"
  pass "policy-scan rejects a missing structural owner"
}

test_review_counterexamples_are_rejected_through_public_evaluator() {
  local report out rc

  report="$REPORT_DIR/missing-separator-counterexample.md"
  write_report "$report" \
    '| hypothesis | prediction | experiment | outcome | verdict |' \
    '| ignored-first-hypothesis | p | e | o | supported |' \
    '| second-hypothesis | p | e | o | refuted |' \
    '| third-hypothesis | p | e | o | inconclusive |'
  out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
  expect_code 1 "$rc" "missing-separator counterexample must be rejected: $out"

  report="$REPORT_DIR/empty-cells-counterexample.md"
  write_report "$report" \
    '| hypothesis | prediction | experiment | outcome | verdict |' \
    '| --- | --- | --- | --- | --- |' \
    '| Leading cause |  | Run | Seen | supported |' \
    '| Competing cause | Predict | Run | Seen | refuted |'
  out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
  expect_code 1 "$rc" "empty-cell counterexample must be rejected: $out"

  report="$REPORT_DIR/fenced-table-counterexample.md"
  write_report "$report" \
    '```markdown' \
    '| hypothesis | prediction | experiment | outcome | verdict |' \
    '| --- | --- | --- | --- | --- |' \
    '| Leading cause | Predict | Run | Seen | supported |' \
    '| Competing cause | Predict | Run | Seen | refuted |' \
    '```'
  out=$("$EVAL" evaluate "$report" 2>&1); rc=$?
  expect_code 1 "$rc" "fenced-table counterexample must be rejected: $out"

  pass "review counterexamples are rejected through the public evaluator"
}

test_policy_scan_is_hidden_aware_and_excludes_self() {
  local scan_root="$TMP_ROOT/scan-root" owner skill hits
  owner="$FM_DIAGNOSTIC_HYPOTHESIS_POLICY_OWNER"
  skill="$scan_root/$owner"
  mkdir -p "$(dirname "$skill")"
  printf '%s\n' "$FM_DIAGNOSTIC_HYPOTHESIS_POLICY_DECLARATION" > "$skill"
  mkdir -p "$scan_root/.agents/extra"
  printf '%s\n' "$FM_DIAGNOSTIC_HYPOTHESIS_POLICY_DECLARATION" > "$scan_root/.agents/extra/duplicate.md"
  mkdir -p "$scan_root/.git/objects" "$scan_root/.claude/skills" \
    "$scan_root/bin" "$scan_root/tests"
  printf '%s\n' "$FM_DIAGNOSTIC_HYPOTHESIS_TABLE_MARKER" > "$scan_root/.git/objects/note"
  printf '%s\n' "$FM_DIAGNOSTIC_HYPOTHESIS_TABLE_MARKER" > "$scan_root/.claude/skills/note.md"
  printf '%s\n' "$FM_DIAGNOSTIC_HYPOTHESIS_TABLE_MARKER" > "$scan_root/bin/fm-diagnostic-report-lib.sh"
  printf '%s\n' "$FM_DIAGNOSTIC_HYPOTHESIS_TABLE_MARKER" > "$scan_root/tests/fm-diagnostic-report.test.sh"
  hits=$(fm_diagnostic_hypothesis_policy_scan "$scan_root" || true)
  assert_contains "$hits" '.agents/extra/duplicate.md' \
    "hidden-aware scan must find duplicate policy outside the owner"
  assert_not_contains "$hits" '.git/objects/note' "scan must exclude .git"
  assert_not_contains "$hits" '.claude/skills/note.md' "scan must exclude .claude"
  assert_not_contains "$hits" 'bin/fm-diagnostic-report-lib.sh' "scan must exclude its implementation"
  assert_not_contains "$hits" 'tests/fm-diagnostic-report.test.sh' "scan must exclude its behavior test"
  pass "policy scan is hidden-aware and does not self-flag"
}

test_scout_brief_wires_hypothesis_table_requirement() {
  local brief_home="$TMP_ROOT/brief-home" brief
  mkdir -p "$brief_home/data"
  FM_HOME="$brief_home" "$ROOT/bin/fm-brief.sh" diag-scout firstmate --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh failed to generate the scout brief"
  brief="$brief_home/data/diag-scout/brief.md"
  assert_grep 'table contract from' "$brief" \
    "scout brief must wire diagnostic-reasoning hypothesis-table policy"
  assert_grep 'bin/fm-diagnostic-report.sh evaluate' "$brief" \
    "scout brief must wire the mechanical evaluator"
  pass "generated scout brief wires the hypothesis table and evaluator"
}

test_verdict_vocabulary_accepts_closed_values
test_verdict_vocabulary_rejects_unknown_values
test_evaluate_accepts_every_closed_verdict
test_evaluate_accepts_valid_two_row_table
test_evaluate_rejects_unknown_verdict
test_evaluate_rejects_wrong_row_count
test_evaluate_rejects_missing_separator_with_three_rows
test_evaluate_rejects_invalid_separator
test_evaluate_rejects_empty_required_fields
test_evaluate_rejects_table_in_fenced_code
test_evaluate_rejects_table_in_html_comment
test_evaluate_rejects_non_table_markdown_contexts
test_policy_scan_is_hidden_aware_and_excludes_self
test_policy_scan_passes_on_repository_root
test_policy_scan_rejects_duplicate_owner_fixture
test_policy_scan_rejects_missing_owner_fixture
test_review_counterexamples_are_rejected_through_public_evaluator
test_scout_brief_wires_hypothesis_table_requirement
