#!/usr/bin/env bash
# Behavior tests for FirstMate's Lavish review feedback bridge.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lavish-review)
REVIEW="$ROOT/bin/fm-lavish-review.sh"
WATCH="$ROOT/bin/fm-watch.sh"
BASE_PATH=$PATH

install_fake_lavish() {
  local fakebin=$1
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = poll ]; then
  {
    printf 'state=%s\n' "${LAVISH_AXI_STATE_DIR-<unset>}"
    printf 'host=%s\n' "${LAVISH_AXI_HOST-<unset>}"
    printf 'link_host=%s\n' "${LAVISH_AXI_LINK_HOST-<unset>}"
    printf 'port=%s\n' "${LAVISH_AXI_PORT-<unset>}"
    printf 'args=%s\n' "$*"
  } >> "${FM_FAKE_LAVISH_ENV_LOG:?}"
  if [ -n "${FM_FAKE_LAVISH_RESPONSE_FILE:-}" ]; then
    cat "$FM_FAKE_LAVISH_RESPONSE_FILE"
  else
    printf 'session:\n  file: %s\n  status: waiting\n' "${2:-}"
  fi
  exit "${FM_FAKE_LAVISH_RC:-0}"
fi
printf 'session:\n  file: %s\n  status: opened\n' "${1:-}"
printf 'next_step: fake open complete\n'
SH
  chmod +x "$fakebin/lavish-axi"
}

make_home() {
  local dir=$1
  mkdir -p "$dir/home/data" "$dir/home/state"
  printf '%s\n' "$dir/home"
}

test_registered_check_preserves_lavish_environment_and_wakes() {
  local dir home fakebin html response log out watch_out feedback_file captured_state
  dir="$TMP_ROOT/env-wake"
  mkdir -p "$dir"
  home=$(make_home "$dir")
  fakebin=$(fm_fakebin "$dir")
  install_fake_lavish "$fakebin"
  html="$dir/review.html"
  printf '<html><body>review</body></html>\n' > "$html"
  response="$dir/feedback.yml"
  cat > "$response" <<'EOF'
session:
  file: /tmp/review.html
  status: feedback
prompts[1]:
  - prompt: Captain feedback arrived
EOF
  log="$dir/env.log"
  captured_state="$(cd "$dir" && pwd -P)/relative-lavish-state"

  (
    cd "$dir"
    FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
      LAVISH_AXI_STATE_DIR=relative-lavish-state \
      LAVISH_AXI_HOST=0.0.0.0 \
      LAVISH_AXI_LINK_HOST=100.82.46.113 \
      LAVISH_AXI_PORT=4397 \
      "$REVIEW" --arm-only task-a "$html" > "$dir/arm.out"
  )
  assert_grep 'armed: state/task-a.check.sh' "$dir/arm.out" "Lavish helper did not arm the task check"
  assert_grep "LAVISH_AXI_STATE_DIR='$captured_state'" "$home/data/task-a/lavish-review.env" \
    "Lavish helper did not persist the exact state dir"
  assert_grep "LAVISH_AXI_LINK_HOST='100.82.46.113'" "$home/data/task-a/lavish-review.env" \
    "Lavish helper did not persist the exact link host"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_LAVISH_RESPONSE_FILE="$response" \
    FM_FAKE_LAVISH_ENV_LOG="$log" PATH="$fakebin:$BASE_PATH" \
    FM_CHECK_INTERVAL=0 FM_POLL=0 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 \
    "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err"
  watch_out=$(cat "$dir/watch.out")
  assert_contains "$watch_out" "check: $home/state/task-a.check.sh: lavish-feedback:" \
    "watcher did not surface Lavish feedback from the registered check"
  assert_grep "state=$captured_state" "$log" "poll did not use the captured relative state dir as an absolute path"
  assert_grep 'host=0.0.0.0' "$log" "poll did not preserve LAVISH_AXI_HOST"
  assert_grep 'link_host=100.82.46.113' "$log" "poll did not preserve LAVISH_AXI_LINK_HOST"
  assert_grep 'port=4397' "$log" "poll did not preserve LAVISH_AXI_PORT"
  assert_grep 'args=poll' "$log" "Lavish poll was not invoked"
  assert_grep '--agent-reply Received — routing this into the active UI work now.' "$log" \
    "picked-up Lavish prompts were not acknowledged immediately"
  feedback_file=$(find "$home/data/task-a/lavish-feedback" -type f -name '*feedback*.txt' | head -1)
  [ -n "$feedback_file" ] || fail "Lavish feedback output was not stored under task data"
  assert_grep 'acknowledgement: sent' "$feedback_file" "stored Lavish feedback did not record acknowledgement"
  assert_grep 'Captain feedback arrived' "$feedback_file" "stored Lavish feedback lost the prompt body"
  pass "fm-lavish-review: registered check preserves Lavish environment, acknowledges prompts, and wakes on feedback"
}

