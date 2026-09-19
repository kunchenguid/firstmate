#!/usr/bin/env bash
# Behavior tests for bin/fm-voice-check.sh.
#
# Drives the public argv, stdin, and environment interface with a fake curl on
# PATH (the network boundary) that records each call, the request body, and
# the header read from file descriptor 3, and answers with a canned typesafe.ai
# response or a transport failure. No case touches the network, and the
# absent-key case proves the tool makes no call at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-voice-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-voice-check)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
TEXT="$TMP_ROOT/text.md"
RESPONSE="$TMP_ROOT/response.json"
BASE_PATH=$PATH
KEY='ts-test-key-not-real'
mkdir -p "$HOME_DIR" "$LOG"
unset TYPESAFE_API_KEY

printf '%s\n' 'Refresh the pager so each call returns exactly one page.' > "$TEXT"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf 'secret-present\n' >> "${FAKE_CURL_LOG:?}/child-env"
fi
printf 'call\n' >> "$FAKE_CURL_LOG/calls"
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "$FAKE_CURL_LOG/argv"; shift ;;
  esac
done
cat > "$FAKE_CURL_LOG/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
[ "${FAKE_CURL_FAIL:-0}" = 1 ] && exit 28
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE"

# respond <choice:confidence:yes> x4 in category order: operator_address,
# relayed_orders, quoted_answer, other_language.
respond() {
  jq -n --arg a "$1" --arg b "$2" --arg c "$3" --arg d "$4" '
    def ans($s): ($s | split(":")) as $p |
      {type: "choice", choice: $p[0], confidence: ($p[1] | tonumber),
       probabilities: {yes: ($p[2] | tonumber), no: (1 - ($p[2] | tonumber))}};
    {model: "jev-test", answers: {operator_address: ans($a), relayed_orders: ans($b),
      quoted_answer: ans($c), other_language: ans($d)}, usage: {input_tokens: 10, output_tokens: 4}}' > "$RESPONSE"
}
CLEAN='no:0.9:0.05'

reset_log() { rm -rf "$LOG"; mkdir -p "$LOG"; }
calls() { if [ -f "$LOG/calls" ]; then wc -l < "$LOG/calls" | tr -d ' '; else echo 0; fi; }

# run <exit-var> <out-var> <err-var> [args...]
run() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

test_key_absent_is_off_with_no_call() {
  local code out err
  reset_log
  respond "yes:0.99:0.99" "$CLEAN" "$CLEAN" "$CLEAN"
  run code out err "$TEXT"
  [ "$code" = 0 ] || fail "absent key must exit 0, got $code"
  [ -z "$out" ] || fail "absent key must print nothing on stdout: $out"
  assert_contains "$err" "voice-check: off" "absent key must say the check is off"
  [ "$(calls)" = 0 ] || fail "absent key must make no network call"
  pass "fm-voice-check: key absent means off, exit 0, no network call"
}

test_clean_text_is_clear() {
  local code out err
  reset_log
  respond "$CLEAN" "$CLEAN" "$CLEAN" "$CLEAN"
  TYPESAFE_API_KEY=$KEY run code out err --kind pr "$TEXT"
  [ "$code" = 0 ] || fail "clean text must exit 0, got $code: $out $err"
  assert_contains "$out" "status: clear" "clean text must report clear"
  [ "$(calls)" = 1 ] || fail "clean text must take one call, got $(calls)"
  jq -e '.questions | keys == ["operator_address","other_language","quoted_answer","relayed_orders"]' "$LOG/body" >/dev/null \
    || fail "request must ask the four closed category questions"
  jq -e --rawfile t "$TEXT" '.state.artifact.text == $t and .state.artifact.kind == "pull request description"' "$LOG/body" >/dev/null \
    || fail "request must carry the text and its artifact kind as state"
  assert_not_contains "$(cat "$LOG/argv")" "$KEY" "the key must never reach curl argv"
  assert_contains "$(cat "$LOG/header")" "Authorization: Bearer $KEY" "the key must reach curl as an fd header"
  [ ! -f "$LOG/child-env" ] || fail "the key must not be exported to curl's environment"
  pass "fm-voice-check: a clean text is clear, exit 0, and the key stays off argv and child env"
}

