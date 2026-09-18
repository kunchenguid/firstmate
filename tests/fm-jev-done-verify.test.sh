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

test_script_never_invokes_teardown_or_status_writes() {
  if grep -E 'fm-teardown|>>.*\.status|resolved:' "$ROOT/bin/fm-jev-done-verify.sh" \
    | grep -v '^#' | grep -q .; then
    fail "script body must not call teardown, write status, or emit resolved"
  fi
  pass "script source does not teardown, write status, or emit resolved"
}

test_usage_requires_task_and_done_line
test_evidenced_logs_without_annotate_or_close
test_not_evidenced_at_floor_annotates
test_need_human_at_floor_annotates
test_below_floor_does_not_annotate
test_transport_failure_skips_without_blocking
test_missing_key_skips_without_curl
test_report_and_pr_reach_state
test_script_never_invokes_teardown_or_status_writes
