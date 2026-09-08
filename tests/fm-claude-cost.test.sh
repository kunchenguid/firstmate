#!/usr/bin/env bash
# Tests for fm-claude-cost.sh, the on-demand Claude Code extra-usage spend
# report.
#
# Hermetic throughout: a fakebin `curl` stands in for the Anthropic usage
# endpoint (recording the exact bearer header it received into a private log
# the script itself never sees or prints), so no case ever makes a real
# network call or reads the real ~/.claude/.credentials.json. Real jq, awk,
# and mktemp are used via a restricted BASE_PATH, matching this suite's other
# curl-fake tests (see fm-public-followup.test.sh).
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-claude-cost.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-cost)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# make_case <name>: a fresh fixture directory with its own fakebin, a valid
# credentials fixture, and empty logs.
make_case() {  # <name>
  local dir fakebin
  dir="$TMP_ROOT/$1"
  fakebin="$dir/fakebin"
  mkdir -p "$dir" "$fakebin"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl standing in for the Anthropic usage endpoint. Understands exactly
# the flag shape fm-claude-cost.sh uses: -s, -K <config>, -o <file>,
# -w <fmt>, --max-time <n>, and a trailing URL.
orig_args=("$@")
ofile="" cfg="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s) shift ;;
    -o) ofile=$2; shift 2 ;;
    -K) cfg=$2; shift 2 ;;
    -w) shift 2 ;;
    --max-time) shift 2 ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_CURL_ARGV_LOG:-}" ]; then
  printf '%s\n' "${orig_args[*]}" >> "$FAKE_CURL_ARGV_LOG"
fi
if [ -n "${FAKE_CURL_HEADER_LOG:-}" ] && [ -n "$cfg" ]; then
  sed -n 's/^header = "Authorization: \(.*\)"$/\1/p' "$cfg" >> "$FAKE_CURL_HEADER_LOG"
fi
if [ -n "${FAKE_CURL_EXIT:-}" ]; then
  exit "$FAKE_CURL_EXIT"
fi
if [ -n "$ofile" ]; then
  printf '%s' "${FAKE_CURL_BODY:-}" > "$ofile"
fi
printf '%s' "${FAKE_CURL_HTTP_CODE:-200}"
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "${FAKE_TOKEN:-test-token-abc123}" > "$dir/creds.json"
  : > "$dir/argv.log"
  : > "$dir/header.log"
  printf '%s\n' "$dir"
}

run_script() {  # <dir> [args...]
  local dir=$1
  shift
  FM_CLAUDE_CREDENTIALS_FILE="$dir/creds.json" FM_CLAUDE_USAGE_URL="http://usage.invalid/api/oauth/usage" \
    FAKE_CURL_ARGV_LOG="$dir/argv.log" FAKE_CURL_HEADER_LOG="$dir/header.log" \
    FAKE_CURL_HTTP_CODE="${FAKE_CURL_HTTP_CODE:-200}" FAKE_CURL_BODY="${FAKE_CURL_BODY:-}" \
    FAKE_CURL_EXIT="${FAKE_CURL_EXIT:-}" \
    PATH="$dir/fakebin:$BASE_PATH" "$SCRIPT" "$@"
}

SPEND_BODY='{"spend":{"used":{"amount_minor":15386,"currency":"USD","exponent":2},"limit":{"amount_minor":50000,"currency":"USD","exponent":2},"percent":31,"severity":"normal","enabled":true},"extra_usage":{"is_enabled":true}}'

test_help_and_usage_errors_touch_nothing() {
  local dir out rc
  dir=$(make_case help)
  out=$(run_script "$dir" --help) || fail "help exited non-zero"
  case "$out" in
    *"Usage:"*) ;;
    *) fail "help output did not print usage" ;;
  esac
  [ ! -s "$dir/argv.log" ] || fail "help made a network call"

  set +e
  run_script "$dir" --bogus >/dev/null 2>"$dir/stderr"; rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unknown flag did not exit with usage status 2"
  [ ! -s "$dir/argv.log" ] || fail "unknown flag made a network call"

  set +e
  run_script "$dir" --json extra >/dev/null 2>"$dir/stderr"; rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "extra argument did not exit with usage status 2"
  [ ! -s "$dir/argv.log" ] || fail "extra argument made a network call"
  pass "help and malformed arguments exit cleanly without any network call"
}