test_flagged_text_stops() {
  local code out err
  reset_log
  respond "$CLEAN" "yes:0.4:0.55" "yes:0.95:0.98" "$CLEAN"
  TYPESAFE_API_KEY=$KEY run code out err --kind intent - < "$TEXT"
  [ "$code" = 1 ] || fail "flagged text must exit 1, got $code"
  assert_contains "$out" "status: flagged" "flagged text must report flagged"
  assert_contains "$out" "finding: quoted_answer yes=0.98" "the flagged category must be named"
  assert_contains "$out" "finding: relayed_orders yes=0.55" "a low-confidence yes still flags"
  assert_contains "$err" "do not publish" "stderr must say not to publish"
  reset_log
  TYPESAFE_API_KEY=$KEY run code out err --accept-unverified "operator said go" "$TEXT"
  [ "$code" = 1 ] || fail "the unverified override must never clear a flagged text, got $code"
  assert_not_contains "$out" "accepted-unverified" "a flagged text must not be reported as accepted"
  pass "fm-voice-check: a flagged text stops with exit 1 and no override clears it"
}

test_unavailable_service_is_unverified_after_one_retry() {
  local code out err
  reset_log
  respond "$CLEAN" "$CLEAN" "$CLEAN" "$CLEAN"
  FAKE_CURL_FAIL=1 TYPESAFE_API_KEY=$KEY run code out err "$TEXT"
  [ "$code" = 3 ] || fail "an unreachable service must exit 3, got $code"
  assert_contains "$out" "status: unverified" "an unreachable service must report unverified"
  assert_contains "$out" "service unavailable: http 000" "the reason must name the transport failure"
  [ "$(calls)" = 2 ] || fail "an unreachable service must be retried exactly once, got $(calls) calls"
  reset_log
  FAKE_CURL_HTTP=503 TYPESAFE_API_KEY=$KEY run code out err "$TEXT"
  [ "$code" = 3 ] || fail "an error response must exit 3, got $code"
  assert_contains "$out" "http 503" "the reason must name the error status"
  reset_log
  printf '{"answers":{"operator_address":{"choice":"maybe"}}}' > "$RESPONSE"
  TYPESAFE_API_KEY=$KEY run code out err "$TEXT"
  [ "$code" = 3 ] || fail "a malformed answer must exit 3, got $code"
  [ "$(calls)" = 2 ] || fail "a malformed answer must be retried exactly once, got $(calls) calls"
  pass "fm-voice-check: unreachable, error, and malformed answers are unverified after one retry"
}

test_uncertain_answer_is_unverified() {
  local code out err
  reset_log
  respond "$CLEAN" "no:0.3:0.4" "$CLEAN" "$CLEAN"
  TYPESAFE_API_KEY=$KEY run code out err "$TEXT"
  [ "$code" = 3 ] || fail "an uncertain answer leaning clean must exit 3, got $code"
  assert_contains "$out" "uncertain: relayed_orders yes=0.4" "the uncertain category must be named"
  [ "$(calls)" = 2 ] || fail "an uncertain answer must be retried exactly once, got $(calls) calls"
  pass "fm-voice-check: an uncertain answer leaning clean is retried once, then unverified, exit 3"
}

test_accepted_unverified_publishes_with_reason() {
  local code out err
  reset_log
  FAKE_CURL_FAIL=1 TYPESAFE_API_KEY=$KEY run code out err --accept-unverified "firstmate steer: service outage" "$TEXT"
  [ "$code" = 0 ] || fail "an accepted unverified result must exit 0, got $code"
  assert_contains "$out" "status: unverified" "the result must still say unverified"
  assert_contains "$out" "accepted-unverified: firstmate steer: service outage" "the override reason must be printed"
  run code out err --accept-unverified "   " "$TEXT"
  [ "$code" = 2 ] || fail "a blank override reason is a usage error, got $code"
  pass "fm-voice-check: an explicit override publishes an unverified text and prints its reason"
}

test_usage_errors() {
  local code out err
  : > "$TMP_ROOT/empty.md"
  TYPESAFE_API_KEY=$KEY run code out err "$TMP_ROOT/empty.md"
  [ "$code" = 2 ] || fail "empty text must be a usage error, got $code"
  TYPESAFE_API_KEY=$KEY run code out err "$TMP_ROOT/missing.md"
  [ "$code" = 2 ] || fail "a missing file must be a usage error, got $code"
  run code out err --kind comment "$TEXT"
  [ "$code" = 2 ] || fail "an unknown kind must be a usage error, got $code"
  pass "fm-voice-check: usage errors exit 2"
}

test_key_absent_is_off_with_no_call
test_clean_text_is_clear
test_flagged_text_stops
test_unavailable_service_is_unverified_after_one_retry
test_uncertain_answer_is_unverified
test_accepted_unverified_publishes_with_reason
test_usage_errors
echo "# all fm-voice-check tests passed"