test_waiting_poll_is_silent() {
  local dir home fakebin html log out
  dir="$TMP_ROOT/waiting"
  mkdir -p "$dir"
  home=$(make_home "$dir")
  fakebin=$(fm_fakebin "$dir")
  install_fake_lavish "$fakebin"
  html="$dir/review.html"
  log="$dir/env.log"
  printf '<html><body>review</body></html>\n' > "$html"
  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$REVIEW" --arm-only task-b "$html" >/dev/null
  out=$(FM_FAKE_LAVISH_ENV_LOG="$log" PATH="$fakebin:$BASE_PATH" bash "$home/state/task-b.check.sh")
  [ -z "$out" ] || fail "waiting Lavish poll should print nothing, got: $out"
  assert_no_grep '--agent-reply' "$log" "waiting Lavish poll should not send an acknowledgement"
  pass "fm-lavish-review: no-feedback Lavish polls stay silent"
}

test_layout_warnings_wake_without_prompt_acknowledgement() {
  local dir home fakebin html response log out feedback_file
  dir="$TMP_ROOT/layout-warning"
  mkdir -p "$dir"
  home=$(make_home "$dir")
  fakebin=$(fm_fakebin "$dir")
  install_fake_lavish "$fakebin"
  html="$dir/review.html"
  printf '<html><body>review</body></html>\n' > "$html"
  response="$dir/layout.yml"
  cat > "$response" <<'EOF'
session:
  file: /tmp/review.html
  status: feedback
layout_warnings[1]:
  - severity: error
    summary: heading clipped
EOF
  log="$dir/env.log"
  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$REVIEW" --arm-only task-layout "$html" >/dev/null
  out=$(FM_FAKE_LAVISH_RESPONSE_FILE="$response" FM_FAKE_LAVISH_ENV_LOG="$log" \
    PATH="$fakebin:$BASE_PATH" bash "$home/state/task-layout.check.sh")
  assert_contains "$out" 'lavish-feedback:' "layout warning feedback did not wake FirstMate"
  assert_no_grep '--agent-reply' "$log" "layout-warning-only feedback should not send a prompt acknowledgement"
  feedback_file=$(find "$home/data/task-layout/lavish-feedback" -type f -name '*feedback*.txt' | head -1)
  [ -n "$feedback_file" ] || fail "layout warning output was not stored under task data"
  assert_grep 'layout_warnings[1]:' "$feedback_file" "stored Lavish feedback lost layout warnings"
  pass "fm-lavish-review: layout warnings wake without prompt acknowledgement"
}

test_final_feedback_disarms_check_after_storing_output() {
  local dir home fakebin html response log out
  dir="$TMP_ROOT/final"
  mkdir -p "$dir"
  home=$(make_home "$dir")
  fakebin=$(fm_fakebin "$dir")
  install_fake_lavish "$fakebin"
  html="$dir/review.html"
  printf '<html><body>review</body></html>\n' > "$html"
  response="$dir/final.yml"
  cat > "$response" <<'EOF'
session:
  file: /tmp/review.html
  status: feedback
  session_ended: true
prompts[1]:
  - prompt: Final review note
EOF
  log="$dir/env.log"
  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$REVIEW" --arm-only task-c "$html" >/dev/null
  out=$(FM_FAKE_LAVISH_RESPONSE_FILE="$response" FM_FAKE_LAVISH_ENV_LOG="$log" \
    PATH="$fakebin:$BASE_PATH" bash "$home/state/task-c.check.sh")
  assert_contains "$out" 'lavish-feedback-final:' "final feedback did not surface as a final Lavish event"
  assert_absent "$home/state/task-c.check.sh" "final Lavish feedback did not disarm the source check"
  assert_absent "$home/state/task-c.check-trust" "final Lavish feedback did not remove custom-check trust"
  assert_grep '--agent-reply Received — routing this into the active UI work now.' "$log" \
    "final Lavish prompts were not acknowledged before disarming"
  assert_grep 'Final review note' "$(find "$home/data/task-c/lavish-feedback" -type f | head -1)" \
    "final Lavish feedback was not stored before disarming"
  pass "fm-lavish-review: final feedback stores output and disarms polling"
}

test_invalid_ack_timeout_aborts_before_consuming_poll() {
  local dir home fakebin html log rc
  dir="$TMP_ROOT/ack-timeout"
  mkdir -p "$dir"
  home=$(make_home "$dir")
  fakebin=$(fm_fakebin "$dir")
  install_fake_lavish "$fakebin"
  html="$dir/review.html"
  printf '<html><body>review</body></html>\n' > "$html"
  log="$dir/env.log"
  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$REVIEW" --arm-only task-ack "$html" >/dev/null
  rc=0
  FM_LAVISH_ACK_TIMEOUT_MS=soon FM_FAKE_LAVISH_ENV_LOG="$log" PATH="$fakebin:$BASE_PATH" \
    bash "$home/state/task-ack.check.sh" > "$dir/check.out" 2> "$dir/check.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "invalid FM_LAVISH_ACK_TIMEOUT_MS should fail the check"
  assert_grep 'invalid FM_LAVISH_ACK_TIMEOUT_MS' "$dir/check.err" \
    "invalid ack timeout did not report a clear error"
  if [ -e "$log" ]; then
    assert_no_grep 'args=poll' "$log" "invalid ack timeout must abort before the consuming poll"
  fi
  pass "fm-lavish-review: invalid ack timeout aborts before consuming queued feedback"
}

