#!/usr/bin/env bash
# Behavior tests for bin/fm-intake-classify.sh.
#
# Drives the public argv and environment interface with a fake curl that records
# argv, body, and the header read from file descriptor 3 before returning a
# canned System One response.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-intake-classify.sh"
TMP_ROOT=$(fm_test_tmproot fm-intake-classify)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
REQUEST_FILE="$TMP_ROOT/request.md"
SCOUT_REQUEST_FILE="$TMP_ROOT/scout-request.md"
ANSWER_REQUEST_FILE="$TMP_ROOT/answer-request.md"
RESPONSE="$TMP_ROOT/response.json"
BASE_PATH=$PATH
mkdir -p "$HOME_DIR" "$LOG"

cat > "$REQUEST_FILE" <<'MD'
# Request

Fix the off-by-one in the pager, whose cause and expected behavior are already stated.
MD

cat > "$SCOUT_REQUEST_FILE" <<'MD'
# Request

Investigate the intermittent pager skip and report the cause without changing code.
MD

cat > "$ANSWER_REQUEST_FILE" <<'MD'
# Request

What does the pager's follow flag do?
MD

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf '%s\n' 'curl:secret-present' >> "${CHILD_ENV_LOG:?}"
else
  printf '%s\n' 'curl:clean' >> "${CHILD_ENV_LOG:?}"
fi
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
cat > "${FAKE_CURL_LOG:?}/body"
cat /dev/fd/3 > "${FAKE_CURL_LOG:?}/header" 2>/dev/null || printf '%s\n' 'fd3 unreadable' > "${FAKE_CURL_LOG:?}/header"
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then exit 7; fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

write_response() {  # <deliverable> <deliverable-confidence> <intent-noul> <score> <score-confidence>
  local ship=0.02 scout=0.02 answer_now=0.02 unclear=0.02
  case "$1" in
    ship) ship=0.94 ;;
    scout) scout=0.94 ;;
    answer_now) answer_now=0.94 ;;
    unclear) unclear=0.94 ;;
  esac
  cat > "$RESPONSE" <<JSON
{
  "model": "jev-1.13.0",
  "answers": {
    "deliverable": {
      "type": "choice",
      "choice": "$1",
      "confidence": $2,
      "probabilities": {"ship": $ship, "scout": $scout, "answer_now": $answer_now, "unclear": $unclear}
    },
    "intent_clear": {"type": "noul", "noul": $3},
    "urgency": {"type": "score", "score": $4, "confidence": $5}
  },
  "usage": {"input_tokens": 321, "output_tokens": 47}
}
JSON
}

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

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

export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" CHILD_ENV_LOG="$LOG/child-env"
KEY='test-key-9f1c2d3e-never-on-argv'
code='' out='' err=''

# --- absent key: off, exact stderr, no network ---------------------------------
reset_log
write_response ship 0.95 0.94 0 0.93
run code out err "$REQUEST_FILE" --project pager
expect_code 0 "$code" "absent key exits 0"
assert_equals '' "$out" "absent key prints nothing on stdout"
assert_equals 'intake-classify: off' "$err" "absent key has the fixed off diagnostic"
assert_absent "$LOG/argv" "absent key never calls curl"
pass "absent key leaves classification off without a network call"

# --- .env key, environment precedence, and request shape -----------------------
printf '%s\n' "export TYPESAFE_API_KEY=\"$KEY\"" > "$HOME_DIR/.env"
reset_log
write_response ship 0.95 0.94 0 0.93
run code out err "$REQUEST_FILE" --project pager
expect_code 0 "$code" ".env key exits 0"
assert_contains "$out" '  status: clear' ".env key enables classification"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" ".env key reaches curl through fd 3"
reset_log
TYPESAFE_API_KEY=env-wins run code out err "$REQUEST_FILE" --project pager
assert_equals 'Authorization: Bearer env-wins' "$(cat "$LOG/header")" "environment key wins over .env"
rm -f "$HOME_DIR/.env"

argv=$(cat "$LOG/argv")
body=$(cat "$LOG/body")
assert_not_contains "$argv" "$KEY" "the key never appears on curl argv"
assert_equals '-q' "$(head -n 1 "$LOG/argv")" "curl disables ambient configuration before every other option"
assert_contains "$argv" 'https://api.typesafe.ai/v1/systemone' "the fixed endpoint is used"
assert_contains "$argv" $'--max-time\n5' "the fixed timeout is used"
assert_contains "$argv" '@/dev/fd/3' "curl reads the header from a file descriptor"
assert_equals 'curl:clean' "$(cat "$LOG/child-env")" "the key is absent from curl's environment"
assert_equals 'jev-latest' "$(jq -r .model <<<"$body")" "the request pins the Jev model"
assert_equals 'pager' "$(jq -r .state.intake.project <<<"$body")" "project is in state"
assert_contains "$(jq -r .state.intake.request <<<"$body")" 'off-by-one in the pager' "request text is in state"
assert_equals '["deliverable","intent_clear","urgency"]' "$(jq -c '.questions | keys' <<<"$body")" "all questions share one request"
assert_equals 'choice' "$(jq -r .questions.deliverable.type <<<"$body")" "deliverable is Choice"
assert_equals 'noul' "$(jq -r .questions.intent_clear.type <<<"$body")" "authorization is NOUL"
assert_equals 'score' "$(jq -r .questions.urgency.type <<<"$body")" "urgency is Score"
assert_equals '["answer_now","scout","ship","unclear"]' "$(jq -c '.questions.deliverable.criteria | keys' <<<"$body")" "deliverable choices are fixed"
assert_contains "$(jq -r '.questions.urgency.criteria[0]' <<<"$body")" '0 routine' "urgency criteria explains routine"
assert_contains "$(jq -r '.questions.urgency.criteria[2]' <<<"$body")" '2 blocking' "urgency criteria explains blocking"
pass "opted-in request uses all typed questions and keeps the key off argv and child environments"

