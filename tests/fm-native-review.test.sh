#!/usr/bin/env bash
# Behavioral tests for exact-candidate, intent-aware native review routing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-native-review)

make_case() {
  local harness=$1 dir
  dir=$(mktemp -d "$TMP_ROOT/$harness.XXXXXX") || fail "could not create native-review fixture"
  mkdir -p "$dir/home/data/task" "$dir/home/state" "$dir/home/config" "$dir/codex" "$dir/bin" "$dir/repo"
  git -C "$dir/repo" init -q
  git -C "$dir/repo" config user.email test@example.com
  git -C "$dir/repo" config user.name test
  printf 'base\n' >"$dir/repo/file"
  git -C "$dir/repo" add file
  git -C "$dir/repo" commit -qm base
  git -C "$dir/repo" rev-parse HEAD >"$dir/base"
  printf 'candidate\n' >>"$dir/repo/file"
  git -C "$dir/repo" commit -qam candidate
  git -C "$dir/repo" rev-parse HEAD >"$dir/candidate"
  printf 'worktree=%s\nharness=%s\n' "$dir/repo" "$harness" >"$dir/home/state/task.meta"
  printf '%s\n' '{"schema":"fm-native-review-config.v1","harness":"codex","model":"gpt-6.1-sol","effort":"xhigh"}' >"$dir/home/config/native-review.json"
  printf '%s\n' '{"models":[{"slug":"gpt-6.1-sol","supported_reasoning_levels":[{"effort":"xhigh"}]}]}' >"$dir/codex/models_cache.json"
  cat >"$dir/home/data/task/brief.md" <<'EOF'
# Task
## Captain's intent
Preserve the requested behavior.

## Firstmate spec
Do not widen scope.
EOF
  printf '%s\n' "$dir"
}

write_reviewer() {
  local dir=$1 conclusion=${2:-pass}
  cat >"$dir/bin/codex" <<EOF
#!/usr/bin/env bash
set -eu
if [ "\${1:-}" = --version ]; then echo 'codex test-version'; exit 0; fi
if [ "\${1:-}" = --help ]; then echo 'Usage: codex --model MODEL'; exit 0; fi
if [ "\${1:-}" = login ] && [ "\${2:-}" = status ]; then
  [ "\${FM_TEST_REVIEW_AUTH:-ok}" = ok ] || exit 9
  echo 'Logged in'
  exit 0
fi
if [ "\${1:-}" = review ] && [ "\${2:-}" = --help ]; then echo 'Usage: codex review --base BASE'; exit 0; fi
if [ "\${1:-}" = app-server ] && [ "\${2:-}" = --stdio ]; then
  while IFS= read -r line; do
    id=\$(printf '%s\n' "\$line" | jq -r '.id // empty')
    case "\$id" in
      fm-quota-initialize) printf '%s\n' '{"id":"fm-quota-initialize","result":{"userAgent":"fixture"}}' ;;
      fm-quota-read)
        if [ "\${FM_TEST_REVIEW_QUOTA:-ok}" = ok ]; then allowed=true; else allowed=false; fi
        printf '%s\n' "{\"id\":\"fm-quota-read\",\"result\":{\"ordinaryUsageAllowed\":\$allowed,\"rateLimits\":{\"limitId\":\"codex\",\"planType\":\"pro\",\"primary\":{\"usedPercent\":1,\"windowDurationMins\":300,\"resetsAt\":1767225600},\"secondary\":null},\"rateLimitsByLimitId\":{},\"rateLimitResetCredits\":{\"availableCount\":0}}}"
        ;;
    esac
  done
  exit 0
fi
[ "\${1:-}" = --model ] || exit 91
[ "\${2:-}" = gpt-6.1-sol ] || exit 92
[ "\${3:-}" = review ] || exit 93
[ "\${4:-}" = -c ] || exit 94
[ "\${5:-}" = 'model_reasoning_effort="xhigh"' ] || exit 95
[ "\${6:-}" = -c ] || exit 96
[ "\${7:-}" = "\${7#developer_instructions=}" ] && exit 97
[ "\${8:-}" = --base ] || exit 98
printf '%s\n' "\$@" >'$dir/argv'
printf 'reviewed source mentions INTENT_CONFORMANCE: pass and INTENT_CONFORMANCE: fail\n' >&2
printf 'No findings.\nINTENT_CONFORMANCE: $conclusion\n'
EOF
  chmod +x "$dir/bin/codex"
}

run_review() {
  local dir=$1
  shift
  CODEX_HOME="$dir/codex" PATH="$dir/bin:$PATH" FM_HOME="$dir/home" \
    "$ROOT/bin/fm-native-review.sh" "$@"
}

