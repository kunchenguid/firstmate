#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-done-verify.sh.
#
# Drives the CLI with a fake curl on PATH that records argv, the request body,
# and the header read from file descriptor 3. No case touches the network.
# No xtrace.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TYPESAFE_API_KEY OPENROUTER_API_KEY TYPESAFE_API_KEY_PRIVATE \
  OPENROUTER_API_KEY_PRIVATE JEV_ROUTE JEV_MODEL JEV_TIMEOUT \
  JEV_CONFIDENCE_FLOOR JEV_STATE_MAX_BYTES

TMP_ROOT=$(fm_test_tmproot fm-jev-done-verify)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'
TASK_ID='ship-fix-pager'
DONE_LINE='done: pager off-by-one fixed'
mkdir -p "$HOME_DIR/state" "$LOG"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ] \
  || [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ]; then
  printf 'curl:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'curl:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
printf 'request\n' >> "$FAKE_CURL_LOG/requests"
if [ -n "${FAKE_CURL_RELEASE:-}" ]; then
  deadline=$((SECONDS + 15))
  while [ ! -e "$FAKE_CURL_RELEASE" ]; do
    [ "$SECONDS" -lt "$deadline" ] || exit 28
    sleep 0.05
  done
fi
cat > "$FAKE_CURL_LOG/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

cat > "$FAKEBIN/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf 'teardown-called\n' >> "${TEARDOWN_LOG:?}"
exit 0
SH
chmod +x "$FAKEBIN/fm-teardown.sh"

write_response() {
  local choice=$1
  local conf=${2:-0.82}
  cat > "$RESPONSE" <<JSON
{ "model": "jev-1.13.0",
  "answers": {
    "claim": { "type": "choice", "choice": "$choice", "confidence": $conf,
      "probabilities": { "evidenced": 0.8, "not_evidenced": 0.1, "need_human": 0.1 } },
    "strength": { "type": "score", "score": 0.91, "confidence": 0.8 } },
  "usage": { "input_tokens": 40, "output_tokens": 12 } }
JSON
}

RESPONSE="$TMP_ROOT/response.json"
write_response evidenced
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" CHILD_ENV_LOG="$LOG/child-env"
export TEARDOWN_LOG="$LOG/teardown"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
  : > "$TEARDOWN_LOG"
}

# run_verify <exit-var> <out-var> <err-var> [args...]
run_verify() {
  local __exit=$1 __out=$2 __err=$3
  shift 3
  local _out _errfile _code
  _errfile="$TMP_ROOT/stderr"
  reset_log
  rm -f "$HOME_DIR/state/${TASK_ID}.jev-done.jsonl" "$HOME_DIR/state/${TASK_ID}.status"
  _code=0
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" \
    FAKE_CURL_HTTP="${FAKE_CURL_HTTP:-200}" FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" \
    "$ROOT/bin/fm-jev-done-verify.sh" "$@" 2> "$_errfile") || _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$_errfile")"
  unset FAKE_CURL_HTTP FAKE_CURL_FAIL JEV_MODEL JEV_ROUTE
}

test_usage_requires_task_and_done_line() {
  local code out err
  run_verify code out err
  expect_code 2 "$code" "missing args exit 2"
  assert_contains "$err" 'Usage:' "usage is printed"
  run_verify code out err "$TASK_ID"
  expect_code 2 "$code" "missing done-line exits 2"
  run_verify code out err "$TASK_ID/../escape" --done-line "$DONE_LINE"
  expect_code 2 "$code" "path-like task id is refused"
  [ ! -f "$TEARDOWN_LOG" ] || [ ! -s "$TEARDOWN_LOG" ] \
    || fail "usage errors must not call teardown"
  pass "usage requires a task id and --done-line and refuses a path-like id"
}