test_missing_or_malformed_credentials_are_refused() {
  local dir rc
  dir=$(make_case missing-creds)
  rm -f "$dir/creds.json"
  set +e
  run_script "$dir" >/dev/null 2>"$dir/stderr"; rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "missing credentials file did not exit 1"
  [ ! -s "$dir/argv.log" ] || fail "missing credentials file still made a network call"

  dir=$(make_case malformed-creds)
  printf 'not json\n' > "$dir/creds.json"
  set +e
  run_script "$dir" >/dev/null 2>"$dir/stderr"; rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "malformed credentials JSON did not exit 1"
  [ ! -s "$dir/argv.log" ] || fail "malformed credentials JSON still made a network call"

  dir=$(make_case no-token)
  printf '{"claudeAiOauth":{}}\n' > "$dir/creds.json"
  set +e
  run_script "$dir" >/dev/null 2>"$dir/stderr"; rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "credentials with no accessToken did not exit 1"
  [ ! -s "$dir/argv.log" ] || fail "credentials with no accessToken still made a network call"
  pass "missing, malformed, or token-less credentials are refused before any network call"
}

test_successful_spend_report_and_token_never_leaks() {
  local dir out
  dir=$(make_case success)
  FAKE_TOKEN='super-secret-token-xyz'
  printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$FAKE_TOKEN" > "$dir/creds.json"
  out=$(FAKE_CURL_HTTP_CODE=200 FAKE_CURL_BODY="$SPEND_BODY" run_script "$dir" 2>"$dir/stderr") \
    || fail "successful spend report exited non-zero: $(cat "$dir/stderr")"
  [ "$out" = 'Claude Code extra usage: USD 153.86 of USD 500.00 (31%) - normal' ] \
    || fail "spend summary line did not match: $out"
  [ "$(cat "$dir/header.log")" = "Bearer $FAKE_TOKEN" ] \
    || fail "fake endpoint did not receive the exact bearer token"
  case "$out" in
    *"$FAKE_TOKEN"*) fail "the access token leaked into script stdout" ;;
  esac
  case "$(cat "$dir/stderr")" in
    *"$FAKE_TOKEN"*) fail "the access token leaked into script stderr" ;;
  esac
  case "$(cat "$dir/argv.log")" in
    *"$FAKE_TOKEN"*) fail "the access token appeared on curl's own argv rather than only in its private config file" ;;
  esac
  pass "a successful call reports the exact dollar figures and never leaks the bearer token"
}

test_json_mode_prints_the_raw_response() {
  local dir out expected
  dir=$(make_case json-mode)
  out=$(FAKE_CURL_HTTP_CODE=200 FAKE_CURL_BODY="$SPEND_BODY" run_script "$dir" --json) \
    || fail "--json exited non-zero"
  expected=$(printf '%s' "$SPEND_BODY" | jq .)
  [ "$out" = "$expected" ] || fail "--json did not print the pretty-printed raw response"
  pass "--json prints the exact pretty-printed usage response"
}

test_extra_usage_fallback_when_spend_is_absent() {
  local dir out body
  dir=$(make_case extra-usage-fallback)
  body='{"spend":null,"extra_usage":{"is_enabled":true,"monthly_limit":50000,"used_credits":12345,"utilization":24.69,"currency":"USD","decimal_places":2}}'
  out=$(FAKE_CURL_HTTP_CODE=200 FAKE_CURL_BODY="$body" run_script "$dir" 2>"$dir/stderr") \
    || fail "extra_usage fallback exited non-zero: $(cat "$dir/stderr")"
  [ "$out" = 'Claude Code extra usage: USD 123.45 of USD 500.00 (24%) - n/a' ] \
    || fail "extra_usage fallback summary did not match: $out"
  pass "spend falls back to extra_usage when the spend object is absent"
}

test_disabled_extra_usage_is_reported_plainly() {
  local dir out body
  dir=$(make_case disabled)
  body='{"spend":null,"extra_usage":{"is_enabled":false}}'
  out=$(FAKE_CURL_HTTP_CODE=200 FAKE_CURL_BODY="$body" run_script "$dir") \
    || fail "disabled extra usage exited non-zero"
  [ "$out" = 'Claude Code extra usage is not enabled or not reported for this account.' ] \
    || fail "disabled extra usage message did not match: $out"
  pass "an account with no reported extra usage gets a plain explanatory line, not an error"
}

