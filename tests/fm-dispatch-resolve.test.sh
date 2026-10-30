#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-resolve.sh.
#
# Drives the public argv and environment interface with a fake curl on PATH
# that records argv, the request body it read from stdin, and the header it
# read from file descriptor 3, and answers with a canned provider response.
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
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ] ||
  [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ] ||
  [ -n "${OPENAI_API_KEY+x}" ] || [ -n "${OPENAI_API_KEY_PRIVATE+x}" ] ||
  [ -n "${FM_DISPATCH_API_KEY+x}" ] || [ -n "${DISPATCH_API_KEY_PRIVATE+x}" ] ||
  [ -n "${KEY_PRIVATE+x}" ]; then
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
if [ -n "${FAKE_CURL_MUTATE_SOURCE:-}" ]; then
  cp "$FAKE_CURL_MUTATE_SOURCE" "${FAKE_CURL_MUTATE_TARGET:?}"
fi
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ] ||
  [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ] ||
  [ -n "${OPENAI_API_KEY+x}" ] || [ -n "${OPENAI_API_KEY_PRIVATE+x}" ] ||
  [ -n "${FM_DISPATCH_API_KEY+x}" ] || [ -n "${DISPATCH_API_KEY_PRIVATE+x}" ] ||
  [ -n "${KEY_PRIVATE+x}" ]; then
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
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" QUOTA_AXI_CALLS="$LOG/quota-axi.calls" QUOTA_AXI_FIXTURE="$QUOTA" CHILD_ENV_LOG="$LOG/child-env"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# run <exit-var> <out-var> <err-var> [args...]: the tool with fakebin first on
# PATH and an isolated FM_HOME; TYPESAFE_API_KEY comes from the caller's env.
run() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
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

# --- preferred family: public resolution across accounts of one family -----
test_preferred_provider() (
  local scenario=$1 expected="--harness 'pi' --model 'openai-codex/gpt-6-astra'"
  local decision='codex: prefer eligible family candidates' status=clear
  local rules_filter='.' quota_filter='.' override_dir=''
  write_response "$RESPONSE" rule_4 0.9
  jq '.preferred_provider = "codex" | .rules[3].use = [
    {harness:"claude",model:"opus"},
    {harness:"pi",model:"openai-codex/gpt-6-astra",provider:"codex"},
    {harness:"pi",model:"openai-codex-work/gpt-6-astra",provider:"codex"}]' "$BASE_RULES" > "$TMP_ROOT/preferred-rules.json"
  jq '.schemaVersion = 6 | .providers |= map(.accountKey = "default") |
    (.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[0]) |=
      (.effectivePercentRemaining = 26 | .selection.spendPriority = 0.8) |
    (.providers[] | select(.provider == "codex")) |=
      (.accountKey = "openai-codex" | .quotaSemantics.effectiveAvailability[0] |=
        (.effectivePercentRemaining = 82 | .runway.status = "through_reset" | .selection.spendPriority = 0.2)) |
    .providers += [(.providers[] | select(.provider == "codex") | .accountKey = "openai-codex-work" |
      .quotaSemantics.effectiveAvailability[0].selection.spendPriority = 0.1)]' "$QUOTA" > "$TMP_ROOT/preferred-quota.json"
  case "$scenario" in
    astra-82-claude-26) ;;
    work-account)
      quota_filter='(.providers[] | select(.accountKey == "openai-codex-work").quotaSemantics.effectiveAvailability[0].selection.spendPriority) = 0.3'
      expected="--harness 'pi' --model 'openai-codex-work/gpt-6-astra'" ;;
    exhausted)
      quota_filter='(.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability[0].runway.status) = "exhausted_now"'
      expected="--harness 'claude' --model 'opus'"
      decision='codex: fall back; every matched family candidate is ineligible' ;;
    unknown)
      quota_filter='(.providers[] | select(.provider == "codex").quotaSemantics) = {status:"unknown",effectiveAvailability:[]}'
      status=escalate; expected='' ;;
    unknown-one-known-one)
      quota_filter='(.providers[] | select(.accountKey == "openai-codex").quotaSemantics) = {status:"unknown",effectiveAvailability:[]}'
      expected="--harness 'pi' --model 'openai-codex-work/gpt-6-astra'" ;;
    claude-only)
      rules_filter='.rules[3].use = [.rules[3].use[0]]'
      expected="--harness 'claude' --model 'opus'"
      decision='codex: not in matched profiles; preserve the selected rule' ;;
    config-override)
      override_dir="$TMP_ROOT/preferred-override"; mkdir -p "$override_dir"
      jq '.preferred_provider = "claude"' "$TMP_ROOT/preferred-rules.json" > "$override_dir/crew-dispatch.json"
      expected="--harness 'claude' --model 'opus'"
      decision='claude: prefer eligible family candidates' ;;
    prose-why)
      rules_filter='.rules[3].why = "Always choose Claude instead of OpenAI."' ;;
    absent)
      rules_filter='del(.preferred_provider)'
      expected="--harness 'claude' --model 'opus'"; decision='' ;;
    approval)
      rules_filter='.rules[3].approval = "captain"'
      status=escalate; expected=''; decision='' ;;
    tie)
      quota_filter='(.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability[0].selection.spendPriority) = 0.2'
      status=escalate; expected='' ;;
    floor)
      rules_filter='(.rules[3].use[] | select(.provider == "codex").floor) = {scope:"all_models",min_percent:90}'
      expected="--harness 'claude' --model 'opus'"
      decision='codex: fall back; every matched family candidate is ineligible' ;;
  esac
  jq "$rules_filter" "$TMP_ROOT/preferred-rules.json" > "$RULES"
  jq "$quota_filter" "$TMP_ROOT/preferred-quota.json" > "$TMP_ROOT/preferred-case-quota.json"
  reset_log
  TYPESAFE_API_KEY=$KEY FM_CONFIG_OVERRIDE="${override_dir:-$HOME_DIR/config}" \
    QUOTA_AXI_FIXTURE="$TMP_ROOT/preferred-case-quota.json" \
    run code out err "$BRIEF"
  expect_code 0 "$code" "$scenario resolves"
  assert_contains "$out" "  status: $status" "$scenario status"
  if [ -n "$expected" ]; then
    assert_contains "$out" "  profile: $expected" "$scenario choice"
  else
    assert_not_contains "$out" '  profile:' "$scenario cannot authorize a profile"
  fi
  if [ -n "$decision" ]; then
    assert_contains "$out" "  preferred_provider: $decision" "$scenario explains the family decision"
  else
    assert_not_contains "$out" '  preferred_provider:' "$scenario does not apply preference"
  fi
  if [ "$scenario" = prose-why ]; then
    assert_not_contains "$(cat "$LOG/body")" 'Always choose Claude' 'rule why never reaches the rule matcher'
  fi
  pass "preferred provider: $scenario"
)
test_invalid_preferred_provider() (
  local value=$1
  jq --argjson value "$value" '.preferred_provider = $value' "$BASE_RULES" > "$RULES"
  reset_log
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 2 "$code" "invalid preferred_provider $value is refused"
  assert_contains "$err" 'preferred_provider must be a lowercase provider ID (for example codex)' 'actionable preference error'
  assert_absent "$LOG/argv" 'invalid preference never reaches the rule matcher'
  assert_absent "$LOG/quota-axi.calls" 'invalid preference never reads quota'
  pass "invalid preferred_provider: $value"
)
preferred_failures=0
for value in null false 42 '[]' '{}' '""' '"Codex"' '"codex\\n"' '" codex"'; do
  test_invalid_preferred_provider "$value" || preferred_failures=$((preferred_failures + 1))