test_evidenced_logs_without_annotate_or_close() {
  local code out err line body
  write_response evidenced 0.82
  TYPESAFE_API_KEY=$TS_KEY run_verify code out err "$TASK_ID" --done-line "$DONE_LINE" \
    --acceptance "pager no longer skips the last row"
  expect_code 0 "$code" "evidenced verify exits 0"
  assert_contains "$out" 'verdict: evidenced' "prints evidenced"
  assert_contains "$out" 'annotate: no' "evidenced does not annotate"
  assert_contains "$out" 'shadow: yes' "shadow marker is present"
  assert_contains "$out" 'close: no' "never claims close"
  assert_contains "$out" 'teardown: no' "never claims teardown"
  [ -f "$HOME_DIR/state/${TASK_ID}.jev-done.jsonl" ] \
    || fail "must log to state/<id>.jev-done.jsonl"
  line=$(cat "$HOME_DIR/state/${TASK_ID}.jev-done.jsonl")
  assert_contains "$line" '"verdict":"evidenced"' "log records evidenced"
  assert_contains "$line" '"close":false' "log close is false"
  assert_contains "$line" '"teardown":false' "log teardown is false"
  assert_contains "$line" '"shadow":true' "log shadow is true"
  [ ! -f "$HOME_DIR/state/${TASK_ID}.status" ] \
    || fail "must not write a worker status file"
  [ ! -s "$TEARDOWN_LOG" ] || fail "must not call teardown"
  body=$(cat "$LOG/body")
  assert_contains "$body" '"need_human"' "questions include need_human"
  assert_contains "$body" '"not_evidenced"' "questions include not_evidenced"
  assert_contains "$body" '"evidenced"' "questions include evidenced"
  assert_contains "$body" '"type": "score"' "questions include a strength score"
  assert_contains "$body" 'Healthy now is not repaired' "state/instructions carry the HacksonClark note"
  assert_not_contains "$body" "$TS_KEY" "key is absent from the request body"
  pass "evidenced at floor logs shadow-only and offers need_human"
}

test_not_evidenced_at_floor_annotates() {
  local code out err line
  write_response not_evidenced 0.85
  TYPESAFE_API_KEY=$TS_KEY run_verify code out err "$TASK_ID" --done-line "$DONE_LINE"
  expect_code 0 "$code" "not_evidenced verify exits 0"
  assert_contains "$out" 'verdict: not_evidenced' "prints not_evidenced"
  assert_contains "$out" 'annotate: yes' "high-conf not_evidenced annotates"
  assert_contains "$out" 'close: no' "annotation is not a close"
  line=$(cat "$HOME_DIR/state/${TASK_ID}.jev-done.jsonl")
  assert_contains "$line" '"annotate":true' "log annotate is true"
  assert_contains "$line" '"close":false' "log still close false"
  [ ! -s "$TEARDOWN_LOG" ] || fail "must not call teardown on not_evidenced"
  pass "not_evidenced at conf>=0.7 annotates and does not close"
}

test_need_human_at_floor_annotates() {
  local code out err
  write_response need_human 0.91
  TYPESAFE_API_KEY=$TS_KEY run_verify code out err "$TASK_ID" --done-line "$DONE_LINE"
  expect_code 0 "$code" "need_human verify exits 0"
  assert_contains "$out" 'verdict: need_human' "prints need_human"
  assert_contains "$out" 'annotate: yes' "high-conf need_human annotates"
  assert_contains "$out" 'close: no' "need_human is not a close"
  [ ! -s "$TEARDOWN_LOG" ] || fail "must not call teardown on need_human"
  pass "need_human at conf>=0.7 annotates and does not close"
}

test_below_floor_does_not_annotate() {
  local code out err line
  write_response not_evidenced 0.4
  TYPESAFE_API_KEY=$TS_KEY run_verify code out err "$TASK_ID" --done-line "$DONE_LINE"
  expect_code 0 "$code" "below-floor verify exits 0"
  assert_contains "$out" 'verdict: not_evidenced' "still reports the choice"
  assert_contains "$out" 'annotate: no' "below floor does not annotate"
  line=$(cat "$HOME_DIR/state/${TASK_ID}.jev-done.jsonl")
  assert_contains "$line" '"annotate":false' "log annotate is false below floor"
  pass "not_evidenced below 0.7 logs without annotate"
}

