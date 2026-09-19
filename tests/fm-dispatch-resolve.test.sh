#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-resolve.sh.
#
# Drives the executable interface with fake curl and quota-axi commands.
# The fake curl records its request and returns canned Jev responses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-dispatch-resolve.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-resolve)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NO_CURL_BIN="$TMP_ROOT/no-curl-bin"
LOG="$TMP_ROOT/log"
BRIEF="$TMP_ROOT/brief.md"
BASE_RULES="$TMP_ROOT/rules.json"
RULES="$HOME_DIR/config/crew-dispatch.json"
RESPONSE="$TMP_ROOT/response.json"
BASE_PATH=$PATH
mkdir -p "$HOME_DIR/config" "$LOG" "$NO_CURL_BIN"
for command_name in bash chmod cp dirname jq mktemp rm; do
  ln -s "$(command -v "$command_name")" "$NO_CURL_BIN/$command_name"
done

cat > "$BRIEF" <<'MD'
# Task
Fix the off-by-one in the pager: root cause is the <= on line 40.
MD

cat > "$BASE_RULES" <<'JSON'
{
  "rules": [
    {
      "when": "New feature work on the app.",
      "use": { "harness": "claude", "model": "fable", "effort": "xhigh" },
      "why": "SECRET-WHY-TEXT"
    },
    {
      "when": "The task generates images.",
      "use": [
        { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "provider": "codex" },
        { "harness": "codex", "model": "gpt-5.6-sol", "floor": { "scope": "all_models", "min_percent": 50 } }
      ]
    },
    {
      "when": "Genuinely difficult design work.",
      "approval": "captain",
      "use": { "harness": "claude", "model": "fable", "effort": "xhigh" }
    },
    {
      "when": "A simple bug fix with a stated root cause.",
      "use": [
        { "harness": "codex", "model": "gpt-5.5", "effort": "high", "provider": "claude" },
        { "harness": "claude", "model": "sonnet", "effort": "high", "provider": "claude" }
      ]
    }
  ],
  "default": [
    { "harness": "claude", "model": "opus" },
    { "harness": "cursor", "model": "cursor-grok-4.6-high" }
  ]
}
JSON
cp "$BASE_RULES" "$RULES"

