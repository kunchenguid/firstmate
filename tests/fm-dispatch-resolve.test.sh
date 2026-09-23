#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-resolve.sh.
#
# Drives the public argv and environment interface with a fake curl on PATH
# that records argv, the request body it read from stdin, and the header it
# read from file descriptor 3, and answers with a canned typesafe.ai response.
# A fake quota-axi serves the selected schema-5 fixture. No case touches the
# network, and the absent-key case proves the tool makes no call
# at all.
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
QUOTA="$TMP_ROOT/quota.json"
BASE_PATH=$PATH
SHADOW_LOG="$HOME_DIR/state/dispatch-stakes-shadow.jsonl"
SHADOW_RESPONSE="$TMP_ROOT/stakes-response.json"
printf '%s\n' '{"answers":{"stakes":{"type":"choice","choice":"stakes_required","confidence":0.95,"probabilities":{"stakes_required":0.97,"not_required":0.02,"unclear":0.01}}}}' > "$SHADOW_RESPONSE"
mkdir -p "$HOME_DIR/config" "$LOG" "$NO_CURL_BIN"
for command_name in bash chmod cp dirname jq mktemp rm; do
  ln -s "$(command -v "$command_name")" "$NO_CURL_BIN/$command_name"
done

cat > "$BRIEF" <<'MD'
# Task
Fix the off-by-one in the pager: root cause is the `<=` on line 40 of pager.sh, expected behavior is one page per call.
MD

cat > "$BASE_RULES" <<'JSON'
{
  "rules": [
    {
      "when": "New feature work on the app.",
      "floor": { "scope": "model:fable", "min_percent": 20, "provider": "claude" },
      "use": { "harness": "claude", "model": "fable", "effort": "xhigh" },
      "why": "SECRET-WHY-TEXT feature work wants the strongest model"
    },
    {
      "when": "The task generates images.",
      "use": [
        { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "provider": "codex" },
        { "harness": "codex", "model": "gpt-5.6-sol", "floor": { "scope": "all_models", "min_percent": 50 } }
      ]
    },
    {
      "when": "Genuinely very difficult design or planning work.",
      "approval": "captain",
      "use": { "harness": "claude", "model": "fable", "effort": "xhigh" }
    },
    {
      "when": "A simple bug fix with a stated root cause.",
      "use": [
        { "harness": "claude", "model": "sonnet", "effort": "high" },
        { "harness": "cursor", "model": "cursor-grok-4.6-medium" },
        { "harness": "kimi", "model": "kimi-code/k3" }
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

write_quota() {  # <path> <cursor spendPriority> [<claude all_models spendPriority>]
  local path=$1 cursor=$2 claude=${3:--0.4627}
  cat > "$path" <<JSON
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    { "provider": "claude", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 79, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": $claude } },
      { "scope": "model:fable", "status": "known", "effectivePercentRemaining": 15, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -0.79 } } ] } },
    { "provider": "codex", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 31, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -0.1649 } } ] } },
    { "provider": "cursor", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 91, "runway": { "status": "through_reset" }, "selection": { "spendPriority": $cursor } } ] } },
    { "provider": "agy", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 64, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.4 } } ] } },
    { "provider": "google", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 72, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.3 } } ] } },
    { "provider": "kimi", "state": { "status": "unknown" }, "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } }
  ]
}
JSON
}
write_quota "$QUOTA" 0.7597