test_worker_harnesses_use_configured_reviewer() {
  local harness dir base candidate out
  for harness in pi codex traex; do
    dir=$(make_case "$harness")
    write_reviewer "$dir"
    base=$(cat "$dir/base")
    candidate=$(cat "$dir/candidate")
    out="$dir/home/data/task/review.md"
    run_review "$dir" task \
      --base "$base" --candidate "$candidate" --output "$out" >/dev/null \
      || fail "$harness coding task did not use configured Codex review"
    assert_equals --model "$(sed -n '1p' "$dir/argv")" "$harness review omitted explicit model selection"
    assert_equals gpt-6.1-sol "$(sed -n '2p' "$dir/argv")" "$harness review selected the wrong model"
    assert_equals review "$(sed -n '3p' "$dir/argv")" "$harness review misplaced the native review subcommand"
    assert_equals 'model_reasoning_effort="xhigh"' "$(sed -n '5p' "$dir/argv")" "$harness review omitted review-local effective effort"
    assert_equals --base "$(sed -n '8p' "$dir/argv")" "$harness review omitted the base selector"
    assert_equals "$base" "$(sed -n '9p' "$dir/argv")" "$harness review did not bind the exact base"
    assert_grep "$candidate" "$out" "$harness evidence did not bind the exact candidate"
    assert_grep "Coding harness: \`$harness\`" "$out" "$harness coding identity was not retained separately"
    assert_grep "Reviewer harness: \`codex\`" "$out" "$harness evidence omitted reviewer identity"
    assert_grep "Reviewer model: \`gpt-6.1-sol\`" "$out" "$harness evidence omitted reviewer model"
    assert_grep "Reviewer effort: \`xhigh\`" "$out" "$harness evidence omitted reviewer effort"
    assert_grep "Preserve the requested behavior" "$dir/argv" "$harness review did not receive Captain intent"
    assert_grep "Do not widen scope" "$dir/argv" "$harness review did not receive Firstmate acceptance scope"
    assert_grep "Do not run session/bootstrap lifecycle commands" "$dir/argv" "$harness review omitted its bounded-review constraint"
    assert_grep "INTENT_CONFORMANCE: pass" "$out" "$harness evidence omitted its intent conclusion"
  done
  pass "native review: Pi, Codex, and TraeX coding tasks use the configured Codex reviewer"
}

test_ordinary_brief_edit_rebinds_review_intent() {
  local dir base candidate out
  dir=$(make_case codex)
  write_reviewer "$dir"
  cat >"$dir/home/data/task/brief.md" <<'EOF'
# Task
## Captain's intent
确认不是通过枚举的方式来覆盖这些场景。

### 验收
使用行为测试验证开放式分类。

## Firstmate spec
Do not widen scope.
EOF
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  out="$dir/home/data/task/ordinary-edit-review.md"
  run_review "$dir" task \
    --base "$base" --candidate "$candidate" --output "$out" >/dev/null \
    || fail "native review rejected an ordinarily edited brief"
  assert_grep '\u786e\u8ba4\u4e0d\u662f\u901a\u8fc7\u679a\u4e3e\u7684\u65b9\u5f0f' "$dir/argv" \
    "native review did not receive processed Intent from an ordinary brief edit"
  assert_grep '### \u9a8c\u6536' "$dir/argv" \
    "native review lost multiline structured Intent from an ordinary brief edit"
  assert_no_grep 'Preserve the requested behavior' "$dir/argv" \
    "native review retained the stale pre-edit Intent"
  pass "native review: ordinary brief edits replace the review Intent"
}

test_missing_or_invalid_configuration_fails_actionably() {
  local dir base candidate out rc=0
  dir=$(make_case pi)
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  rm "$dir/home/config/native-review.json"
  out=$(run_review "$dir" task \
    --base "$base" --candidate "$candidate" 2>&1) || rc=$?
  expect_code 3 "$rc" "missing native review configuration must fail"
  assert_contains "$out" "native review configuration is missing or unsafe" "missing configuration refusal was not actionable"
  assert_absent "$dir/argv" "missing configuration silently invoked the coding harness"

  printf '%s\n' '{"schema":"fm-native-review-config.v1","harness":"traex","model":"gpt-6.1-sol","effort":"xhigh"}' >"$dir/home/config/native-review.json"
  rc=0
  out=$(run_review "$dir" task --base "$base" --candidate "$candidate" 2>&1) || rc=$?
  expect_code 3 "$rc" "unsupported configured reviewer must fail"
  assert_contains "$out" "unsupported configured native review harness: traex" "unsupported reviewer refusal was not actionable"
  assert_absent "$dir/argv" "unsupported configuration silently invoked another harness"
  pass "native review: missing or invalid configuration fails without fallback"
}