write_response() {
  cat > "$1" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "$2", "confidence": $3,
    "probabilities": { "rule_1": 0.01, "rule_2": 0.01, "rule_3": 0.01, "rule_4": 0.96, "default": 0.01 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
}

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
first_arg=${1:-}
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf 'secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'clean\n' >> "${CHILD_ENV_LOG:?}"
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
if [ "$first_arg" != -q ] && [ -r "${CURL_HOME:-}/.curlrc" ]; then
  while read -r option value; do
    [ "$option" = trace-ascii ] || continue
    cp "$FAKE_CURL_LOG/header" "$value"
  done < "$CURL_HOME/.curlrc"
fi
if [ -n "${FAKE_CURL_MUTATE_SOURCE:-}" ]; then
  cp "$FAKE_CURL_MUTATE_SOURCE" "${FAKE_CURL_MUTATE_TARGET:?}"
fi
[ "${FAKE_CURL_FAIL:-0}" = 1 ] && exit 7
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${QUOTA_AXI_CALLS:?}"
exit 99
SH
chmod +x "$FAKEBIN/quota-axi"

export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE"
export QUOTA_AXI_CALLS="$LOG/quota-axi.calls" CHILD_ENV_LOG="$LOG/child-env"

assert_equals() {
  local expected=$1 actual=$2 message=$3
  if [ "$expected" = "$actual" ]; then
    pass "$message"
  else
    fail "$message (expected: '$expected', got: '$actual')"
  fi
}

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

run() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

run_traced() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" bash -x "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

run_allexport() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" bash -a "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

run_without_curl() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$NO_CURL_BIN" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="$KEY" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

KEY='test-key-9f1c2d3e-never-on-argv'
code='' out='' err=''

reset_log
write_response "$RESPONSE" rule_4 0.9
run code out err "$BRIEF" --project pager
expect_code 0 "$code" "absent key exits 0"
assert_equals '' "$out" "absent key prints nothing"
assert_contains "$err" 'dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and' "absent key explains itself"
assert_absent "$LOG/argv" "absent key never calls curl"
assert_absent "$LOG/quota-axi.calls" "absent key never calls quota-axi"
pass "absent key preserves deterministic dispatch"

printf '%s\n' "export TYPESAFE_API_KEY=\"$KEY\"" > "$HOME_DIR/.env"
reset_log
run_traced code out err "$BRIEF" --project pager
expect_code 0 "$code" ".env key invokes the matcher"
assert_contains "$out" '  status: escalate' ".env key yields a non-clear match"
assert_contains "$(cat "$LOG/header")" "Authorization: Bearer $KEY" ".env key reaches curl on fd 3"
assert_not_contains "$err" "$KEY" ".env key stays out of shell trace output"
reset_log
run_allexport code out err "$BRIEF" --project pager
expect_code 0 "$code" ".env key works with allexport enabled"
assert_equals 'clean' "$(cat "$LOG/child-env")" ".env key stays out of child environments with allexport enabled"
reset_log
TRACE_ENV_KEY='env-wins-trace-secret'
TYPESAFE_API_KEY=$TRACE_ENV_KEY run_traced code out err "$BRIEF"
assert_equals "Authorization: Bearer $TRACE_ENV_KEY" "$(cat "$LOG/header")" "process environment wins"
assert_not_contains "$err" "$TRACE_ENV_KEY" "environment key stays out of shell trace output"
reset_log
TYPESAFE_API_KEY=$TRACE_ENV_KEY run_allexport code out err "$BRIEF"
expect_code 0 "$code" "environment key works with allexport enabled"
assert_equals 'clean' "$(cat "$LOG/child-env")" "environment key stays out of child environments with allexport enabled"
rm -f "$HOME_DIR/.env"
pass "environment activation works without exposing keys through shell debug modes"

CURL_HOME_DIR="$TMP_ROOT/curl-home"
CURL_TRACE="$TMP_ROOT/curl-trace.log"
mkdir -p "$CURL_HOME_DIR"
printf 'trace-ascii %s\n' "$CURL_TRACE" > "$CURL_HOME_DIR/.curlrc"
rm -f "$CURL_TRACE"
reset_log
write_response "$RESPONSE" rule_4 0.9
CURL_HOME="$CURL_HOME_DIR" TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "curl config isolation exits 0"
assert_equals '-q' "$(head -n 1 "$LOG/argv")" "curl config loading is disabled by the first option"
assert_absent "$CURL_TRACE" "curlrc cannot trace the authorization header"
pass "curl user configuration cannot log the API key"

reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "matched rule exits 0"
assert_contains "$out" '  status: escalate' "matched rule is non-clear"
assert_contains "$out" '  rule: rule_4 (A simple bug fix with a stated root cause.)   confidence: 0.9' "matched rule is inspectable"
assert_contains "$out" '  reason: normal dispatch must verify catalog, provider, authentication, reasoning-class, and quota gates' "normal profile gates own selection"
assert_contains "$out" '  note: rule matched' "successful match is identified"
assert_not_contains "$out" '  profile:' "declared provider mismatch cannot authorize a profile"
assert_not_contains "$out" '  candidate:' "mixed reasoning candidates are not ranked"
assert_absent "$LOG/quota-axi.calls" "matcher never calls quota-axi"
argv=$(cat "$LOG/argv")
assert_not_contains "$argv" "$KEY" "key never appears on curl argv"
assert_contains "$argv" 'https://api.typesafe.ai/v1/systemone' "fixed endpoint is used"
assert_contains "$argv" $'--max-time\n5' "request has a five-second timeout"
assert_contains "$argv" '@/dev/fd/3' "authorization header is read from fd 3"
assert_equals 'clean' "$(cat "$LOG/child-env")" "key is absent from child environment"
body=$(cat "$LOG/body")
assert_equals 'jev-latest' "$(jq -r .model <<<"$body")" "default model is Jev latest"
assert_equals 'pager' "$(jq -r .state.task.project <<<"$body")" "project is sent"
assert_equals '["default","rule_1","rule_2","rule_3","rule_4"]' "$(jq -c '.questions.rule.criteria | keys' <<<"$body")" "only written rules plus default are selectable"
assert_not_contains "$body" 'SECRET-WHY-TEXT' "rationale stays local"
assert_not_contains "$body" 'gpt-5.5' "profiles stay local"
pass "matched rules remain advisory until normal gates run"

MUTATED_RULES="$TMP_ROOT/mutated-rules.json"
jq '.rules[3].when = "Replacement condition."' "$BASE_RULES" > "$MUTATED_RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY FAKE_CURL_MUTATE_SOURCE="$MUTATED_RULES" FAKE_CURL_MUTATE_TARGET="$RULES" run code out err "$BRIEF"
assert_contains "$out" 'rule_4 (A simple bug fix with a stated root cause.)' "same rules snapshot drives request and output"
assert_not_contains "$out" 'Replacement condition.' "mid-request replacement cannot change the match"
cp "$BASE_RULES" "$RULES"
pass "rule snapshot is stable"

rm -f "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  reason: no rules to match' "absent rules return to normal intake"
assert_absent "$LOG/argv" "absent rules never call curl"
printf '%s\n' '{"rules":[],"default":{"harness":"claude","model":"opus"}}' > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  reason: no rules to match' "empty rules return to normal intake"
cp "$BASE_RULES" "$RULES"
pass "missing rules safely fall back"

reset_log
write_response "$RESPONSE" rule_4 0.41
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "low confidence is ambiguous"
assert_contains "$out" '  reason: confidence 0.41 below floor 0.6' "confidence floor is inspectable"
assert_absent "$LOG/quota-axi.calls" "ambiguous result never calls quota-axi"

write_response "$RESPONSE" rule_3 0.59
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" "  reason: rule requires the captain's explicit approval before dispatch" "captain approval precedes confidence"
assert_not_contains "$out" '  reason: confidence' "confidence cannot obscure approval"
assert_absent "$LOG/quota-axi.calls" "approval result never calls quota-axi"
pass "confidence and captain approval gates remain inspectable"

write_response "$RESPONSE" default 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "default match is non-clear"
assert_contains "$out" '  rule: default (No listed rule applies to this task.)' "default is inspectable"
assert_contains "$out" '  note: no rule matched' "default is explained"
assert_not_contains "$out" '  profile:' "default cannot authorize a profile"
pass "default match returns to normal intake"

reset_log
run_without_curl code out err "$BRIEF"
assert_contains "$out" '  reason: curl not installed' "missing curl is safe"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=429 run code out err "$BRIEF"
assert_contains "$out" '  reason: http 429 after' "HTTP failure is safe"
TYPESAFE_API_KEY=$KEY FAKE_CURL_FAIL=1 run code out err "$BRIEF"
assert_contains "$out" '  reason: http 000 after' "transport failure is safe"
for mutation in '.answers = {}' '.answers.rule.type = "text"' '.usage = "bad"' 'del(.answers.rule.probabilities.default)' '.answers.rule.confidence = 2'; do
  write_response "$RESPONSE" rule_4 0.9
  jq "$mutation" "$RESPONSE" > "$TMP_ROOT/bad-response.json"
  mv "$TMP_ROOT/bad-response.json" "$RESPONSE"
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  assert_contains "$out" '  reason: response is not a rule Choice answer' "malformed response is rejected"
done
write_response "$RESPONSE" rule_9 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  reason: rule rule_9 is not in the rules file' "unknown rule is rejected"
assert_absent "$LOG/quota-axi.calls" "failures never call quota-axi"
pass "API and response failures fall back safely"

reset_log
TYPESAFE_API_KEY=$KEY run code out err
expect_code 2 "$code" "missing brief exits 2"
assert_contains "$err" 'brief file required' "missing brief is named"
printf '%s\n' '{"rules":[' > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "non-JSON rules exit 2"
assert_contains "$err" 'not JSON' "non-JSON rules are named"
for bad in \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"approval":"firstmate"}]}|approval must be "captain" when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"select":"mystery"}]}|unknown select: mystery' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":"CLAUDE"}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"spaceship"}}]}|each use profile must name a verified harness' \
  '{"rules":[{"when":"x","use":{"harness":"codex","model":"gpt-5.6-luna","effort":"max"}}]}|each use profile effort must be supported by its harness and model'; do
  printf '%s\n' "${bad%%|*}" > "$RULES"
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 2 "$code" "malformed rules exit 2"
  assert_contains "$err" "malformed rules file: $RULES - ${bad#*|}" "malformed rules are named"
done
assert_absent "$LOG/argv" "configuration errors never reach the network"
assert_absent "$LOG/quota-axi.calls" "configuration errors never call quota-axi"
cp "$BASE_RULES" "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --bogus
expect_code 2 "$code" "unknown flag exits 2"
run code out err --help
expect_code 0 "$code" "--help exits 0"
assert_contains "$out" 'Usage:' "--help prints usage"
pass "configuration errors fail closed"

printf '# all fm-dispatch-resolve tests passed\n'
