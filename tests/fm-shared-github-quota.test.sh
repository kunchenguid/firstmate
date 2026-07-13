#!/usr/bin/env bash
# Behavior tests for fleet-wide shared GitHub quota coordination.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUOTA="$ROOT/bin/fm-shared-github-quota.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-shared-github-quota)
PR_URL=https://github.com/example/repo/pull/9

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$FM_TEST_GH_LOG"
case " $* " in
  *" --json headRefOid "*) printf '%s\n' deadbeefcafefeed0000000000000000deadbeef; exit 0 ;;
  *" --json state "*) printf '%s\n' "${FM_FAKE_PR_STATE:-OPEN}"; exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'gh-axi %s\n' "$*" >> "$FM_TEST_GH_LOG"
exit 0
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi"
  printf '%s\n' "$fakebin"
}

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/state" "$home/config" "$home/wt"
  fm_write_meta "$home/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$home"
}

arm_check() {
  local home=$1 fakebin=$2 shared=$3 now=$4
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_CONFIG_OVERRIDE="$home/config" \
  FM_SHARED_STATE_OVERRIDE="$shared" \
  FM_SHARED_QUOTA_NOW_EPOCH="$now" \
  FM_TEST_GH_LOG="$home/gh.log" \
  PATH="$fakebin:$PATH" \
    "$PR_CHECK" task-x1 "$PR_URL" >/dev/null 2>"$home/pr-check.err"
}

run_check_script() {
  local home=$1 fakebin=$2 shared=$3 now=$4
  FM_SHARED_STATE_OVERRIDE="$shared" \
  FM_SHARED_QUOTA_NOW_EPOCH="$now" \
  FM_TEST_GH_LOG="$home/gh.log" \
  PATH="$fakebin:$PATH" \
    bash "$home/state/task-x1.check.sh"
}

mark_cooldown() {
  local shared=$1 reset=$2 now=$3
  FM_SHARED_STATE_OVERRIDE="$shared" FM_SHARED_QUOTA_NOW_EPOCH="$now" \
    "$QUOTA" mark --provider github --account 94498628 --route default --reset-epoch "$reset" --source test >/dev/null
}

test_mark_from_text_records_observed_account_and_reset() {
  local shared out active
  shared="$TMP_ROOT/shared-text"
  out=$(printf '%s\n' 'GitHub user/account 94498628 is rate-limited until 2026-07-13T02:23:23Z.' \
    | FM_SHARED_STATE_OVERRIDE="$shared" FM_SHARED_QUOTA_NOW_EPOCH=1000 \
      "$QUOTA" mark-from-text --provider github --route default --source incident)
  assert_contains "$out" "provider=github" "mark-from-text should preserve provider"
  assert_contains "$out" "account=94498628" "mark-from-text should extract the GitHub account"
  assert_contains "$out" "reset_at=2026-07-13T02:23:23Z" "mark-from-text should preserve observed reset time"

  active=$(FM_SHARED_STATE_OVERRIDE="$shared" FM_SHARED_QUOTA_NOW_EPOCH=1000 \
    "$QUOTA" check --provider github --account 94498628 --route default)
  assert_contains "$active" "state=defer" "observed GitHub cooldown should be active"
  assert_contains "$active" "reset_at=2026-07-13T02:23:23Z" "active cooldown should report reset evidence"
  pass "observed GitHub account/reset text records a shared cooldown"
}

test_shared_cooldown_blocks_polling_across_homes() {
  local shared fakebin home_a home_b out
  shared="$TMP_ROOT/shared-a"
  fakebin=$(make_fakebin "$TMP_ROOT/fake-a")
  home_a=$(make_home home-a)
  home_b=$(make_home home-b)
  : > "$home_a/gh.log"
  : > "$home_b/gh.log"
  mark_cooldown "$shared" 2000 1000

  arm_check "$home_a" "$fakebin" "$shared" 1000
  arm_check "$home_b" "$fakebin" "$shared" 1000
  out=$(run_check_script "$home_a" "$fakebin" "$shared" 1000)
  [ -z "$out" ] || fail "cooldown check should not wake from home A: $out"
  out=$(run_check_script "$home_b" "$fakebin" "$shared" 1000)
  [ -z "$out" ] || fail "cooldown check should not wake from home B: $out"
  [ ! -s "$home_a/gh.log" ] || fail "home A burned gh quota during shared cooldown: $(cat "$home_a/gh.log")"
  [ ! -s "$home_b/gh.log" ] || fail "home B burned gh quota during shared cooldown: $(cat "$home_b/gh.log")"
  pass "fleet-wide GitHub cooldown blocks gh-heavy polling across simulated homes"
}

test_local_status_supervision_continues_during_cooldown() {
  local shared home out pid i
  shared="$TMP_ROOT/shared-local"
  home=$(make_home local-supervision)
  mark_cooldown "$shared" 2000 1000
  printf 'done: local status still works\n' > "$home/state/task-x1.status"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_SHARED_STATE_OVERRIDE="$shared" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$home/watch.out" &
  pid=$!
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  out=$(cat "$home/watch.out")
  assert_contains "$out" "signal:" "local status wake should still surface during GitHub cooldown"
  pass "local status/file supervision continues during shared GitHub cooldown"
}