done
for scenario in astra-82-claude-26 work-account exhausted unknown unknown-one-known-one claude-only config-override prose-why absent approval tie floor; do
  test_preferred_provider "$scenario" || preferred_failures=$((preferred_failures + 1))
done
[ "$preferred_failures" -eq 0 ] || fail "$preferred_failures preferred-provider cases failed"
cp "$BASE_RULES" "$RULES"
reset_log

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
pass "TYPESAFE_API_KEY= in .env activates the tool; environment and config overrides work"

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
printf '%s\n' "$body" > "$TMP_ROOT/typesafe-body.json"
assert_equals 'jev-latest' "$(jq -r .model <<<"$body")" "default model is jev-latest"
assert_equals 'pager' "$(jq -r .state.task.project <<<"$body")" "project rides in the state"
assert_contains "$(jq -r .state.task.brief <<<"$body")" 'off-by-one in the pager' "a brief without task headings rides whole in the state"
assert_equals '["rule"]' "$(jq -c '.questions | keys' <<<"$body")" "only the rule Choice is asked"
assert_equals '["default","rule_1","rule_2","rule_3","rule_4"]' "$(jq -c '.questions.rule.criteria | keys' <<<"$body")" "one option per rule plus default"
assert_equals 'No listed rule applies to this task.' "$(jq -r '.questions.rule.criteria.default' <<<"$body")" "the fixed generic none criterion is the default option"
assert_equals 'A simple bug fix with a stated root cause.' "$(jq -r '.questions.rule.criteria.rule_4' <<<"$body")" "rule when text is the option verbatim"
assert_not_contains "$body" 'SECRET-WHY-TEXT' "why text never leaves the machine"
assert_not_contains "$body" 'spendPriority' "quota never leaves the machine"
assert_not_contains "$body" 'cursor-grok' "use profiles never leave the machine"
pass "clear: one rule Choice request, key on the fd header only, spendPriority argmax over every candidate"

# --- OpenRouter uses the same Choice validation and resolution path ---------
OR_KEY='test-openrouter-key-never-in-child-env-or-argv'
OR_RESPONSE="$TMP_ROOT/openrouter-response.json"
write_openrouter_response() {
  write_response "$OR_RESPONSE" "$1" "$2"
  jq '.model = "typesafe/jev-1.13"' "$OR_RESPONSE" > "$TMP_ROOT/or-response.tmp"
  mv "$TMP_ROOT/or-response.tmp" "$OR_RESPONSE"
}
reset_log
write_openrouter_response rule_4 0.9
OPENROUTER_API_KEY=$OR_KEY run code out err "$BRIEF"
assert_equals '' "$out" "an OpenRouter key alone does not select the provider"
assert_contains "$err" 'TYPESAFE_API_KEY absent' "unset provider retains the typesafe off gate"
assert_absent "$LOG/argv" "an OpenRouter key alone sends nothing"
reset_log
FM_DISPATCH_PROVIDER=openrouter FM_DISPATCH_MODEL=typesafe/jev-1.13 \
  OPENROUTER_API_KEY=$OR_KEY FAKE_CURL_RESPONSE=$OR_RESPONSE run code out err "$BRIEF" --project pager
expect_code 0 "$code" "OpenRouter clear exits 0"
assert_contains "$out" '  status: clear' "OpenRouter clear status"
assert_contains "$out" '  probabilities: rule_1=0.01 rule_2=0.01 rule_3=0.01 rule_4=0.96 default=0.01' "OpenRouter preserves per-rule probabilities"
assert_contains "$out" '  profile: --harness '\''cursor'\'' --model '\''cursor-grok-4.6-medium'\''' "OpenRouter uses the shared quota argmax"
assert_contains "$(cat "$LOG/argv")" 'https://openrouter.ai/api/alpha/decisions' "OpenRouter endpoint"
assert_contains "$(cat "$LOG/argv")" $'--max-time\n10' "OpenRouter timeout"
assert_not_contains "$(cat "$LOG/argv")" "$OR_KEY" "OpenRouter key never appears in curl argv"
assert_equals "Authorization: Bearer $OR_KEY" "$(cat "$LOG/header")" "OpenRouter key reaches curl only through fd 3"
assert_equals $'curl:clean\nquota-axi:clean' "$(cat "$LOG/child-env")" "OpenRouter key is absent from child environments"
assert_equals 'typesafe/jev-1.13' "$(jq -r .model "$LOG/body")" "OpenRouter model is explicit"
assert_equals 'pager' "$(jq -r .state.task.project "$LOG/body")" "project reaches the model"
assert_equals 'choice' "$(jq -r .questions.rule.type "$LOG/body")" "OpenRouter uses the native Choice request"
assert_equals "$(jq -Sc 'del(.model)' "$TMP_ROOT/typesafe-body.json")" "$(jq -Sc 'del(.model)' "$LOG/body")" "providers send identical Choice inputs apart from model"
assert_not_contains "$(cat "$LOG/body")" 'SECRET-WHY-TEXT' "OpenRouter never sends rule why text"
pass "OpenRouter clear uses the same output contract and keeps its key out of argv and child environments"