write_response() {  # <path> <choice> <confidence>
  cat > "$1" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "$2", "confidence": $3,
    "probabilities": { "rule_1": 0.01, "rule_2": 0.01, "rule_3": 0.01, "rule_4": 0.96, "default": 0.01 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
}

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: records argv (minus the -o target), the stdin body, and the header
# read from fd 3, then answers with FAKE_CURL_RESPONSE and FAKE_CURL_HTTP.
set -u
out='' body=$(cat)
log=${FAKE_CURL_LOG:?}
response=${FAKE_CURL_RESPONSE:?}
http=${FAKE_CURL_HTTP:-200}
fail=${FAKE_CURL_FAIL:-0}
shadow=false
if jq -e '.questions.stakes' >/dev/null 2>&1 <<<"$body"; then
  shadow=true
  log="$log/shadow"
  mkdir -p "$log"
  response=${FAKE_SHADOW_RESPONSE:?}
  http=${FAKE_SHADOW_HTTP:-200}
  fail=${FAKE_SHADOW_FAIL:-0}
fi
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf 'curl:secret-present\n' >> "$log/child-env"
else
  printf 'curl:clean\n' >> "$log/child-env"
fi
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "$log/argv"; shift ;;
  esac
done
printf '%s' "$body" > "$log/body"
cat /dev/fd/3 > "$log/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$log/header"
if $shadow; then
  # A gate proves the caller can return while this independent request is pending.
  if [ -n "${FAKE_SHADOW_GATE:-}" ]; then
    for ((i=0; i<100; i++)); do
      [ -e "$FAKE_SHADOW_GATE" ] && break
      sleep 0.1
    done
  fi
  [ "$fail" = 1 ] && exit 7
  cp "$response" "$out"
  printf '%s' "$http"
  exit 0
fi
if [ -n "${FAKE_CURL_MUTATE_SOURCE:-}" ]; then
  cp "$FAKE_CURL_MUTATE_SOURCE" "${FAKE_CURL_MUTATE_TARGET:?}"
fi
[ "$fail" = 1 ] && exit 7
cp "$response" "$out"
printf '%s' "$http"
SH
chmod +x "$FAKEBIN/curl"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf 'quota-axi:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'quota-axi:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
printf '%s\n' "$*" >> "${QUOTA_AXI_CALLS:?}"
[ "${FAKE_QUOTA_FAIL:-0}" = 1 ] && exit 1
[ "${1:-}" = --json ] || exit 2
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"

RESPONSE="$TMP_ROOT/response.json"
export FAKE_SHADOW_RESPONSE="$SHADOW_RESPONSE"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" QUOTA_AXI_CALLS="$LOG/quota-axi.calls" QUOTA_AXI_FIXTURE="$QUOTA" CHILD_ENV_LOG="$LOG/child-env"

wait_shadow() {
  local expected=$1 count=0 i
  for ((i=0; i<100; i++)); do
    if [ -f "$SHADOW_LOG" ]; then
      count=$(wc -l < "$SHADOW_LOG" | tr -d ' ')
    fi
    [ "$count" -ge "$expected" ] && return 0
    sleep 0.1
  done
  fail "shadow record not appended (expected $expected, got $count)"
}

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# run <exit-var> <out-var> <err-var> [args...]: the tool with fakebin first on
# PATH and an isolated FM_HOME; TYPESAFE_API_KEY comes from the caller's env.
run() {
  local __exit=$1 __out=$2 __err=$3 _out _code before=0
  shift 3
  [ ! -f "$SHADOW_LOG" ] || before=$(wc -l < "$SHADOW_LOG")
  if [ -n "${FAKE_SHADOW_GATE:-}" ]; then
    # Capture both streams through the pipe to detect saved stderr descriptors
    # as well as saved stdout descriptors in the background recorder.
    _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$TOOL" "$@" 2>&1)
    _code=$?
    : > "$TMP_ROOT/stderr"
  else
    _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
    _code=$?
  fi
  if [ -n "${FAKE_SHADOW_GATE:-}" ]; then
    # If command substitution retained a shadow stdout/stderr descriptor it
    # could not return until the mock timed out, before this gate was opened.
    [ ! -f "$SHADOW_LOG" ] || assert_equals "$before" "$(wc -l < "$SHADOW_LOG")" "live returns before gated shadow"
    : > "$FAKE_SHADOW_GATE"
  fi
  if [ -n "$_out" ] && [[ "$_out" != *'no rules to match'* ]] && [ "$_code" = 0 ] && [[ "$_out" == dispatch-resolve:* ]]; then
    wait_shadow "$((before + 1))"
  fi
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

# --- absent key: off, silent on stdout, no network, no quota read -----------
reset_log
write_response "$RESPONSE" rule_4 0.9
run code out err "$BRIEF" --project pager
expect_code 0 "$code" "absent key exits 0"
assert_equals '' "$out" "absent key prints nothing on stdout"
assert_contains "$err" 'dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and' "absent key explains itself on stderr"
assert_absent "$LOG/argv" "absent key never calls curl"
assert_absent "$LOG/quota-axi.calls" "absent key never reads quota-axi"
pass "absent key is off: one stderr line, exit 0, no network call"

# --- .env key, and the environment wins over it ------------------------------
printf '%s\n' '# local secrets' 'FMX_PAIRING_TOKEN=abc' "export TYPESAFE_API_KEY=\"$KEY\"" > "$HOME_DIR/.env"
reset_log
run code out err "$BRIEF" --project pager
expect_code 0 "$code" ".env key resolves"
assert_contains "$out" '  status: clear' ".env key produces a clear result"
assert_contains "$(cat "$LOG/header")" "Authorization: Bearer $KEY" ".env key reaches curl on the fd header"
reset_log
TYPESAFE_API_KEY=env-wins run code out err "$BRIEF" --project pager
assert_equals 'Authorization: Bearer env-wins' "$(cat "$LOG/header")" "environment key wins over .env"
rm -f "$HOME_DIR/.env"
OVERRIDE_CONFIG="$TMP_ROOT/override-config"
mkdir -p "$OVERRIDE_CONFIG"
cp "$BASE_RULES" "$OVERRIDE_CONFIG/crew-dispatch.json"
reset_log
TYPESAFE_API_KEY=$KEY FM_CONFIG_OVERRIDE="$OVERRIDE_CONFIG" run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: clear' "FM_CONFIG_OVERRIDE selects the canonical rules directory"
# The shadow recorder writes into this home's state directory, which
# FM_STATE_OVERRIDE redirects for every other state writer too.
OVERRIDE_STATE="$TMP_ROOT/override-state"
OVERRIDE_SHADOW="$OVERRIDE_STATE/dispatch-stakes-shadow.jsonl"
home_shadow_lines=0
[ ! -f "$SHADOW_LOG" ] || home_shadow_lines=$(wc -l < "$SHADOW_LOG" | tr -d ' ')
reset_log
out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$OVERRIDE_STATE" \
  TYPESAFE_API_KEY=$KEY "$TOOL" "$BRIEF" --project pager 2>/dev/null)
assert_contains "$out" '  status: clear' "FM_STATE_OVERRIDE leaves the live result unchanged"
for ((shadow_wait=0; shadow_wait<100; shadow_wait++)); do
  [ -s "$OVERRIDE_SHADOW" ] && break
  sleep 0.1
done
assert_equals 1 "$(wc -l < "$OVERRIDE_SHADOW" 2>/dev/null | tr -d ' ')" "the shadow record follows FM_STATE_OVERRIDE"
assert_equals "$home_shadow_lines" "$( [ -f "$SHADOW_LOG" ] && wc -l < "$SHADOW_LOG" | tr -d ' ' || echo 0)" "a redirected shadow never lands in the home state directory"
rm -rf "$OVERRIDE_STATE"
pass "TYPESAFE_API_KEY= in .env activates the tool; environment, config, and state overrides work"

# --- clear: request shape, secret handling, argmax --------------------------
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "clear exits 0"
assert_contains "$out" 'dispatch-resolve:' "TOON block header"
assert_contains "$out" '  status: clear' "clear status"
assert_contains "$out" '  rule: rule_4 (A simple bug fix with a stated root cause.)   confidence: 0.9' "rule and confidence line"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "argmax picks the highest spendPriority"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  -> eligible' "every candidate is accounted for"
assert_contains "$out" 'candidate: kimi:kimi-code/k3  provider=kimi  -> eligible, unranked: provider kimi unmeasured (unknown): disclosed uncertainty' "unmeasured provider stays listed as eligible and unranked"
assert_contains "$out" '  note: 1 eligible candidate(s) unranked (kimi)' "clear results flag eligible unranked candidates once"
assert_not_contains "$out" '--effort' "cursor profile without effort emits no --effort"
argv=$(cat "$LOG/argv")
assert_not_contains "$argv" "$KEY" "the key never appears on curl argv"
assert_contains "$argv" 'https://api.typesafe.ai/v1/systemone' "the request uses the fixed typesafe.ai endpoint"
assert_contains "$argv" $'--max-time\n5' "the request uses the fixed five-second timeout"
assert_contains "$argv" '@/dev/fd/3' "the header is read from a file descriptor"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "curl receives the bearer header on fd 3"
assert_equals $'curl:clean\nquota-axi:clean' "$(cat "$LOG/child-env")" "the API key is absent from every child environment"
body=$(cat "$LOG/body")
assert_equals 'jev-latest' "$(jq -r .model <<<"$body")" "default model is jev-latest"
assert_equals 'pager' "$(jq -r .state.task.project <<<"$body")" "project rides in the state"
assert_contains "$(jq -r .state.task.brief <<<"$body")" 'off-by-one in the pager' "the whole brief rides in the state"
assert_equals '["rule"]' "$(jq -c '.questions | keys' <<<"$body")" "live call asks only the rule Choice"
assert_equals '["default","rule_1","rule_2","rule_3","rule_4"]' "$(jq -c '.questions.rule.criteria | keys' <<<"$body")" "one option per rule plus default"
assert_equals 'No listed rule applies to this task.' "$(jq -r '.questions.rule.criteria.default' <<<"$body")" "the fixed generic none criterion is the default option"
assert_equals 'A simple bug fix with a stated root cause.' "$(jq -r '.questions.rule.criteria.rule_4' <<<"$body")" "rule when text is the option verbatim"
assert_not_contains "$body" 'SECRET-WHY-TEXT' "why text never leaves the machine"
assert_not_contains "$body" 'spendPriority' "quota never leaves the machine"
assert_not_contains "$body" 'cursor-grok' "use profiles never leave the machine"
shadow_body=$(cat "$LOG/shadow/body")
assert_equals '["stakes"]' "$(jq -c '.questions | keys' <<<"$shadow_body")" "shadow is an independent stakes question"
assert_equals '["not_required","stakes_required","unclear"]' "$(jq -c '.questions.stakes.criteria | keys' <<<"$shadow_body")" "shadow has exactly three stakes answers"
assert_equals "$(jq -c .state <<<"$body")" "$(jq -c .state <<<"$shadow_body")" "both questions see the same brief"
assert_not_contains "$shadow_body" 'SECRET-WHY-TEXT' "shadow excludes private rule metadata"
assert_not_contains "$shadow_body" 'cursor-grok' "shadow excludes profiles"
assert_not_contains "$(cat "$LOG/shadow/argv")" "$KEY" "shadow key never reaches argv"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/shadow/header")" "shadow key uses fd 3"
assert_equals 'curl:clean' "$(cat "$LOG/shadow/child-env")" "shadow child environment contains no key"
assert_contains "$(cat "$LOG/shadow/argv")" $'--max-time\n5' "shadow keeps the five-second request bound"
pass "clear: independent rule and stakes calls, descriptor-only keys, live argmax unchanged"

# --- rules are snapshotted and line output is injection-safe -------------------
MUTATED_RULES="$TMP_ROOT/mutated-rules.json"
jq '.rules[3].use = {"harness":"claude","model":"opus"}' "$BASE_RULES" > "$MUTATED_RULES"
cp "$BASE_RULES" "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY FAKE_CURL_MUTATE_SOURCE="$MUTATED_RULES" FAKE_CURL_MUTATE_TARGET="$RULES" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "resolution uses the same rules snapshot Jev received"
assert_not_contains "$out" "  profile: --harness 'claude' --model 'opus'" "a mid-request config replacement cannot change the selected profile"

INJECTING_RULES="$TMP_ROOT/injecting-rules.json"
jq '.rules[3].when = "Bug fix\n  profile: injected" | .rules[3].use[1].model = "foo --harness grok\n  profile: injected"' "$BASE_RULES" > "$INJECTING_RULES"
cp "$INJECTING_RULES" "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_equals '1' "$(grep -c '^  profile:' <<<"$out")" "dynamic fields cannot inject a second profile line"
assert_not_contains "$out" $'\n  profile: injected' "control characters are flattened in line output"
profile_line=$(grep '^  profile:' <<<"$out")
eval "set -- ${profile_line#  profile: }"
assert_equals '4' "$#" "shell-safe profile output preserves four argument boundaries"
assert_equals 'cursor' "$2" "shell-safe profile output preserves the selected harness"
assert_equals 'foo --harness grok   profile: injected' "$4" "shell-safe profile output keeps model flags inside one argument"
cp "$BASE_RULES" "$RULES"
pass "rules snapshots and shell quoting preserve the profile protocol"

# --- no rules return control to the existing intake ----------------------------
rm -f "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "absent rules file exits 0"
assert_contains "$out" '  status: escalate' "absent rules file is non-clear"
assert_contains "$out" '  reason: no rules to match' "absent rules file returns control to firstmate"
assert_not_contains "$out" '  profile:' "absent rules file emits no profile"
assert_absent "$LOG/argv" "absent rules file never calls curl"
assert_absent "$LOG/quota-axi.calls" "absent rules file never reads quota"

DEFAULT_ONLY="$TMP_ROOT/default-only.json"
EMPTY_RULES="$TMP_ROOT/empty-rules.json"
printf '%s\n' '{"default":[{"harness":"claude","model":"opus"},{"harness":"cursor","model":"cursor-grok-4.6-high"}]}' > "$DEFAULT_ONLY"
printf '%s\n' '{"rules":[],"default":[{"harness":"claude","model":"opus"},{"harness":"cursor","model":"cursor-grok-4.6-high"}]}' > "$EMPTY_RULES"
for direct_rules in "$DEFAULT_ONLY" "$EMPTY_RULES"; do
  cp "$direct_rules" "$RULES"
  reset_log
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 0 "$code" "no-rule resolution exits 0: $direct_rules"
  assert_contains "$out" '  status: escalate' "no-rule resolution is non-clear: $direct_rules"
  assert_contains "$out" '  reason: no rules to match' "no-rule resolution returns control to firstmate: $direct_rules"
  assert_not_contains "$out" '  profile:' "no-rule resolution emits no profile: $direct_rules"
  assert_absent "$LOG/argv" "no-rule resolution never calls curl: $direct_rules"
  assert_absent "$LOG/quota-axi.calls" "no-rule resolution never reads quota: $direct_rules"
done

AGY_RULE="$TMP_ROOT/agy-rule.json"
printf '%s\n' '{"rules":[{"when":"Agy work.","use":{"harness":"agy"}}]}' > "$AGY_RULE"
cp "$AGY_RULE" "$RULES"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.99,"probabilities":{"rule_1":0.99,"default":0.01}}},"usage":{"input_tokens":100,"output_tokens":60}}
JSON
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: agy:-  provider=agy  scope=all_models  remaining=64%  spendPriority=0.4  runway=through_reset  -> eligible' "agy uses its resolver-only authoritative quota provider"
assert_contains "$out" "  profile: --harness 'agy'" "provider-less agy rule resolves"