test_reset_time_is_honored_before_polling_resumes() {
  local shared fakebin home out calls
  shared="$TMP_ROOT/shared-reset"
  fakebin=$(make_fakebin "$TMP_ROOT/fake-reset")
  home=$(make_home reset-home)
  : > "$home/gh.log"
  mark_cooldown "$shared" 2000 1000
  arm_check "$home" "$fakebin" "$shared" 1000

  out=$(FM_FAKE_PR_STATE=MERGED run_check_script "$home" "$fakebin" "$shared" 1999)
  [ -z "$out" ] || fail "polling resumed before reset: $out"
  [ ! -s "$home/gh.log" ] || fail "gh was called before reset: $(cat "$home/gh.log")"

  out=$(FM_FAKE_PR_STATE=MERGED run_check_script "$home" "$fakebin" "$shared" 2000)
  assert_contains "$out" "merged" "polling should resume at reset and see merged state"
  calls=$(grep -c -- '--json state' "$home/gh.log" || true)
  [ "$calls" = 1 ] || fail "expected one gh state call after reset, got $calls"
  pass "GitHub cooldown reset time is honored before polling resumes"
}

test_cached_read_is_used_during_cooldown_without_gh() {
  local shared fakebin home out calls
  shared="$TMP_ROOT/shared-cache"
  fakebin=$(make_fakebin "$TMP_ROOT/fake-cache")
  home=$(make_home cache-home)
  : > "$home/gh.log"
  printf '%s\n' MERGED | FM_SHARED_STATE_OVERRIDE="$shared" FM_SHARED_QUOTA_NOW_EPOCH=900 \
    "$QUOTA" cache-put --provider github --account 94498628 --route default --key "pr-state:$PR_URL"
  mark_cooldown "$shared" 2000 1000
  arm_check "$home" "$fakebin" "$shared" 1000

  out=$(run_check_script "$home" "$fakebin" "$shared" 1000)
  assert_contains "$out" "merged" "cached merged state should still wake during cooldown"
  out=$(run_check_script "$home" "$fakebin" "$shared" 1000)
  assert_contains "$out" "merged" "duplicate cached request should reuse the same cached state"
  calls=$(grep -c -- '--json state' "$home/gh.log" || true)
  [ "$calls" = 0 ] || fail "cached cooldown reads should not call gh, got $calls"
  pass "duplicate GitHub read requests use cached state during cooldown"
}

test_merge_escalates_with_exact_account_and_reset() {
  local shared fakebin home status err calls
  shared="$TMP_ROOT/shared-merge"
  fakebin=$(make_fakebin "$TMP_ROOT/fake-merge")
  home=$(make_home merge-home)
  : > "$home/gh.log"
  FM_SHARED_STATE_OVERRIDE="$shared" FM_SHARED_QUOTA_NOW_EPOCH=1000 \
    "$QUOTA" mark --provider github --account 94498628 --route default --reset-at 2026-07-13T02:23:23Z --source test >/dev/null

  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SHARED_STATE_OVERRIDE="$shared" FM_SHARED_QUOTA_NOW_EPOCH=1000 \
    FM_TEST_GH_LOG="$home/gh.log" PATH="$fakebin:$PATH" \
    "$PR_MERGE" task-x1 "$PR_URL" > "$home/merge.out" 2> "$home/merge.err"
  status=$?
  set +e

  expect_code 1 "$status" "merge should refuse during shared GitHub cooldown"
  err=$(cat "$home/merge.err")
  assert_contains "$err" "escalation=github_shared_quota" "merge refusal should be a structured escalation"
  assert_contains "$err" "provider=github" "merge escalation should name provider"
  assert_contains "$err" "account=94498628" "merge escalation should name account"
  assert_contains "$err" "reset_at=2026-07-13T02:23:23Z" "merge escalation should name reset time"
  assert_contains "$err" "needed_action=wait until reset" "merge escalation should name the required action"
  calls=$(grep -c '^gh-axi pr merge' "$home/gh.log" || true)
  [ "$calls" = 0 ] || fail "merge called gh-axi despite cooldown"
  pass "shared GitHub quota escalation names provider, account, reset, and action"
}

test_no_cooldown_preserves_existing_polling_semantics() {
  local shared fakebin home calls
  shared="$TMP_ROOT/shared-none"
  fakebin=$(make_fakebin "$TMP_ROOT/fake-none")
  home=$(make_home no-cooldown)
  : > "$home/gh.log"
  arm_check "$home" "$fakebin" "$shared" 1000
  FM_FAKE_PR_STATE=OPEN run_check_script "$home" "$fakebin" "$shared" 1000 >/dev/null
  FM_FAKE_PR_STATE=OPEN run_check_script "$home" "$fakebin" "$shared" 1000 >/dev/null
  calls=$(grep -c -- '--json state' "$home/gh.log" || true)
  [ "$calls" = 2 ] || fail "no-cooldown polling should call gh each time, got $calls"
  pass "default no-cooldown path preserves existing polling behavior"
}

test_mark_from_text_records_observed_account_and_reset
test_shared_cooldown_blocks_polling_across_homes
test_local_status_supervision_continues_during_cooldown
test_reset_time_is_honored_before_polling_resumes
test_cached_read_is_used_during_cooldown_without_gh
test_merge_escalates_with_exact_account_and_reset
test_no_cooldown_preserves_existing_polling_semantics

echo "# all fm-shared-github-quota tests passed"
