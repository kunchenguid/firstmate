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
RECEIPTS="$HOME_DIR/state/dispatch-receipts.jsonl"
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
        { "harness": "cursor", "model": "cursor-grok-4.6-medium", "provider": "cursor" },
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
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf 'curl:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'curl:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
out='' headers=''
while [ $# -gt 0 ]; do
  case "$1" in
    -D) headers=$2; shift 2 ;;
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
[ -z "$headers" ] || printf 'HTTP/1.1 %s Fake\r\nx-typesafe-request-id: request-test-123\r\n\r\n' "${FAKE_CURL_HTTP:-200}" > "$headers"
printf '%s' "${FAKE_CURL_HTTP:-200}"
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
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" QUOTA_AXI_CALLS="$LOG/quota-axi.calls" QUOTA_AXI_FIXTURE="$QUOTA" CHILD_ENV_LOG="$LOG/child-env"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

test_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
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
code='' out='' err='' baseline_out='' baseline_err=''

# --- absent key: off, silent on stdout, no network, no quota read -----------
reset_log
write_response "$RESPONSE" rule_4 0.9
run code out err "$BRIEF" --project pager
expect_code 0 "$code" "absent key exits 0"
assert_equals '' "$out" "absent key prints nothing on stdout"
assert_contains "$err" 'dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and' "absent key explains itself on stderr"
assert_absent "$LOG/argv" "absent key never calls curl"
assert_absent "$LOG/quota-axi.calls" "absent key never reads quota-axi"
assert_absent "$RECEIPTS" "absent key creates no receipt file"
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
assert_equals 'jev-1.13.0' "$(jq -r .model <<<"$body")" "request model is pinned to jev-1.13.0"
assert_equals 'pager' "$(jq -r .state.task.project <<<"$body")" "project rides in the state"
assert_contains "$(jq -r .state.task.brief <<<"$body")" 'off-by-one in the pager' "the whole brief rides in the state"
assert_equals '["rule"]' "$(jq -c '.questions | keys' <<<"$body")" "only the rule Choice is asked"
assert_equals '["default","rule_1","rule_2","rule_3","rule_4"]' "$(jq -c '.questions.rule.criteria | keys' <<<"$body")" "one option per rule plus default"
assert_equals 'No listed rule applies to this task.' "$(jq -r '.questions.rule.criteria.default' <<<"$body")" "the fixed generic none criterion is the default option"
assert_equals 'A simple bug fix with a stated root cause.' "$(jq -r '.questions.rule.criteria.rule_4' <<<"$body")" "rule when text is the option verbatim"
assert_not_contains "$body" 'SECRET-WHY-TEXT' "why text never leaves the machine"
assert_not_contains "$body" 'spendPriority' "quota never leaves the machine"
assert_not_contains "$body" 'cursor-grok' "use profiles never leave the machine"
clear_receipt=$(jq -sc '[.[] | select(.receipt_type == "resolution")] | last' "$RECEIPTS")
assert_equals 'clear' "$(jq -r .status <<<"$clear_receipt")" "clear writes a resolution receipt"
assert_equals 'jev-1.13.0' "$(jq -r .requested_model <<<"$clear_receipt")" "receipt carries the pinned requested model"
assert_equals 'jev-1.13.0' "$(jq -r .answering_model <<<"$clear_receipt")" "receipt carries the answering model"
assert_equals 'request-test-123' "$(jq -r .request_id <<<"$clear_receipt")" "receipt carries the response request id"
assert_equals '812' "$(jq -r .usage.input_tokens <<<"$clear_receipt")" "receipt carries token usage"
assert_equals '0.9' "$(jq -r .confidence <<<"$clear_receipt")" "receipt carries confidence"
assert_equals '0.96' "$(jq -r .probabilities.rule_4 <<<"$clear_receipt")" "receipt carries full probabilities"
assert_equals 'cursor' "$(jq -r .chosen_profile.harness <<<"$clear_receipt")" "receipt carries the chosen profile"
brief_hash=$(test_sha256 "$BRIEF")
rules_hash=$(test_sha256 "$BASE_RULES")
assert_equals "$brief_hash" "$(jq -r .brief_sha256 <<<"$clear_receipt")" "brief hash matches an independent computation"
assert_equals "$rules_hash" "$(jq -r .rules_sha256 <<<"$clear_receipt")" "rules snapshot hash matches an independent computation"
assert_not_contains "$(cat "$RECEIPTS")" "$KEY" "receipts never contain the API key"
assert_not_contains "$(cat "$RECEIPTS")" 'SECRET-WHY-TEXT' "receipts never contain rule rationale text"
pass "clear: pinned request plus content-bound, secret-free resolution receipt"

