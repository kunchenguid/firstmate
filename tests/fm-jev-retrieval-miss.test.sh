#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-retrieval-miss.sh.
#
# Drives the CLI with a fake curl on PATH that records argv, the request body,
# and the header read from file descriptor 3. No case touches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TYPESAFE_API_KEY OPENROUTER_API_KEY TYPESAFE_API_KEY_PRIVATE \
  OPENROUTER_API_KEY_PRIVATE JEV_ROUTE JEV_MODEL JEV_TIMEOUT \
  JEV_CONFIDENCE_FLOOR JEV_STATE_MAX_BYTES

TMP_ROOT=$(fm_test_tmproot fm-jev-retrieval-miss)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'
QUERY='How can I protect my hands against burns?'
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

write_response() {
  local choice=$1
  local conf=${2:-0.82}
  cat > "$RESPONSE" <<JSON
{ "model": "jev-1.13.0",
  "answers": {
    "miss": { "type": "choice", "choice": "$choice", "confidence": $conf,
      "probabilities": { "true_miss": 0.1, "vocab_divergence": 0.7, "consent_blocked": 0.1, "need_human": 0.1 } } },
  "usage": { "input_tokens": 40, "output_tokens": 12 } }
JSON
}

MISS_ENVELOPE='{"status":"no-match","query":"How can I protect my hands against burns?","citations":[],"text":"No authorized wiki matched.","retrieval":{"status":"disabled","mode":"full-corpus-bm25","pages_searched":0}}'
EXCERPT_ENVELOPE='{"status":"no-match","query":"hands","excerpt":"Wear insulated gauntlets when handling a hot kiln.","citations":[]}'

MISS_ENVELOPE_FILE="$TMP_ROOT/miss.json"
EXCERPT_ENVELOPE_FILE="$TMP_ROOT/excerpt.json"
printf '%s\n' "$MISS_ENVELOPE" > "$MISS_ENVELOPE_FILE"
printf '%s\n' "$EXCERPT_ENVELOPE" > "$EXCERPT_ENVELOPE_FILE"

RESPONSE="$TMP_ROOT/response.json"
write_response vocab_divergence
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" CHILD_ENV_LOG="$LOG/child-env"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

run_miss() {
  local __exit=$1 __out=$2 __err=$3
  shift 3
  local _out _errfile _code
  _errfile="$TMP_ROOT/stderr"
  reset_log
  rm -f "$HOME_DIR/state/jev-retrieval-miss.jsonl"
  _code=0
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" \
    FAKE_CURL_HTTP="${FAKE_CURL_HTTP:-200}" FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" \
    "$ROOT/bin/fm-jev-retrieval-miss.sh" "$@" 2> "$_errfile") || _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$_errfile")"
  unset FAKE_CURL_HTTP FAKE_CURL_FAIL
}

test_usage_requires_query_and_envelope() {
  local code out err
  run_miss code out err
  expect_code 2 "$code" "missing args exit 2"
  assert_contains "$err" 'Usage:' "usage is printed"
  run_miss code out err --query "$QUERY"
  expect_code 2 "$code" "missing envelope exits 2"
  run_miss code out err --query "$QUERY" --envelope "$MISS_ENVELOPE"
  expect_code 2 "$code" "inline envelope is not a supported interface"
  [ ! -f "$LOG/argv" ] || fail "invalid usage must not call curl"
  pass "usage requires --query and --envelope-file"
}