test_explicit_selection_and_capability_failures() {
  local dir base candidate out rc=0
  dir=$(make_case traex)
  write_reviewer "$dir"
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  rm "$dir/home/config/native-review.json"
  run_review "$dir" task --base "$base" --candidate "$candidate" \
    --output "$dir/home/data/task/explicit.md" \
    --review-harness codex --model gpt-6.1-sol --effort xhigh >/dev/null \
    || fail "complete explicit native review selection was rejected"
  assert_grep "Reviewer model: \`gpt-6.1-sol\`" "$dir/home/data/task/explicit.md" \
    "explicit reviewer selection was not recorded"

  rm "$dir/codex/models_cache.json"
  rm -f "$dir/argv"
  printf '%s\n' 'next candidate' >>"$dir/repo/file"
  git -C "$dir/repo" commit -qam next
  candidate=$(git -C "$dir/repo" rev-parse HEAD)
  rc=0
  out=$(run_review "$dir" task --base "$base" --candidate "$candidate" \
    --review-harness codex --model gpt-6.1-sol --effort xhigh 2>&1) || rc=$?
  expect_code 3 "$rc" "missing model capability cache must fail"
  assert_contains "$out" "model capability cache is missing or unsafe" "missing capability refusal was not actionable"
  assert_absent "$dir/argv" "missing model capability silently invoked Codex review"
  pass "native review: complete explicit selection works and missing capability fails without fallback"
}

test_auth_and_quota_fail_without_fallback() {
  local dir base candidate out rc=0
  dir=$(make_case pi)
  write_reviewer "$dir"
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  out=$(FM_TEST_REVIEW_AUTH=unavailable run_review "$dir" task \
    --base "$base" --candidate "$candidate" 2>&1) || rc=$?
  expect_code 3 "$rc" "unavailable Codex authentication must fail"
  assert_contains "$out" "Codex authentication is unavailable" "authentication refusal was not actionable"
  assert_absent "$dir/argv" "authentication failure silently fell back to the Pi coding harness"

  rc=0
  out=$(FM_TEST_REVIEW_QUOTA=unavailable run_review "$dir" task \
    --base "$base" --candidate "$candidate" 2>&1) || rc=$?
  expect_code 3 "$rc" "unavailable Codex quota must fail"
  assert_contains "$out" "quota does not currently allow ordinary usage" "quota refusal was not actionable"
  assert_absent "$dir/argv" "quota failure silently fell back to the Pi coding harness"
  pass "native review: Codex authentication and quota failures do not fall back"
}

test_moving_or_uncommitted_candidate_is_refused() {
  local dir base candidate out rc=0
  dir=$(make_case traex)
  write_reviewer "$dir"
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  printf 'dirty\n' >>"$dir/repo/file"
  out=$(run_review "$dir" task \
    --base "$base" --candidate "$candidate" 2>&1) || rc=$?
  expect_code 2 "$rc" "an uncommitted candidate must be refused"
  assert_contains "$out" "clean committed candidate" "dirty-candidate refusal was not actionable"
  pass "native review: moving candidate state is refused"
}

test_candidate_change_during_review_is_refused() {
  local dir base candidate out rc=0
  dir=$(make_case traex)
  write_reviewer "$dir"
  sed -i "/printf 'No findings/ i printf 'changed during review\\n' >> '$dir/repo/file'" "$dir/bin/codex"
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  out=$(run_review "$dir" task \
    --base "$base" --candidate "$candidate" 2>&1) || rc=$?
  expect_code 2 "$rc" "a candidate changed during review must be refused"
  assert_contains "$out" "changed while native review was running" "post-review candidate refusal was not actionable"
  pass "native review: candidate identity is revalidated after review"
}

test_untracked_candidate_input_is_refused() {
  local dir base candidate out rc=0
  dir=$(make_case traex)
  write_reviewer "$dir"
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  printf 'untracked build input\n' >"$dir/repo/generated.conf"
  out=$(run_review "$dir" task \
    --base "$base" --candidate "$candidate" 2>&1) || rc=$?
  rm -f "$dir/repo/generated.conf"
  expect_code 2 "$rc" "an untracked candidate input must be refused"
  assert_contains "$out" "clean committed candidate" "untracked-candidate refusal was not actionable"
  pass "native review: untracked candidate input is refused"
}