printf '%s\n' 'FM_DISPATCH_PROVIDER=openrouter' 'FM_DISPATCH_MODEL=typesafe/jev-1.13' "OPENROUTER_API_KEY=$OR_KEY" > "$HOME_DIR/.env"
reset_log
FAKE_CURL_RESPONSE=$OR_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "OpenRouter provider, model, and key work from .env"
assert_equals "Authorization: Bearer $OR_KEY" "$(cat "$LOG/header")" ".env OpenRouter key uses fd 3"
reset_log
OPENROUTER_API_KEY=env-wins FAKE_CURL_RESPONSE=$OR_RESPONSE run code out err "$BRIEF"
assert_equals 'Authorization: Bearer env-wins' "$(cat "$LOG/header")" "OpenRouter environment key wins over .env"
rm -f "$HOME_DIR/.env"
reset_log
printf '%s\n' 'pager' > "$HOME_DIR/config/dispatch-never-send"
FM_DISPATCH_PROVIDER=openrouter FM_DISPATCH_MODEL=typesafe/jev-1.13 \
  OPENROUTER_API_KEY=$OR_KEY FAKE_CURL_RESPONSE=$OR_RESPONSE run code out err "$BRIEF" --project pager
assert_equals '' "$out" "OpenRouter never-send match withholds the request"
assert_contains "$err" 'nothing sent)' "OpenRouter never-send reports withholding"
assert_absent "$LOG/argv" "OpenRouter never-send makes no network call"
rm -f "$HOME_DIR/config/dispatch-never-send"

reset_log
write_openrouter_response rule_4 0.5
FM_DISPATCH_PROVIDER=openrouter FM_DISPATCH_MODEL=typesafe/jev-1.13 \
  OPENROUTER_API_KEY=$OR_KEY FAKE_CURL_RESPONSE=$OR_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "OpenRouter low confidence is ambiguous"
assert_not_contains "$out" '  profile:' "OpenRouter ambiguous response has no profile"
reset_log
printf '%s\n' '{"answers":{"rule":{"choice":"rule_4"}}}' > "$OR_RESPONSE"
FM_DISPATCH_PROVIDER=openrouter FM_DISPATCH_MODEL=typesafe/jev-1.13 \
  OPENROUTER_API_KEY=$OR_KEY FAKE_CURL_RESPONSE=$OR_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  status: error' "malformed OpenRouter response is an error"
assert_contains "$out" '  reason: response is not a rule Choice answer' "malformed OpenRouter response names the Choice contract"
reset_log
FM_DISPATCH_PROVIDER=openrouter FM_DISPATCH_MODEL=typesafe/jev-1.13 \
  OPENROUTER_API_KEY=$OR_KEY FAKE_CURL_RESPONSE=$OR_RESPONSE FAKE_CURL_HTTP=429 run code out err "$BRIEF"
assert_contains "$out" '  status: error' "OpenRouter HTTP error is reported"
assert_contains "$out" '  reason: http 429 after' "OpenRouter HTTP status is reported"
assert_not_contains "$out$err" "$OR_KEY" "OpenRouter HTTP error never includes the key"
reset_log
FM_DISPATCH_PROVIDER=openrouter OPENROUTER_API_KEY=$OR_KEY run code out err "$BRIEF"
expect_code 2 "$code" "OpenRouter missing model is a configuration error"
assert_contains "$err" 'FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=openrouter' "missing model is actionable"
assert_absent "$LOG/argv" "missing model makes no network call"
FM_DISPATCH_PROVIDER=unknown OPENROUTER_API_KEY=$OR_KEY run code out err "$BRIEF"
expect_code 2 "$code" "unknown provider is a configuration error"
assert_contains "$err" 'unknown FM_DISPATCH_PROVIDER' "unknown provider is actionable"
pass "OpenRouter ambiguous, malformed, HTTP, and missing-model paths are handled"

# --- off stays off: no provider and no typesafe key, whatever else is set ----
reset_log
FM_DISPATCH_BASE_URL=http://127.0.0.1:8080 FM_DISPATCH_API_KEY=unused OPENAI_API_KEY=unused \
  OPENROUTER_API_KEY=unused run code out err "$BRIEF" --project pager
expect_code 0 "$code" "config-absent off exits 0"
assert_equals '' "$out" "config-absent off prints nothing on stdout"
assert_equals "dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and $HOME_DIR/.env)" "$err" \
  "config-absent off is the original single stderr line, byte for byte"
assert_absent "$LOG/argv" "config-absent off makes no network call"
assert_absent "$LOG/quota-axi.calls" "config-absent off reads no quota"
pass "with no provider set, other providers' settings leave the original off line unchanged"

# --- systemone: any System One-compatible host at a base URL ----------------
SO_KEY='test-systemone-key-never-in-child-env-or-argv'
SO_RESPONSE="$TMP_ROOT/systemone-response.json"
write_response "$SO_RESPONSE" rule_4 0.9
reset_log
FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_MODEL=clef-flash FM_DISPATCH_BASE_URL=http://127.0.0.1:8080/ \
  FAKE_CURL_RESPONSE=$SO_RESPONSE run code out err "$BRIEF" --project pager
expect_code 0 "$code" "systemone clear exits 0"
assert_contains "$out" '  status: clear' "systemone clear status"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "systemone uses the shared quota argmax"
assert_contains "$(cat "$LOG/argv")" 'http://127.0.0.1:8080/v1/systemone' "systemone posts to <base>/v1/systemone with a trailing slash trimmed"
assert_contains "$(cat "$LOG/argv")" $'--max-time\n10' "systemone timeout"
assert_not_contains "$(cat "$LOG/argv")" '@/dev/fd/3' "systemone without a key sends no Authorization header"
assert_equals 'fd3 unreadable' "$(cat "$LOG/header")" "systemone without a key opens no header descriptor"
assert_equals "$(jq -Sc 'del(.model)' "$TMP_ROOT/typesafe-body.json")" "$(jq -Sc 'del(.model)' "$LOG/body")" "systemone sends the unchanged System One request"
assert_equals 'clef-flash' "$(jq -r .model "$LOG/body")" "systemone model is explicit"
reset_log
FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_MODEL=clef-flash FM_DISPATCH_BASE_URL=https://so.example.test \
  FM_DISPATCH_API_KEY=$SO_KEY FAKE_CURL_RESPONSE=$SO_RESPONSE run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: clear' "systemone with a key is clear"