test_http_error_statuses_are_reported_distinctly() {
  local dir rc err
  dir=$(make_case http-429)
  set +e
  FAKE_CURL_HTTP_CODE=429 run_script "$dir" >/dev/null 2>"$dir/stderr"; rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "HTTP 429 did not exit 1"
  err=$(cat "$dir/stderr")
  case "$err" in
    *"429"*"rate-limit"*|*"429"*|*rate-limit*) ;;
    *) fail "HTTP 429 diagnostic did not mention the rate limit: $err" ;;
  esac

  dir=$(make_case http-401)
  set +e
  FAKE_CURL_HTTP_CODE=401 run_script "$dir" >/dev/null 2>"$dir/stderr"; rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "HTTP 401 did not exit 1"
  case "$(cat "$dir/stderr")" in
    *401*) ;;
    *) fail "HTTP 401 diagnostic did not mention the status" ;;
  esac

  dir=$(make_case http-500)
  set +e
  FAKE_CURL_HTTP_CODE=500 run_script "$dir" >/dev/null 2>"$dir/stderr"; rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "HTTP 500 did not exit 1"
  pass "rate-limit, credential, and generic HTTP failures are all reported distinctly and exit non-zero"
}

test_malformed_response_and_network_failure_are_refused() {
  local dir rc
  dir=$(make_case bad-json-response)
  set +e
  FAKE_CURL_HTTP_CODE=200 FAKE_CURL_BODY='not json' run_script "$dir" >/dev/null 2>"$dir/stderr"; rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "non-JSON 200 response did not exit 1"

  dir=$(make_case network-failure)
  set +e
  FAKE_CURL_EXIT=7 run_script "$dir" >/dev/null 2>"$dir/stderr"; rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "a failed curl invocation did not exit 1"
  pass "a non-JSON response and a failed request are both refused rather than crashing"
}

test_no_temporary_files_are_left_behind() {
  local dir before after
  dir=$(make_case cleanup)
  mkdir -p "$dir/tmphome"
  before=$(find "$dir/tmphome" -mindepth 1 | LC_ALL=C sort)
  TMPDIR="$dir/tmphome" FAKE_CURL_HTTP_CODE=200 FAKE_CURL_BODY="$SPEND_BODY" run_script "$dir" >/dev/null 2>"$dir/stderr" \
    || fail "successful run failed unexpectedly: $(cat "$dir/stderr")"
  after=$(find "$dir/tmphome" -mindepth 1 | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "a temporary curl config or response file was left behind"

  set +e
  TMPDIR="$dir/tmphome" FAKE_CURL_HTTP_CODE=429 run_script "$dir" >/dev/null 2>"$dir/stderr"
  set -e
  after=$(find "$dir/tmphome" -mindepth 1 | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "a temporary file was left behind after an error exit"
  pass "temporary curl config and response files are always cleaned up, on success and on error"
}

test_timeout_override_validation() {
  local dir rc
  dir=$(make_case timeout-validation)
  set +e
  FM_CLAUDE_COST_TIMEOUT=0 run_script "$dir" >/dev/null 2>"$dir/stderr"; rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "a zero timeout override was not refused"
  set +e
  FM_CLAUDE_COST_TIMEOUT=abc run_script "$dir" >/dev/null 2>"$dir/stderr"; rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "a non-numeric timeout override was not refused"
  set +e
  FM_CLAUDE_COST_TIMEOUT=61 run_script "$dir" >/dev/null 2>"$dir/stderr"; rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "a too-large timeout override was not refused"
  [ ! -s "$dir/argv.log" ] || fail "an invalid timeout override still made a network call"
  pass "an invalid FM_CLAUDE_COST_TIMEOUT override is refused before any network call"
}

test_help_and_usage_errors_touch_nothing
test_missing_or_malformed_credentials_are_refused
test_successful_spend_report_and_token_never_leaks
test_json_mode_prints_the_raw_response
test_extra_usage_fallback_when_spend_is_absent
test_disabled_extra_usage_is_reported_plainly
test_http_error_statuses_are_reported_distinctly
test_malformed_response_and_network_failure_are_refused
test_no_temporary_files_are_left_behind
test_timeout_override_validation