test_transport_failure_skips_without_blocking() {
  local code out err
  write_response evidenced
  FAKE_CURL_FAIL=1 TYPESAFE_API_KEY=$TS_KEY \
    run_verify code out err "$TASK_ID" --done-line "$DONE_LINE"
  expect_code 0 "$code" "transport failure still exits 0"
  assert_contains "$out" 'verdict: skipped' "transport failure is skipped"
  assert_contains "$out" 'annotate: no' "skip does not annotate"
  assert_contains "$out" 'close: no' "skip does not close"
  [ -f "$HOME_DIR/state/${TASK_ID}.jev-done.jsonl" ] \
    || fail "transport failure still logs"
  [ ! -s "$TEARDOWN_LOG" ] || fail "must not call teardown on skip"
  pass "transport failure skips, logs, and does not block done"
}

test_missing_key_skips_without_curl() {
  local code out err
  unset TYPESAFE_API_KEY OPENROUTER_API_KEY
  write_response evidenced
  run_verify code out err "$TASK_ID" --done-line "$DONE_LINE"
  expect_code 0 "$code" "missing key still exits 0"
  assert_contains "$out" 'verdict: skipped' "missing key is skipped"
  [ ! -f "$LOG/argv" ] || fail "missing key must not call curl"
  [ -f "$HOME_DIR/state/${TASK_ID}.jev-done.jsonl" ] \
    || fail "missing key still logs"
  pass "missing key skips without a network call"
}

test_report_and_pr_reach_state() {
  local code out err body report
  write_response evidenced 0.8
  report="$TMP_ROOT/report.md"
  printf 'reproduced the skip, then patched the off-by-one\n' > "$report"
  TYPESAFE_API_KEY=$TS_KEY run_verify code out err "$TASK_ID" \
    --done-line "$DONE_LINE" \
    --acceptance "no skip on last row" \
    --report "$report" \
    --pr-url "https://github.com/example/firstmate/pull/1"
  expect_code 0 "$code" "report/pr verify exits 0"
  body=$(cat "$LOG/body")
  assert_contains "$body" 'reproduced the skip' "report excerpt is in state"
  assert_contains "$body" 'https://github.com/example/firstmate/pull/1' "PR URL is in state"
  assert_contains "$body" 'no skip on last row' "acceptance excerpt is in state"
  pass "optional report path and PR URL are included in Jev state"
}

# Drain caller: a presented worker done: line must leave a jev-done record
# without closing the task. Uses the real drain over a fixture home.
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

wait_for_jev_done() {  # <jsonl> <timeout-sec>
  local jsonl=$1 timeout=${2:-5} start now
  start=$(date +%s)
  while [ ! -s "$jsonl" ]; do
    now=$(date +%s)
    [ $((now - start)) -lt "$timeout" ] || return 1
    sleep 0.05
  done
}

test_drain_done_line_records_without_closing() {
  local dir state line jsonl
  dir=$(make_case jev-done-drain)
  state="$dir/state"
  jsonl="$state/ship-fix.jev-done.jsonl"
  printf 'done: pager off-by-one fixed\n' > "$state/ship-fix.status"
  reset_log
  write_response evidenced 0.82
  PATH="$FAKEBIN:$BASE_PATH" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" TYPESAFE_API_KEY=$TS_KEY \
    FAKE_CURL_HTTP=200 FAKE_CURL_FAIL=0 \
    "$DRAIN" >/dev/null 2>/dev/null \
    || fail "drain failed while presenting a done: line"
  wait_for_jev_done "$jsonl" 5 \
    || fail "drain did not record state/<id>.jev-done.jsonl for a done: line"
  line=$(cat "$jsonl")
  assert_contains "$line" '"purpose":"shadow-done-verify"' "drain wrote a done-verify record"
  assert_contains "$line" '"close":false' "drain-triggered verify never closes"
  assert_contains "$line" '"teardown":false' "drain-triggered verify never tears down"
  [ ! -s "$TEARDOWN_LOG" ] || fail "drain-triggered verify must not call teardown"
  grep -E '^done:' "$state/ship-fix.status" >/dev/null \
    || fail "drain must leave the worker done: line in place"
  [ "$(grep -c '^done:' "$state/ship-fix.status")" -eq 1 ] \
    || fail "drain must not append a second done: line"
  pass "drain records a presented done: line without closing or teardown"
}

