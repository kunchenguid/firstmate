#!/usr/bin/env bash
# Focused readiness classification tests for bin/fm-pr-ready.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

READY="$ROOT/bin/fm-pr-ready.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-ready)
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
URL=https://github.com/example/project/pull/42

make_fake_gh() {
  local dir=$1
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    printf '%s\t%s\n' "${FM_FAKE_PR_STATE:-OPEN}" "${FM_FAKE_PR_HEAD:-}"
    ;;
  "api --paginate")
    case "${3:-}" in
      */status\?*) printf '%s\n' "${FM_FAKE_STATUS_ROWS:-}" ;;
      */check-runs\?*) printf '%s\n' "${FM_FAKE_CHECK_ROWS:-}" ;;
      */deployments\?*) printf '%s\n' "${FM_FAKE_DEPLOYMENT_ROWS:-}" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/gh"
}

reset_fake_data() {
  FM_FAKE_PR_STATE=OPEN
  FM_FAKE_PR_HEAD=$HEAD_A
  FM_FAKE_STATUS_ROWS=
  FM_FAKE_CHECK_ROWS=
  FM_FAKE_DEPLOYMENT_ROWS=
  export FM_FAKE_PR_STATE FM_FAKE_PR_HEAD FM_FAKE_STATUS_ROWS FM_FAKE_CHECK_ROWS FM_FAKE_DEPLOYMENT_ROWS
}

run_ready() {
  local dir=$1 expected_head=$2
  FM_FAKE_GH_LOG="$dir/gh.log" PATH="$dir/fakebin:$PATH" "$READY" "$URL" "$expected_head"
}

expect_ready() {
  local name=$1 expected_head=${2:-$HEAD_A} dir out rc
  dir="$TMP_ROOT/$name"
  make_fake_gh "$dir"
  : > "$dir/gh.log"
  set +e
  out=$(run_ready "$dir" "$expected_head" 2> "$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "$name should be ready"
  [ "$out" = ready ] || fail "$name did not print the stable ready result"
  LAST_CASE_DIR=$dir
}

expect_not_ready() {
  local name=$1 expected_head=${2:-$HEAD_A} dir out rc
  dir="$TMP_ROOT/$name"
  make_fake_gh "$dir"
  : > "$dir/gh.log"
  set +e
  out=$(run_ready "$dir" "$expected_head" 2> "$dir/stderr")
  rc=$?
  set -e
  expect_code 1 "$rc" "$name should remain not ready"
  [ -z "$out" ] || fail "$name printed a ready result"
  LAST_CASE_DIR=$dir
}

# The representation observed on stacker-scan PR 657: a commit status named
# Vercel plus an exact-head deployment whose authoritative environment is
# Preview. Pending and failed Preview deployments are both non-blocking.
test_only_vercel_preview_pending() {
  reset_fake_data
  FM_FAKE_STATUS_ROWS=$'Vercel\tpending'
  FM_FAKE_DEPLOYMENT_ROWS="$HEAD_A"$'\tPreview\tfalse\tvercel[bot]'
  expect_ready preview-pending
  pass "only a pending Vercel Preview deployment is ready"
}

test_only_vercel_preview_failed() {
  reset_fake_data
  FM_FAKE_STATUS_ROWS=$'Vercel\tfailure'
  FM_FAKE_DEPLOYMENT_ROWS="$HEAD_A"$'\tPreview\tfalse\tvercel[bot]'
  expect_ready preview-failed
  pass "only a failed Vercel Preview deployment is ready"
}

test_preview_plus_pending_ordinary_check() {
  reset_fake_data
  FM_FAKE_STATUS_ROWS=$'Vercel\tpending'
  FM_FAKE_CHECK_ROWS=$'unit tests\tin_progress\t'
  FM_FAKE_DEPLOYMENT_ROWS="$HEAD_A"$'\tPreview\tfalse\tvercel[bot]'
  expect_not_ready preview-plus-tests
  pass "a pending ordinary check still blocks beside Vercel Preview"
}

test_production_deployment_pending() {
  reset_fake_data
  FM_FAKE_STATUS_ROWS=$'Vercel\tpending'
  FM_FAKE_DEPLOYMENT_ROWS="$HEAD_A"$'\tProduction\ttrue\tvercel[bot]'
  expect_not_ready production-pending
  pass "a pending production Vercel deployment remains blocking"
}

test_unclassified_vercel_status() {
  reset_fake_data
  FM_FAKE_STATUS_ROWS=$'Vercel\tpending'
  FM_FAKE_DEPLOYMENT_ROWS=
  expect_not_ready unclassified-vercel
  pass "a Vercel display status without deployment evidence remains blocking"
}

test_failed_ordinary_status() {
  reset_fake_data
  FM_FAKE_STATUS_ROWS=$'security scan\tfailure'
  expect_not_ready failed-security
  pass "a failed ordinary status remains blocking"
}

test_head_change_rejects_stale_evidence() {
  reset_fake_data
  FM_FAKE_PR_HEAD=$HEAD_B
  FM_FAKE_STATUS_ROWS=$'Vercel\tpending'
  FM_FAKE_DEPLOYMENT_ROWS="$HEAD_A"$'\tPreview\tfalse\tvercel[bot]'
  expect_not_ready changed-head "$HEAD_A"
  assert_no_grep '/commits/' "$LAST_CASE_DIR/gh.log" \
    "changed head should refuse before reading stale status evidence"
  assert_no_grep '/deployments' "$LAST_CASE_DIR/gh.log" \
    "changed head should refuse before reading stale deployment evidence"
  pass "a changed PR head cannot reuse stale readiness evidence"
}

test_only_vercel_preview_pending
test_only_vercel_preview_failed
test_preview_plus_pending_ordinary_check
test_production_deployment_pending
test_unclassified_vercel_status
test_failed_ordinary_status
test_head_change_rejects_stale_evidence