test_allowlisted_miss_logs_without_retry() {
  local code out err line body
  write_response vocab_divergence 0.82
  TYPESAFE_API_KEY=$TS_KEY run_miss code out err --query "$QUERY" \
    --envelope-file "$MISS_ENVELOPE_FILE" --embeddings-enabled 0 --openviking-enabled 0
  expect_code 0 "$code" "allowlisted miss exits 0"
  assert_contains "$out" 'verdict: vocab_divergence' "prints vocab_divergence"
  assert_contains "$out" 'sent: yes' "sent the allowlisted state"
  assert_contains "$out" 'shadow: yes' "shadow marker is present"
  [ -f "$HOME_DIR/state/jev-retrieval-miss.jsonl" ] \
    || fail "must log to state/jev-retrieval-miss.jsonl"
  line=$(cat "$HOME_DIR/state/jev-retrieval-miss.jsonl")
  assert_contains "$line" '"purpose":"retrieval-miss"' "log purpose is retrieval-miss"
  assert_contains "$line" '"verdict":"vocab_divergence"' "log records the choice"
  assert_contains "$line" '"retry":false' "log retry is false"
  assert_contains "$line" '"config_write":false' "log config_write is false"
  assert_contains "$line" '"sent":true' "log sent is true"
  jq -e '.route == "typesafe" and .http == "200" and (.latency_ms | type == "number")' \
    "$HOME_DIR/state/jev-retrieval-miss.jsonl" >/dev/null || fail "transport metadata must survive the call"
  body=$(cat "$LOG/body")
  assert_contains "$body" "$QUERY" "query reaches Jev state"
  assert_contains "$body" 'retrieval_status' "retrieval status is in state"
  assert_contains "$body" 'pages_searched' "pages searched is in state"
  assert_contains "$body" 'embeddings_enabled' "embeddings flag is in state"
  assert_contains "$body" 'openviking_enabled' "openviking flag is in state"
  assert_not_contains "$body" 'Wear insulated' "no page body in the request"
  assert_not_contains "$body" "$TS_KEY" "key is absent from the request body"
  pass "allowlisted miss logs a shadow record and never retries"
}

test_excerpt_payload_is_refused_not_sent() {
  local code out err line
  write_response vocab_divergence 0.9
  TYPESAFE_API_KEY=$TS_KEY run_miss code out err --query "$QUERY" \
    --envelope-file "$EXCERPT_ENVELOPE_FILE"
  expect_code 0 "$code" "excerpt refusal still exits 0"
  assert_contains "$out" 'verdict: refused' "prints refused"
  assert_contains "$out" 'sent: no' "did not send"
  [ ! -f "$LOG/argv" ] || fail "excerpt payload must not call curl"
  line=$(cat "$HOME_DIR/state/jev-retrieval-miss.jsonl")
  assert_contains "$line" '"verdict":"refused"' "log records refused"
  assert_contains "$line" '"sent":false' "log sent is false"
  assert_contains "$line" '"refused":true' "log refused is true"
  pass "a payload carrying an excerpt is refused rather than sent"
}

test_nonempty_citations_are_refused() {
  local code out err
  write_response true_miss 0.9
  printf '%s\n' '{"status":"no-match","citations":[{"path":"wiki/x.md","excerpts":[{"excerpt":"secret line"}]}]}' > "$TMP_ROOT/citations.json"
  TYPESAFE_API_KEY=$TS_KEY run_miss code out err --query "$QUERY" \
    --envelope-file "$TMP_ROOT/citations.json"
  expect_code 0 "$code" "citation refusal exits 0"
  assert_contains "$out" 'verdict: refused' "citations are treated as page content"
  [ ! -f "$LOG/argv" ] || fail "citation payload must not call curl"
  pass "non-empty citations are refused rather than sent"
}

test_low_confidence_rewrites_to_need_human() {
  local code out err line
  write_response vocab_divergence 0.4
  TYPESAFE_API_KEY=$TS_KEY run_miss code out err --query "$QUERY" \
    --envelope-file "$MISS_ENVELOPE_FILE"
  expect_code 0 "$code" "low-confidence miss exits 0"
  assert_contains "$out" 'verdict: need_human' "low confidence becomes need_human"
  line=$(cat "$HOME_DIR/state/jev-retrieval-miss.jsonl")
  assert_contains "$line" '"verdict":"need_human"' "log records need_human"
  assert_contains "$line" '"retry":false' "low confidence is not a retry"
  pass "low confidence resolves to need_human, never a retry"
}