# --- clear classifications ------------------------------------------------------
reset_log
write_response ship 0.95 0.94 0 0.93
TYPESAFE_API_KEY=$KEY run code out err "$REQUEST_FILE"
expect_code 0 "$code" "clear classification exits 0"
assert_contains "$out" 'intake-classify:' "TOON header is present"
assert_contains "$out" '  status: clear' "authorized ship is clear"
assert_contains "$out" '  deliverable: ship   confidence: 0.95' "ship recommendation is printed"
assert_contains "$out" '  intent_clear: true   noul: 0.94' "authorization answer is printed"
assert_contains "$out" '  urgency: routine   score: 0   confidence: 0.93' "routine urgency is printed"
assert_contains "$out" '  request_truncated: false' "short request is not truncated"
write_response scout 0.95 0.05 1 0.93
TYPESAFE_API_KEY=$KEY run code out err "$SCOUT_REQUEST_FILE"
assert_contains "$out" '  status: clear' "high-confidence scout is clear without implementation authorization"
assert_contains "$out" '  deliverable: scout' "scout remains a recommendation"
assert_contains "$out" '  intent_clear: false   noul: 0.05' "scout preserves its low implementation authorization"
write_response answer_now 0.95 0.05 2 0.93
TYPESAFE_API_KEY=$KEY run code out err "$ANSWER_REQUEST_FILE"
assert_contains "$out" '  status: clear' "high-confidence answer-now is clear without implementation authorization"
assert_contains "$out" '  deliverable: answer_now' "answer-now remains a recommendation"
assert_contains "$out" '  intent_clear: false   noul: 0.05' "answer-now preserves its low implementation authorization"
assert_contains "$out" '  urgency: blocking   score: 2' "blocking urgency does not auto-spawn or change status"
pass "ship authorization gates only ship while all recommendations stay advisory"

# --- ambiguous and escalate outcomes -------------------------------------------
reset_log
write_response scout 0.55 0.05 1 0.93
TYPESAFE_API_KEY=$KEY run code out err "$SCOUT_REQUEST_FILE"
assert_contains "$out" '  status: ambiguous' "low confidence is ambiguous"
assert_contains "$out" 'lowest answer confidence 0.55 below floor 0.6' "the confidence floor is named"
write_response ship 0.95 0.05 1 0.93
TYPESAFE_API_KEY=$KEY run code out err "$REQUEST_FILE"
assert_contains "$out" '  status: escalate' "missing authorization escalates"
assert_contains "$out" 'concrete implementation authorization is not clear' "authorization escalation is named"
write_response unclear 0.95 0.05 1 0.93
TYPESAFE_API_KEY=$KEY run code out err "$REQUEST_FILE"
assert_contains "$out" '  status: ambiguous' "unclear deliverable is ambiguous"
assert_contains "$out" 'deliverable recommendation is unclear' "unclear recommendation is named"
pass "confidence, authorization, and unclear recommendations compose in code"

# --- bounded input and runtime failures -----------------------------------------
BIG_REQUEST="$TMP_ROOT/large-request.md"
head -c 40000 /dev/zero | tr '\0' x > "$BIG_REQUEST"
reset_log
write_response scout 0.95 0.94 1 0.93
TYPESAFE_API_KEY=$KEY run code out err "$BIG_REQUEST"
assert_equals '32768' "$(jq -r '.state.intake.request | length' < "$LOG/body")" "request text is byte-bounded"
assert_contains "$out" '  request_truncated: true' "truncation is disclosed"
reset_log
FAKE_CURL_HTTP=429 TYPESAFE_API_KEY=$KEY run code out err "$REQUEST_FILE"
expect_code 0 "$code" "HTTP failure exits 0"
assert_contains "$out" '  status: error' "HTTP failure is structured"
assert_contains "$out" 'http 429' "HTTP status is named"
reset_log
write_response ship 0.95 0.94 1 0.93
jq 'del(.answers.urgency.score) | .answers.urgency.value = 1 | .answers.urgency.answer = 2' "$RESPONSE" > "$RESPONSE.tmp"
mv "$RESPONSE.tmp" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$REQUEST_FILE"
expect_code 0 "$code" "undocumented urgency fields exit 0"
assert_contains "$out" '  status: error' "undocumented urgency fields are rejected"
assert_contains "$out" 'response is not a typed intake answer' "the Score contract requires score"
cat > "$RESPONSE" <<'JSON'
{"answers":{"deliverable":{"choice":"ship"}}}
JSON
TYPESAFE_API_KEY=$KEY run code out err "$REQUEST_FILE"
expect_code 0 "$code" "malformed response exits 0"
assert_contains "$out" 'response is not a typed intake answer' "malformed response is structured"
pass "bounded input and ordinary runtime failures never block intake"

# --- usage errors stay actionable ------------------------------------------------
TYPESAFE_API_KEY=$KEY run code out err
expect_code 2 "$code" "missing request file exits 2"
assert_contains "$err" 'request file required' "missing request is named"
TYPESAFE_API_KEY=$KEY run code out err "$REQUEST_FILE" --bogus
expect_code 2 "$code" "unknown option exits 2"
assert_contains "$err" 'unknown flag --bogus' "unknown option is named"

printf '%s\n' '# all fm-intake-classify tests passed'