test_promoted_ship_uses_current_ship_contract() {
  local dir base candidate out
  dir=$(make_case traex)
  write_reviewer "$dir"
  cat >"$dir/home/data/task/ship-instructions.md" <<'EOF'
# Task
## Captain's intent
Deliver the promoted implementation.

## Firstmate spec
Verify the ship-time acceptance and exclusions.
EOF
  python3 - "$dir/home/data/task/brief.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace('Preserve the requested behavior.',
                    'Deliver the promoted implementation.\n\nHonor the later authenticated clarification.')
path.write_text(text)
PY
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  out="$dir/home/data/task/promoted-review.md"
  run_review "$dir" task \
    --base "$base" --candidate "$candidate" --output "$out" >/dev/null \
    || fail "promoted native review route failed"
  assert_grep "Deliver the promoted implementation" "$dir/argv" "promoted review omitted current Captain intent"
  assert_grep "Honor the later authenticated clarification" "$dir/argv" "promoted review omitted later authenticated Captain intent"
  assert_grep "Verify the ship-time acceptance and exclusions" "$dir/argv" "promoted review omitted current ship spec"
  assert_grep "ship-instructions.md (current ship spec)" "$out" "promoted review evidence omitted its composite current contract source"
  pass "native review: promoted ships use the current ship-time contract"
}

test_legacy_promoted_ship_uses_normalized_intent() {
  local dir base candidate
  dir=$(make_case traex)
  write_reviewer "$dir"
  cat >"$dir/home/data/task/brief.md" <<'EOF'
# Task
Legacy unsectioned scout instructions.
EOF
  cat >"$dir/home/data/task/ship-instructions.md" <<'EOF'
# Task
## Captain's intent
Preserve the normalized legacy request.

## Firstmate spec
Apply the current promoted acceptance contract.
EOF
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  run_review "$dir" task \
    --base "$base" --candidate "$candidate" >/dev/null \
    || fail "legacy promoted native review route failed"
  assert_grep "Preserve the normalized legacy request" "$dir/argv" "legacy promoted review omitted normalized Captain intent"
  pass "native review: legacy promoted intent falls back to ship instructions"
}

test_structured_result_marker_is_accepted() {
  local dir base candidate output
  dir=$(make_case codex)
  write_reviewer "$dir"
  sed -i "s/printf 'No findings.\\\\nINTENT_CONFORMANCE: pass\\\\n'/printf 'Summary. INTENT_CONFORMANCE: pass\\\\n\\\\nFull review comments:\\\\nNone.\\\\n'/" "$dir/bin/codex"
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  output="$dir/home/data/task/structured.md"
  run_review "$dir" task \
    --base "$base" --candidate "$candidate" --output "$output" >/dev/null \
    || fail "structured native review result was refused"
  assert_grep "Full review comments:" "$output" "structured native review evidence was truncated"
  pass "native review: structured harness result marker is parsed"
}

test_output_must_resolve_under_task_directory() {
  local dir base candidate escaped link original_brief rc=0 out
  dir=$(make_case traex)
  write_reviewer "$dir"
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  escaped="$dir/home/data/escaped.md"
  out=$(run_review "$dir" task \
    --base "$base" --candidate "$candidate" \
    --output "$dir/home/data/task/../../escaped.md" 2>&1) || rc=$?
  expect_code 2 "$rc" "a traversal review output must be refused"
  assert_absent "$escaped" "traversal review output escaped the task directory"
  assert_contains "$out" "must resolve under" "traversal-output refusal was not actionable"

  link="$dir/home/data/task/linked"
  ln -s "$dir/home/data" "$link"
  rc=0
  out=$(run_review "$dir" task \
    --base "$base" --candidate "$candidate" --output "$link/symlink-escaped.md" 2>&1) || rc=$?
  expect_code 2 "$rc" "a symlink-escaped review output must be refused"
  assert_absent "$dir/home/data/symlink-escaped.md" "symlink review output escaped the task directory"

  original_brief=$(cat "$dir/home/data/task/brief.md")
  rc=0
  out=$(run_review "$dir" task \
    --base "$base" --candidate "$candidate" --output "$dir/home/data/task/brief.md" 2>&1) || rc=$?
  expect_code 2 "$rc" "a review output that replaces its task contract must be refused"
  assert_contains "$out" "must not replace task contract input" "contract-overwrite refusal was not actionable"
  assert_equals "$original_brief" "$(cat "$dir/home/data/task/brief.md")" "review output replaced the immutable task contract"
  pass "native review: output containment is canonical"
}