assert_contains "$(cat "$LOG/argv")" 'https://so.example.test/v1/systemone' "systemone https base URL"
assert_not_contains "$(cat "$LOG/argv")" "$SO_KEY" "systemone key never appears in curl argv"
assert_equals "Authorization: Bearer $SO_KEY" "$(cat "$LOG/header")" "systemone key reaches curl only through fd 3"
assert_equals $'curl:clean\nquota-axi:clean' "$(cat "$LOG/child-env")" "systemone key is absent from child environments"
printf '%s\n' 'FM_DISPATCH_PROVIDER=systemone' 'FM_DISPATCH_MODEL=clef' 'FM_DISPATCH_BASE_URL=http://10.0.0.5:8080' \
  "FM_DISPATCH_API_KEY=$SO_KEY" > "$HOME_DIR/.env"
reset_log
FAKE_CURL_RESPONSE=$SO_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "systemone provider, model, base URL, and key work from .env"
assert_contains "$(cat "$LOG/argv")" 'http://10.0.0.5:8080/v1/systemone' ".env base URL is used"
assert_equals "Authorization: Bearer $SO_KEY" "$(cat "$LOG/header")" ".env systemone key uses fd 3"
rm -f "$HOME_DIR/.env"
pass "systemone posts the unchanged request to its base URL with an optional fd-3 key"

reset_log
FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_BASE_URL=http://127.0.0.1:8080 run code out err "$BRIEF"
expect_code 2 "$code" "systemone missing model is a configuration error"
assert_contains "$err" 'FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=systemone' "systemone missing model is actionable"
FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_MODEL=clef run code out err "$BRIEF"
expect_code 2 "$code" "systemone missing base URL is a configuration error"
assert_contains "$err" 'FM_DISPATCH_BASE_URL required when FM_DISPATCH_PROVIDER=systemone' "systemone missing base URL is actionable"
FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_MODEL=clef FM_DISPATCH_BASE_URL=127.0.0.1:8080 run code out err "$BRIEF"
expect_code 2 "$code" "systemone base URL without a scheme is a configuration error"
assert_contains "$err" 'FM_DISPATCH_BASE_URL must start with http:// or https://' "systemone bad base URL is actionable"
assert_absent "$LOG/argv" "systemone configuration errors make no network call"
reset_log
printf '%s\n' '10.0.0.5' > "$HOME_DIR/config/dispatch-never-send"
FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_MODEL=clef FM_DISPATCH_BASE_URL=http://10.0.0.5:8080 \
  FAKE_CURL_RESPONSE=$SO_RESPONSE run code out err "$BRIEF"
assert_equals '' "$out" "a never-send base URL withholds the request"
assert_contains "$err" 'nothing sent)' "a never-send base URL reports withholding"
assert_absent "$LOG/argv" "a never-send base URL makes no network call"
rm -f "$HOME_DIR/config/dispatch-never-send"
reset_log
printf '%s\n' '{"answers":{"rule":{"choice":"rule_4","confidence":0.9}}}' > "$SO_RESPONSE"
FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_MODEL=clef FM_DISPATCH_BASE_URL=http://127.0.0.1:8080 \
  FAKE_CURL_RESPONSE=$SO_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  reason: response is not a rule Choice answer' "systemone partial response is rejected"
reset_log
FM_DISPATCH_PROVIDER=systemone FM_DISPATCH_MODEL=clef FM_DISPATCH_BASE_URL=http://127.0.0.1:8080 \
  FAKE_CURL_FAIL=1 run code out err "$BRIEF"
expect_code 0 "$code" "systemone transport failure exits 0"
assert_contains "$out" '  status: error' "systemone transport failure returns to normal intake"
assert_contains "$out" '  reason: http 000 after' "systemone transport failure reads as http 000"
assert_not_contains "$out" '  profile:' "systemone transport failure never emits a profile"
assert_absent "$LOG/quota-axi.calls" "systemone transport failure reads no quota"
pass "systemone configuration errors, never-send base URL, partial response, and transport failure are handled"

# --- openai: Decisions API, mapped to and from the System One shape ----------
OA_KEY='test-openai-key-never-in-child-env-or-argv'
OA_RESPONSE="$TMP_ROOT/openai-response.json"
write_openai_response() {  # <choice> <confidence> [<rule_4 probability>]
  cat > "$OA_RESPONSE" <<JSON
{ "answers": [ { "type": "choice", "name": "rule", "choice": "$1", "confidence": $2,
    "probabilities": [ { "value": "rule_1", "probability": 0.01 }, { "value": "rule_2", "probability": 0.01 },
      { "value": "rule_3", "probability": 0.01 }, { "value": "rule_4", "probability": ${3:-0.96} },
      { "value": "default", "probability": 0.01 } ] } ],
  "usage": { "input_tokens": 700, "output_tokens": 5 } }
JSON
}
write_openai_response rule_4 0.9
reset_log
OPENAI_API_KEY=$OA_KEY run code out err "$BRIEF"
assert_contains "$err" 'TYPESAFE_API_KEY absent' "an OpenAI key alone does not select the provider"
assert_absent "$LOG/argv" "an OpenAI key alone sends nothing"
reset_log
FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna run code out err "$BRIEF"
expect_code 0 "$code" "openai without a key exits 0"
assert_equals '' "$out" "openai without a key prints nothing on stdout"
assert_equals "dispatch-resolve: off (OPENAI_API_KEY absent from the environment and $HOME_DIR/.env)" "$err" "openai without a key is one off line"
assert_absent "$LOG/argv" "openai without a key makes no network call"
reset_log
FM_DISPATCH_PROVIDER=openai OPENAI_API_KEY=$OA_KEY run code out err "$BRIEF"
expect_code 2 "$code" "openai missing model is a configuration error"
assert_contains "$err" 'FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=openai' "openai missing model is actionable"
assert_absent "$LOG/argv" "openai missing model makes no network call"
reset_log
FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna OPENAI_API_KEY=$OA_KEY \
  FAKE_CURL_RESPONSE=$OA_RESPONSE run code out err "$BRIEF" --project pager
