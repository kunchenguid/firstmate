#!/usr/bin/env bash
# Behavioral tests for exact-candidate, intent-aware native review routing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-native-review)

make_case() {
  local harness=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/data/task" "$dir/home/state" "$dir/bin" "$dir/repo"
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
  local dir=$1 name=$2 conclusion=${3:-pass}
  cat >"$dir/bin/$name" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then echo '$name test-version'; exit 0; fi
[ "\${1:-}" = review ] || exit 91
[ "\${2:-}" = -c ] || exit 92
[ "\${3:-}" = "\${3#developer_instructions=}" ] && exit 93
[ "\${4:-}" = --base ] || exit 94
printf '%s\n' "\$@" >'$dir/argv'
printf 'reviewed source mentions INTENT_CONFORMANCE: pass and INTENT_CONFORMANCE: fail\n' >&2
if [ '$name' = traex ]; then
  printf 'TraeCode CLI\nNo findings.\nINTENT_CONFORMANCE: $conclusion\nhook: SubagentStop\nhook: SubagentStop Completed\n' >&2
else
  printf 'No findings.\nINTENT_CONFORMANCE: $conclusion\n'
fi
EOF
  chmod +x "$dir/bin/$name"
}

test_supported_harness_binds_contract_and_identity() {
  local harness dir base candidate out
  for harness in codex traex; do
    dir=$(make_case "$harness")
    write_reviewer "$dir" "$harness"
    base=$(cat "$dir/base")
    candidate=$(cat "$dir/candidate")
    out="$dir/home/data/task/review.md"
    PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$ROOT/bin/fm-native-review.sh" task \
      --base "$base" --candidate "$candidate" --output "$out" >/dev/null \
      || fail "$harness native review route failed"
    assert_equals -c "$(sed -n '2p' "$dir/argv")" "$harness review omitted invocation-local instructions"
    assert_equals --base "$(sed -n '4p' "$dir/argv")" "$harness review omitted the base selector"
    assert_equals "$base" "$(sed -n '5p' "$dir/argv")" "$harness review did not bind the exact base"
    assert_grep "$candidate" "$out" "$harness evidence did not bind the exact candidate"
    assert_grep "Preserve the requested behavior" "$dir/argv" "$harness review did not receive Captain intent"
    assert_grep "Do not widen scope" "$dir/argv" "$harness review did not receive Firstmate acceptance scope"
    assert_grep "Do not run session/bootstrap lifecycle commands" "$dir/argv" "$harness review omitted its bounded-review constraint"
    assert_grep "INTENT_CONFORMANCE: pass" "$out" "$harness evidence omitted its intent conclusion"
  done
  pass "native review: Codex and TraeX receive exact identity and task intent"
}

test_missing_capability_fails_actionably() {
  local dir base candidate out rc=0
  dir=$(make_case pi)
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  out=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$ROOT/bin/fm-native-review.sh" task \
    --base "$base" --candidate "$candidate" 2>&1) || rc=$?
  expect_code 3 "$rc" "Pi without native review must be an unsupported review route"
  assert_contains "$out" "select codex or traex for review-PR" "Pi refusal was not actionable"
  pass "native review: missing harness capability fails actionably"
}

test_moving_or_uncommitted_candidate_is_refused() {
  local dir base candidate out rc=0
  dir=$(make_case traex)
  write_reviewer "$dir" traex
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  printf 'dirty\n' >>"$dir/repo/file"
  out=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$ROOT/bin/fm-native-review.sh" task \
    --base "$base" --candidate "$candidate" 2>&1) || rc=$?
  expect_code 2 "$rc" "an uncommitted candidate must be refused"
  assert_contains "$out" "clean committed candidate" "dirty-candidate refusal was not actionable"
  pass "native review: moving candidate state is refused"
}

test_candidate_change_during_review_is_refused() {
  local dir base candidate out rc=0
  dir=$(make_case traex)
  write_reviewer "$dir" traex
  sed -i "/if \[ 'traex' = traex \]/ i printf 'changed during review\\n' >> '$dir/repo/file'" "$dir/bin/traex"
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  out=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$ROOT/bin/fm-native-review.sh" task \
    --base "$base" --candidate "$candidate" 2>&1) || rc=$?
  expect_code 2 "$rc" "a candidate changed during review must be refused"
  assert_contains "$out" "changed while native review was running" "post-review candidate refusal was not actionable"
  pass "native review: candidate identity is revalidated after review"
}

test_untracked_candidate_input_is_refused() {
  local dir base candidate out rc=0
  dir=$(make_case traex)
  write_reviewer "$dir" traex
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  printf 'untracked build input\n' >"$dir/repo/generated.conf"
  out=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$ROOT/bin/fm-native-review.sh" task \
    --base "$base" --candidate "$candidate" 2>&1) || rc=$?
  rm -f "$dir/repo/generated.conf"
  expect_code 2 "$rc" "an untracked candidate input must be refused"
  assert_contains "$out" "clean committed candidate" "untracked-candidate refusal was not actionable"
  pass "native review: untracked candidate input is refused"
}