# --- actual dispatch is a separate joined receipt -------------------------------
before_dispatch_bytes=$(wc -c < "$RECEIPTS")
cp "$RECEIPTS" "$TMP_ROOT/receipts-before-dispatch"
TYPESAFE_API_KEY=$KEY run code out err --record-dispatch "$BRIEF" --harness claude --model sonnet --effort high
expect_code 0 "$code" "actual-dispatch receipt exits 0"
assert_equals '' "$out" "actual-dispatch receipt writes no stdout"
dispatch_receipt=$(jq -sc '[.[] | select(.receipt_type == "dispatch")] | last' "$RECEIPTS")
assert_equals "$(jq -r .resolution_id <<<"$clear_receipt")" "$(jq -r .resolution_id <<<"$dispatch_receipt")" "dispatch receipt joins its resolution"
assert_equals '{"harness":"cursor","model":"cursor-grok-4.6-medium","effort":null}' "$(jq -c '.chosen_profile | {harness, model, effort}' <<<"$dispatch_receipt")" "dispatch receipt retains the resolver choice"
assert_equals '{"harness":"claude","model":"sonnet","effort":"high"}' "$(jq -c '.dispatched_profile | {harness, model, effort}' <<<"$dispatch_receipt")" "dispatch receipt carries the profile actually dispatched"
assert_equals 'cursor' "$(jq -r .chosen_profile.provider <<<"$dispatch_receipt")" "chosen_profile keeps the declared provider the rules file carried"
assert_equals 'false' "$(jq -r '(.chosen_profile | {harness, model, effort}) == (.dispatched_profile | {harness, model, effort})' <<<"$dispatch_receipt")" "a dispatch that overrode the resolver disagrees under the projection"
head -c "$before_dispatch_bytes" "$RECEIPTS" > "$TMP_ROOT/receipt-prefix"
cmp "$TMP_ROOT/receipts-before-dispatch" "$TMP_ROOT/receipt-prefix" || fail "the dispatch join left earlier receipt rows unchanged"
pass "actual dispatch is separately recorded and joined without changing earlier rows"

# --- agreement is the {harness, model, effort} projection, not the whole object -
TYPESAFE_API_KEY=$KEY run code out err --record-dispatch "$BRIEF" --harness cursor --model cursor-grok-4.6-medium
expect_code 0 "$code" "dispatching exactly what the resolver chose exits 0"
agreeing_receipt=$(jq -sc '[.[] | select(.receipt_type == "dispatch")] | last' "$RECEIPTS")
assert_equals "$(jq -c '.chosen_profile | {harness, model, effort}' <<<"$agreeing_receipt")" "$(jq -c '.dispatched_profile | {harness, model, effort}' <<<"$agreeing_receipt")" "a dispatch of the chosen profile agrees under the projection"
assert_not_equals "$(jq -c .chosen_profile <<<"$agreeing_receipt")" "$(jq -c .dispatched_profile <<<"$agreeing_receipt")" "whole-object equality would read this agreeing dispatch as a disagreement"
pass "chosen and dispatched profiles are compared by harness, model, and effort"

# --- the dispatch join is by brief content, not by path spelling ---------------
dispatch_count_before_spelling=$(jq -s '[.[] | select(.receipt_type == "dispatch")] | length' "$RECEIPTS")
RELATIVE_BRIEF=$(basename "$BRIEF")
(cd "$TMP_ROOT" && PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="$KEY" \
  "$TOOL" --record-dispatch "./$RELATIVE_BRIEF" --harness claude >/dev/null 2>&1)