expect_code 0 "$code" "openai clear exits 0"
assert_contains "$out" '  status: clear' "openai clear status"
assert_contains "$out" '  model: gpt-6-luna   latency_ms:' "openai answer without a model reports the configured model"
assert_contains "$out" 'tokens: 700/5' "openai usage is shown"
assert_contains "$out" '  probabilities: rule_1=0.01 rule_2=0.01 rule_3=0.01 rule_4=0.96 default=0.01' "openai probabilities map back to every option"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "openai uses the shared quota argmax"
assert_contains "$(cat "$LOG/argv")" 'https://api.openai.com/v1/decisions' "openai endpoint"
assert_contains "$(cat "$LOG/argv")" $'--max-time\n10' "openai timeout"
assert_not_contains "$(cat "$LOG/argv")" "$OA_KEY" "openai key never appears in curl argv"
assert_equals "Authorization: Bearer $OA_KEY" "$(cat "$LOG/header")" "openai key reaches curl only through fd 3"
assert_equals $'curl:clean\nquota-axi:clean' "$(cat "$LOG/child-env")" "openai key is absent from child environments"
body=$(cat "$LOG/body")
assert_equals 'gpt-6-luna' "$(jq -r .model <<<"$body")" "openai model is explicit"
assert_equals "$(jq -c .state "$TMP_ROOT/typesafe-body.json")" "$(jq -c '.input | fromjson' <<<"$body")" "openai input carries the same state as JSON text"
assert_equals '1 choice rule' "$(jq -r '"\(.questions | length) \(.questions[0].type) \(.questions[0].name)"' <<<"$body")" "openai asks one named choice question"
assert_equals "$(jq -r .questions.rule.instructions "$TMP_ROOT/typesafe-body.json")" "$(jq -r '.questions[0].instructions' <<<"$body")" "openai keeps the question instructions"
assert_equals "$(jq -Sc '.questions.rule.criteria' "$TMP_ROOT/typesafe-body.json")" \
  "$(jq -Sc '.questions[0].choices | map({key: .value, value: .description}) | from_entries' <<<"$body")" "openai choices are every rule plus the none option"
assert_equals 'input,model,questions' "$(jq -r 'keys | join(",")' <<<"$body")" "openai body carries nothing else"
assert_not_contains "$body" 'SECRET-WHY-TEXT' "openai never sends rule why text"
assert_not_contains "$body" 'spendPriority' "openai never sends quota"
pass "openai maps the Choice request to the Decisions API and its answer back, key on fd 3 only"

reset_log
printf '%s\n' 'off-by-one in the pager' > "$HOME_DIR/config/dispatch-never-send"
FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna OPENAI_API_KEY=$OA_KEY \
  FAKE_CURL_RESPONSE=$OA_RESPONSE run code out err "$BRIEF"
assert_equals '' "$out" "a never-send match inside the serialized openai input withholds the request"
assert_contains "$err" 'nothing sent)' "openai never-send reports withholding"
assert_absent "$LOG/argv" "openai never-send makes no network call"
printf '%s\n' 'gpt-6-luna' > "$HOME_DIR/config/dispatch-never-send"
FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna OPENAI_API_KEY=$OA_KEY \
  FAKE_CURL_RESPONSE=$OA_RESPONSE run code out err "$BRIEF"
assert_contains "$err" 'nothing sent)' "a never-send model name withholds the openai request"
assert_absent "$LOG/argv" "a never-send model name makes no network call"
rm -f "$HOME_DIR/config/dispatch-never-send"
pass "the never-send check runs on the final openai request body"

openai_rejects() {  # <response-json> <label>
  printf '%s\n' "$1" > "$OA_RESPONSE"
  reset_log
  FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna OPENAI_API_KEY=$OA_KEY \
    FAKE_CURL_RESPONSE=$OA_RESPONSE run code out err "$BRIEF"
  expect_code 0 "$code" "$2 exits 0"
  assert_contains "$out" '  reason: response is not a rule Choice answer' "$2 is rejected"
  assert_not_contains "$out" '  profile:' "$2 never emits a profile"
  assert_absent "$LOG/quota-axi.calls" "$2 reads no quota"
}
openai_rejects '{"answers":[{"type":"refusal","name":"rule"}]}' "an openai refusal"
openai_rejects '{"answers":{"rule":{"choice":"rule_4"}}}' "an openai answers object"
openai_rejects '{"answers":[]}' "an openai response without the rule answer"
openai_rejects 'not json' "a non-JSON openai response"
openai_rejects '{"answers":[{"type":"choice","name":"rule","choice":"rule_4","confidence":0.9,"probabilities":[{"value":"rule_4","probability":0.5},{"value":"rule_4","probability":0.5}]}]}' "duplicate openai option values"
openai_rejects '{"answers":[{"type":"choice","name":"rule","choice":"rule_4","confidence":0.9,"probabilities":[{"value":"rule_4","probability":0.99},{"value":"default","probability":0.01}]}]}' "openai probabilities missing options"
openai_rejects '{"answers":[{"type":"choice","name":"rule","choice":"rule_4","probabilities":[{"value":"rule_1","probability":0.01},{"value":"rule_2","probability":0.01},{"value":"rule_3","probability":0.01},{"value":"rule_4","probability":0.96},{"value":"default","probability":0.01}]}]}' "an openai answer without confidence"
reset_log
write_openai_response rule_4 0.5
FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna OPENAI_API_KEY=$OA_KEY \
  FAKE_CURL_RESPONSE=$OA_RESPONSE run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "openai low confidence is ambiguous"
reset_log
FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna OPENAI_API_KEY=$OA_KEY \
  FAKE_CURL_RESPONSE=$OA_RESPONSE FAKE_CURL_HTTP=401 run code out err "$BRIEF"
