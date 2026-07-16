#!/usr/bin/env bash
# Behavior tests for the primary captain-attention lifecycle.
#
# Public seam:
#   fleet wake only -> silent
#   primary arms and publishes a captain wait -> one notification
#   the same wait publishes again -> silent
#   captain input clears the pending wait
#   a genuinely new wait -> one new notification
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WAIT="$ROOT/bin/fm-captain-wait.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-wait)

install_notifier() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/notify.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_NOTIFY_LOG"
SH
  chmod +x "$dir/notify.sh"
}

notification_count() {
  local log=$1
  if [ -f "$log" ]; then
    wc -l < "$log" | tr -d ' '
  else
    printf '0\n'
  fi
}

run_wait() {
  local home=$1 notifier=$2 log=$3
  shift 3
  FM_HOME="$home" FM_CAPTAIN_ATTENTION_EXEC="$notifier" FM_NOTIFY_LOG="$log" bash "$WAIT" "$@"
}

test_public_transition() {
  local dir="$TMP_ROOT/public" home="$TMP_ROOT/public/home" log="$TMP_ROOT/public/notify.log" stop_command
  mkdir -p "$home/state"
  install_notifier "$dir"

  : > "$home/state/crew-a.turn-ended"
  printf 'report-ready: routine wake\n' > "$home/state/crew-a.status"
  stop_command=$(jq -r '.hooks.Stop[0].hooks[0].command' "$ROOT/.codex/hooks.json")
  (
    cd "$ROOT" || exit 1
    FM_HOME="$home" FM_CAPTAIN_ATTENTION_EXEC="$dir/notify.sh" FM_NOTIFY_LOG="$log" \
      bash -c "$stop_command" <<<'{"stop_hook_active":false}'
  )
  [ "$(notification_count "$log")" = 0 ] || fail "fleet wake without an armed captain wait must stay silent"

  run_wait "$home" "$dir/notify.sh" "$log" arm review-pr-42
  run_wait "$home" "$dir/notify.sh" "$log" arm must-not-replace-pending
  run_wait "$home" "$dir/notify.sh" "$log" publish
  [ "$(notification_count "$log")" = 1 ] || fail "the first published captain wait must notify exactly once"
  assert_grep 'review-pr-42' "$log" "the notifier must receive the durable wait identity"
  assert_no_grep 'must-not-replace-pending' "$log" "a second arm must not replace an uncleared pending wait"

  run_wait "$home" "$dir/notify.sh" "$log" publish
  run_wait "$home" "$dir/notify.sh" "$log" arm still-must-not-replace-pending
  run_wait "$home" "$dir/notify.sh" "$log" publish
  [ "$(notification_count "$log")" = 1 ] || fail "Stop retries and re-arms before captain input must stay silent"

  run_wait "$home" "$dir/notify.sh" "$log" clear
  run_wait "$home" "$dir/notify.sh" "$log" publish
  [ "$(notification_count "$log")" = 1 ] || fail "captain response clearing the wait must not notify"

  run_wait "$home" "$dir/notify.sh" "$log" arm review-pr-42
  run_wait "$home" "$dir/notify.sh" "$log" publish
  [ "$(notification_count "$log")" = 2 ] || fail "a cleared epoch must allow the same identity text to notify again"

  run_wait "$home" "$dir/notify.sh" "$log" clear
  run_wait "$home" "$dir/notify.sh" "$log" arm choose-release-name
  run_wait "$home" "$dir/notify.sh" "$log" publish
  [ "$(notification_count "$log")" = 3 ] || fail "a genuinely new captain wait must notify once"

  run_wait "$home" "$dir/notify.sh" "$log" clear
  run_wait "$home" "$dir/notify.sh" "$log" arm concurrent-stop-retry
  run_wait "$home" "$dir/notify.sh" "$log" publish &
  local first=$!
  run_wait "$home" "$dir/notify.sh" "$log" publish &
  local second=$!
  wait "$first"
  wait "$second"
  [ "$(notification_count "$log")" = 4 ] || fail "concurrent Stop-hook retries must still notify exactly once"
  pass "captain-attention public transition is silent -> one -> silent -> clear -> one"
}

test_signal_terminates_lock_owner() {
  local dir="$TMP_ROOT/signal" home="$TMP_ROOT/signal/home" log="$TMP_ROOT/signal/notify.log"
  local publisher status i
  mkdir -p "$home/state" "$dir"
  cat > "$dir/slow-notify.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_NOTIFY_READY"
sleep 0.2
SH
  chmod +x "$dir/slow-notify.sh"

  run_wait "$home" "$dir/slow-notify.sh" "$log" arm signal-exit
  FM_HOME="$home" FM_CAPTAIN_ATTENTION_EXEC="$dir/slow-notify.sh" \
    FM_NOTIFY_LOG="$log" FM_NOTIFY_READY="$dir/ready" bash "$WAIT" publish &
  publisher=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -f "$dir/ready" ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -f "$dir/ready" ] || fail "signal test notifier did not start"
  kill -TERM "$publisher"
  wait "$publisher"
  status=$?
  expect_code 143 "$status" "TERM must terminate the lock owner"
  assert_absent "$home/state/.captain-wait.lock" "TERM must release the captain-wait lock through EXIT"
  pass "captain-attention signal handlers terminate before releasing the lock"
}