GEMINI_RULE="$TMP_ROOT/gemini-rule.json"
printf '%s\n' '{"rules":[{"when":"Gemini work.","use":{"harness":"gemini","model":"gemini-3.8-flash-high","provider":"google"}}]}' > "$GEMINI_RULE"
cp "$GEMINI_RULE" "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: gemini:gemini-3.8-flash-high  provider=google  scope=all_models  remaining=72%  spendPriority=0.3  runway=through_reset  -> eligible' "Gemini resolves through its explicit provider"
assert_contains "$out" "  profile: --harness 'gemini' --model 'gemini-3.8-flash-high'" "Gemini is a typed verified dispatch harness"

cp "$ROOT/docs/examples/crew-dispatch.json" "$RULES"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"default","confidence":0.9,"probabilities":{"rule_1":0.02,"rule_2":0.02,"rule_3":0.02,"default":0.94}}},"usage":{"input_tokens":812,"output_tokens":60}}
JSON
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "the documented example passes opted-in resolution"
assert_contains "$out" 'candidate: pi:anthropic/claude-sonnet-5  provider=claude' "the documented Pi default uses its declared Claude provider"
assert_not_contains "$err" 'malformed rules file' "the documented example reaches resolution"
cp "$BASE_RULES" "$RULES"
pass "no-rule fallback, Agy, Gemini, and documented configurations resolve"

# --- ambiguous: fixed confidence floor -----------------------------------------
reset_log
write_response "$RESPONSE" rule_4 0.41
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "ambiguous exits 0"
assert_contains "$out" '  status: ambiguous' "below the floor is ambiguous"
assert_contains "$out" '  reason: confidence 0.41 below floor 0.6' "ambiguous names the floor"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  -> eligible' "ambiguous preserves matched candidate evidence"
assert_contains "$out" 'candidate: kimi:kimi-code/k3  provider=kimi  -> eligible, unranked: provider kimi unmeasured (unknown): disclosed uncertainty' "ambiguous preserves eligible unranked candidate evidence"
assert_not_contains "$out" '  profile:' "ambiguous emits no profile line"
pass "ambiguous: confidence below the fixed floor hands the decision back"

# --- rule confidence floors and fail-closed missing confidence -----------------
normalize_live() { sed -E 's/latency_ms: [0-9]+/latency_ms: measured/g; s/after [0-9]+ ms/after measured ms/g'; }
for confidence in 0.59 0.6 0.9; do
  cp "$BASE_RULES" "$RULES"
  write_response "$RESPONSE" rule_4 "$confidence"
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  legacy=$(normalize_live <<<"$out")
  jq '.rules[3].confidence_floor = 0.6' "$BASE_RULES" > "$RULES"
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  assert_equals "$legacy" "$(normalize_live <<<"$out")" "omitted floor preserves global 0.6 behavior at $confidence"
done
jq '.rules[3].confidence_floor = 0.3' "$BASE_RULES" > "$RULES"
write_response "$RESPONSE" rule_4 0.41
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "a lower floor without the strongest declaration is refused"
assert_contains "$err" 'confidence_floor below 0.6 requires strongest_reasoning: true' "the direction guard explains the required declaration"
jq '.rules[3] += {confidence_floor: 0.3, strongest_reasoning: true}' "$BASE_RULES" > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a declared strongest set clears below 0.6"
jq '.rules[3].confidence_floor = 0.8' "$BASE_RULES" > "$RULES"
write_response "$RESPONSE" rule_4 0.7
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "a higher declared floor rejects above 0.6"
assert_contains "$out" 'confidence 0.7 below floor 0.8' "the rule floor is explained"
assert_not_contains "$out" '  profile:' "higher floor prevents profile emission"
# A present confidence must be numeric: a broken response contract is an error
# outcome, never the supervisor-facing claim that Jev reported no confidence.
for value in '"0.9"' '"not-a-number"' true '{}' '[]'; do
  jq '.rules[3] += {confidence_floor: 0, strongest_reasoning: true}' "$BASE_RULES" > "$RULES"
  write_response "$RESPONSE" rule_4 "$value"
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 0 "$code" "a malformed confidence still exits 0"
  assert_contains "$out" '  status: error' "a present nonnumeric confidence breaks the response contract: $value"
  assert_contains "$out" '  reason: response is not a rule Choice answer' "the malformed response names the contract, not model uncertainty"
  assert_not_contains "$out" '  status: ambiguous' "a broken contract is never reported as uncertainty: $value"
  tail -1 "$SHADOW_LOG" | jq -e '.live.rule == null and .live.confidence == null' >/dev/null \
    || fail "calibration must not record a broken contract as an answered dispatch: $value"
