#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
PR_RECONCILE="$ROOT/bin/fm-pr-arrival-reconcile.sh"
TURNEND_GUARD="$ROOT/bin/fm-turnend-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

# Regression for the 2026-07-23 agents.house incident: PR 60 was open without a
# matching status event, the Codex foreground checkpoint expired, and the
# loop-guarded Stop was allowed to end blind.
test_unreported_task_pr_is_actionable_before_turn_end() {
  local home wt fakebin checkpoint_out checkpoint_err checkpoint_status
  local guard_out guard_status combined
  home=$(make_home unreported-pr)
  wt="$home/task-worktree"
  fakebin="$home/fakebin"
  mkdir -p "$home/bin" "$wt" "$fakebin"
  : > "$home/AGENTS.md"
  git init -q "$home"
  git -C "$home" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m "primary fixture"
  git init -q "$wt"
  git -C "$wt" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m "task fixture"
  git -C "$wt" switch -q -c fm/agents-house-delivery
  git -C "$wt" remote add origin https://github.com/example/agents.house.git
cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr list")
    sleep "${FM_TEST_GH_AXI_SLEEP:-0}"
    [ "${FM_TEST_GH_AXI_FAIL:-0}" = 0 ] || exit 1
    if [ "${FM_TEST_GH_AXI_MALFORMED:-0}" = 1 ]; then
      printf '%s\n' "count: 1 of 1 total" "pull_requests: changed schema"
      exit 0
    fi
    requested_head=
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --head)
          requested_head=${2:-}
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    if [ "$requested_head" = "${FM_TEST_PR_HEAD:-fm/agents-house-delivery}" ]; then
      printf '%s\n' \
        "count: 1 of 1 total" \
        "pull_requests[1]{number,title,state,author,draft,review,url}:" \
        "  60,\"agents.house delivery\",open,example,${FM_TEST_PR_DRAFT:-no},none,\"${FM_TEST_PR_URL:-https://github.com/example/agents.house/pull/60}\""
      exit 0
    fi
    printf '%s\n' "count: 0" "pull_requests: []"
    exit 0
    ;;
