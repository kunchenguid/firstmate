#!/usr/bin/env bash
# Focused tests for captain decision alert filtering, deduplication, channel
# configuration, safe execution, and best-effort failure behavior.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALERT="$ROOT/bin/fm-decision-alert.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-alert)

make_recorder() {  # <dir>
  local dir=$1 recorder="$1/recorder"
  mkdir -p "$dir"
  cat > "$recorder" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "$2" >> "${FM_DECISION_ALERT_LOG:?}"
if [ "${FM_DECISION_ALERT_FAIL:-0}" = 1 ]; then
  exit 73
fi
SH
  chmod +x "$recorder"
  printf '%s\n' "$recorder"
}

run_alert() {  # <home> <recorder> <args...>
  local home=$1 recorder=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DECISION_ALERT_EXEC="$recorder" FM_DECISION_ALERT_LOG="$home/alert.log" \
    FM_DECISION_ALERT_CHANNEL=osascript "$ALERT" "$@"
}

test_status_filtering_and_cross_boundary_dedup() {
  local home recorder status
  home="$TMP_ROOT/filter"; mkdir -p "$home/state" "$home/config"
  recorder=$(make_recorder "$home")
  status="$home/state/sample-review.status"
  printf 'working: inspecting\nblocked [key=tool]: supervisor can resolve\npaused: vendor wait\ndone: draft ready\n' > "$status"
  run_alert "$home" "$recorder" status "$status"
  [ ! -s "$home/alert.log" ] || fail "routine, blocked, paused, or done events triggered a decision alert"

  printf 'needs-decision [key=route]: choose a route\n' >> "$status"
  run_alert "$home" "$recorder" status "$status"
  run_alert "$home" "$recorder" status "$status"
  run_alert "$home" "$recorder" prompt sample-review route
  [ "$(wc -l < "$home/alert.log" | tr -d ' ')" -eq 1 ] \
    || fail "the same status/direct decision identity alerted more than once"

  printf 'resolved [key=route]: route selected\n' >> "$status"
  run_alert "$home" "$recorder" status "$status"
  [ "$(wc -l < "$home/alert.log" | tr -d ' ')" -eq 1 ] \
    || fail "a resolved decision triggered another alert"
  printf 'needs-decision [key=masked]: choose the masked option\nworking: unrelated follow-up\n' >> "$status"
  run_alert "$home" "$recorder" status "$status"
  [ "$(wc -l < "$home/alert.log" | tr -d ' ')" -eq 2 ] \
    || fail "a later routine event masked an earlier still-open decision"
  printf 'resolved [key=masked]: masked option selected\n' >> "$status"
  run_alert "$home" "$recorder" status "$status"
  [ "$(wc -l < "$home/alert.log" | tr -d ' ')" -eq 2 ] \
    || fail "the resolved masked decision alerted again"
  pass "only open needs-decision events alert, and status/direct delivery deduplicates by origin and key"
}

test_configuration_and_opt_out() {
  local home recorder count
  home="$TMP_ROOT/config"; mkdir -p "$home/state" "$home/config"
  recorder=$(make_recorder "$home")
  printf 'off\n' > "$home/config/decision-alert"
  FM_HOME="$home" FM_DECISION_ALERT_EXEC="$recorder" FM_DECISION_ALERT_LOG="$home/alert.log" \
    "$ALERT" decision sample off-choice
  [ ! -s "$home/alert.log" ] || fail "config/decision-alert=off still emitted"
  count=$(find "$home/state" -name '.decision-alerted-*' -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 0 ] || fail "off consumed the decision identity and prevented a later opt-in"

  FM_HOME="$home" FM_DECISION_ALERT_EXEC="$recorder" FM_DECISION_ALERT_LOG="$home/alert.log" \
    FM_DECISION_ALERT_CHANNEL=herdr "$ALERT" decision sample off-choice
  assert_grep $'herdr\tReturn to Firstmate to review the decision.' "$home/alert.log" \
    "the environment channel override did not replace config/decision-alert=off"

  : > "$home/alert.log"
  printf '# two channels\n\nosascript\ncommand:printf ignored\n' > "$home/config/decision-alert"
  FM_HOME="$home" FM_DECISION_ALERT_EXEC="$recorder" FM_DECISION_ALERT_LOG="$home/alert.log" \
    "$ALERT" decision sample multi-channel
  assert_grep 'osascript' "$home/alert.log" "the config file did not select osascript"
  assert_grep 'command' "$home/alert.log" "the config file did not select command:"
  pass "off, environment override, and multi-channel config behave deterministically"
}