test_persist_failure_still_wakes_with_inline_feedback() {
  local dir home fakebin html response log out
  dir="$TMP_ROOT/persist-fail"
  mkdir -p "$dir"
  home=$(make_home "$dir")
  fakebin=$(fm_fakebin "$dir")
  install_fake_lavish "$fakebin"
  html="$dir/review.html"
  printf '<html><body>review</body></html>\n' > "$html"
  response="$dir/feedback.yml"
  cat > "$response" <<'EOF'
session:
  file: /tmp/review.html
  status: feedback
prompts[1]:
  - prompt: Captain feedback arrived
EOF
  log="$dir/env.log"
  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$REVIEW" --arm-only task-persist "$html" >/dev/null
  chmod 0500 "$home/data/task-persist"
  out=$(FM_FAKE_LAVISH_RESPONSE_FILE="$response" FM_FAKE_LAVISH_ENV_LOG="$log" \
    PATH="$fakebin:$BASE_PATH" bash "$home/state/task-persist.check.sh" 2>/dev/null)
  chmod 0700 "$home/data/task-persist"
  assert_contains "$out" 'lavish-feedback: persist failed' \
    "persist failure did not surface an inline Lavish wake"
  assert_contains "$out" 'Captain feedback arrived' \
    "inline Lavish wake lost the feedback body after persist failure"
  pass "fm-lavish-review: persist failure still wakes FirstMate with inline feedback"
}

test_arm_only_rejects_open_args() {
  local dir home fakebin html rc
  dir="$TMP_ROOT/arm-only-open-args"
  mkdir -p "$dir"
  home=$(make_home "$dir")
  fakebin=$(fm_fakebin "$dir")
  install_fake_lavish "$fakebin"
  html="$dir/review.html"
  printf '<html><body>review</body></html>\n' > "$html"
  rc=0
  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    "$REVIEW" --arm-only task-oa "$html" -- --reopen > "$dir/oa.out" 2> "$dir/oa.err" || rc=$?
  [ "$rc" -eq 2 ] || fail "--arm-only with open args should exit 2, got $rc"
  assert_grep 'open arguments after -- would be ignored' "$dir/oa.err" \
    "--arm-only with open args did not explain the rejection"
  assert_absent "$home/state/task-oa.check.sh" "--arm-only with open args must not arm the check"
  pass "fm-lavish-review: --arm-only rejects Lavish open arguments"
}

test_input_notice_distinguishes_queue_only_from_send_controls() {
  local dir ambiguous paired sends err rc
  dir="$TMP_ROOT/input-notice"
  mkdir -p "$dir"
  ambiguous="$dir/ambiguous.html"
  paired="$dir/paired.html"
  sends="$dir/sends.html"
  printf '<script>window.lavish.queuePrompt("choice")</script>\n' > "$ambiguous"
  printf '<p>Queue this choice, then press Send to Agent.</p><script>window.lavish.queuePrompt("choice")</script>\n' > "$paired"
  printf '<script>window.lavish.queuePrompt("choice"); window.lavish.sendQueuedPrompts()</script>\n' > "$sends"
  rc=0
  "$REVIEW" --check-input "$ambiguous" > "$dir/ambiguous.out" 2> "$dir/ambiguous.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "ambiguous queue-only artifact should fail the Lavish input check"
  err=$(cat "$dir/ambiguous.err")
  assert_contains "$err" 'LAVISH_INPUT_ERROR:' "ambiguous queue-only artifact did not get a Lavish input error"
  assert_contains "$err" 'sendQueuedPrompts() after queuePrompt()' \
    "Lavish input error did not explain when to send queued prompts"
  "$REVIEW" --check-input "$paired" > "$dir/paired.out" 2> "$dir/paired.err"
  assert_grep 'LAVISH_INPUT_NOTICE:' "$dir/paired.err" \
    "queue-only artifact paired with visible Send instructions should get a notice"
  "$REVIEW" --check-input "$sends" > "$dir/sends.out" 2> "$dir/sends.err"
  [ ! -s "$dir/sends.err" ] || fail "artifact with an explicit send control should not warn: $(cat "$dir/sends.err")"
  pass "fm-lavish-review: input check enforces immediate send or visible Send action"
}

test_registered_check_preserves_lavish_environment_and_wakes
test_waiting_poll_is_silent
test_layout_warnings_wake_without_prompt_acknowledgement
test_final_feedback_disarms_check_after_storing_output
test_invalid_ack_timeout_aborts_before_consuming_poll
test_persist_failure_still_wakes_with_inline_feedback
test_arm_only_rejects_open_args
test_input_notice_distinguishes_queue_only_from_send_controls
