#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-lib.sh.
#
# Sources the library and drives fm_jev_decide with a fake curl on PATH that
# records argv, the request body, and the header read from file descriptor 3.
# No case touches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-jev-lib.sh"

unset TYPESAFE_API_KEY OPENROUTER_API_KEY TYPESAFE_API_KEY_PRIVATE \
  OPENROUTER_API_KEY_PRIVATE JEV_ROUTE JEV_MODEL JEV_TIMEOUT \
  JEV_CONFIDENCE_FLOOR JEV_STATE_MAX_BYTES

TMP_ROOT=$(fm_test_tmproot fm-jev-lib)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NO_CURL_BIN="$TMP_ROOT/no-curl-bin"
LOG="$TMP_ROOT/log"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'
OR_KEY='sk-or-v1-test-key-not-for-argv'
STATE='task: fix the pager off-by-one'
QUESTIONS='{"pick":{"type":"choice","instructions":"Which option?","criteria":{"a":"alpha","b":"bravo"}}}'
mkdir -p "$HOME_DIR/state" "$LOG" "$NO_CURL_BIN"
for command_name in bash jq mktemp rm cat head tr wc awk dirname mkdir printf; do
  ln -s "$(command -v "$command_name")" "$NO_CURL_BIN/$command_name"
done

write_response() {
  cat > "$1" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "pick": { "type": "choice", "choice": "a", "confidence": 0.82,
    "probabilities": { "a": 0.8, "b": 0.2 } } },
  "usage": { "input_tokens": 40, "output_tokens": 12 } }
JSON
}

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: records argv (minus the -o target), the stdin body, and the header
# read from fd 3, then answers with FAKE_CURL_RESPONSE and FAKE_CURL_HTTP.
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

RESPONSE="$TMP_ROOT/response.json"
write_response "$RESPONSE"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" CHILD_ENV_LOG="$LOG/child-env"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# run_decide <exit-var> <out-var> <err-var>
# Calls fm_jev_decide with fake curl first on PATH and isolated FM_HOME.
# Keys and JEV_* come from the calling environment.
run_decide() {
  local __exit=$1 __out=$2 __err=$3 _out _errfile _code
  _errfile="$TMP_ROOT/stderr"
  reset_log
  _code=0
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" \
    FAKE_CURL_HTTP="${FAKE_CURL_HTTP:-200}" FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" \
    fm_jev_decide "$STATE" "$QUESTIONS" 2> "$_errfile") || _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$_errfile")"
  unset FAKE_CURL_HTTP FAKE_CURL_FAIL JEV_MODEL JEV_ROUTE
}

test_cli_is_not_a_user_command() {
  local code out
  code=0
  out=$(bash "$ROOT/bin/fm-jev-lib.sh" 2>&1) || code=$?
  expect_code 2 "$code" "executing the library exits 2"
  assert_contains "$out" 'sourceable library' "executing the library explains itself"
  pass "executing fm-jev-lib.sh is refused; it is sourceable only"
}

test_openrouter_only_uses_openrouter_url_and_bearer() {
  local code out err argv
  unset TYPESAFE_API_KEY JEV_ROUTE JEV_MODEL
  OPENROUTER_API_KEY=$OR_KEY run_decide code out err
  expect_code 0 "$code" "OpenRouter-only decide succeeds"
  argv=$(cat "$LOG/argv")
  assert_contains "$argv" 'https://openrouter.ai/api/alpha/decisions' "OpenRouter-only uses the OpenRouter URL"
  assert_not_contains "$argv" 'https://api.typesafe.ai/v1/systemone' "OpenRouter-only does not use TypeSafe"
  assert_not_contains "$argv" "$OR_KEY" "the OpenRouter key never appears on curl argv"
  assert_contains "$argv" '@/dev/fd/3' "the header is read from a file descriptor"
  assert_equals "Authorization: Bearer $OR_KEY" "$(cat "$LOG/header")" "curl receives the OpenRouter bearer header on fd 3"
  assert_equals 'curl:clean' "$(cat "$LOG/child-env")" "the API key is absent from the curl environment"
  assert_contains "$(cat "$LOG/body")" '"model": "typesafe/jev-1.13"' "OpenRouter default model is typesafe/jev-1.13"
  jq -e --arg state "$STATE" '.state == $state and (.questions | type) == "object"' "$LOG/body" >/dev/null \
    || fail "OpenRouter body must send state string and questions object"
  assert_contains "$out" '"choice": "a"' "successful decide prints the JSON response"
  pass "with only OPENROUTER_API_KEY, decide uses the OpenRouter URL and bearer header"
}