test_notification_claim_survives_notifier_failure() {
  local dir="$TMP_ROOT/failure" home="$TMP_ROOT/failure/home" log="$TMP_ROOT/failure/notify.log"
  mkdir -p "$home/state" "$dir"
  cat > "$dir/failing-notify.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_NOTIFY_LOG"
exit 1
SH
  chmod +x "$dir/failing-notify.sh"

  run_wait "$home" "$dir/failing-notify.sh" "$log" arm durable-at-most-once
  if run_wait "$home" "$dir/failing-notify.sh" "$log" publish; then
    fail "a failing notifier must remain observable to the lifecycle hook"
  fi
  run_wait "$home" "$dir/failing-notify.sh" "$log" publish
  [ "$(notification_count "$log")" = 1 ] || fail "a retry after an emitted-but-failed notification must stay silent"
  pass "captain-attention claims an identity before the external sound effect"
}

test_home_isolation() {
  local dir="$TMP_ROOT/isolation" log="$TMP_ROOT/isolation/notify.log"
  local home_a="$TMP_ROOT/isolation/home-a" home_b="$TMP_ROOT/isolation/home-b"
  mkdir -p "$home_a/state" "$home_b/state"
  install_notifier "$dir"

  run_wait "$home_a" "$dir/notify.sh" "$log" arm shared-key
  run_wait "$home_a" "$dir/notify.sh" "$log" publish
  run_wait "$home_b" "$dir/notify.sh" "$log" arm shared-key
  run_wait "$home_b" "$dir/notify.sh" "$log" publish
  [ "$(notification_count "$log")" = 2 ] || fail "each firstmate home must own an independent wait identity"
  pass "captain-attention state is isolated per FM_HOME"
}

test_codex_lifecycle_hooks() {
  local hooks="$ROOT/.codex/hooks.json" content stop_command
  content=$(cat "$hooks")
  printf '%s' "$content" | jq -e '
    any(.hooks.UserPromptSubmit[]?.hooks[]?.command?; contains("fm-captain-wait.sh") and contains("clear"))
  ' >/dev/null || fail "UserPromptSubmit must clear the pending captain wait"
  printf '%s' "$content" | jq -e '
    any(.hooks.Stop[]?.hooks[]?.command?; contains("fm-captain-wait.sh") and contains("publish"))
  ' >/dev/null || fail "Stop must publish an armed captain wait"
  stop_command=$(printf '%s' "$content" | jq -r '.hooks.Stop[0].hooks[0].command')
  # shellcheck disable=SC2016 # Hook source must contain these literal shell variables.
  case "$stop_command" in
    *'printf "%s" "$payload" | "$root/bin/fm-turnend-guard.sh"; rc=$?; if [ "$rc" -eq 0 ]'*'fm-captain-wait.sh" publish'*) ;;
    *) fail "Stop must publish only after the turn-end guard accepts the yield" ;;
  esac
  pass "Codex lifecycle clears on captain input and publishes on yield"
}

test_codex_primary_launch_silences_generic_notifier() {
  local dir="$TMP_ROOT/codex-launch" fakebin log
  fakebin=$(fm_fakebin "$dir")
  log="$dir/codex-args"
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_CODEX_ARGS_LOG"
SH
  chmod +x "$fakebin/codex"

  PATH="$fakebin:$PATH" FM_CODEX_ARGS_LOG="$log" bash "$ROOT/bin/fm-codex-primary.sh" --model test-model
  assert_grep '-c' "$log" "Codex primary wrapper must pass a config override"
  assert_grep 'notify=["true"]' "$log" "Codex primary wrapper must replace the global generic notifier"
  assert_grep '--model' "$log" "Codex primary wrapper must preserve caller arguments"
  assert_grep 'test-model' "$log" "Codex primary wrapper must preserve caller argument values"
  pass "Codex primary launch suppresses generic turn completion notifications without changing global config"
}

test_script_help() {
  bash "$WAIT" --help | grep -q 'FM_CAPTAIN_ATTENTION_EXEC' \
    || fail "captain-wait --help must describe its injectable notifier"
  bash "$ROOT/bin/fm-codex-primary.sh" --help | grep -q 'notify' \
    || fail "codex-primary --help must explain generic notification suppression"
  if bash "$WAIT" arm 'invalid wait identity' >/dev/null 2>&1; then
    fail "captain-wait must reject an invalid identity with a nonzero exit"
  fi
  pass "captain-attention scripts expose operational help"
}

test_public_transition
test_signal_terminates_lock_owner
test_notification_claim_survives_notifier_failure
test_home_isolation
test_codex_lifecycle_hooks
test_codex_primary_launch_silences_generic_notifier
test_script_help