test_drain_deduplicates_first_record() {
  local dir state
  dir=$(make_case jev-done-dedup)
  state="$dir/state"
  printf '%s\n' "$DONE_LINE" > "$state/ship-fix.status"
  jq -nc --arg line "$DONE_LINE" '{done_line: $line}' > "$state/ship-fix.jev-done.jsonl"
  reset_log
  PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" TYPESAFE_API_KEY=$TS_KEY \
    "$DRAIN" >/dev/null 2>/dev/null || fail "dedup drain failed"
  sleep 0.3
  [ ! -f "$LOG/body" ] || fail "first JSONL record must prevent another request"
  [ "$(wc -l < "$state/ship-fix.jev-done.jsonl" | tr -d ' ')" -eq 1 ] || fail "dedup must keep one record"
  pass "first verification record prevents duplicate scoring"
}

test_drain_uses_presented_span() {
  local dir state initial appended out jsonl
  for initial in 'done' note; do
    dir=$(make_case "jev-done-race-$initial")
    state="$dir/state"
    jsonl="$state/ship-fix.jev-done.jsonl"
    if [ "$initial" = 'done' ]; then appended='note: appended during presentation'; else appended="$DONE_LINE"; fi
    printf '%s: original event\n' "$initial" > "$state/ship-fix.status"
    cat > "$dir/fakebin/cat" <<'SH'
#!/usr/bin/env bash
/bin/cat "$@"
case "${1:-}" in
  */.status-presentation.prepared.*)
    if [ ! -e "$RACE_MARKER" ]; then
      printf '%s\n' "$RACE_LINE" >> "$RACE_STATUS"
      : > "$RACE_MARKER"
    fi
    ;;
esac
SH
    chmod +x "$dir/fakebin/cat"
    reset_log
    write_response evidenced
    out=$(PATH="$dir/fakebin:$FAKEBIN:$BASE_PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
      TYPESAFE_API_KEY=$TS_KEY RACE_MARKER="$dir/appended" RACE_STATUS="$state/ship-fix.status" RACE_LINE="$appended" \
      "$DRAIN" 2>/dev/null) || fail "racing drain failed"
    [ -f "$dir/appended" ] || fail "status append must occur during presentation"
    assert_not_contains "$out" "$appended" "appended event was not presented"
    if [ "$initial" = 'done' ]; then
      wait_for_jev_done "$jsonl" 5 || fail "presented done event was lost after note append"
      jq -e '.done_line == "done: original event"' "$jsonl" >/dev/null || fail "wrong done event scored"
    else
      sleep 0.3
      assert_absent "$jsonl" "unpresented done event must not be scored"
      PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" TYPESAFE_API_KEY=$TS_KEY \
        "$DRAIN" >/dev/null 2>/dev/null || fail "follow-up drain failed"
      wait_for_jev_done "$jsonl" 5 || fail "next presentation must score appended done event"
    fi
    [ "$(wc -l < "$state/ship-fix.status" | tr -d ' ')" -eq 2 ] || fail "verifier changed status history"
    [ ! -s "$TEARDOWN_LOG" ] || fail "verifier invoked teardown"
  done
  pass "completion scoring uses the captured presentation span"
}