test_missing_conclusion_is_refused() {
  local dir base candidate out rc=0
  dir=$(make_case codex)
  write_reviewer "$dir" omitted
  sed -i 's/INTENT_CONFORMANCE:/NO_CONCLUSION:/g' "$dir/bin/codex"
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  out=$(run_review "$dir" task \
    --base "$base" --candidate "$candidate" 2>&1) || rc=$?
  expect_code 1 "$rc" "review without an intent-conformance conclusion must fail"
  assert_contains "$out" "exactly one explicit intent-conformance conclusion" "missing-conclusion refusal was not actionable"
  pass "native review: explicit intent-conformance conclusion is required"
}

test_failing_conclusion_preserves_evidence_and_stops_delivery() {
  local dir base candidate output out rc=0
  dir=$(make_case traex)
  write_reviewer "$dir" fail
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  output="$dir/home/data/task/review-failed.md"
  out=$(run_review "$dir" task \
    --base "$base" --candidate "$candidate" --output "$output" 2>&1) || rc=$?
  expect_code 1 "$rc" "an intent-conformance failure must stop delivery"
  assert_contains "$out" "does not conform to the accepted intent" "failed review did not explain the delivery boundary"
  assert_grep "INTENT_CONFORMANCE: fail" "$output" "failed review evidence was not preserved"
  pass "native review: actionable failure preserves evidence without granting delivery authority"
}

test_original_task_review_attempts_are_capped_at_two() {
  local dir base candidate second third out rc=0 calls
  dir=$(make_case codex)
  write_reviewer "$dir"
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  run_review "$dir" task \
    --base "$base" --candidate "$candidate" --output "$dir/home/data/task/first.md" >/dev/null \
    || fail "first native review attempt failed"

  printf 'second candidate\n' >> "$dir/repo/file"
  git -C "$dir/repo" commit -qam second
  second=$(git -C "$dir/repo" rev-parse HEAD)
  run_review "$dir" task \
    --base "$base" --candidate "$second" --output "$dir/home/data/task/renamed-second.md" >/dev/null \
    || fail "second native review attempt failed after a candidate change"

  printf 'third candidate\n' >> "$dir/repo/file"
  git -C "$dir/repo" commit -qam third
  third=$(git -C "$dir/repo" rev-parse HEAD)
  rc=0
  out=$(run_review "$dir" task \
    --base "$base" --candidate "$third" --output "$dir/home/data/task/third.md" 2>&1) || rc=$?
  expect_code 4 "$rc" "a third review attempt for the original task must be refused"
  assert_contains "$out" "attempt limit reached for original task task (2/2)" "third-attempt refusal omitted the stable task boundary"
  assert_contains "$out" "ask MAIN to decide only a severe" "third-attempt refusal did not route the exceptional decision"
  assert_absent "$dir/home/data/task/third.md" "third-attempt refusal fabricated review evidence"
  calls=$(find "$dir/home/data/task" -name 'native-review-attempt-*.record' -type f | wc -l | tr -d ' ')
  assert_equals 2 "$calls" "candidate changes or output renaming reset the task review count"
  pass "native review: one original task cannot automatically exceed two attempts"
}

test_existing_review_evidence_counts_toward_cap() {
  local dir base candidate out rc=0
  dir=$(make_case traex)
  write_reviewer "$dir"
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  printf '# Native review evidence\n\nHistorical attempt one.\n' > "$dir/home/data/task/old-name.md"
  printf '# Native review evidence\n\nHistorical attempt two.\n' > "$dir/home/data/task/renamed-history.md"
  out=$(run_review "$dir" task \
    --base "$base" --candidate "$candidate" 2>&1) || rc=$?
  expect_code 4 "$rc" "historical review evidence must prevent an automatic third attempt"
  assert_contains "$out" "attempt limit reached for original task task (2/2)" "historical-attempt refusal was not actionable"
  assert_absent "$dir/argv" "historical-attempt refusal still invoked the harness"
  pass "native review: retained historical attempts cannot be reset"
}

test_worker_harnesses_use_configured_reviewer
test_ordinary_brief_edit_rebinds_review_intent
test_missing_or_invalid_configuration_fails_actionably
test_explicit_selection_and_capability_failures
test_auth_and_quota_fail_without_fallback
test_moving_or_uncommitted_candidate_is_refused
test_candidate_change_during_review_is_refused
test_untracked_candidate_input_is_refused
test_promoted_ship_uses_current_ship_contract
test_legacy_promoted_ship_uses_normalized_intent
test_structured_result_marker_is_accepted
test_output_must_resolve_under_task_directory
test_missing_conclusion_is_refused
test_failing_conclusion_preserves_evidence_and_stops_delivery
test_original_task_review_attempts_are_capped_at_two
test_existing_review_evidence_counts_toward_cap