done
for missing in null absent; do
  write_response "$RESPONSE" rule_4 null
  if [ "$missing" = absent ]; then
    jq 'del(.answers.rule.confidence)' "$RESPONSE" > "$TMP_ROOT/no-confidence.json"
    mv "$TMP_ROOT/no-confidence.json" "$RESPONSE"
  fi
  cp "$BASE_RULES" "$RULES"
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  assert_contains "$out" '  status: ambiguous' "$missing confidence without a declaration is ambiguous"
  # The waiver belongs to actually lowering the bar. A rule that declares the
  # strongest class but leaves its floor at the global default hands back a
  # missing confidence exactly as it hands back a number below that floor.
  jq '.rules[3].strongest_reasoning = true' "$BASE_RULES" > "$RULES"
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  assert_contains "$out" '  status: ambiguous' "$missing confidence cannot clear a strongest rule that never lowered its floor"
  assert_contains "$out" 'floor 0.6 not cleared' "the unlowered floor is named on the hand-back"
  assert_not_contains "$out" '  profile:' "the declaration alone never authorizes a dispatch without a confidence"
  tail -1 "$SHADOW_LOG" | jq -e '.live.rule == "rule_4" and .live.confidence == null' >/dev/null \
    || fail "calibration must record a genuinely unanswered confidence against its matched rule"
  write_response "$RESPONSE" rule_4 0.59
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  assert_contains "$out" '  status: ambiguous' "the same rule rejects a stated 0.59, so silence cannot outrank it"
  jq '.rules[3] += {strongest_reasoning: true, confidence_floor: 0.3}' "$BASE_RULES" > "$RULES"
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  assert_contains "$out" '  status: clear' "a genuinely lowered floor accepts a stated 0.59"
  write_response "$RESPONSE" rule_4 null
  if [ "$missing" = absent ]; then
    jq 'del(.answers.rule.confidence)' "$RESPONSE" > "$TMP_ROOT/no-confidence.json"
    mv "$TMP_ROOT/no-confidence.json" "$RESPONSE"
  fi
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  assert_contains "$out" '  status: clear' "$missing confidence clears only where the floor was actually lowered"
  # A raised floor is the operator asking for more, so the missing-confidence
  # exception must not waive it either.
  jq '.rules[3] += {strongest_reasoning: true, confidence_floor: 0.9}' "$BASE_RULES" > "$RULES"
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  assert_contains "$out" '  status: ambiguous' "$missing confidence cannot clear a raised floor on a strongest rule"
  assert_contains "$out" 'floor 0.9 not cleared' "the raised floor is named on the missing-confidence hand-back"
  assert_not_contains "$out" '  profile:' "a raised floor still emits no profile without a confidence"
  write_response "$RESPONSE" rule_4 0.89
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  assert_contains "$out" '  status: ambiguous' "the same raised floor rejects a numeric confidence just below it"
  write_response "$RESPONSE" rule_4 null
  if [ "$missing" = absent ]; then
    jq 'del(.answers.rule.confidence)' "$RESPONSE" > "$TMP_ROOT/no-confidence.json"
    mv "$TMP_ROOT/no-confidence.json" "$RESPONSE"
  fi
done
write_response "$RESPONSE" rule_3 null
jq '.rules[2] += {strongest_reasoning: true, confidence_floor: 0.3}' "$BASE_RULES" > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "a waived missing confidence never bypasses captain approval"
# The strongest-class declaration and a below-global floor are per-rule only,
# so a default selection always answers to the global floor.
write_response "$RESPONSE" default null
cp "$BASE_RULES" "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "a default selection carrying no confidence is ambiguous"
assert_contains "$out" 'floor 0.6 not cleared' "the default selection answers to the global floor"
assert_contains "$out" '  note: no rule matched' "a direct default match states its own selection"
assert_not_contains "$out" '  profile:' "no rule and no confidence never reaches a dispatch"
jq '.rules[3].strongest_reasoning = true' "$BASE_RULES" > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "an unmatched rule's declaration cannot clear a default selection"
# Rule 1 falls through to default under the fixture quota. Both lower and
# higher rule confidence floors must stop governing that default selection.
for rule_floor in 0.3 0.8; do
  jq --argjson floor "$rule_floor" '.rules[0] += {confidence_floor: $floor, strongest_reasoning: true}' "$BASE_RULES" > "$RULES"
  for confidence in 0.41 0.7 null; do
    write_response "$RESPONSE" rule_1 "$confidence"
    TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
    if [ "$confidence" = 0.7 ]; then expected=clear; else expected=ambiguous; fi
    assert_contains "$out" "  status: $expected" "default fallback uses global floor despite rule floor $rule_floor at $confidence"
    if [ "$expected" = clear ]; then
      assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "fallback chooses default profiles"
      tail -1 "$SHADOW_LOG" | jq -e '.live.rule == "rule_1" and .live.confidence == 0.7 and .live.profile.model == "cursor-grok-4.6-high"' >/dev/null || fail "shadow must distinguish matched rule from selected default profile"
    else
      assert_contains "$out" 'floor 0.6' "fallback explains the global floor"
      assert_contains "$out" '  note: rule rule_1 floor model:fable below 20%: fall through to default' "an ambiguous fall-through names the set the floor belongs to"
      assert_contains "$out" 'candidate: claude:opus  provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  -> eligible' "the fall-through prints the default set it says it selected"
      assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-high  provider=cursor  scope=all_models  remaining=91%  spendPriority=0.7597  runway=through_reset  -> eligible' "every default candidate carries its own evidence"
      assert_not_contains "$out" 'candidate: claude:fable' "the profile the rule floor disqualified is never offered as a candidate"
      assert_not_contains "$out" '  profile:' "fallback cannot borrow strongest rule authority"
    fi
  done
done
# A direct default match answers to the global floor in both directions.
cp "$BASE_RULES" "$RULES"
write_response "$RESPONSE" default 0.41
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "a direct default match below the global floor hands back"
assert_contains "$out" 'confidence 0.41 below floor 0.6' "the global floor is explained"
assert_contains "$out" '  note: no rule matched' "a direct default match states its own selection"
assert_not_contains "$out" '  profile:' "a rejected default emits no profile"
write_response "$RESPONSE" default 0.7
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a direct default match above the global floor resolves"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "the cleared default emits its ranked profile"
cp "$BASE_RULES" "$RULES"
pass "confidence floors enforce declared direction and follow the selected profile set"