test_macos_notification_argv_and_command_safety() {
  local home fakebin args injected out_argv out_stdin body command secret
  home="$TMP_ROOT/safety"; fakebin="$home/fakebin"
  mkdir -p "$home/state" "$home/config" "$fakebin"
  args="$home/osascript.args"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
  cat > "$fakebin/osascript" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FM_OSASCRIPT_ARGS:?}"
SH
  chmod +x "$fakebin/uname" "$fakebin/osascript"
  env -u FM_DECISION_ALERT_EXEC PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_OSASCRIPT_ARGS="$args" "$ALERT" decision sample macos
  assert_grep 'Firstmate needs your decision' "$args" "the macOS alert title was not passed as argv"
  assert_grep 'Return to Firstmate to review the decision.' "$args" "the macOS alert body was not passed as argv"
  assert_grep 'Basso' "$args" "the macOS alert did not request an audible system sound"
  assert_grep 'item 2 of argv' "$args" "notification text was not kept out of AppleScript source"

  injected="$home/injected"; out_argv="$home/argv"; out_stdin="$home/stdin"
  # shellcheck disable=SC2016  # Literal shell syntax is the hostile data under test.
  body='$(touch '"$injected"') "quoted"; newline-safe'
  command="printf '%s' \"\$1\" > '$out_argv'; cat > '$out_stdin'"
  # shellcheck source=bin/fm-notify-lib.sh
  . "$ROOT/bin/fm-notify-lib.sh"
  fm_notify_emit fm_notify_run_bounded '' 2 command title "$body" Basso "$command"
  [ ! -e "$injected" ] || fail "notification body text executed as shell syntax"
  [ "$(cat "$out_argv")" = "$body" ] || fail "command channel changed the body passed in \$1"
  [ "$(cat "$out_stdin")" = "$body" ] || fail "command channel changed the body passed on stdin"
  secret='https://alerts.example.invalid/hook?token=private-decision-token'
  env -u FM_DECISION_ALERT_EXEC FM_HOME="$home" \
    FM_DECISION_ALERT_CHANNEL="command:exit 73 # $secret" \
    "$ALERT" decision sample command-redaction 2> "$home/command-error"
  assert_grep 'command notifier failed with status 73' "$home/command-error" \
    "command notifier failure did not retain a useful redacted diagnostic"
  assert_no_grep "$secret" "$home/command-error" \
    "command notifier failure leaked the configured command"
  pass "macOS uses an audible argv-safe notification and command data never becomes shell source"
}

