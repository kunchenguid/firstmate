#!/usr/bin/env bash
# Behavior tests for the canonical zero-token verifier and exact-head PR CI wait.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-bounded-direct-pr)
VERIFY="$ROOT/bin/fm-verify.sh"
PR_CI="$ROOT/bin/fm-pr-ci.sh"

make_verify_fixture() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/.agents/skills" "$dir/.claude"
  cp "$VERIFY" "$dir/bin/fm-verify.sh"
  cat > "$dir/bin/fm-lint.sh" <<'SH'
#!/usr/bin/env bash
[ "$#" -eq 1 ] && [ "$1" = --full ] || {
  printf 'expected canonical --full lint mode\n' >&2
  exit 2
}
printf 'lint-ok\n'
SH
  chmod +x "$dir/bin/fm-verify.sh" "$dir/bin/fm-lint.sh"
  printf '%s\n' '@AGENTS.md' > "$dir/CLAUDE.md"
  ln -s ../.agents/skills "$dir/.claude/skills"
  printf '%s\n' '# fixture' > "$dir/AGENTS.md"
  git -C "$dir" init -q
  git -C "$dir" add AGENTS.md CLAUDE.md .claude/skills bin/fm-lint.sh bin/fm-verify.sh
}

test_canonical_verify_contract() {
  local dir out status
  dir="$TMP_ROOT/verify"
  make_verify_fixture "$dir"

  out=$(FM_ROOT_OVERRIDE="$dir" "$dir/bin/fm-verify.sh" 2>&1) \
    || fail "canonical verifier rejected a valid repository fixture: $out"
  assert_contains "$out" "verified: canonical repository checks passed" \
    "canonical verifier did not report its deterministic success"

  printf '%s\n' '@WRONG.md' > "$dir/CLAUDE.md"
  status=0
  out=$(FM_ROOT_OVERRIDE="$dir" "$dir/bin/fm-verify.sh" 2>&1) || status=$?
  expect_code 1 "$status" "canonical verifier must reject a wrong CLAUDE.md target"
  assert_contains "$out" "CLAUDE.md must point to AGENTS.md" \
    "wrong instruction alias refusal was not diagnostic"

  printf '%s\n' '@AGENTS.md' > "$dir/CLAUDE.md"
  mkdir -p "$dir/data"
  printf '%s\n' secret > "$dir/data/tracked.txt"
  git -C "$dir" add -f data/tracked.txt
  status=0
  out=$(FM_ROOT_OVERRIDE="$dir" "$dir/bin/fm-verify.sh" 2>&1) || status=$?
  expect_code 1 "$status" "canonical verifier must reject tracked private fleet data"
  assert_contains "$out" "private fleet paths are tracked" \
    "tracked-private-path refusal was not diagnostic"
  pass "fm-verify provides one deterministic zero-token repository gate"
}

make_pr_fixture() {
  local dir=$1 head=$2 checks=$3
  mkdir -p "$dir/fakebin"
  printf '%s\n' "$head" > "$dir/head"
  printf '%s\n' "$checks" > "$dir/checks"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
cat "$FM_TEST_HEAD"
SH
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
cat "$FM_TEST_CHECKS"
SH
  chmod +x "$dir/fakebin/gh" "$dir/fakebin/gh-axi"
}

run_pr_ci() {
  local dir=$1 expected=$2
  FM_TEST_HEAD="$dir/head" FM_TEST_CHECKS="$dir/checks" \
    PATH="$dir/fakebin:$PATH" \
    "$PR_CI" https://github.com/example/repo/pull/7 "$expected" \
      --attempts 1 --interval 0 2>&1
}

test_exact_head_green_contract() {
  local dir out status sha
  sha=1111111111111111111111111111111111111111
  dir="$TMP_ROOT/pr-green"
  make_pr_fixture "$dir" "$sha" $'summary: 2 passed, 0 failed, 2 total\nchecks[2]{name,conclusion}:\n  Verify exact PR head,pass\n  policy,pass'
  out=$(run_pr_ci "$dir" "$sha") \
    || fail "exact-head wait rejected terminal success: $out"
  assert_contains "$out" "green: https://github.com/example/repo/pull/7 head=$sha checks=2" \
    "exact-head wait did not report the verified identity"

  printf '%s\n' $'summary: 1 passed, 0 failed, 1 pending, 2 total\nchecks[2]{name,conclusion}:\n  Verify exact PR head,pending\n  policy,pass' > "$dir/checks"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "pending checks must not be green"
  assert_contains "$out" "canonical Verify exact PR head check is not terminal-successful" \
    "pending canonical-check refusal was not diagnostic"

  printf '%s\n' $'summary: 2 passed, 0 failed, 2 total\nchecks[2]{name,conclusion}:\n  policy,pass\n  security,pass' > "$dir/checks"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "an all-pass summary without the canonical job must not be green"
  assert_contains "$out" "canonical Verify exact PR head check is missing" \
    "missing canonical-check refusal was not diagnostic"

  printf '%s\n' 2222222222222222222222222222222222222222 > "$dir/head"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "a different PR head must not reuse old green checks"
  assert_contains "$out" "expected head $sha" "wrong-head refusal omitted the expected SHA"

  printf '%s\n' "$sha" > "$dir/head"
  printf '%s\n' $'summary: 1 passed, 0 failed, 1 total\nsummary: 0 passed, 1 failed, 1 total' > "$dir/checks"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "duplicate check summaries must be ambiguous"
  assert_contains "$out" "ambiguous check summary count=2" \
    "duplicate-summary refusal did not identify ambiguity"

  printf '%s\n' 'checks: 0 passed, 0 failed - this PR has no CI checks configured' > "$dir/checks"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "missing checks must not be green"
  assert_contains "$out" "no terminal successful checks" \
    "missing-check refusal was not diagnostic"
  pass "fm-pr-ci accepts only terminal success for the exact PR head"
}

test_canonical_verify_contract
test_exact_head_green_contract
echo "# all bounded direct-PR tests passed"
