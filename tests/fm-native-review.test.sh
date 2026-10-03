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
printf 'No findings.\nINTENT_CONFORMANCE: $conclusion\n'
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

test_missing_conclusion_is_refused() {
  local dir base candidate out rc=0
  dir=$(make_case codex)
  write_reviewer "$dir" codex omitted
  sed -i '/INTENT_CONFORMANCE:/d' "$dir/bin/codex"
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
test_missing_conclusion_is_refused
test_failing_conclusion_preserves_evidence_and_stops_delivery
