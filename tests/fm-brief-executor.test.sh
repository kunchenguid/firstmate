#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh --executor: the short one-shot executor
# brief (AGENTS.md section 7, the executor-dispatch skill).
#
#   (a) scaffold shape: short, numbered, names the issue, branch, and gate,
#       and ends with the machine-readable delivery-contract line the spawn checks
#   (b) --issue and --verify are required and validated; a literal <VERIFY>
#       placeholder is refused
#   (c) no status-file protocol, no steering-inbox section, no no-mistakes
#       definition of done, no project-memory section, no {TASK} placeholders
#   (d) --mode, --scout, --secondmate, and --herdr-lab are refused with
#       --executor; --issue and --verify are refused without it
#   (e) fm_brief_executor_issue reads the contract line and rejects ship briefs
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-dod-lib.sh"

BRIEF_BIN="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-brief-executor)

run_brief() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$BRIEF_BIN" "$@" 2>&1
}

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

test_executor_scaffold_shape() {
  local home out rc brief lines
  home=$(new_home shape)
  out=$(run_brief "$home" exec-shape-a1 widget-repo --executor --issue 42 --verify 'make ci'); rc=$?
  expect_code 0 "$rc" "executor scaffold should succeed: $out"
  assert_contains "$out" "scaffolded: $home/data/exec-shape-a1/brief.md (executor, issue=42)" "scaffold report"
  brief="$home/data/exec-shape-a1/brief.md"
  [ -f "$brief" ] || fail "brief not written"
  lines=$(wc -l < "$brief" | tr -d ' ')
  [ "$lines" -lt 60 ] || fail "an executor brief must stay well under 60 lines, got $lines"
  assert_grep 'gh issue view 42' "$brief" "the brief reads the issue"
  assert_grep 'git push -u origin fm/exec-shape-a1' "$brief" "the brief pushes the task branch"
  assert_grep 'git branch --show-current' "$brief" "the brief asserts the branch it was launched on"
  assert_grep 'make ci' "$brief" "the brief carries the resolved gate"
  assert_grep 'Close #42:' "$brief" "the commit message carries Close #N"
  assert_grep 'Closes #42' "$brief" "the pull request body closes the issue"
  assert_grep '--body-file .fm-pr-body.md' "$brief" "the pull request body is a file inside the worktree"
  assert_grep '--draft' "$brief" "a draft is required when the gate cannot pass"
  assert_grep 'never weaken, skip, delete, or loosen a test' "$brief" "tests are never weakened"
  assert_grep 'Never merge' "$brief" "executors never merge"
  assert_grep 'git rev-parse --show-toplevel' "$brief" "the worktree-isolation assertion is present"
  [ "$(tail -n 1 "$brief")" = 'Delivery contract: kind=executor issue=42' ] \
    || fail "the brief must end with the exact delivery-contract line, got: $(tail -n 1 "$brief")"
  assert_grep 'widget-repo' "$brief" "the brief names the project"
  out=$(run_brief "$home" exec-shape-a1 widget-repo --executor --issue 42 --verify 'make ci'); rc=$?
  expect_code 1 "$rc" "an existing brief is never overwritten"
  pass "executor scaffold: short, numbered, issue-driven, and ends with the delivery contract"
}

test_executor_brief_omits_interactive_contracts() {
  local home brief
  home=$(new_home omit)
  run_brief "$home" exec-omit-b1 widget-repo --executor --issue 3 --verify 'npm test' >/dev/null
  brief="$home/data/exec-omit-b1/brief.md"
  assert_no_grep '.status' "$brief" "no status-file protocol"
  assert_no_grep 'needs-decision' "$brief" "no decision-state protocol"
  assert_no_grep 'instruction inbox' "$brief" "no steering-inbox section"
  assert_no_grep '.inbox' "$brief" "no inbox path"
  assert_no_grep 'no-mistakes' "$brief" "no no-mistakes definition of done"
  assert_no_grep 'Project memory' "$brief" "no project-memory section"
  assert_no_grep 'fm-ensure-agents-md' "$brief" "no AGENTS.md authoring instruction"
  assert_no_grep '{TASK}' "$brief" "no Task placeholder"
  assert_no_grep '{FIRSTMATE_SPEC}' "$brief" "no Firstmate spec placeholder"
  assert_no_grep '## Captain' "$brief" "no intent subsection"
  assert_no_grep 'Herdr' "$brief" "no Herdr lifecycle declaration"
  pass "executor brief carries none of the interactive worker contracts"
}