test_typesafe_only_uses_typesafe_url() {
  local code out err argv
  unset OPENROUTER_API_KEY JEV_ROUTE JEV_MODEL
  TYPESAFE_API_KEY=$TS_KEY run_decide code out err
  expect_code 0 "$code" "TypeSafe-only decide succeeds"
  argv=$(cat "$LOG/argv")
  assert_contains "$argv" 'https://api.typesafe.ai/v1/systemone' "TypeSafe-only uses the TypeSafe URL"
  assert_not_contains "$argv" 'https://openrouter.ai/api/alpha/decisions' "TypeSafe-only does not use OpenRouter"
  assert_not_contains "$argv" "$TS_KEY" "the TypeSafe key never appears on curl argv"
  assert_equals "Authorization: Bearer $TS_KEY" "$(cat "$LOG/header")" "curl receives the TypeSafe bearer header on fd 3"
  assert_equals 'curl:clean' "$(cat "$LOG/child-env")" "the API key is absent from the curl environment"
  assert_contains "$(cat "$LOG/body")" '"model": "jev-latest"' "TypeSafe default model is jev-latest"
  pass "with only TYPESAFE_API_KEY, decide uses the TypeSafe URL and bearer header"
}

test_typesafe_wins_when_both_keys_present() {
  local code out err argv
  unset JEV_ROUTE
  TYPESAFE_API_KEY=$TS_KEY OPENROUTER_API_KEY=$OR_KEY run_decide code out err
  expect_code 0 "$code" "both-keys decide succeeds"
  argv=$(cat "$LOG/argv")
  assert_contains "$argv" 'https://api.typesafe.ai/v1/systemone' "TypeSafe wins when both keys are present"
  assert_equals "Authorization: Bearer $TS_KEY" "$(cat "$LOG/header")" "both-keys uses the TypeSafe bearer"
  pass "with both keys and no JEV_ROUTE, TypeSafe wins"
}

test_jev_route_openrouter_overrides_typesafe_key() {
  local code out err argv
  TYPESAFE_API_KEY=$TS_KEY OPENROUTER_API_KEY=$OR_KEY JEV_ROUTE=openrouter \
    run_decide code out err
  expect_code 0 "$code" "JEV_ROUTE=openrouter decide succeeds"
  argv=$(cat "$LOG/argv")
  assert_contains "$argv" 'https://openrouter.ai/api/alpha/decisions' "JEV_ROUTE=openrouter selects OpenRouter"
  assert_equals "Authorization: Bearer $OR_KEY" "$(cat "$LOG/header")" "JEV_ROUTE=openrouter uses the OpenRouter bearer"
  pass "JEV_ROUTE=openrouter selects OpenRouter even when a TypeSafe key is present"
}

test_jev_model_override() {
  local code out err
  unset OPENROUTER_API_KEY JEV_ROUTE
  TYPESAFE_API_KEY=$TS_KEY JEV_MODEL=jev-custom run_decide code out err
  expect_code 0 "$code" "JEV_MODEL override decide succeeds"
  assert_contains "$(cat "$LOG/body")" '"model": "jev-custom"' "JEV_MODEL overrides the default"
  pass "JEV_MODEL overrides the route default"
}

test_env_file_openrouter_key() {
  local code out err
  unset TYPESAFE_API_KEY OPENROUTER_API_KEY JEV_ROUTE
  printf '%s\n' "OPENROUTER_API_KEY=$OR_KEY" > "$HOME_DIR/.env"
  run_decide code out err
  rm -f "$HOME_DIR/.env"
  expect_code 0 "$code" ".env OpenRouter key decide succeeds"
  assert_contains "$(cat "$LOG/argv")" 'https://openrouter.ai/api/alpha/decisions' ".env OpenRouter key selects OpenRouter"
  assert_equals "Authorization: Bearer $OR_KEY" "$(cat "$LOG/header")" ".env OpenRouter key reaches curl on the fd header"
  pass "OPENROUTER_API_KEY in .env activates the OpenRouter route"
}