test_low_confidence_true_miss_stays_true_miss() {
  local code out err
  write_response true_miss 0.2
  TYPESAFE_API_KEY=$TS_KEY run_miss code out err --query "$QUERY" \
    --envelope-file "$MISS_ENVELOPE_FILE"
  expect_code 0 "$code" "low-confidence true_miss exits 0"
  assert_contains "$out" 'verdict: true_miss' "true_miss is kept at low confidence"
  pass "low confidence true_miss stays true_miss"
}

test_missing_key_skips_without_curl() {
  local code out err
  unset TYPESAFE_API_KEY OPENROUTER_API_KEY
  write_response vocab_divergence
  run_miss code out err --query "$QUERY" --envelope-file "$MISS_ENVELOPE_FILE"
  expect_code 0 "$code" "missing key still exits 0"
  assert_contains "$out" 'verdict: skipped' "missing key is skipped"
  assert_contains "$out" 'sent: no' "missing key does not send"
  [ ! -f "$LOG/argv" ] || fail "missing key must not call curl"
  [ -f "$HOME_DIR/state/jev-retrieval-miss.jsonl" ] \
    || fail "missing key still logs"
  pass "missing key skips without a network call"
}

test_failed_responses_still_record_transport_attempt() {
  local code out err mode expected_http
  for mode in http invalid transport; do
    write_response vocab_divergence
    expected_http=200
    case "$mode" in
      http) FAKE_CURL_HTTP=500; expected_http=500 ;;
      invalid) printf 'invalid json\n' > "$RESPONSE" ;;
      transport) FAKE_CURL_FAIL=1; expected_http=000 ;;
    esac
    TYPESAFE_API_KEY=$TS_KEY run_miss code out err --query "$QUERY" --envelope-file "$MISS_ENVELOPE_FILE"
    expect_code 0 "$code" "failed response remains nonblocking"
    assert_contains "$out" 'verdict: skipped' "failed response skips classification"
    assert_contains "$out" 'sent: yes' "attempted transport cannot claim unsent"
    jq -e --arg http "$expected_http" \
      '.sent and .decide_code == 1 and .route == "typesafe" and .http == $http and (.latency_ms | type == "number")' \
      "$HOME_DIR/state/jev-retrieval-miss.jsonl" >/dev/null || fail "failed response retains transport evidence"
    [ -s "$LOG/body" ] || fail "transport received request body"
  done
  pass "failed responses retain transport attempts independently of classification"
}

test_missing_confidence_requires_human() {
  local code out err choice confidence
  for choice in vocab_divergence consent_blocked; do
    for confidence in missing null; do
      jq -nc --arg choice "$choice" --arg confidence "$confidence" \
        '{answers: {miss: ({choice: $choice} + (if $confidence == "null" then {confidence: null} else {} end))}}' > "$RESPONSE"
      TYPESAFE_API_KEY=$TS_KEY run_miss code out err --query "$QUERY" --envelope-file "$MISS_ENVELOPE_FILE"
      expect_code 0 "$code" "missing confidence remains nonblocking"
      assert_contains "$out" 'verdict: need_human' "unsupported classification needs human review"
      jq -e '.verdict == "need_human" and .confidence == null and .sent' \
        "$HOME_DIR/state/jev-retrieval-miss.jsonl" >/dev/null || fail "missing confidence must be logged conservatively"
    done
  done
  pass "missing and null confidence require human review"
}

test_usage_requires_query_and_envelope
test_allowlisted_miss_logs_without_retry
test_failed_responses_still_record_transport_attempt
test_excerpt_payload_is_refused_not_sent
test_nonempty_citations_are_refused
test_low_confidence_rewrites_to_need_human
test_missing_confidence_requires_human
test_low_confidence_true_miss_stays_true_miss
test_missing_key_skips_without_curl

printf '# all fm-jev-retrieval-miss tests passed\n'