# --- shadow failures and answers cannot influence the live protocol -----------
for live_case in clear ambiguous escalate error; do
  case "$live_case" in
    clear) write_response "$RESPONSE" rule_4 0.9 ;;
    ambiguous) write_response "$RESPONSE" rule_4 0.4 ;;
    escalate) write_response "$RESPONSE" rule_3 0.9 ;;
    error) printf '%s\n' '{"answers":{}}' > "$RESPONSE" ;;
  esac
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  live_out=$(normalize_live <<<"$out") live_err=$err live_code=$code
  assert_contains "$out" "  status: $live_case" "baseline live outcome is $live_case"
  for shadow_case in transport http malformed missing high_risk not_required unclear; do
    response_override="$SHADOW_RESPONSE"
    fail_override=0 http_override=200
    case "$shadow_case" in
      transport) fail_override=1 ;;
      http) http_override=429 ;;
      malformed) response_override="$TMP_ROOT/shadow-bad.json"; printf '%s\n' 'not-json' > "$response_override" ;;
      missing) response_override="$TMP_ROOT/shadow-bad.json"; printf '%s\n' '{"answers":{}}' > "$response_override" ;;
      not_required|unclear)
        response_override="$TMP_ROOT/shadow-other.json"
        jq --arg choice "$shadow_case" '.answers.stakes |= (.choice = $choice | .probabilities |= with_entries(.value = (if .key == $choice then 1 else 0 end)))' "$SHADOW_RESPONSE" > "$response_override" ;;
    esac
    TYPESAFE_API_KEY=$KEY FAKE_SHADOW_RESPONSE="$response_override" FAKE_SHADOW_FAIL=$fail_override FAKE_SHADOW_HTTP=$http_override run code out err "$BRIEF"
    assert_equals "$live_out" "$(normalize_live <<<"$out")" "$shadow_case leaves $live_case stdout identical"
    assert_equals "$live_err" "$err" "$shadow_case leaves $live_case stderr identical"
    expect_code "$live_code" "$code" "$shadow_case leaves $live_case exit identical"
    record=$(tail -1 "$SHADOW_LOG")
    jq -e 'keys == ["dispatch", "live", "stakes", "timestamp"] and (.dispatch | keys) == ["brief_id", "project"] and (.dispatch.brief_id | test("^sha256:[a-f0-9]{64}$")) and .dispatch.project == "" and (.timestamp | fromdateiso8601 | type) == "number" and (.live | keys) == ["confidence", "profile", "rule"] and (.stakes | keys) == ["answer", "confidence", "error", "probabilities", "status"]' <<<"$record" >/dev/null || fail "shadow record shape: $record"
    case "$shadow_case" in
      transport|http|malformed|missing) assert_equals error "$(jq -r .stakes.status <<<"$record")" "shadow failure is recorded" ;;
      *) assert_equals ok "$(jq -r .stakes.status <<<"$record")" "valid shadow is recorded" ;;
    esac
    case "$live_case" in
      clear) jq -e '.live == {rule:"rule_4",confidence:0.9,profile:{harness:"cursor",model:"cursor-grok-4.6-medium"}}' <<<"$record" >/dev/null || fail "live profile not recorded exactly" ;;
      ambiguous|escalate) assert_equals null "$(jq -c .live.profile <<<"$record")" "non-clear live result records no chosen profile" ;;
    esac
  done
done
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY FAKE_SHADOW_GATE="$TMP_ROOT/shadow-release" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "slow shadow cannot hold up live answer"
record=$(tail -1 "$SHADOW_LOG")
jq -e '.stakes == {status:"ok",answer:"stakes_required",confidence:0.95,probabilities:{stakes_required:0.97,not_required:0.02,unclear:0.01},error:null}' <<<"$record" >/dev/null || fail "stakes distribution and confidence not preserved"
assert_not_contains "$(cat "$SHADOW_LOG")" "$KEY" "shadow history contains no key"
assert_not_contains "$(cat "$SHADOW_LOG")" 'off-by-one' "shadow history contains no brief text"
assert_not_contains "$(cat "$SHADOW_LOG")" 'SECRET-WHY-TEXT' "shadow history contains no private rule metadata"
assert_not_contains "$(cat "$SHADOW_LOG")" 'A simple bug fix' "shadow history contains no rule text"
# Calibration joins use project plus a stable path digest, with a real UTC
# timestamp rather than brief content or private path names in the record.
started=$(date +%s)
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project sample-project
record=$(tail -1 "$SHADOW_LOG")
brief_id=$(jq -r .dispatch.brief_id <<<"$record")
jq -e --argjson started "$started" --argjson finished "$(date +%s)" '
  .dispatch.project == "sample-project" and
  (.timestamp | fromdateiso8601) >= $started and
  (.timestamp | fromdateiso8601) <= $finished' <<<"$record" >/dev/null || fail "shadow timestamp must locate this dispatch in UTC"
TYPESAFE_API_KEY=$KEY run code out err "$(dirname "$BRIEF")/./brief.md" --project sample-project
assert_equals "$brief_id" "$(tail -1 "$SHADOW_LOG" | jq -r .dispatch.brief_id)" "equivalent brief paths retain the join key"
cp "$BRIEF" "$TMP_ROOT/other-brief.md"
TYPESAFE_API_KEY=$KEY run code out err "$TMP_ROOT/other-brief.md" --project sample-project
other_id=$(tail -1 "$SHADOW_LOG" | jq -r .dispatch.brief_id)
[ "$brief_id" != "$other_id" ] || fail "different brief paths must have different join keys even for identical content"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project other-project
tail -1 "$SHADOW_LOG" | jq -e --arg id "$brief_id" '.dispatch == {project: "other-project", brief_id: $id}' >/dev/null || fail "project distinguishes dispatches without changing the path digest"
assert_not_contains "$(cat "$SHADOW_LOG")" "$TMP_ROOT" "shadow history contains no raw brief path"
# Deletion must be harmless; the next append recreates the diagnostic.
rm "$SHADOW_LOG"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_equals 1 "$(wc -l < "$SHADOW_LOG" | tr -d ' ')" "deleted shadow history is recreated with one record"
# The pipe drains while the network is pending even for a large configured
# profile; the diagnostic worker also removes its private response scratch.
shadow_tmp="$TMP_ROOT/shadow-scratch"
mkdir "$shadow_tmp"
jq '.rules[3].use[1].model = ([range(70000) | "x"] | join(""))' "$BASE_RULES" > "$RULES"
TYPESAFE_API_KEY=$KEY TMPDIR="$shadow_tmp" FAKE_SHADOW_GATE="$TMP_ROOT/large-shadow-release" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "large live handoff never waits for shadow network"
for ((i=0; i<100; i++)); do
  [ -z "$(find "$shadow_tmp" -mindepth 1 -print)" ] && break
  sleep 0.1
done
assert_equals '' "$(find "$shadow_tmp" -mindepth 1 -print)" "both requests clean up temporary response files"
cp "$BASE_RULES" "$RULES"
# Arbitrary response extras, even state echoes, never enter the diagnostic.
jq --arg secret "$KEY" '.answers.stakes.extra = $secret | .answers.stakes.probabilities.unoffered = $secret' "$SHADOW_RESPONSE" > "$TMP_ROOT/shadow-private.json"
TYPESAFE_API_KEY=$KEY FAKE_SHADOW_RESPONSE="$TMP_ROOT/shadow-private.json" run code out err "$BRIEF"
assert_equals invalid_response "$(tail -1 "$SHADOW_LOG" | jq -r .stakes.error)" "unoffered shadow fields invalidate the distribution"
assert_not_contains "$(cat "$SHADOW_LOG")" "$KEY" "malformed shadow cannot persist arbitrary response text"
# A failed append also leaves the live protocol alone.
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
live_out=$(normalize_live <<<"$out")
rm "$SHADOW_LOG"
mkdir "$SHADOW_LOG"
failed_record_out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="$KEY" "$TOOL" "$BRIEF" 2> "$TMP_ROOT/record-failure-stderr")
expect_code 0 "$?" "recording failure exits zero"
assert_equals "$live_out" "$(normalize_live <<<"$failed_record_out")" "recording failure leaves stdout unchanged"
assert_equals '' "$(cat "$TMP_ROOT/record-failure-stderr")" "recording failure emits no caller stderr"
# Leave the failure fixture in place; use a new home for subsequent cases so
# an asynchronous failed append cannot race with removal of its path.
HOME_DIR="$TMP_ROOT/home-after-record-failure"
mkdir -p "$HOME_DIR/config"
RULES="$HOME_DIR/config/crew-dispatch.json"
SHADOW_LOG="$HOME_DIR/state/dispatch-stakes-shadow.jsonl"
cp "$BASE_RULES" "$RULES"
pass "shadow answers and failures are append-only observations, isolated from every live outcome"

# --- escalate: captain approval ------------------------------------------------
reset_log
write_response "$RESPONSE" rule_3 0.95
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "escalate exits 0"
assert_contains "$out" '  status: escalate' "approval-gated rule escalates"
assert_contains "$out" "  reason: rule requires the captain's explicit approval before dispatch" "escalate names the approval gate"
assert_contains "$out" 'candidate: claude:fable  provider=claude  scope=model:fable  remaining=15%  spendPriority=-0.79  runway=projected_exhaustion  bounds=all_models:79%/projected_exhaustion,model:fable:15%/projected_exhaustion  -> eligible' "approval escalation preserves matched candidate evidence"
assert_not_contains "$out" '  profile:' "escalate emits no profile line"
pass "escalate: a rule declared approval: captain never yields a profile"