spelling_receipt=$(jq -sc '[.[] | select(.receipt_type == "dispatch")] | last' "$RECEIPTS")
assert_equals "$((dispatch_count_before_spelling + 1))" "$(jq -s '[.[] | select(.receipt_type == "dispatch")] | length' "$RECEIPTS")" "a differently spelled brief path still joins its resolution"
assert_equals "$(jq -r .resolution_id <<<"$clear_receipt")" "$(jq -r .resolution_id <<<"$spelling_receipt")" "the join is the brief content hash"
pass "the dispatch join survives any spelling of the same brief path"

# --- brief_path is display only, recorded as the caller spelled it -------------
(cd "$TMP_ROOT" && PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="$KEY" \
  "$TOOL" "./$RELATIVE_BRIEF" >/dev/null 2>&1)
assert_equals "./$RELATIVE_BRIEF" "$(jq -sr '[.[] | select(.receipt_type == "resolution")] | last | .brief_path' "$RECEIPTS")" "brief_path is the path as spelled on the command line"
pass "brief_path records the caller's spelling and nothing else"

# --- a join that does not land says so, once, on stderr -----------------------
EDITED_BRIEF="$TMP_ROOT/edited-brief.md"
printf '# Task\nA brief that was never resolved.\n' > "$EDITED_BRIEF"
dispatch_count_before_miss=$(jq -s '[.[] | select(.receipt_type == "dispatch")] | length' "$RECEIPTS")
TYPESAFE_API_KEY=$KEY run code out err --record-dispatch "$EDITED_BRIEF" --harness claude
expect_code 0 "$code" "a failed join still exits 0"
assert_equals '' "$out" "a failed join writes no stdout"
assert_contains "$err" 'dispatch-resolve: no dispatch receipt' "a failed join names itself on stderr"
assert_contains "$err" "content hash" "a failed join names why it did not land"
assert_equals '1' "$(grep -c 'no dispatch receipt' <<<"$err")" "a failed join reports exactly one line"
assert_not_contains "$err" "$KEY" "the failed-join line never carries the API key"
assert_not_contains "$err" 'SECRET-WHY-TEXT' "the failed-join line never carries rule rationale"
assert_equals "$dispatch_count_before_miss" "$(jq -s '[.[] | select(.receipt_type == "dispatch")] | length' "$RECEIPTS")" "a failed join appends nothing"
TYPESAFE_API_KEY=$KEY run code out err --record-dispatch "$BRIEF" --harness claude
assert_equals '' "$err" "a join that lands stays silent"
pass "a dispatch join that does not land is distinguishable from one that agrees"

# --- the resolve invocation form, reused verbatim for the join -----------------
project_join_before=$(jq -s '[.[] | select(.receipt_type == "dispatch")] | length' "$RECEIPTS")
TYPESAFE_API_KEY=$KEY run code out err --record-dispatch "$BRIEF" --project demo-project --harness claude --model sonnet
expect_code 0 "$code" "--project alongside --record-dispatch is accepted"
assert_equals '' "$err" "--project alongside --record-dispatch reports no failure"
assert_equals "$((project_join_before + 1))" "$(jq -s '[.[] | select(.receipt_type == "dispatch")] | length' "$RECEIPTS")" "--project alongside --record-dispatch records the dispatch"
pass "the documented resolve invocation form still joins when reused after the spawn"

# --- a blocked receipt cannot delay the resolver block ------------------------
reset_log
write_response "$RESPONSE" rule_4 0.9
ln -s "$$" "$HOME_DIR/state/.dispatch-receipts.lock"
blocked_before=$(jq -s 'length' "$RECEIPTS")
ORDERING_OUT="$TMP_ROOT/ordering-stdout"
: > "$ORDERING_OUT"
PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="$KEY" \
  "$TOOL" "$BRIEF" > "$ORDERING_OUT" 2>/dev/null &