esac
echo "unexpected gh-axi call: $*" >&2
exit 1
SH
  chmod +x "$fakebin/gh-axi"
  printf '%s\n' \
    'window=fm-agents-house-delivery' \
    "worktree=$wt" \
    "project=$home/agents.house" \
    'harness=codex' \
    'kind=ship' \
    'mode=no-mistakes' \
    'yolo=off' > "$home/state/agents-house-delivery.meta"
  chmod 0600 "$home/state/agents-house-delivery.meta"
  : > "$home/gh-axi.log"

  checkpoint_out="$home/checkpoint.out"
  checkpoint_err="$home/checkpoint.err"
  checkpoint_status=0
  PATH="$fakebin:$PATH" FM_TEST_GH_AXI_LOG="$home/gh-axi.log" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_POLL=1 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 1 >"$checkpoint_out" 2>"$checkpoint_err" \
    || checkpoint_status=$?

  guard_status=0
  guard_out=$(printf '{"stop_hook_active":true}' \
    | PATH="$fakebin:$PATH" FM_TEST_GH_AXI_LOG="$home/gh-axi.log" \
      FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      bash "$TURNEND_GUARD" 2>&1) || guard_status=$?
  combined="$(cat "$checkpoint_out")"$'\n'"$(cat "$checkpoint_err")"$'\n'"$guard_out"

  if { [ "$checkpoint_status" -eq 0 ] || [ "$guard_status" -eq 2 ]; } \
    && printf '%s\n' "$combined" | grep -qF 'agents-house-delivery' \
    && printf '%s\n' "$combined" | grep -qF 'https://github.com/example/agents.house/pull/60'; then
    assert_contains "$(cat "$home/state/.wake-queue")" \
      "https://github.com/example/agents.house/pull/60" \
      "unreported PR was printed without a durable reconciliation wake"
    assert_no_grep '^pr checks' "$home/gh-axi.log" \
      "PR arrival reconciliation depended on GitHub CI"
  else
    fail "unreported task PR stayed invisible: checkpoint rc=$checkpoint_status; guard rc=$guard_status; output=$combined"
  fi

  : > "$home/state/.wake-queue"
  : > "$home/gh-axi.log"
  checkpoint_status=0
  checkpoint_out=$(
    PATH="$fakebin:$PATH" FM_TEST_GH_AXI_LOG="$home/gh-axi.log" FM_TEST_PR_DRAFT=yes \
      FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      "$PR_RECONCILE" --timeout 2 2>&1
  ) || checkpoint_status=$?
  expect_code 1 "$checkpoint_status" "draft task PR reconciliation exit"
  [ -z "$checkpoint_out" ] || fail "draft task PR produced reconciliation output: $checkpoint_out"
  [ ! -s "$home/state/.wake-queue" ] || fail "draft task PR produced a durable wake"

  : > "$home/gh-axi.log"
  checkpoint_status=0
  checkpoint_out=$(
    PATH="$fakebin:$PATH" FM_TEST_GH_AXI_LOG="$home/gh-axi.log" \
      FM_TEST_PR_HEAD=fm/unrelated-delivery \
      FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      "$PR_RECONCILE" --timeout 2 2>&1
  ) || checkpoint_status=$?
  expect_code 1 "$checkpoint_status" "unrelated task PR reconciliation exit"
  [ -z "$checkpoint_out" ] || fail "unrelated task PR produced reconciliation output: $checkpoint_out"
  [ ! -s "$home/state/.wake-queue" ] || fail "unrelated task PR produced a durable wake"

  checkpoint_status=0
  checkpoint_out=$(
    PATH="$fakebin:$PATH" FM_TEST_GH_AXI_LOG="$home/gh-axi.log" \
      FM_TEST_PR_URL=https://github.com/example/unrelated/pull/60 \
      FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      "$PR_RECONCILE" --timeout 2 2>&1
  ) || checkpoint_status=$?
  expect_code 1 "$checkpoint_status" "other-repository PR reconciliation exit"
  [ -z "$checkpoint_out" ] || fail "other-repository PR produced reconciliation output: $checkpoint_out"
  [ ! -s "$home/state/.wake-queue" ] || fail "other-repository PR produced a durable wake"

  checkpoint_status=0
  checkpoint_out=$(
    PATH="$fakebin:$PATH" FM_TEST_GH_AXI_LOG="$home/gh-axi.log" \
      FM_TEST_GH_AXI_SLEEP=5 \
      FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      "$PR_RECONCILE" --timeout 1 2>&1
  ) || checkpoint_status=$?
  expect_code 3 "$checkpoint_status" "bounded task PR reconciliation timeout exit"
  assert_contains "$checkpoint_out" "timed out after 1s" \
    "bounded task PR reconciliation timeout diagnostic"
  [ ! -s "$home/state/.wake-queue" ] || fail "timed-out task PR scan produced a durable wake"

  checkpoint_status=0
  checkpoint_out=$(
    PATH="$fakebin:$PATH" FM_TEST_GH_AXI_LOG="$home/gh-axi.log" \
      FM_TEST_GH_AXI_FAIL=1 \
      FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      "$PR_RECONCILE" --timeout 2 2>&1
  ) || checkpoint_status=$?
  expect_code 3 "$checkpoint_status" "failed task PR lookup exit"
  assert_contains "$checkpoint_out" "could not inspect task(s): agents-house-delivery" \
    "failed task PR lookup diagnostic"

  checkpoint_status=0
  checkpoint_out=$(
    PATH="$fakebin:$PATH" FM_TEST_GH_AXI_LOG="$home/gh-axi.log" \
      FM_TEST_GH_AXI_MALFORMED=1 \
      FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      "$PR_RECONCILE" --timeout 2 2>&1
  ) || checkpoint_status=$?
  expect_code 3 "$checkpoint_status" "unrecognized task PR response exit"
  assert_contains "$checkpoint_out" "could not inspect task(s): agents-house-delivery" \
    "unrecognized task PR response diagnostic"

  printf '%s\n' 'pr=https://github.com/example/agents.house/pull/60' \
    >> "$home/state/agents-house-delivery.meta"
  : > "$home/gh-axi.log"
  checkpoint_status=0
  checkpoint_out=$(
    PATH="$fakebin:$PATH" FM_TEST_GH_AXI_LOG="$home/gh-axi.log" \
      FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      "$PR_RECONCILE" --timeout 2 2>&1
  ) || checkpoint_status=$?
  expect_code 1 "$checkpoint_status" "recorded task PR reconciliation exit"
  [ -z "$checkpoint_out" ] || fail "recorded task PR produced reconciliation output: $checkpoint_out"
  [ ! -s "$home/gh-axi.log" ] || fail "recorded task PR was looked up again"
  pass "unreported task PR is surfaced before turn end without waking on drafts, unrelated PRs, or GitHub CI"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_unreported_task_pr_is_actionable_before_turn_end