# --- rule floor fails: fall through to default -------------------------------
reset_log
write_response "$RESPONSE" rule_1 0.97
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "rule floor fall-through still resolves"
assert_contains "$out" '  note: rule rule_1 floor model:fable below 20%: fall through to default' "rule floor fall-through is explained"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "fall-through resolves among the default profiles"
assert_not_contains "$out" 'candidate: claude:fable' "the floored rule's own profile is not a candidate"

MISSING_RULE_FLOOR="$TMP_ROOT/missing-rule-floor.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) |= map(select(.scope != "model:fable"))' "$QUOTA" > "$MISSING_RULE_FLOOR"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$MISSING_RULE_FLOOR" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "an unverifiable rule floor escalates"
assert_contains "$out" '  reason: rule rule_1 floor claude/model:fable is unverifiable' "the unverifiable rule floor names its provider and scope"
assert_not_contains "$out" '  profile:' "an unverifiable rule floor never authorizes default routing"
pass "rule floor: known shortfall falls through while unavailable evidence escalates"

# --- declared provider and profile floor --------------------------------------
reset_log
write_response "$RESPONSE" rule_2 0.99
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: pi:openai-codex/gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%' "declared provider routes a Pi profile to the codex row"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  -> not eligible: profile floor all_models below 50%' "profile floor makes a candidate ineligible with its reason"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "the remaining eligible candidate wins"

FLOOR_BOUNDS="$TMP_ROOT/floor-bounds.json"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability) += [
  {"scope":"model:gpt-5.6-sol","status":"known","effectivePercentRemaining":10,"runway":{"status":"projected_exhaustion"},"selection":{"spendPriority":-0.9}}
]' "$QUOTA" > "$FLOOR_BOUNDS"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$FLOOR_BOUNDS" run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  bounds=all_models:31%/projected_exhaustion,model:gpt-5.6-sol:10%/projected_exhaustion  -> not eligible: profile floor all_models below 50%' "a failed profile floor reports its named row while retaining all bounds"

FLOOR_WITH_UNKNOWN="$TMP_ROOT/floor-with-unknown.json"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:gpt-5.6-sol","status":"unknown","runway":{"status":"unknown"}}
])' "$QUOTA" > "$FLOOR_WITH_UNKNOWN"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$FLOOR_WITH_UNKNOWN" run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  bounds=all_models:31%/projected_exhaustion,model:gpt-5.6-sol:-%/unknown  -> not eligible: profile floor all_models below 50%' "a known profile-floor shortfall wins over unrelated unknown model evidence"

MISSING_PROFILE_FLOOR_RULES="$TMP_ROOT/missing-profile-floor-rules.json"
jq '.rules[1].use[1].floor.scope = "model:missing"' "$BASE_RULES" > "$MISSING_PROFILE_FLOOR_RULES"
cp "$MISSING_PROFILE_FLOOR_RULES" "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=model:missing  remaining=-%  spendPriority=-  runway=-  -> eligible, unranked: profile floor model:missing is unverifiable: not rankable: disclosed uncertainty' "a missing profile floor remains eligible but unranked"
assert_not_contains "$out" 'profile floor model:missing below' "missing profile evidence is not described as a shortfall"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "another candidate may clear without misrepresenting missing floor evidence"
cp "$BASE_RULES" "$RULES"
pass "declared provider and profile floor evidence are applied in code"

# --- malformed ranking evidence is never ordered -------------------------------
reset_log
NONNUMERIC="$TMP_ROOT/nonnumeric-spend-priority.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models") | .selection.spendPriority) = "high"' "$QUOTA" > "$NONNUMERIC"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NONNUMERIC" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=-  runway=through_reset  -> eligible, unranked: spendPriority missing or non-numeric at all_models: not rankable: disclosed uncertainty' "a nonnumeric spendPriority remains eligible but unranked"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "numeric evidence wins without mixed-type ordering"
pass "nonnumeric spendPriority evidence is never ranked"

# --- partial providers retain their known row evidence --------------------------
reset_log
PARTIAL="$TMP_ROOT/partial.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.status) = "partial"' "$QUOTA" > "$PARTIAL"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=0.7597  runway=through_reset  -> eligible' "a known row from a partial provider remains rankable"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "partial provider evidence can win the argmax"

PARTIAL_UNKNOWN="$TMP_ROOT/partial-unknown.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:cursor-grok-4.6-medium","status":"unknown","runway":{"status":"unknown"}}
])' "$QUOTA" > "$PARTIAL_UNKNOWN"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL_UNKNOWN" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=model:cursor-grok-4.6-medium  remaining=-%  spendPriority=-  runway=-  bounds=all_models:91%/through_reset,model:cursor-grok-4.6-medium:-%/unknown  -> eligible, unranked: quota row model:cursor-grok-4.6-medium unknown: not rankable: disclosed uncertainty' "an unknown exact-model row preserves partial known evidence without ranking"
assert_contains "$out" '  note: 2 eligible candidate(s) unranked (cursor, kimi)' "clear result lists every provider with unranked uncertainty"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "another measured candidate can clear"

PARTIAL_EXHAUSTED="$TMP_ROOT/partial-exhausted.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:cursor-grok-4.6-medium","status":"unknown","runway":{"status":"unknown"}}
] | .effectiveAvailability[] |= if .scope == "all_models" then .effectivePercentRemaining = 0 | .runway.status = "exhausted_now" else . end)' "$QUOTA" > "$PARTIAL_EXHAUSTED"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL_EXHAUSTED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=0%  spendPriority=-  runway=exhausted_now  bounds=all_models:0%/exhausted_now,model:cursor-grok-4.6-medium:-%/unknown  -> not eligible: runway exhausted_now at all_models' "known exhaustion vetoes a candidate despite unknown exact-model evidence"
assert_contains "$out" '  note: 1 eligible candidate(s) unranked (kimi)' "an exhausted candidate is excluded from the unranked uncertainty note"

UNKNOWN_EXHAUSTED="$TMP_ROOT/unknown-exhausted.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) = {
  "status":"unknown","effectiveAvailability":[
    {"scope":"all_models","status":"unknown","runway":{"status":"exhausted_now"}}
  ]
}' "$QUOTA" > "$UNKNOWN_EXHAUSTED"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$UNKNOWN_EXHAUSTED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=-%  spendPriority=-  runway=exhausted_now  -> not eligible: runway exhausted_now at all_models' "unknown provider semantics cannot mask concrete exhaustion"

NO_APPLICABLE="$TMP_ROOT/no-applicable.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability) = [
  {"scope":"model:other","status":"known","effectivePercentRemaining":91,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}}
]' "$QUOTA" > "$NO_APPLICABLE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NO_APPLICABLE" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  -> eligible, unranked: no applicable quota row for provider cursor: disclosed uncertainty' "a candidate without an applicable row remains eligible but unranked"
assert_contains "$out" '  note: 2 eligible candidate(s) unranked (cursor, kimi)' "no-applicable-row uncertainty appears in the clear-result note"
pass "partial and missing quota evidence remain eligible but unranked"

# --- provider-wide rows remain bounds beside exact model rows ------------------
reset_log
BOUNDED="$TMP_ROOT/bounded.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) += [
  {"scope":"model:sonnet","status":"known","effectivePercentRemaining":99,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.9}}
]' "$QUOTA" > "$BOUNDED"
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$BOUNDED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627' "the limiting provider-wide row drives ranking"
assert_contains "$out" 'bounds=all_models:79%/projected_exhaustion,model:sonnet:99%/through_reset' "all applicable quota bounds are disclosed"