test_drain_serializes_inflight_verification() {
  local dir state jsonl deadline
  dir=$(make_case jev-done-inflight)
  state="$dir/state"
  jsonl="$state/ship-fix.jev-done.jsonl"
  printf '%s\n' "$DONE_LINE" > "$state/ship-fix.status"
  reset_log
  write_response evidenced
  PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" TYPESAFE_API_KEY=$TS_KEY \
    FAKE_CURL_RELEASE="$dir/release" "$DRAIN" >/dev/null 2>/dev/null || fail "first drain failed"
  wait_for_jev_done "$LOG/requests" 5 || fail "first request did not start"
  assert_absent "$jsonl" "first verification must still be in flight"
  append_wake "$state" signal ship-fix.status completion
  PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" TYPESAFE_API_KEY=$TS_KEY \
    FAKE_CURL_RELEASE="$dir/release" "$DRAIN" >/dev/null 2>/dev/null || fail "second drain failed"
  sleep 0.3
  [ "$(wc -l < "$LOG/requests" | tr -d ' ')" -eq 1 ] || fail "in-flight verification must exclude duplicate requests"
  : > "$dir/release"
  wait_for_jev_done "$jsonl" 5 || fail "first verification never completed"
  deadline=$((SECONDS + 5))
  while [ -e "$state/.ship-fix.jev-done.lock" ] || [ -L "$state/.ship-fix.jev-done.lock" ]; do
    [ "$SECONDS" -lt "$deadline" ] || fail "verification lock was not released"
    sleep 0.05
  done
  sleep 0.3
  [ "$(wc -l < "$LOG/requests" | tr -d ' ')" -eq 1 ] || fail "waiting verification must recheck the completed record"
  [ "$(wc -l < "$jsonl" | tr -d ' ')" -eq 1 ] || fail "verification must append exactly once"
  pass "overlapping drains serialize verification through log append"
}

check_completion_deduplication() {
  local variant=$1 location=$2 dir state out jsonl deadline completion expected
  dir=$(make_case "jev-completion-$variant-$location")
  state="$dir/state"
  if [ "$location" = external ]; then
    state="$TMP_ROOT/external-$variant"
    mkdir -p "$state"
  fi
  jsonl="$state/ship-fix.jev-done.jsonl"
  completion=$'done: pager\toff-by-one fixed'
  expected=$DONE_LINE
  case "$variant" in
    crlf) completion+=$'\r' ;;
    trailing-tab) completion+=$'\t'; expected+=' ' ;;
    trailing-tab-crlf) completion+=$'\t\r'; expected+=' ' ;;
  esac
  printf '%s\n' "$completion" > "$state/ship-fix.status"
  cp "$state/ship-fix.status" "$dir/original-status"
  append_wake "$state" signal ship-fix.status completion
  reset_log
  write_response evidenced
  out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" TYPESAFE_API_KEY=$TS_KEY \
    FAKE_CURL_RELEASE="$dir/release" "$DRAIN" 2>/dev/null) || fail "completion drain failed"
  assert_contains "$out" "ship-fix.status: $DONE_LINE" "annotation must present completion"
  assert_contains "$out" "ship-fix ${completion%$'\r'}" "backstop must present the same completion"
  wait_for_jev_done "$LOG/requests" 5 || fail "verification request did not start"
  assert_absent "$jsonl" "transport must remain in flight after presentation"
  : > "$dir/release"
  wait_for_jev_done "$jsonl" 5 || fail "completion was not recorded in effective state directory"
  deadline=$((SECONDS + 5))
  while [ -e "$state/.ship-fix.jev-done.lock" ] || [ -L "$state/.ship-fix.jev-done.lock" ]; do
    [ "$SECONDS" -lt "$deadline" ] || fail "verification lock was not released"
    sleep 0.05
  done
  sleep 0.3
  jq -se --arg line "$expected" 'length == 1 and .[0].done_line == $line and .[0].close == false and .[0].teardown == false' "$jsonl" >/dev/null \
    || fail "both presentation paths must produce one normalized durable record ($variant, $location)"
  [ "$(wc -l < "$LOG/requests" | tr -d ' ')" -eq 1 ] || fail "same completion reached transport twice"
  cmp -s "$state/ship-fix.status" "$dir/original-status" || fail "normalization modified worker status bytes"
  if [ "$location" = external ]; then
    assert_absent "$dir/state/ship-fix.jev-done.jsonl" "verification must not log in the default state directory"
  fi
  [ ! -s "$TEARDOWN_LOG" ] || fail "verification invoked teardown"
  pass "$variant completion in $location state emits through both paths but is verified once"
}