resolver_pid=$!
stdout_arrived=no
while kill -0 "$resolver_pid" 2>/dev/null; do
  if [ -s "$ORDERING_OUT" ]; then stdout_arrived=yes; break; fi
  sleep 0.01
done
wait "$resolver_pid"
expect_code 0 "$?" "a receipt blocked behind a live lock exits 0"
assert_equals 'yes' "$stdout_arrived" "the resolver block is readable while the receipt path is still blocked on the lock"
assert_contains "$(cat "$ORDERING_OUT")" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the blocked run still prints its whole block"
assert_equals "$blocked_before" "$(jq -s 'length' "$RECEIPTS")" "a receipt that never gets the lock is dropped, not retried into the output path"
rm -f "$HOME_DIR/state/.dispatch-receipts.lock"
pass "the receipt path is behind the resolver block it must never delay"

# --- a lock left by a dead owner does not stall receipts forever ---------------
reset_log
write_response "$RESPONSE" rule_4 0.9
DEAD_PID=$(bash -c 'echo $$')
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID + 1)); done
ln -s "$DEAD_PID" "$HOME_DIR/state/.dispatch-receipts.lock"
stalled_before=$(jq -s 'length' "$RECEIPTS")
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "a stale lock leaves the resolver exit 0"
assert_equals "$((stalled_before + 1))" "$(jq -s 'length' "$RECEIPTS")" "a lock owned by a dead process is broken and the receipt is written"
assert_equals 'absent' "$([ -L "$HOME_DIR/state/.dispatch-receipts.lock" ] && echo present || echo absent)" "the resolver releases the lock it recovered"
pass "receipt writes recover from a lock whose owner died"

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
assert_equals 'ambiguous' "$(jq -rs '[.[] | select(.receipt_type == "resolution")] | last.status' "$RECEIPTS")" "ambiguous writes a receipt"
pass "ambiguous: confidence below the fixed floor hands the decision back"

# --- escalate: captain approval ------------------------------------------------
reset_log
write_response "$RESPONSE" rule_3 0.95
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "escalate exits 0"
assert_contains "$out" '  status: escalate' "approval-gated rule escalates"
assert_contains "$out" "  reason: rule requires the captain's explicit approval before dispatch" "escalate names the approval gate"
assert_contains "$out" 'candidate: claude:fable  provider=claude  scope=model:fable  remaining=15%  spendPriority=-0.79  runway=projected_exhaustion  bounds=all_models:79%/projected_exhaustion,model:fable:15%/projected_exhaustion  -> eligible' "approval escalation preserves matched candidate evidence"
assert_not_contains "$out" '  profile:' "escalate emits no profile line"
assert_equals 'escalate' "$(jq -rs '[.[] | select(.receipt_type == "resolution")] | last.status' "$RECEIPTS")" "escalate writes a receipt"
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

# --- the answering model is recorded, never an acceptance gate -----------------
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.model = "jev-1.14.0"' "$RESPONSE" > "$TMP_ROOT/drift-response.json"
mv "$TMP_ROOT/drift-response.json" "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "an unexpected answering model exits 0"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "an unexpected answering model does not disable selection"
drift_receipt=$(jq -sc '[.[] | select(.receipt_type == "resolution")] | last' "$RECEIPTS")
assert_equals 'jev-1.13.0' "$(jq -r .requested_model <<<"$drift_receipt")" "the receipt still carries the pinned requested model"
assert_equals 'jev-1.14.0' "$(jq -r .answering_model <<<"$drift_receipt")" "the receipt carries the answering model that actually replied"
pass "answering-model drift is observable in the receipt without gating dispatch"

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
assert_equals 'error' "$(jq -rs '[.[] | select(.receipt_type == "resolution")] | last.status' "$RECEIPTS")" "error writes a receipt"
assert_contains "$(jq -rs '[.[] | select(.receipt_type == "resolution")] | last.reason' "$RECEIPTS")" 'http 429 after' "an error receipt carries the reason the block printed"
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