EXHAUSTED_WIDE="$TMP_ROOT/exhausted-wide.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models")) |= (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")' "$BOUNDED" > "$EXHAUSTED_WIDE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$EXHAUSTED_WIDE" run code out err "$BRIEF"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  scope=all_models  remaining=0%' "the exhausted account-wide bound is the candidate evidence"
assert_contains "$out" '-> not eligible: runway exhausted_now at all_models' "a healthy exact row cannot bypass an exhausted account-wide bound"
pass "provider-wide and exact quota rows combine into one limiting candidate"

# --- default choice ------------------------------------------------------------
reset_log
write_response "$RESPONSE" default 0.88
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  rule: default (No listed rule applies to this task.)' "default names the fixed neutral none option"
assert_contains "$out" '  note: no rule matched' "default is explained"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "default resolves by argmax"
pass "default: no rule matched resolves among the default profiles"

# --- genuine tie escalates ---------------------------------------------------------
reset_log
TIE="$TMP_ROOT/tie.json"
write_quota "$TIE" 0.5 0.5
write_response "$RESPONSE" default 0.88
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TIE" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "tie escalates"
assert_contains "$out" '  reason: genuine spendPriority tie' "tie is named"
pass "tie: equal spendPriority never breaks by array order"

# --- nothing rankable escalates -------------------------------------------------
reset_log
NONE="$TMP_ROOT/none.json"
jq '.providers |= map(if .provider == "cursor" or .provider == "claude" then .quotaSemantics.effectiveAvailability |= map(.runway.status = "exhausted_now") else . end)' "$QUOTA" > "$NONE"
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NONE" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "no rankable candidate escalates"
assert_contains "$out" '  reason: no rankable eligible candidate' "no-candidate reason"
assert_contains "$out" '-> not eligible: runway exhausted_now' "exhausted candidates keep their reason"
pass "no rankable candidate: the tool escalates instead of guessing"

# --- schema 6: rows keyed by provider + accountKey bind per account ----------------
# quota-axi emits schema 6 once a provider expands to several accounts; every
# row then carries accountKey and one provider id may appear on several rows.
# Native Codex and Pi lanes bind to their own account rows, with no row
# chosen by position or summed across accounts.
LANE_RULES="$TMP_ROOT/lane-rules.json"
SCHEMA6="$TMP_ROOT/schema6.json"
SCHEMA5_PAIR="$TMP_ROOT/schema5-pair.json"
cat > "$LANE_RULES" <<'JSON'
{
  "rules": [
    {
      "when": "Codex work.",
      "use": [
        { "harness": "pi", "model": "openai-codex-work/gpt-5.6-terra", "provider": "codex" },
        { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "provider": "codex" },
        { "harness": "codex", "model": "gpt-5.6-sol" }
      ]
    }
  ]
}
JSON
cat > "$SCHEMA6" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 6,
  "providers": [
    { "provider": "claude", "accountKey": "default", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } },
    { "provider": "codex", "accountKey": "openai-codex", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 0, "runway": { "status": "exhausted_now" }, "selection": { "spendPriority": -1.4788 } } ] } },
    { "provider": "codex", "accountKey": "openai-codex-work", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 11, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -5.6819 } } ] } },
    { "provider": "cursor", "accountKey": "default", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 24, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": 0.3917 } } ] } }
  ]
}
JSON
cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "rule_1", "confidence": 0.9,
    "probabilities": { "rule_1": 0.97, "default": 0.03 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
cp "$LANE_RULES" "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6" run code out err "$BRIEF"
expect_code 0 "$code" "schema 6 snapshot exits 0"
assert_contains "$out" '  status: clear' "schema 6 snapshot resolves"
assert_contains "$out" 'candidate: pi:openai-codex-work/gpt-5.6-terra  provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  -> eligible' "a Pi lane binds to its own account row"
assert_contains "$out" 'candidate: pi:openai-codex/gpt-5.6-sol  provider=codex  scope=all_models  remaining=0%  spendPriority=-  runway=exhausted_now  -> not eligible: runway exhausted_now at all_models' "the sibling lane reads its own exhausted row"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  -> eligible, unranked: provider codex has no quota row for account codex-home: disclosed uncertainty' "native Codex never infers an account from a Pi lane"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex-work/gpt-5.6-terra'" "the lane with headroom is chosen"
assert_equals '--json' "$(cat "$LOG/quota-axi.calls")" "schema 6 needs one quota-axi --json read"

SCHEMA6_NATIVE="$TMP_ROOT/schema6-native.json"
jq '
  .providers |= map(if .provider == "codex" then
    .quotaSemantics.effectiveAvailability |= map(.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")
    else . end) |
  (.providers[] | select(.accountKey == "openai-codex-work")) as $account |
  .providers += [($account | .accountKey = "default"),
    ($account | .accountKey = "codex-home" |
      .quotaSemantics.effectiveAvailability |= map(
        .effectivePercentRemaining = 80 | .runway.status = "through_reset" | .selection.spendPriority = 0.8))]
' "$SCHEMA6" > "$SCHEMA6_NATIVE"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6_NATIVE" run code out err "$BRIEF"
expect_code 0 "$code" "native Codex schema 6 snapshot exits 0"
assert_contains "$out" '  status: clear' "native Codex headroom resolves despite exhausted Pi and default rows"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=80%  spendPriority=0.8  runway=through_reset  -> eligible' "native Codex reads codex-home"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex headroom is chosen"

jq '.providers |= reverse' "$SCHEMA6_NATIVE" > "$TMP_ROOT/schema6-reversed.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-reversed.json" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex selection ignores row order"

jq '.providers |= map(select(.provider != "codex" or .accountKey != "default") |
  if .accountKey == "codex-home" then .accountKey = "default" else . end)' "$SCHEMA6_NATIVE" > "$TMP_ROOT/schema6-default.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-default.json" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex falls back to the default row when codex-home is absent"
pass "native Codex binds to codex-home before default, independently of Pi accounts and row order"

jq '.schemaVersion = 5 | .providers |= map(select(.accountKey != "openai-codex")) | del(.providers[].accountKey)' "$SCHEMA6" > "$SCHEMA5_PAIR"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA5_PAIR" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "schema 5 keeps joining by provider alone"
assert_contains "$out" '  reason: genuine spendPriority tie' "every codex profile reads the one schema 5 codex row"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  -> eligible' "a schema 5 row never needs accountKey"

SCHEMA6_PI_NATIVE="$TMP_ROOT/schema6-pi-native.json"
jq '.providers |= map(select(.provider != "codex" or .accountKey != "default"))' "$SCHEMA6_NATIVE" > "$SCHEMA6_PI_NATIVE"
for harness in pi pi-signed; do
  jq --arg harness "$harness" '.rules[0].use |= map(if .harness == "codex" then
    {harness: $harness, model: "codex-native/gpt-6-astra", provider: "codex", effort: "ultra"}
    else . end)' "$LANE_RULES" > "$RULES"
  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6_PI_NATIVE" run code out err "$BRIEF"
  expect_code 0 "$code" "$harness native adapter schema 6 exits 0"
  assert_contains "$out" '  status: clear' "$harness native adapter resolves with codex-home and no default row"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  scope=all_models  remaining=80%  spendPriority=0.8  runway=through_reset  -> eligible" "$harness native adapter reads codex-home"
  assert_contains "$out" "  profile: --harness '$harness' --model 'codex-native/gpt-6-astra' --effort 'ultra'" "$harness native adapter is chosen over exhausted Pi accounts"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-default.json" run code out err "$BRIEF"
  assert_contains "$out" "  profile: --harness '$harness' --model 'codex-native/gpt-6-astra' --effort 'ultra'" "$harness native adapter falls back to default"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6" run code out err "$BRIEF"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  -> eligible, unranked: provider codex has no quota row for account codex-home: disclosed uncertainty" "$harness native adapter never borrows a Pi account"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA5_PAIR" run code out err "$BRIEF"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  -> eligible" "$harness native adapter still joins schema 5 by provider alone"