test_drain_deduplicates_tabbed_completion_across_presentation_paths() {
  local variant location
  for location in default external; do
    for variant in internal-tab crlf trailing-tab trailing-tab-crlf; do
      check_completion_deduplication "$variant" "$location"
    done
  done
}

test_drain_scores_only_emitted_completions() {
  local dir state out mode jsonl
  for mode in buried covered unsafe; do
    dir=$(make_case "jev-hidden-$mode")
    state="$dir/state"
    jsonl="$state/ship-fix.jev-done.jsonl"
    printf '%s\n' "$DONE_LINE" > "$state/ship-fix.status"
    case "$mode" in
      buried) printf 'note: later update\n' >> "$state/ship-fix.status" ;;
      covered)
        FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-branch-outcome.sh" append \
          --task ship-fix --verdict captain --summary handled >/dev/null || fail "outcome fixture failed"
        ;;
      unsafe) mkdir "$state/branch-outcomes.jsonl" ;;
    esac
    reset_log
    out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" TYPESAFE_API_KEY=$TS_KEY \
      "$DRAIN" 2>/dev/null) || fail "hidden completion drain failed"
    assert_not_contains "$out" "$DONE_LINE" "hidden completion must not be presented"
    if [ "$mode" = buried ]; then
      assert_contains "$out" 'note: later update' "later note must be presented"
    fi
    sleep 0.3
    assert_absent "$jsonl" "hidden completion must not be verified"
    assert_absent "$LOG/requests" "hidden completion must not reach transport"
    if [ "$mode" = buried ]; then printf '%s\n' "$DONE_LINE" >> "$state/ship-fix.status"; fi
    append_wake "$state" signal ship-fix.status completion
    out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" TYPESAFE_API_KEY=$TS_KEY \
      "$DRAIN" 2>/dev/null) || fail "annotation drain failed"
    assert_contains "$out" "$DONE_LINE" "direct annotation must present completion"
    wait_for_jev_done "$jsonl" 5 || fail "emitted annotation must be verified"
    jq -e --arg line "$DONE_LINE" '.done_line == $line' "$jsonl" >/dev/null || fail "wrong annotation scored"
  done
  pass "buried and suppressed completions are scored only when annotations emit them"
}

test_drain_scores_only_uncapped_backstop_events() {
  local dir state out i task payload shown=0 omitted=0
  dir=$(make_case jev-capped-backstop)
  state="$dir/state"
  payload=$(printf '%0300d' 0)
  for i in $(seq 1 22); do
    printf 'done: completion-%s %s\n' "$i" "$payload" > "$state/task-$i.status"
  done
  reset_log
  out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" TYPESAFE_API_KEY=$TS_KEY \
    "$DRAIN" 2>/dev/null) || fail "capped backstop drain failed"
  assert_contains "$out" 'more omitted (byte cap)' "backstop must omit over-budget events"
  for i in $(seq 1 22); do
    task="task-$i"
    if printf '%s\n' "$out" | grep -F "$task done:" >/dev/null; then
      shown=$((shown + 1))
      wait_for_jev_done "$state/$task.jev-done.jsonl" 10 || fail "emitted backstop completion was not scored"
      jq -e --arg line "done: completion-$i $payload" '.done_line == $line' \
        "$state/$task.jev-done.jsonl" >/dev/null || fail "backstop lost original completion text"
    else
      omitted=$((omitted + 1))
    fi
  done
  sleep 0.3
  for i in $(seq 1 22); do
    task="task-$i"
    if ! printf '%s\n' "$out" | grep -F "$task done:" >/dev/null; then
      assert_absent "$state/$task.jev-done.jsonl" "capped completion must not be scored"
    fi
  done
  [ "$shown" -gt 0 ] && [ "$omitted" -gt 0 ] || fail "cap fixture must exercise both paths"
  [ "$(wc -l < "$LOG/requests" | tr -d ' ')" -eq "$shown" ] || fail "only emitted events may reach transport"
  pass "backstop byte cap also bounds verification candidates"
}