test_environment_key_wins_over_env_file() {
  local code out err
  unset OPENROUTER_API_KEY JEV_ROUTE
  printf '%s\n' "TYPESAFE_API_KEY=from-file" > "$HOME_DIR/.env"
  TYPESAFE_API_KEY=from-env run_decide code out err
  rm -f "$HOME_DIR/.env"
  expect_code 0 "$code" "environment key decide succeeds"
  assert_equals 'Authorization: Bearer from-env' "$(cat "$LOG/header")" "environment key wins over .env"
  pass "environment TYPESAFE_API_KEY wins over .env"
}

test_missing_keys_do_not_call_curl() {
  local code out err
  unset TYPESAFE_API_KEY OPENROUTER_API_KEY JEV_ROUTE
  rm -f "$HOME_DIR/.env"
  run_decide code out err
  expect_code 2 "$code" "missing keys exit 2"
  assert_contains "$err" 'no TYPESAFE_API_KEY or OPENROUTER_API_KEY' "missing keys explain themselves"
  assert_absent "$LOG/argv" "missing keys never call curl"
  pass "absent keys fail closed without a network call"
}

test_bad_questions_do_not_call_curl() {
  local code out _errfile
  unset OPENROUTER_API_KEY JEV_ROUTE
  reset_log
  _errfile="$TMP_ROOT/stderr"
  code=0
  out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=$TS_KEY \
    fm_jev_decide "$STATE" 'not-json' 2> "$_errfile") || code=$?
  expect_code 2 "$code" "non-object questions exit 2"
  assert_contains "$(cat "$_errfile")" 'questions must be a JSON object' "bad questions explain themselves"
  assert_absent "$LOG/argv" "bad questions never call curl"
  pass "questions that are not a JSON object fail before curl"
}

test_http_error_is_hard_failure() {
  local code out err
  unset OPENROUTER_API_KEY JEV_ROUTE
  FAKE_CURL_HTTP=500 TYPESAFE_API_KEY=$TS_KEY run_decide code out err
  expect_code 1 "$code" "HTTP 500 exits 1"
  assert_contains "$err" 'http 500' "HTTP 500 is named"
  [ -z "$out" ] || fail "HTTP failure must not print a response body, got '$out'"
  pass "a non-200 response is a hard failure with no stdout JSON"
}

test_curl_transport_failure() {
  local code out err
  unset OPENROUTER_API_KEY JEV_ROUTE
  FAKE_CURL_FAIL=1 TYPESAFE_API_KEY=$TS_KEY run_decide code out err
  expect_code 1 "$code" "curl failure exits 1"
  assert_contains "$err" 'http 000' "transport failure is named as http 000"
  pass "a curl transport failure is a hard failure"
}

test_missing_curl() {
  local code out _errfile
  unset OPENROUTER_API_KEY JEV_ROUTE
  reset_log
  _errfile="$TMP_ROOT/stderr"
  code=0
  out=$(PATH="$NO_CURL_BIN" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=$TS_KEY \
    fm_jev_decide "$STATE" "$QUESTIONS" 2> "$_errfile") || code=$?
  expect_code 2 "$code" "missing curl exits 2"
  assert_contains "$(cat "$_errfile")" 'curl not installed' "missing curl is named"
  assert_absent "$LOG/argv" "missing curl never calls curl"
  pass "missing curl is a usage failure"
}

test_confidence_floor() {
  fm_jev_choice_confidence_ok 0.7 || fail "0.7 must clear the default 0.7 floor"
  fm_jev_choice_confidence_ok 0.82 || fail "0.82 must clear the default 0.7 floor"
  if fm_jev_choice_confidence_ok 0.69; then
    fail "0.69 must fail the default 0.7 floor"
  fi
  if fm_jev_choice_confidence_ok 0.6; then
    fail "0.6 must fail the default 0.7 floor"
  fi
  fm_jev_choice_confidence_ok 0.6 0.6 || fail "0.6 must clear an explicit 0.6 floor"
  if fm_jev_choice_confidence_ok not-a-number; then
    fail "non-numeric confidence must fail"
  fi
  pass "choice confidence floor defaults to 0.7 and accepts an explicit dispatch-style 0.6"
}