test_notifier_failure_is_nonblocking_and_at_most_once() {
  local home recorder rc attempts markers
  home="$TMP_ROOT/failure"; mkdir -p "$home/state" "$home/config"
  recorder=$(make_recorder "$home")
  set +e
  FM_HOME="$home" FM_DECISION_ALERT_EXEC="$recorder" FM_DECISION_ALERT_LOG="$home/alert.log" \
    FM_DECISION_ALERT_FAIL=1 FM_DECISION_ALERT_CHANNEL=osascript \
    "$ALERT" decision sample failure-choice >/dev/null 2> "$home/error.log"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "notifier failure propagated to the durable decision caller"
  attempts=$(wc -l < "$home/alert.log" | tr -d ' ')
  markers=$(find "$home/state" -name '.decision-alerted-*' -type f | wc -l | tr -d ' ')
  [ "$attempts" -eq 1 ] || fail "failing notifier was not attempted exactly once"
  [ "$markers" -eq 1 ] || fail "failing notifier did not retain the dedup marker"

  FM_HOME="$home" FM_DECISION_ALERT_EXEC="$recorder" FM_DECISION_ALERT_LOG="$home/alert.log" \
    FM_DECISION_ALERT_CHANNEL=osascript "$ALERT" decision sample failure-choice
  [ "$(wc -l < "$home/alert.log" | tr -d ' ')" -eq 1 ] \
    || fail "a repeated delivery retried an already-claimed failed notifier"
  pass "notifier failure never blocks the decision path and repeated delivery stays at most once"
}

test_total_runtime_is_bounded_across_decisions_and_channels() {
  local home start elapsed attempts markers fallbacks
  home="$TMP_ROOT/total-timeout"; mkdir -p "$home/state" "$home/config"
  printf 'needs-decision [key=one]: choose\n' > "$home/state/one.status"
  printf 'needs-decision [key=two]: choose\n' > "$home/state/two.status"
  printf "command:sleep 5\ncommand:echo fallback >> '%s/fallback.log'\n" "$home" \
    > "$home/config/decision-alert"
  start=$SECONDS
  env -u FM_DECISION_ALERT_EXEC FM_HOME="$home" FM_DECISION_ALERT_TIMEOUT_SECS=5 \
    FM_DECISION_ALERT_TOTAL_TIMEOUT_SECS=1 "$ALERT" scan-state \
    >/dev/null 2> "$home/error.log"
  elapsed=$((SECONDS - start))
  [ "$elapsed" -le 2 ] || fail "total alert runtime multiplied across decisions and channels"
  markers=$(find "$home/state" -name '.decision-alerted-*' -type f | wc -l | tr -d ' ')
  [ "$markers" -eq 2 ] || fail "the total deadline did not attempt every open decision identity"
  fallbacks=$(wc -l < "$home/fallback.log" | tr -d ' ')
  [ "$fallbacks" -eq 2 ] || fail "hung channels starved healthy fallback channels"

  cat > "$home/scan-stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_ALERT_STUB_LOG:?}"
SH
  chmod +x "$home/scan-stub"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DECISION_ALERT_BIN="$home/scan-stub" \
    FM_ALERT_STUB_LOG="$home/scan.log" bash -c '. "$1"; alert_all_open_decisions' \
      _ "$ROOT/bin/fm-watch.sh"
  attempts=$(wc -l < "$home/scan.log" | tr -d ' ')
  [ "$attempts" -eq 1 ] || fail "the watcher split a fleet scan across multiple alert budgets"
  assert_grep 'scan-state' "$home/scan.log" "the watcher did not use one bounded fleet scan"
  pass "one total deadline bounds concurrent decisions, channels, and heartbeat status files"
}

test_concurrency_is_bounded() {
  local home recorder task max_active
  home="$TMP_ROOT/worker-pool"; mkdir -p "$home/state" "$home/config" "$home/active"
  recorder="$home/recorder"
  cat > "$recorder" <<'SH'
#!/usr/bin/env bash
slot="${FM_DECISION_ALERT_POOL_DIR:?}/active/$BASHPID"
: > "$slot"
trap 'rm -f "$slot"' EXIT
find "${FM_DECISION_ALERT_POOL_DIR:?}/active" -type f | wc -l >> "${FM_DECISION_ALERT_POOL_DIR:?}/counts"
sleep 5
SH
  chmod +x "$recorder"
  for task in one two three; do
    printf 'needs-decision [key=a]: choose\nneeds-decision [key=b]: choose\nneeds-decision [key=c]: choose\n' \
      > "$home/state/$task.status"
  done
  printf 'osascript\nherdr\ncommand:true\n' > "$home/config/decision-alert"
  FM_HOME="$home" FM_DECISION_ALERT_EXEC="$recorder" FM_DECISION_ALERT_POOL_DIR="$home" \
    FM_DECISION_ALERT_TIMEOUT_SECS=1 FM_DECISION_ALERT_TOTAL_TIMEOUT_SECS=1 \
    "$ALERT" scan-state >/dev/null 2> "$home/error.log"
  max_active=$(sort -nr "$home/counts" | head -1 | tr -d ' ')
  [ "$max_active" -le 8 ] || fail "decision alert execution exceeded its worker limit"
  [ "$max_active" -gt 1 ] || fail "the worker pool did not preserve concurrent fallback delivery"
  pass "decision alert execution stays within eight concurrent workers"
}