test_drain_without_keys_does_not_record() {
  local dir state jsonl
  dir=$(make_case jev-done-drain-nokey)
  state="$dir/state"
  jsonl="$state/ship-fix.jev-done.jsonl"
  printf 'done: pager off-by-one fixed\n' > "$state/ship-fix.status"
  unset TYPESAFE_API_KEY OPENROUTER_API_KEY
  PATH="$FAKEBIN:$BASE_PATH" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    "$DRAIN" >/dev/null 2>/dev/null \
    || fail "drain failed without Jev keys"
  sleep 0.2
  assert_absent "$jsonl" "without keys the drain must not spawn a skipped done-verify record"
  pass "drain without keys leaves done: presentation inert for Jev"
}

test_drain_empty_env_keys_allow_later_scoring() {
  local key dir state jsonl out
  for key in TYPESAFE_API_KEY OPENROUTER_API_KEY; do
    dir=$(make_case "jev-empty-env-$key")
    state="$dir/state"
    jsonl="$state/ship-fix.jev-done.jsonl"
    printf '%s\n' "$DONE_LINE" > "$state/ship-fix.status"
    cp "$state/ship-fix.status" "$dir/original-status"
    printf '%s\n' 'TYPESAFE_API_KEY=""' "OPENROUTER_API_KEY=''" > "$dir/.env"
    reset_log
    write_response evidenced
    unset TYPESAFE_API_KEY OPENROUTER_API_KEY
    out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
      "$DRAIN" 2>/dev/null) || fail "empty-key drain failed"
    assert_contains "$out" "$DONE_LINE" "completion must be presented without credentials"
    sleep 0.5
    assert_absent "$jsonl" "quoted-empty keys must not create a deduplication record"
    assert_absent "$LOG/requests" "quoted-empty keys must not reach transport"
    printf '%s="%s"\n' "$key" "$TS_KEY" >> "$dir/.env"
    append_wake "$state" signal ship-fix.status completion
    out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
      "$DRAIN" 2>/dev/null) || fail "configured-key drain failed"
    assert_contains "$out" "$DONE_LINE" "completion must be presented again"
    wait_for_jev_done "$jsonl" 5 || fail "configured credentials must permit scoring"
    jq -se --arg line "$DONE_LINE" \
      'length == 1 and .[0].done_line == $line and .[0].verdict == "evidenced" and .[0].close == false and .[0].teardown == false' \
      "$jsonl" >/dev/null || fail "later credentials must produce one advisory verification"
    [ "$(wc -l < "$LOG/requests" | tr -d ' ')" -eq 1 ] || fail "configured credentials must make one request"
    cmp -s "$state/ship-fix.status" "$dir/original-status" || fail "verification changed worker status bytes"
    [ ! -s "$TEARDOWN_LOG" ] || fail "verification invoked teardown"
  done
  pass "quoted-empty keys leave no record and later credentials allow scoring"
}

test_drain_empty_env_keys_allow_later_scoring

test_usage_requires_task_and_done_line
test_evidenced_logs_without_annotate_or_close
test_not_evidenced_at_floor_annotates
test_need_human_at_floor_annotates
test_below_floor_does_not_annotate
test_transport_failure_skips_without_blocking
test_missing_key_skips_without_curl
test_report_and_pr_reach_state
test_drain_done_line_records_without_closing
test_drain_deduplicates_first_record
test_drain_serializes_inflight_verification
test_drain_uses_presented_span
test_drain_deduplicates_tabbed_completion_across_presentation_paths
test_drain_scores_only_emitted_completions
test_drain_scores_only_uncapped_backstop_events
test_drain_without_keys_does_not_record