assert_contains "$out" '  reason: http 401 after' "openai HTTP error is reported"
assert_not_contains "$out$err" "$OA_KEY" "openai HTTP error never includes the key"
reset_log
FM_DISPATCH_PROVIDER=openai FM_DISPATCH_MODEL=gpt-6-luna OPENAI_API_KEY=$OA_KEY FAKE_CURL_FAIL=1 run code out err "$BRIEF"
expect_code 0 "$code" "openai transport failure exits 0"
assert_contains "$out" '  status: error' "openai transport failure returns to normal intake"
assert_not_contains "$out" '  profile:' "openai transport failure never emits a profile"
pass "openai malformed, partial, refused, ambiguous, HTTP, and transport paths return to normal intake"

# --- never-send list: a match or a bad list withholds the request -------------
NEVER_SEND="$HOME_DIR/config/dispatch-never-send"
PRIVATE_BRIEF="$TMP_ROOT/private-brief.md"
cat > "$PRIVATE_BRIEF" <<'MD'
# Task
## Captain's intent
Fix the pager for the Acme-Ledger account 4417-2290.

## Firstmate spec
- Keep the change small.
MD
expect_withheld() {  # <label> <stderr fragment> [<value that must not print>...]
  local label=$1 fragment=$2
  shift 2
  expect_code 0 "$code" "$label exits 0"
  assert_equals '' "$out" "$label prints nothing on stdout, so firstmate uses its existing intake"
  assert_contains "$err" "dispatch-resolve: off ($fragment" "$label names why on stderr"
  assert_contains "$err" 'nothing sent)' "$label says nothing was sent"
  assert_equals '1' "$(grep -c . <<<"$err")" "$label prints one diagnostic line"
  assert_absent "$LOG/argv" "$label never calls curl"
  assert_absent "$LOG/quota-axi.calls" "$label never reads quota"
  local value
  for value in "$@"; do
    assert_not_contains "$err" "$value" "$label never prints the listed value"
  done
}

printf '%s\n' '# private values' '' '   ' 'Unlisted-Value' > "$NEVER_SEND"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
assert_contains "$out" '  status: clear' "a list with no match leaves resolution unchanged"
assert_contains "$(jq -r .state.task.brief "$LOG/body")" 'Acme-Ledger' "a list with no match sends the task text"

printf '%s\n' '# private values' '' '  acme-ledger  ' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a case-insensitive literal match" "brief text matches $NEVER_SEND line 3" 'acme-ledger' 'Acme-Ledger'

WRAPPED_BRIEF="$TMP_ROOT/wrapped-brief.md"
printf '# Task\n## Captain'"'"'s intent\nFix the pager for Example Client\nLtd before\tthe\xc2\xa0release.\n' > "$WRAPPED_BRIEF"
printf '%s\n' 'example  client ltd' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$WRAPPED_BRIEF" --project pager
expect_withheld "a literal the brief wraps across lines" "brief text matches $NEVER_SEND line 1" 'example' 'Example'

printf '%s\n' 'before the release' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$WRAPPED_BRIEF" --project pager
expect_withheld "a literal the brief spaces with a tab and a no-break space" "brief text matches $NEVER_SEND line 1" 'release'

printf '%s\n' 'orion-private' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project orion-private
expect_withheld "a project-name match" "brief text matches $NEVER_SEND line 1" 'orion-private'

printf '%s\n' 'stated root cause' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_withheld "a rule-criterion match" "brief text matches $NEVER_SEND line 1" 'stated root cause'

SECOND_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SECOND_HOME/config"
printf '%s\n' 'acme-ledger' > "$NEVER_SEND"
# A child shell keeps the lib's own globals (such as out) out of this script
# shellcheck disable=SC2016 # Expanded by the child shell
bash -c '. "$1" && propagate_inheritable_config "$2" "$3"' _ \
  "$ROOT/bin/fm-config-inherit-lib.sh" "$HOME_DIR/config" "$SECOND_HOME/config" \
  || fail "inheritance into the secondmate home failed"
PRIMARY_HOME=$HOME_DIR
HOME_DIR=$SECOND_HOME
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "an inherited list in a secondmate home" "brief text matches $SECOND_HOME/config/dispatch-never-send line 1" 'acme-ledger' 'Acme-Ledger'
HOME_DIR=$PRIMARY_HOME

rm -f "$NEVER_SEND"
mkdir "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a directory at the list path" "$NEVER_SEND is not a readable regular file"
rmdir "$NEVER_SEND"
ln -s "$TMP_ROOT/missing-never-send" "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a broken symlink at the list path" "$NEVER_SEND is not a readable regular file"
rm -f "$NEVER_SEND"

reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
assert_contains "$out" '  status: clear' "no list resolves exactly as before"
assert_contains "$(jq -r .state.task.brief "$LOG/body")" 'Acme-Ledger' "no list sends the task text as before"
pass "never-send list withholds the request on a match or a bad list, and never prints the value"

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