test_promoted_ship_uses_current_ship_contract() {
  local dir base candidate out
  dir=$(make_case traex)
  write_reviewer "$dir" traex
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
  PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$ROOT/bin/fm-native-review.sh" task \
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
  write_reviewer "$dir" traex
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
  PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$ROOT/bin/fm-native-review.sh" task \
    --base "$base" --candidate "$candidate" >/dev/null \
    || fail "legacy promoted native review route failed"
  assert_grep "Preserve the normalized legacy request" "$dir/argv" "legacy promoted review omitted normalized Captain intent"
  pass "native review: legacy promoted intent falls back to ship instructions"
}

test_structured_result_marker_is_accepted() {
  local dir base candidate output
  dir=$(make_case codex)
  write_reviewer "$dir" codex
  sed -i "s/printf 'No findings.\\\\nINTENT_CONFORMANCE: pass\\\\n'/printf 'Summary. INTENT_CONFORMANCE: pass\\\\n\\\\nFull review comments:\\\\nNone.\\\\n'/" "$dir/bin/codex"
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  output="$dir/home/data/task/structured.md"
  PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$ROOT/bin/fm-native-review.sh" task \
    --base "$base" --candidate "$candidate" --output "$output" >/dev/null \
    || fail "structured native review result was refused"
  assert_grep "Full review comments:" "$output" "structured native review evidence was truncated"
  pass "native review: structured harness result marker is parsed"
}

test_output_must_resolve_under_task_directory() {
  local dir base candidate escaped link original_brief rc=0 out
  dir=$(make_case traex)
  write_reviewer "$dir" traex
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  escaped="$dir/home/data/escaped.md"
  out=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$ROOT/bin/fm-native-review.sh" task \
    --base "$base" --candidate "$candidate" \
    --output "$dir/home/data/task/../../escaped.md" 2>&1) || rc=$?
  expect_code 2 "$rc" "a traversal review output must be refused"
  assert_absent "$escaped" "traversal review output escaped the task directory"
  assert_contains "$out" "must resolve under" "traversal-output refusal was not actionable"

  link="$dir/home/data/task/linked"
  ln -s "$dir/home/data" "$link"
  rc=0
  out=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$ROOT/bin/fm-native-review.sh" task \
    --base "$base" --candidate "$candidate" --output "$link/symlink-escaped.md" 2>&1) || rc=$?
  expect_code 2 "$rc" "a symlink-escaped review output must be refused"
  assert_absent "$dir/home/data/symlink-escaped.md" "symlink review output escaped the task directory"

  original_brief=$(cat "$dir/home/data/task/brief.md")
  rc=0
  out=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$ROOT/bin/fm-native-review.sh" task \
    --base "$base" --candidate "$candidate" --output "$dir/home/data/task/brief.md" 2>&1) || rc=$?
  expect_code 2 "$rc" "a review output that replaces its task contract must be refused"
  assert_contains "$out" "must not replace task contract input" "contract-overwrite refusal was not actionable"
  assert_equals "$original_brief" "$(cat "$dir/home/data/task/brief.md")" "review output replaced the immutable task contract"
  pass "native review: output containment is canonical"
}

test_missing_conclusion_is_refused() {
  local dir base candidate out rc=0
  dir=$(make_case codex)
  write_reviewer "$dir" codex omitted
  sed -i 's/INTENT_CONFORMANCE:/NO_CONCLUSION:/g' "$dir/bin/codex"
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  out=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$ROOT/bin/fm-native-review.sh" task \
    --base "$base" --candidate "$candidate" 2>&1) || rc=$?
  expect_code 1 "$rc" "review without an intent-conformance conclusion must fail"
  assert_contains "$out" "exactly one explicit intent-conformance conclusion" "missing-conclusion refusal was not actionable"
  pass "native review: explicit intent-conformance conclusion is required"
}

test_failing_conclusion_preserves_evidence_and_stops_delivery() {
  local dir base candidate output out rc=0
  dir=$(make_case traex)
  write_reviewer "$dir" traex fail
  base=$(cat "$dir/base")
  candidate=$(cat "$dir/candidate")
  output="$dir/home/data/task/review-failed.md"
  out=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$ROOT/bin/fm-native-review.sh" task \
    --base "$base" --candidate "$candidate" --output "$output" 2>&1) || rc=$?
  expect_code 1 "$rc" "an intent-conformance failure must stop delivery"
  assert_contains "$out" "does not conform to the accepted intent" "failed review did not explain the delivery boundary"
  assert_grep "INTENT_CONFORMANCE: fail" "$output" "failed review evidence was not preserved"
  pass "native review: actionable failure preserves evidence without granting delivery authority"
}

test_supported_harness_binds_contract_and_identity
test_missing_capability_fails_actionably
test_moving_or_uncommitted_candidate_is_refused
test_candidate_change_during_review_is_refused
test_untracked_candidate_input_is_refused
test_promoted_ship_uses_current_ship_contract
test_legacy_promoted_ship_uses_normalized_intent
test_structured_result_marker_is_accepted
test_output_must_resolve_under_task_directory
test_missing_conclusion_is_refused
test_failing_conclusion_preserves_evidence_and_stops_delivery