test_probabilities_sum() {
  fm_jev_probabilities_sum_ok '{"a":0.4,"b":0.6}' || fail "0.4+0.6 must be accepted"
  fm_jev_probabilities_sum_ok '{"a":0.5,"b":0.5}' || fail "0.5+0.5 must be accepted"
  if fm_jev_probabilities_sum_ok '{"a":0.5,"b":0.6}'; then
    fail "probabilities summing to 1.1 must fail"
  fi
  if fm_jev_probabilities_sum_ok '{"a":0.2}'; then
    fail "probabilities summing to 0.2 must fail"
  fi
  if fm_jev_probabilities_sum_ok '[]'; then
    fail "a JSON array must fail"
  fi
  pass "probabilities must be 0..1 numbers that sum to about 1"
}

test_compact_state_strips_secrets_and_refuses_oversized() {
  local out secret big
  secret='note TYPESAFE_API_KEY=abc123 and Bearer tok_secret_value and sk-or-v1-abcdefghijklmnopqrstuvwxyz'
  out=$(fm_jev_compact_state "keep this $secret skill-selector")
  assert_contains "$out" 'keep this' "compact keeps ordinary prose"
  assert_contains "$out" 'skill-selector' "compact does not strip ordinary skill-shaped words"
  assert_not_contains "$out" 'TYPESAFE_API_KEY=' "compact redacts TYPESAFE_API_KEY assignments"
  assert_not_contains "$out" 'abc123' "compact drops the assigned secret"
  assert_not_contains "$out" 'tok_secret_value' "compact drops a Bearer token"
  assert_not_contains "$out" 'sk-or-v1-abcdefghijklmnopqrstuvwxyz' "compact drops an OpenRouter-shaped key"
  assert_contains "$out" '[redacted]' "compact leaves an explicit redaction marker"
  big=$(printf '%*s' 9000 '' | tr ' ' 'x')
  if out=$(fm_jev_compact_state "$big" 2>/dev/null); then
    fail "oversized state must be refused"
  fi
  pass "compact-state strips obvious secrets and refuses oversized input"
}

test_log_call_writes_jsonl_without_secrets() {
  local path line
  path="$TMP_ROOT/jev-calls.jsonl"
  rm -f "$path"
  TYPESAFE_API_KEY=$TS_KEY fm_jev_log_call \
    "{\"purpose\":\"shadow\",\"authorization\":\"Bearer $TS_KEY\",\"model\":\"jev-latest\"}" \
    "$path"
  [ -f "$path" ] || fail "log file must be created"
  line=$(cat "$path")
  assert_not_contains "$line" "$TS_KEY" "log line must not contain the live key"
  assert_contains "$line" '[redacted]' "secret-shaped log keys are redacted"
  assert_contains "$line" '"purpose":"shadow"' "non-secret log fields are kept"
  unset TYPESAFE_API_KEY
  pass "log helper writes one JSONL line and keeps secrets out of it"
}

test_default_log_path() {
  local line
  rm -f "$HOME_DIR/state/jev-calls.jsonl"
  FM_HOME="$HOME_DIR" fm_jev_log_call '{"purpose":"default-path"}'
  [ -f "$HOME_DIR/state/jev-calls.jsonl" ] || fail "default log path must be \$FM_HOME/state/jev-calls.jsonl"
  line=$(cat "$HOME_DIR/state/jev-calls.jsonl")
  assert_contains "$line" '"purpose":"default-path"' "default-path log keeps the payload"
  pass "log helper defaults to \$FM_HOME/state/jev-calls.jsonl"
}

test_cli_is_not_a_user_command
test_openrouter_only_uses_openrouter_url_and_bearer
test_typesafe_only_uses_typesafe_url
test_typesafe_wins_when_both_keys_present
test_jev_route_openrouter_overrides_typesafe_key
test_jev_model_override
test_env_file_openrouter_key
test_environment_key_wins_over_env_file
test_missing_keys_do_not_call_curl
test_bad_questions_do_not_call_curl
test_http_error_is_hard_failure
test_curl_transport_failure
test_missing_curl
test_confidence_floor
test_probabilities_sum
test_compact_state_strips_secrets_and_refuses_oversized
test_log_call_writes_jsonl_without_secrets
test_default_log_path
