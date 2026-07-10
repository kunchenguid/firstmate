#!/usr/bin/env bash
# Tests for bin/fm-pr-check.sh's generated PR poll (state/<id>.check.sh), the
# comment-aware watcher check. The generator arms a poll that must honor the
# check contract - one line of stdout only when firstmate should wake, silence
# otherwise - across:
#   (a) first poll records the review-activity baseline silently (no wake)
#   (b) new activity since the baseline wakes with one "new-review-activity" line
#   (c) unchanged activity stays silent
#   (d) a merged PR wins: only "merged", never the activity line, one line total
#   (e) a gh error stays silent and never corrupts the marker (existing or first)
#   (f) a fallen count resyncs the marker silently (no spurious wake)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)
URL="https://github.com/example/repo/pull/7"

# A gh mock the generated check drives. It answers the state and the
# reviews+comments count from env, and fails outright when FM_TEST_GH_FAIL is
# set so the check exercises its error path. Any other call (e.g. the arm-time
# headRefOid lookup) is a no-op exit 0.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_TEST_GH_FAIL:-}" ] && exit 1
case " $* " in
  *" --json state "*) printf '%s\n' "${FM_TEST_PR_STATE:-OPEN}"; exit 0 ;;
  *"reviews,comments"*) printf '%s\n' "${FM_TEST_PR_COUNT:-0}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$case_dir"
}

arm_check() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" pr-x1 "$URL" >/dev/null
}

# Run the generated check once with the given state/count/fail env, echoing its
# stdout (what the watcher would treat as the wake reason).
poll() {
  local case_dir=$1 state=$2 count=$3 fail=${4:-}
  FM_TEST_PR_STATE="$state" \
  FM_TEST_PR_COUNT="$count" \
  FM_TEST_GH_FAIL="$fail" \
  PATH="$case_dir/fakebin:$PATH" \
    bash "$case_dir/state/pr-x1.check.sh"
}

ACT_PATH() { printf '%s/state/pr-x1.pr-activity' "$1"; }

test_generated_check_is_valid_bash() {
  local case_dir
  case_dir=$(make_case valid-bash)
  arm_check "$case_dir"
  bash -n "$case_dir/state/pr-x1.check.sh" \
    || fail "valid-bash: generated check.sh is not valid bash"
  pass "generated check.sh parses as valid bash"
}

test_baseline_init_is_silent() {
  local case_dir out
  case_dir=$(make_case baseline)
  arm_check "$case_dir"
  assert_absent "$(ACT_PATH "$case_dir")" "baseline: marker existed before first poll"

  out=$(poll "$case_dir" OPEN 3)
  [ -z "$out" ] || fail "baseline: first poll woke firstmate (output: '$out')"
  assert_present "$(ACT_PATH "$case_dir")" "baseline: marker not created on first poll"
  assert_grep "3" "$(ACT_PATH "$case_dir")" "baseline: marker did not record the current count"
  pass "first poll records the review-activity baseline silently"
}

test_wake_on_increase() {
  local case_dir out
  case_dir=$(make_case increase)
  arm_check "$case_dir"
  poll "$case_dir" OPEN 3 >/dev/null   # baseline

  out=$(poll "$case_dir" OPEN 5)
  assert_contains "$out" "new-review-activity: +2 on $URL" \
    "increase: activity wake line missing or malformed"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    || fail "increase: check emitted more than one line ('$out')"
  assert_grep "5" "$(ACT_PATH "$case_dir")" "increase: marker not advanced to the new count"
  pass "new activity since the baseline wakes with one delta line and advances the marker"
}

test_silence_on_no_change() {
  local case_dir out
  case_dir=$(make_case no-change)
  arm_check "$case_dir"
  poll "$case_dir" OPEN 5 >/dev/null   # baseline

  out=$(poll "$case_dir" OPEN 5)
  [ -z "$out" ] || fail "no-change: unchanged activity woke firstmate (output: '$out')"
  assert_grep "5" "$(ACT_PATH "$case_dir")" "no-change: marker drifted off the count"
  pass "unchanged activity stays silent"
}

test_merged_beats_activity() {
  local case_dir out
  case_dir=$(make_case merged-wins)
  arm_check "$case_dir"
  poll "$case_dir" OPEN 5 >/dev/null   # baseline

  # A merged PR that also gained activity: merged must win with exactly one line.
  out=$(poll "$case_dir" MERGED 9)
  assert_contains "$out" "merged" "merged-wins: merge was not reported"
  assert_not_contains "$out" "new-review-activity" \
    "merged-wins: activity line leaked alongside merged"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    || fail "merged-wins: check emitted more than one line ('$out')"
  assert_grep "5" "$(ACT_PATH "$case_dir")" \
    "merged-wins: activity marker was touched despite merge winning"
  pass "a merged PR wins with only the merged line and leaves the activity marker untouched"
}

test_api_error_is_silent_and_preserves_marker() {
  local case_dir out
  case_dir=$(make_case api-error)
  arm_check "$case_dir"
  poll "$case_dir" OPEN 5 >/dev/null   # baseline

  out=$(poll "$case_dir" OPEN 99 fail)
  [ -z "$out" ] || fail "api-error: gh failure produced a wake line (output: '$out')"
  assert_grep "5" "$(ACT_PATH "$case_dir")" \
    "api-error: gh failure corrupted the existing marker"
  pass "a gh error stays silent and preserves the existing marker"
}

test_api_error_on_first_poll_writes_no_marker() {
  local case_dir out
  case_dir=$(make_case api-error-first)
  arm_check "$case_dir"

  out=$(poll "$case_dir" OPEN 99 fail)
  [ -z "$out" ] || fail "api-error-first: gh failure produced a wake line (output: '$out')"
  assert_absent "$(ACT_PATH "$case_dir")" \
    "api-error-first: gh failure created a baseline marker from a failed read"
  pass "a gh error on the first poll writes no marker"
}

test_fallen_count_resyncs_silently() {
  local case_dir out
  case_dir=$(make_case fell)
  arm_check "$case_dir"
  poll "$case_dir" OPEN 5 >/dev/null   # baseline

  out=$(poll "$case_dir" OPEN 2)
  [ -z "$out" ] || fail "fell: a fallen count woke firstmate (output: '$out')"
  assert_grep "2" "$(ACT_PATH "$case_dir")" "fell: marker did not resync to the lower count"
  pass "a fallen count resyncs the marker silently"
}

test_generated_check_is_valid_bash
test_baseline_init_is_silent
test_wake_on_increase
test_silence_on_no_change
test_merged_beats_activity
test_api_error_is_silent_and_preserves_marker
test_api_error_on_first_poll_writes_no_marker
test_fallen_count_resyncs_silently