test_issue_and_verify_are_required_and_validated() {
  local home out rc
  home=$(new_home required)
  out=$(run_brief "$home" exec-req-c1 widget-repo --executor --verify 'make ci'); rc=$?
  expect_code 1 "$rc" "missing --issue must refuse"
  assert_contains "$out" 'requires --issue' "missing --issue names the flag"
  out=$(run_brief "$home" exec-req-c1 widget-repo --executor --issue 0 --verify 'make ci'); rc=$?
  expect_code 1 "$rc" "issue 0 must refuse"
  out=$(run_brief "$home" exec-req-c1 widget-repo --executor --issue 12a --verify 'make ci'); rc=$?
  expect_code 1 "$rc" "a non-numeric issue must refuse"
  assert_contains "$out" 'positive integer' "invalid issue names the shape"
  out=$(run_brief "$home" exec-req-c1 widget-repo --executor --issue 12); rc=$?
  expect_code 1 "$rc" "missing --verify must refuse"
  assert_contains "$out" 'requires --verify' "missing --verify names the flag"
  out=$(run_brief "$home" exec-req-c1 widget-repo --executor --issue 12 --verify '   '); rc=$?
  expect_code 1 "$rc" "a blank --verify must refuse"
  out=$(run_brief "$home" exec-req-c1 widget-repo --executor --issue 12 --verify 'run <VERIFY>'); rc=$?
  expect_code 1 "$rc" "a literal <VERIFY> placeholder must refuse"
  assert_contains "$out" '<VERIFY> placeholder' "the placeholder refusal names it"
  [ ! -e "$home/data/exec-req-c1/brief.md" ] || fail "a refused scaffold must write nothing"
  pass "--issue and --verify are required, shape-checked, and refused when placeholder-literal"
}

test_executor_flag_exclusions() {
  local home out rc
  home=$(new_home excl)
  out=$(run_brief "$home" exec-x-d1 widget-repo --executor --issue 5 --verify 'make ci' --mode direct-PR); rc=$?
  expect_code 1 "$rc" "--mode with --executor must refuse"
  assert_contains "$out" 'inherently direct-PR' "the mode refusal explains the implied delivery"
  out=$(run_brief "$home" exec-x-d1 widget-repo --executor --scout --issue 5 --verify 'make ci'); rc=$?
  expect_code 1 "$rc" "--scout with --executor must refuse"
  assert_contains "$out" 'exactly one' "conflicting kinds are named"
  out=$(run_brief "$home" exec-x-d1 --executor --secondmate --issue 5 --verify 'make ci'); rc=$?
  expect_code 1 "$rc" "--secondmate with --executor must refuse"
  out=$(run_brief "$home" exec-x-d1 widget-repo --executor --issue 5 --verify 'make ci' --herdr-lab); rc=$?
  expect_code 1 "$rc" "--herdr-lab with --executor must refuse"
  assert_contains "$out" 'herdr-lab' "the herdr-lab refusal names the flag"
  out=$(run_brief "$home" ship-x-d2 widget-repo --mode direct-PR --issue 5); rc=$?
  expect_code 1 "$rc" "--issue without --executor must refuse"
  assert_contains "$out" 'apply only to --executor' "the ship refusal names the executor flag"
  out=$(run_brief "$home" scout-x-d3 widget-repo --scout --verify 'make ci'); rc=$?
  expect_code 1 "$rc" "--verify without --executor must refuse"
  [ ! -e "$home/data/exec-x-d1/brief.md" ] || fail "a refused scaffold must write nothing"
  pass "--executor is exclusive with --mode, --scout, --secondmate, and --herdr-lab; --issue/--verify need it"
}

test_contract_reader() {
  local home issue
  home=$(new_home reader)
  run_brief "$home" exec-read-e1 widget-repo --executor --issue 77 --verify 'make ci' >/dev/null
  issue=$(fm_brief_executor_issue "$home/data/exec-read-e1/brief.md") || fail "reader failed on an executor brief"
  [ "$issue" = 77 ] || fail "reader returned '$issue', expected 77"
  run_brief "$home" ship-read-e2 widget-repo --mode direct-PR >/dev/null
  ! fm_brief_executor_issue "$home/data/ship-read-e2/brief.md" >/dev/null \
    || fail "reader accepted a ship brief as an executor brief"
  printf 'The Delivery contract: kind=executor issue=5 line is mentioned in prose\n' > "$home/data/prose.md"
  ! fm_brief_executor_issue "$home/data/prose.md" >/dev/null \
    || fail "a prose mention of the contract must not read as the contract"
  pass "fm_brief_executor_issue reads exactly the executor contract line"
}

test_executor_scaffold_shape
test_executor_brief_omits_interactive_contracts
test_issue_and_verify_are_required_and_validated
test_executor_flag_exclusions
test_contract_reader
