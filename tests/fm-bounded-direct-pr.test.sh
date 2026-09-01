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
  local dir=$1 head=$2 check_runs=$3 statuses=${4:-}
  mkdir -p "$dir/fakebin"
  printf '%s\n' "$head" > "$dir/head"
  printf '%s\n' "$check_runs" > "$dir/check-runs"
  printf '%s\n' "$statuses" > "$dir/statuses"
  : > "$dir/requirements"
  : > "$dir/gh.log"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case " $* " in
  *"/branches/"*"/protection"*) cat "$FM_TEST_REQUIREMENTS" ;;
  *"/check-runs?"*)
    [ -z "${FM_TEST_ABA_MID_HEAD:-}" ] || printf '%s\n' "$FM_TEST_ABA_MID_HEAD" > "$FM_TEST_HEAD"
    cat "$FM_TEST_CHECK_RUNS"
    ;;
  *"/status?"*)
    [ -z "${FM_TEST_ABA_FINAL_HEAD:-}" ] || printf '%s\n' "$FM_TEST_ABA_FINAL_HEAD" > "$FM_TEST_HEAD"
    cat "$FM_TEST_STATUSES"
    ;;
  *" baseRefName "*) printf '%s\n' main ;;
  *" headRefOid "*) cat "$FM_TEST_HEAD" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$dir/fakebin/gh"
}

run_pr_ci() {
  local dir=$1 expected=$2
  FM_TEST_HEAD="$dir/head" FM_TEST_CHECK_RUNS="$dir/check-runs" \
    FM_TEST_STATUSES="$dir/statuses" FM_TEST_REQUIREMENTS="$dir/requirements" \
    FM_TEST_GH_LOG="$dir/gh.log" \
    PATH="$dir/fakebin:$PATH" \
    "$PR_CI" https://github.com/example/repo/pull/7 "$expected" \
      --attempts 1 --interval 0 2>&1
}

test_exact_head_green_contract() {
  local dir other out status sha
  sha=1111111111111111111111111111111111111111
  dir="$TMP_ROOT/pr-green"
  make_pr_fixture "$dir" "$sha" '' ''
  printf 'require\trequired\tnone\tVerify exact PR head\tnone\tnone\t15368\tnone\n' > "$dir/requirements"
  printf 'result\tcheck\t%s\tVerify exact PR head\tcompleted\tsuccess\t15368\tgithub-actions\n' "$sha" > "$dir/check-runs"
  printf 'result\tstatus\t%s\tpolicy\tcompleted\tsuccess\tnone\tnone\n' "$sha" > "$dir/statuses"
  out=$(run_pr_ci "$dir" "$sha") \
    || fail "exact-head wait rejected terminal success: $out"
  assert_contains "$out" "green: https://github.com/example/repo/pull/7 head=$sha checks=2" \
    "exact-head wait did not report the verified identity"
  assert_grep "repos/example/repo/commits/$sha/check-runs?filter=latest&per_page=100" "$dir/gh.log" \
    "exact-head wait did not query check runs by commit SHA"
  assert_grep "repos/example/repo/commits/$sha/status?per_page=100" "$dir/gh.log" \
    "exact-head wait did not query commit statuses by commit SHA"
  assert_grep 'repos/example/repo/branches/main/protection' "$dir/gh.log" \
    "exact-head wait did not query base-branch protection"

  printf '%s\n' \
    $'require\trequired\tnone\tVerify exact PR head\tnone\tnone\t15368\tnone' \
    $'require\trequired\tnone\tsecurity\tnone\tnone\t42\tnone' > "$dir/requirements"
  printf 'result\tcheck\t%s\tVerify exact PR head\tcompleted\tsuccess\t15368\tgithub-actions\n' "$sha" > "$dir/check-runs"
  : > "$dir/statuses"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "a missing required context must not be green"
  assert_contains "$out" "required check is missing: security" \
    "missing-required-context refusal was not diagnostic"

  printf 'require\trequired\tnone\tVerify exact PR head\tnone\tnone\tany\tnone\n' > "$dir/requirements"
  : > "$dir/check-runs"
  printf 'result\tstatus\t%s\tVerify exact PR head\tcompleted\tsuccess\tnone\tnone\n' "$sha" > "$dir/statuses"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "a same-named commit status must not prove the canonical workflow"
  assert_contains "$out" "canonical Verify exact PR head result is not an authorized GitHub Actions check run" \
    "same-named-status refusal was not diagnostic"

  printf 'require\trequired\tnone\tVerify exact PR head\tnone\tnone\t15368\tnone\n' > "$dir/requirements"
  printf 'result\tcheck\t%s\tVerify exact PR head\tcompleted\tsuccess\t99\tgithub-actions\n' "$sha" > "$dir/check-runs"
  : > "$dir/statuses"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "a provider-mismatched check must not be green"
  assert_contains "$out" "required check provider mismatch: Verify exact PR head" \
    "provider-mismatch refusal was not diagnostic"

  printf 'require\trequired\tnone\tVerify exact PR head\tnone\tnone\t15368\tnone\n' > "$dir/requirements"

  printf 'result\tcheck\t%s\tVerify exact PR head\tin_progress\tnone\t15368\tgithub-actions\n' "$sha" > "$dir/check-runs"
  printf 'result\tstatus\t%s\tpolicy\tcompleted\tsuccess\tnone\tnone\n' "$sha" > "$dir/statuses"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "pending checks must not be green"
  assert_contains "$out" "canonical Verify exact PR head check is not terminal-successful" \
    "pending canonical-check refusal was not diagnostic"

  printf 'result\tcheck\t%s\tpolicy\tcompleted\tsuccess\t42\tpolicy-app\n' "$sha" > "$dir/check-runs"
  printf 'result\tstatus\t%s\tsecurity\tcompleted\tsuccess\tnone\tnone\n' "$sha" > "$dir/statuses"
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
  printf 'result\tcheck\t%s\tVerify exact PR head\tcompleted\tsuccess\t15368\tgithub-actions\n' "$sha" > "$dir/check-runs"
  printf 'result\tstatus\t%s\tVerify exact PR head\tcompleted\tsuccess\tnone\tnone\n' "$sha" > "$dir/statuses"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "duplicate check identities must be ambiguous"
  assert_contains "$out" "ambiguous exact-head check evidence" \
    "duplicate-check refusal did not identify ambiguity"

  : > "$dir/check-runs"
  : > "$dir/statuses"
  status=0
  out=$(run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "missing checks must not be green"
  assert_contains "$out" "no exact-head checks or statuses were found" \
    "missing-check refusal was not diagnostic"

  other=2222222222222222222222222222222222222222
  printf '%s\n' "$sha" > "$dir/head"
  printf 'result\tcheck\t%s\tVerify exact PR head\tcompleted\tsuccess\t15368\tgithub-actions\n' "$other" > "$dir/check-runs"
  : > "$dir/statuses"
  status=0
  out=$(FM_TEST_ABA_MID_HEAD="$other" FM_TEST_ABA_FINAL_HEAD="$sha" run_pr_ci "$dir" "$sha") || status=$?
  expect_code 1 "$status" "an A-to-B-to-A PR race must not attach B checks to A"
  assert_contains "$out" "different-head check evidence" \
    "A-to-B-to-A refusal did not identify the different check head"
  pass "fm-pr-ci accepts only terminal success for the exact PR head"
}

test_canonical_verify_contract
test_exact_head_green_contract
echo "# all bounded direct-PR tests passed"