# --- per-rule confidence floor ------------------------------------------------
write_floor_response() {  # <path> <choice> <confidence> <rule_1> <rule_2> <rule_3> <rule_4> <default>
  cat > "$1" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "$2", "confidence": $3,
    "probabilities": { "rule_1": $4, "rule_2": $5, "rule_3": $6, "rule_4": $7, "default": $8 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
}
FLOOR_RULES="$TMP_ROOT/floor-rules.json"
jq '.rules[1].min_confidence = 0.9 | .rules[3].min_confidence = 0.1' "$BASE_RULES" > "$FLOOR_RULES"
cp "$FLOOR_RULES" "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.02 0.76 0.02 0.18 0.02
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a top rule below its own floor falls to a runner-up that clears its floor"
assert_contains "$out" '  rule: rule_2 (The task generates images.)   confidence: 0.76' "the model's own pick stays visible"
assert_contains "$out" '  fallback: rule_4 (A simple bug fix with a stated root cause.) probability 0.18 clears its floor 0.1; rule_2 probability 0.76 is below its floor 0.9' "the fallback names both floors"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the runner-up rule's profiles are resolved"
assert_not_contains "$(cat "$LOG/body")" 'min_confidence' "the model never sees confidence floors"

reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.02 0.76 0.02 0.08 0.12
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "no runner-up clearing its own floor is ambiguous"
assert_contains "$out" '  reason: rule_2 probability 0.76 below its floor 0.9; no other option clears its own floor' "the undeclared default keeps the global floor as a runner-up"
assert_not_contains "$out" '  fallback:' "no fallback is reported when none is taken"
assert_not_contains "$out" '  profile:' "ambiguous per-rule floor emits no profile"

jq '.rules[0].min_confidence = 0.1' "$FLOOR_RULES" > "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.12 0.76 0.0 0.12 0.0
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "equally probable runner-ups never break by option order"
assert_contains "$out" '  reason: rule_2 probability 0.76 below its floor 0.9; runner-up tie' "a runner-up tie is named"

cp "$FLOOR_RULES" "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_4 0.45 0.01 0.01 0.01 0.45 0.52
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "a declared floor below the global floor lets the picked rule resolve"

# A declared floor needs the same support from a rule as the pick or as a runner-up
jq '.rules[3].min_confidence = 0.3' "$FLOOR_RULES" > "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_4 0.25 0.25 0.05 0.05 0.35 0.30
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a picked rule clears its declared floor on its own probability, not the answer confidence"
assert_not_contains "$out" '  fallback:' "a picked rule that clears its own floor takes no fallback"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the picked rule resolves at probability 0.35 over floor 0.3"

reset_log
write_floor_response "$RESPONSE" rule_2 0.95 0.05 0.55 0.05 0.30 0.05
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a high answer confidence does not lift a picked rule over its own floor"
assert_contains "$out" '  fallback: rule_4 (A simple bug fix with a stated root cause.) probability 0.30 clears its floor 0.3; rule_2 probability 0.55 is below its floor 0.9' "the runner-up clears the same floor it would need as the pick"

reset_log
write_floor_response "$RESPONSE" rule_2 0.55 0.05 0.55 0.05 0.25 0.10
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "a runner-up below its own floor is not taken"
assert_contains "$out" '  reason: rule_2 probability 0.55 below its floor 0.9; no other option clears its own floor' "the missed runner-up floor is named"
cp "$BASE_RULES" "$RULES"

reset_log
write_floor_response "$RESPONSE" rule_2 0.55 0.01 0.55 0.01 0.42 0.01
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "without declared floors a low pick stays ambiguous"
assert_contains "$out" '  reason: confidence 0.55 below floor 0.6' "without declared floors the global floor reason is unchanged"
assert_not_contains "$out" '  fallback:' "without declared floors no runner-up is taken"
pass "per-rule confidence floors fall to the most probable runner-up that clears its own floor"

# --- the model sees only the task-specific brief sections ----------------------
SCAFFOLD_BRIEF="$TMP_ROOT/scaffold-brief.md"
cat > "$SCAFFOLD_BRIEF" <<'MD'
# Task
## Captain's intent
Add a flag to the pager.

## Firstmate spec
Touch pager.sh only.
```sh
# Not a heading inside a fence
## Setup
```
### Out of scope
Anything else.

# Setup
BOILERPLATE-SETUP never push to the default branch.

## Captain intent authorized for --intent
BOILERPLATE-DUPLICATE
MD
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$SCAFFOLD_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'## Captain\'s intent\nAdd a flag to the pager.' "the captain's intent section is sent"
assert_contains "$sent" $'## Firstmate spec\nTouch pager.sh only.' "the Firstmate spec section is sent"
assert_contains "$sent" $'# Not a heading inside a fence\n## Setup\n```\n### Out of scope\nAnything else.' "fenced lines and subheadings stay inside the section"
assert_not_contains "$sent" 'BOILERPLATE' "scaffold boilerplate after the task sections is not sent"
assert_not_contains "$sent" '# Task' "the enclosing Task heading is not sent"
assert_not_contains "$sent" 'Brief kind:' "a brief without a scout contract line gets no kind line"

SPEC_ONLY_BRIEF="$TMP_ROOT/spec-only-brief.md"
printf '%s\n' '# Task' '## Firstmate spec' 'Spec text.' '## Rules' 'RULES-TEXT' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals $'## Firstmate spec\nSpec text.' "$(jq -r .state.task.brief "$LOG/body")" "one recognized section is enough"

printf '%s\n' '# Task' '## Firstmate spec   ' 'Spec text.' '## Rules' 'RULES-TEXT' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals "$(cat "$SPEC_ONLY_BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a heading with trailing blanks is not a section, matching spawn validation"

printf '%s\n' 'Preamble.' '## Firstmate spec' 'Spec text.' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals "$(cat "$SPEC_ONLY_BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a section outside the Task heading is not a task section"

KIND_BRIEF="$TMP_ROOT/kind-brief.md"
{ cat "$SCAFFOLD_BRIEF"; printf '%s\n' '# Definition of done' 'Delivery contract: mode=no-mistakes' 'Delivery contract: mode=direct-PR'; } > "$KIND_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$KIND_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'## Captain\'s intent\nAdd a flag to the pager.' "a ship brief still sends its task sections"
assert_not_contains "$sent" 'Brief kind:' "a ship brief gets no kind line"
assert_not_contains "$sent" 'mode=' "a ship brief's delivery mode is not sent"

{ cat "$SCAFFOLD_BRIEF"; printf '%s\n' 'This is a SCOUT task: the deliverable is a written report, not a PR.'; } > "$KIND_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$KIND_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'Brief kind: scout (report only)\n\n## Captain\'s intent' "a scout brief's contract line names its kind"
assert_not_contains "$sent" 'This is a SCOUT task' "the scout contract line itself is not sent"

reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_equals "$(cat "$BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a brief with neither heading is sent whole"
pass "only the brief's task sections and scout tag reach the model, with a whole-brief fallback"

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
  '{"rules":[{"when":"x","use":{"harness":"claude"},"approval":"firstmate"}]}|approval must be "captain" when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"select":"mystery"}]}|unknown select: mystery' \
  '{"shared_quota":"yes","rules":[{"when":"x","use":{"harness":"claude"}}]}|shared_quota must be true or false when present' \
  '{"shared_quota":1,"rules":[{"when":"x","use":{"harness":"claude"}}]}|shared_quota must be true or false when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"min_confidence":"high"}]}|min_confidence must be a number from 0 through 1 when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"min_confidence":1.5}]}|min_confidence must be a number from 0 through 1 when present' \
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
printf '%s\n' '{"rules":[{"when":"x","use":[{"harness":"opencode"},{"harness":"rovo"},{"harness":"codex"}]}],"default":[{"harness":"pi"},{"harness":"claude"}]}' > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "multiple provider-less profiles exit 2"
assert_contains "$err" "malformed rules file: $RULES - use profiles whose harness lacks one authoritative provider family require provider: opencode; use profiles whose harness lacks one authoritative provider family require provider: rovo; default profiles whose harness lacks one authoritative provider family require provider: pi" "all provider-less profiles are reported together across use and default"
[ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" -eq 1 ] || fail "provider errors must use one diagnostic"
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

# --- shared-quota opt-out: no quota call, declared-order pick ----------------
cp "$BASE_RULES" "$RULES"
jq '.shared_quota = true' "$BASE_RULES" > "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "shared-quota clear exits 0"
assert_contains "$out" '  status: clear' "shared-quota clear status"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "shared-quota picks the first declared profile, not the argmax winner"
assert_not_contains "$out" 'spendPriority=' "shared-quota prints no quota evidence"
assert_not_contains "$out" '  remaining=' "shared-quota prints no remaining percentages"
assert_not_contains "$out" '  runway=' "shared-quota prints no runway gates"
assert_contains "$out" 'quota ranking off: home declares a single shared quota' "every candidate line states quota ranking is off"
assert_absent "$LOG/quota-axi.calls" "shared-quota never reads quota-axi"
[ "$(printf '%s\n' "$out" | grep -c 'quota ranking off')" -ge 3 ] || fail "shared-quota states the opt-out on every candidate line"
pass "shared-quota opt-out: no quota snapshot, deterministic declared-order pick, opt-out stated on every candidate"

# --- shared-quota: an unmet rule-level floor is bypassed too -----------------
# rule_1 declares floor model:fable >= 20% but the fixture has 15% there, so the
# quota-ranked path would fall through to default; the opt-out keeps the rule.
jq '.shared_quota = true' "$BASE_RULES" > "$RULES"
reset_log
write_response "$RESPONSE" rule_1 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "shared-quota unmet rule floor exits 0"
assert_contains "$out" '  status: clear' "shared-quota unmet rule floor status"
assert_contains "$out" '  note: rule matched' "shared-quota skips the unmet rule floor instead of falling through to default"
assert_not_contains "$out" 'fall through to default' "shared-quota unmet rule floor never falls through to default"
assert_contains "$out" "  profile: --harness 'claude' --model 'fable' --effort 'xhigh'" "shared-quota unmet rule floor picks the rule's own declared profile"
assert_contains "$out" 'quota ranking off: home declares a single shared quota' "unmet rule floor candidate states quota ranking is off"
assert_absent "$LOG/quota-axi.calls" "shared-quota unmet rule floor never reads quota-axi"
pass "shared-quota bypasses an unmet rule-level floor: the rule's own profile wins with no quota call"

# --- shared-quota: an unmet profile-level floor is bypassed too ---------------
# The codex profile declares floor all_models >= 50% but the fixture has 31%, so
# the quota-ranked path marks it not eligible; the opt-out resolves the declared
# order anyway. The use array is reversed so the floored profile is first.
jq '.shared_quota = true | .rules[1].use |= reverse' "$BASE_RULES" > "$RULES"
reset_log
write_response "$RESPONSE" rule_2 0.99
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "shared-quota unmet profile floor exits 0"
assert_contains "$out" '  status: clear' "shared-quota unmet profile floor status"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "shared-quota unmet profile floor picks the floored profile first in declared order"
assert_not_contains "$out" 'not eligible' "shared-quota unmet profile floor marks no candidate ineligible"
assert_contains "$out" 'quota ranking off: home declares a single shared quota' "unmet profile floor candidates state quota ranking is off"
assert_absent "$LOG/quota-axi.calls" "shared-quota unmet profile floor never reads quota-axi"
pass "shared-quota bypasses an unmet profile-level floor: the first declared profile wins with no quota call"

# --- shared-quota: preferred_provider still narrows the pool ------------------
# The matched rule declares claude first, then two codex-family profiles; the
# home prefers codex, so the first declared codex profile wins.
jq '.shared_quota = true | .preferred_provider = "codex" | .rules[3].use = [
  {harness:"claude",model:"sonnet",effort:"high"},
  {harness:"pi",model:"openai-codex/gpt-5.6-sol",provider:"codex"},
  {harness:"codex",model:"gpt-5.6-sol"}]' "$BASE_RULES" > "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "shared-quota preferred_provider exits 0"
assert_contains "$out" '  status: clear' "shared-quota preferred_provider status"
assert_contains "$out" '  preferred_provider: codex: prefer eligible family candidates' "shared-quota still applies the family preference"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "shared-quota preferred_provider picks the first declared preferred-family profile"
assert_absent "$LOG/quota-axi.calls" "shared-quota preferred_provider never reads quota-axi"
[ "$(printf '%s\n' "$out" | grep -c '^  candidate: ')" -eq 3 ] || fail "shared-quota preferred_provider lists every candidate"
[ "$(printf '%s\n' "$out" | grep '^  candidate: ' | grep -c 'quota ranking off: home declares a single shared quota')" -eq 3 ] ||
  fail "shared-quota preferred_provider states the opt-out on every candidate line"
pass "shared-quota keeps preferred_provider narrowing: the preferred family wins in declared order with no quota call"

# restore the shared response fixture for the false-path test below
write_response "$RESPONSE" rule_4 0.9

# --- shared_quota false: byte-for-byte the quota-ranked path ------------------
jq '.shared_quota = false' "$BASE_RULES" > "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "shared_quota false exits 0"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "shared_quota false keeps the spendPriority argmax"
assert_not_contains "$out" 'quota ranking off' "shared_quota false prints no opt-out wording"
[ -f "$LOG/quota-axi.calls" ] || fail "shared_quota false still reads quota-axi"
assert_contains "$out" 'spendPriority=' "shared_quota false prints quota evidence"
pass "shared_quota false keeps the unchanged quota-ranked behavior"
cp "$BASE_RULES" "$RULES"

printf '# all fm-dispatch-resolve tests passed\n'