test_bash32_empty_retry_batch_continues() {
  local home recorder task markers
  home="$TMP_ROOT/bash32-retry"; mkdir -p "$home/state" "$home/config"
  recorder=$(make_recorder "$home")
  printf 'osascript\n' > "$home/config/decision-alert"
  for task in 01 02 03 04 05 06 07 08 09; do
    printf 'needs-decision [key=choice]: choose\n' > "$home/state/$task.status"
  done
  for task in 01 02 03 04 05 06 07 08; do
    FM_HOME="$home" FM_DECISION_ALERT_EXEC=discard FM_DECISION_ALERT_CHANNEL=osascript \
      /bin/bash "$ALERT" decision "$task" choice >/dev/null 2>&1 \
      || fail "could not seed an existing decision alert identity"
  done
  FM_HOME="$home" FM_DECISION_ALERT_EXEC="$recorder" FM_DECISION_ALERT_LOG="$home/alert.log" \
    /bin/bash "$ALERT" scan-state >/dev/null 2> "$home/error.log" \
    || fail "an empty retry batch aborted the Bash 3.2 alert scan"
  [ "$(wc -l < "$home/alert.log" | tr -d ' ')" -eq 1 ] \
    || fail "the unclaimed decision after an empty retry batch was not alerted"
  markers=$(find "$home/state" -name '.decision-alerted-*' -type f | wc -l | tr -d ' ')
  [ "$markers" -eq 9 ] || fail "the later decision identity was not claimed after an empty retry batch"
  pass "Bash 3.2 empty retry batches preserve later decision alerts"
}

test_test_seam_and_watcher_integration() {
  local home stub out
  home="$TMP_ROOT/watcher"; mkdir -p "$home/state" "$home/config"
  stub="$home/alert-stub"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_ALERT_STUB_LOG:?}"
SH
  chmod +x "$stub"
  printf 'needs-decision [key=shape]: choose a shape\n' > "$home/state/sample.status"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DECISION_ALERT_BIN="$stub" \
    FM_ALERT_STUB_LOG="$home/stub.log" bash -c '. "$1"; mark_surfaced "$2"' \
      _ "$ROOT/bin/fm-watch.sh" "$home/state/sample.status"
  assert_grep "status $home/state/sample.status" "$home/stub.log" \
    "the watcher surface boundary did not invoke the decision alert"

  # shellcheck disable=SC2016  # The clean child must expand its sourced seam value.
  out=$(env -u FM_DECISION_ALERT_EXEC bash -c '. "$1"; printf "%s" "$FM_DECISION_ALERT_EXEC"' \
    _ "$ALERT")
  [ "$out" = discard ] || fail "library mode did not default the test seam to discard"
  pass "the watcher invokes the automatic boundary and library-mode tests default to discard"
}

test_status_filtering_and_cross_boundary_dedup
test_configuration_and_opt_out
test_macos_notification_argv_and_command_safety
test_notifier_failure_is_nonblocking_and_at_most_once
test_total_runtime_is_bounded_across_decisions_and_channels
test_concurrency_is_bounded
test_bash32_empty_retry_batch_continues
test_test_seam_and_watcher_integration