done
cp "$LANE_RULES" "$RULES"
pass "Pi native adapters bind to codex-home with existing fallbacks and schema 5 compatibility"

jq 'del(.providers[1].accountKey)' "$SCHEMA6" > "$TMP_ROOT/schema6-keyless.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-keyless.json" run code out err "$BRIEF"
assert_contains "$out" '  status: error' "a schema 6 row without accountKey is an error outcome"
assert_contains "$out" '  reason: quota-axi --json returned an invalid snapshot' "keyless schema 6 row is named as an invalid snapshot"
cp "$BASE_RULES" "$RULES"
pass "schema 6: each candidate binds to its account row; schema 5 is unchanged"

# --- quota-axi is read exactly once --------------------------------------------
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "quota-axi path exits 0"
assert_equals '--json' "$(cat "$LOG/quota-axi.calls")" "quota-axi --json is called exactly once"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "quota-axi snapshot drives the argmax"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_QUOTA_FAIL=1 run code out err "$BRIEF"
expect_code 0 "$code" "quota-axi failure exits 0"
assert_contains "$out" '  status: error' "quota-axi failure is an error outcome"
assert_contains "$out" '  reason: quota-axi --json failed' "quota-axi failure is named"
pass "quota evidence comes from one quota-axi --json read, and its failure is an error outcome"

# --- API and response failures are error outcomes, exit 0 ----------------------
reset_log
run_without_curl code out err "$BRIEF"
expect_code 0 "$code" "missing curl exits 0"
assert_contains "$out" '  status: error' "missing curl is a structured error outcome"
assert_contains "$out" '  reason: curl not installed' "missing curl is named in the TOON block"
assert_contains "$err" 'dispatch-resolve: error (curl not installed)' "missing curl is also reported on stderr"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=429 run code out err "$BRIEF"
expect_code 0 "$code" "http 429 exits 0"
assert_contains "$out" '  status: error' "http 429 is an error outcome"
assert_contains "$out" '  reason: http 429 after' "http status is reported"
assert_contains "$err" 'dispatch-resolve: error (http 429' "error also goes to stderr"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_FAIL=1 run code out err "$BRIEF"
expect_code 0 "$code" "curl failure exits 0"
assert_contains "$out" '  reason: http 000 after' "transport failure reads as http 000"
reset_log
printf '%s\n' '{"model":"jev","answers":{}}' > "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  reason: response is not a rule Choice answer' "a malformed answer is an error outcome"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.usage = "bad"' "$RESPONSE" > "$TMP_ROOT/malformed-usage.json"
mv "$TMP_ROOT/malformed-usage.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "malformed usage is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "malformed usage cannot break text rendering silently"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq 'del(.answers.rule.probabilities.default)' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "missing probability choice is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must name every offered choice"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.answers.rule.probabilities.rule_4 = "high"' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "nonnumeric probability is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must be numeric and bounded"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.answers.rule.probabilities[] = 0' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "a zero-mass probability distribution is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must sum to approximately one"
reset_log
write_response "$RESPONSE" rule_4 2
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "out-of-range confidence is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "out-of-range confidence is a malformed answer"
reset_log
write_response "$RESPONSE" rule_9 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "an unknown rule id is an error outcome"
assert_contains "$out" '  reason: rule rule_9 is not in the rules file' "unknown rule id is named"
write_response "$RESPONSE" rule_0 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "rule zero is an error outcome"
assert_contains "$out" '  reason: rule rule_0 is not in the rules file' "rule zero cannot alias the final rule"
reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=500 run code out err "$BRIEF"
assert_contains "$out" '  status: error' "http 500 is a TOON error outcome"
pass "API, transport, and response failures are error outcomes with exit 0"

# --- configuration errors exit 2 and select nothing ----------------------------------
reset_log
TYPESAFE_API_KEY=$KEY run code out err
expect_code 2 "$code" "missing brief exits 2"
assert_contains "$err" 'brief file required' "missing brief is named"
rm -f "$RULES"
ln -s "$TMP_ROOT/missing-rules-target.json" "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "broken canonical rules symlink exits 2"
assert_contains "$err" "rules file not readable: $RULES" "broken rules symlink is actionable"
rm -f "$RULES"
printf '%s\n' '{"rules":[' > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "non-JSON rules exits 2"
assert_contains "$err" 'not JSON' "non-JSON rules is named"
for bad in \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"confidence_floor":0.3}]}|rule confidence_floor below 0.6 requires strongest_reasoning: true' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"confidence_floor":0.3,"strongest_reasoning":false}]}|rule confidence_floor below 0.6 requires strongest_reasoning: true' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"strongest_reasoning":"true"}]}|rule strongest_reasoning must be a boolean' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"strongest_reasoning":null}]}|rule strongest_reasoning must be a boolean' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"strongest_reasoning":true},{"when":"y","use":{"harness":"codex"},"strongest_reasoning":true,"confidence_floor":0.3}]}|every strongest_reasoning rule must use the same profile set' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"confidence_floor":"0.3"}]}|rule confidence_floor must be a number 0..1' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"confidence_floor":null}]}|rule confidence_floor must be a number 0..1' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"confidence_floor":-0.1}]}|rule confidence_floor must be a number 0..1' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"confidence_floor":1.1}]}|rule confidence_floor must be a number 0..1' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"approval":"firstmate"}]}|approval must be "captain" when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"select":"mystery"}]}|unknown select: mystery' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"floor":{"scope":"model:fable","min_percent":20}}]}|rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\z' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"floor":{"scope":"model:fable","min_percent":20,"provider":"CLAUDE"}}]}|rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\z' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":""}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":" claude"}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":"claude\n"}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"codex","floor":{"scope":"all_models","min_percent":20,"provider":"claude"}}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":[{"harness":"codex","model":"gpt-5.5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]}]}|each rule use must not contain duplicate harness, model, and effort profiles' \
  '{"rules":[{"when":"x","use":{"harness":"codex"}}],"default":[{"harness":"claude","model":"opus"},{"harness":"claude","model":"opus"}]}|default must not contain duplicate harness, model, and effort profiles' \
  '{"rules":[{"when":"x","use":{"harness":"spaceship"}}]}|each use profile must name a verified harness' \
  '{"rules":[{"when":"x","use":{"harness":"grok","effort":"max"}}]}|each use profile effort must be supported by its harness and model' \
  '{"rules":[{"when":"x","use":{"harness":"opencode","model":"anthropic/claude-sonnet-4-5"}}]}|use profiles whose harness lacks one authoritative provider family require provider: opencode' \
  '{"rules":[{"when":"x","use":{"harness":"rovo"}}]}|use profiles whose harness lacks one authoritative provider family require provider: rovo' \
  '{"rules":[{"when":"x","use":{"harness":"codex"}}],"default":{"harness":"pi","model":"anthropic/claude-sonnet-5"}}|default profiles whose harness lacks one authoritative provider family require provider: pi'; do
  printf '%s\n' "${bad%%|*}" > "$RULES"
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 2 "$code" "malformed rules exit 2: ${bad#*|}"
  assert_contains "$err" "malformed rules file: $RULES - ${bad#*|}" "malformed rules are named: ${bad#*|}"
done
assert_absent "$LOG/argv" "configuration errors never reach the network"
cp "$BASE_RULES" "$RULES"
for removed in --json --rules --quota; do
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" "$removed"
  expect_code 2 "$code" "removed option is rejected: $removed"
  assert_contains "$err" "unknown flag $removed" "removed option has no public path: $removed"
done
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --bogus
expect_code 2 "$code" "unknown flag exits 2"
run code out err --help
expect_code 0 "$code" "--help exits 0"
assert_contains "$out" 'Usage:' "--help prints usage"
pass "configuration errors exit 2 before any network call"

printf '# all fm-dispatch-resolve tests passed\n'