# --- receipt failures, concurrency, and the fixed size bound -------------------
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code baseline_out baseline_err "$BRIEF"
mv "$RECEIPTS" "$TMP_ROOT/receipts-before-failure"
mkdir "$RECEIPTS"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "receipt write failure leaves resolver exit 0"
normalized_baseline=$(sed -E 's/latency_ms: [0-9]+/latency_ms: N/' <<<"$baseline_out")
normalized_failure=$(sed -E 's/latency_ms: [0-9]+/latency_ms: N/' <<<"$out")
assert_equals "$normalized_baseline" "$normalized_failure" "receipt write failure leaves stdout untouched"
assert_equals '' "$baseline_err" "a receipt that lands says nothing on stderr"
assert_equals 'dispatch-resolve: no resolution receipt for this run' "$err" "receipt write failure names itself on exactly one stderr line"
rmdir "$RECEIPTS"
mv "$TMP_ROOT/receipts-before-failure" "$RECEIPTS"

reset_log
TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=429 run code baseline_out baseline_err "$BRIEF"
assert_contains "$baseline_out" '  status: error' "the 429 baseline is a non-clear outcome"
mv "$RECEIPTS" "$TMP_ROOT/receipts-before-failure"
mkdir "$RECEIPTS"
TYPESAFE_API_KEY=$KEY FAKE_CURL_HTTP=429 run code out err "$BRIEF"
expect_code 0 "$code" "a non-clear receipt failure leaves resolver exit 0"
assert_equals "$(sed -E 's/[0-9]+ ms/N ms/g' <<<"$baseline_out")" "$(sed -E 's/[0-9]+ ms/N ms/g' <<<"$out")" "a non-clear receipt failure leaves stdout untouched"
assert_equals '1' "$(grep -c 'no resolution receipt for this run' <<<"$err")" "a non-clear receipt failure names itself on exactly one stderr line"
assert_contains "$err" 'dispatch-resolve: error (http 429' "the outcome's own stderr line is still there"
assert_not_contains "$err" "$KEY" "the dropped-receipt line never carries the API key"
assert_not_contains "$err" 'SECRET-WHY-TEXT' "the dropped-receipt line never carries rule rationale"
rmdir "$RECEIPTS"
mv "$TMP_ROOT/receipts-before-failure" "$RECEIPTS"
reset_log
write_response "$RESPONSE" rule_4 0.9

dispatch_count_before=$(jq -s '[.[] | select(.receipt_type == "dispatch")] | length' "$RECEIPTS")
CONCURRENT_ERR="$TMP_ROOT/concurrent-stderr"
: > "$CONCURRENT_ERR"
for _ in 1 2 3; do
  PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="$KEY" \
    "$TOOL" --record-dispatch "$BRIEF" --harness claude --model sonnet --effort high \
    >/dev/null 2>>"$CONCURRENT_ERR" &
done
wait
dispatch_count_after=$(jq -s '[.[] | select(.receipt_type == "dispatch")] | length' "$RECEIPTS")
concurrent_appended=$((dispatch_count_after - dispatch_count_before))
concurrent_dropped=$(grep -c 'no dispatch receipt' "$CONCURRENT_ERR")
assert_equals '3' "$((concurrent_appended + concurrent_dropped))" "each concurrent run either appends its dispatch record or says it dropped one"
assert_equals '' "$(grep -v 'no dispatch receipt' "$CONCURRENT_ERR")" "a concurrent run has no third outcome to report"
jq -e -s 'all(.[]; type == "object")' "$RECEIPTS" >/dev/null || fail "concurrent receipt appends remain valid JSONL"
assert_equals "$(wc -l < "$RECEIPTS")" "$(jq -s 'length' "$RECEIPTS")" "concurrent appends leave no partial or interleaved line"

assert_not_contains "$(cat "$RECEIPTS")" "$KEY" "concurrent receipts never contain the API key"
assert_not_contains "$(cat "$RECEIPTS")" 'SECRET-WHY-TEXT' "concurrent receipts never contain rule rationale"
pass "receipt writes are best-effort, concurrent-safe, and append-only"

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
