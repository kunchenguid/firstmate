#!/usr/bin/env bash
# Behavior tests for bin/fm-jev.sh, the lean worker-facing Jev command.
#
# A fake curl on PATH records the request body and the Authorization header
# read from file descriptor 3, then answers with a canned TypeSafe response.
# No case touches the network. Key discovery runs against disposable copies of
# the command and temporary homes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
HOME_DIR="$TMP_ROOT/home"
RESPONSE="$TMP_ROOT/response.json"
KEY='ts-cli-test-key-0123456789'
JEV="$ROOT/bin/fm-jev.sh"
mkdir -p "$LOG" "$HOME_DIR/state"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: records the request URL, stdin body, and fd 3 header, then answers
# with FAKE_CURL_RESPONSE and FAKE_CURL_HTTP.
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY+x}" ] \
  || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ]; then
  printf 'provider-key-present\n' > "${FAKE_CURL_LOG:?}/curl-env"
else
  printf 'clean\n' > "${FAKE_CURL_LOG:?}/curl-env"
fi
out=''
url=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -X) shift 2; url=$1; shift ;;
    *) shift ;;
  esac
done
printf '%s' "$url" > "$FAKE_CURL_LOG/url"
cat > "${FAKE_CURL_LOG:?}/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE"

respond() {
  printf '%s\n' "$1" > "$RESPONSE"
}

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# run_jev <exit-var> <out-var> <err-var> [args...] - runs with the key in the
# environment and FM_HOME on the temporary home; stdin passes through.
run_jev() {
  local __code=$1 __out=$2 __err=$3 __o __e __c
  local invoke_key=${JEV_TEST_API_KEY-$KEY} invoke_home=${JEV_TEST_HOME:-$HOME_DIR}
  shift 3
  __o="$TMP_ROOT/run.out"
  __e="$TMP_ROOT/run.err"
  PATH="$FAKEBIN:$PATH" TYPESAFE_API_KEY="$invoke_key" FM_HOME="$invoke_home" \
    "$JEV" "$@" > "$__o" 2> "$__e"
  __c=$?
  printf -v "$__code" '%s' "$__c"
  printf -v "$__out" '%s' "$(cat "$__o")"
  printf -v "$__err" '%s' "$(cat "$__e")"
}

test_help_is_short_and_complete() {
  local out lines top_help
  out=$("$JEV" yes --help)
  top_help=$("$JEV" --help) || fail "top-level --help should exit 0"
  assert_equals "$top_help" "$out" "top-level --help prints the CLI interface"
  lines=$(printf '%s\n' "$out" | wc -l)
  lines=${lines// /}
  [ "$lines" -lt 15 ] || fail "--help is $lines lines, want under 15"
  for word in pick yes score batch --json ESCALATE TYPESAFE_API_KEY; do
    assert_contains "$out" "$word" "--help names $word"
  done
  assert_contains "$out" 'First "=" splits label from meaning' "--help documents option parsing"
  assert_contains "$out" "4096 bytes total" "--help documents the combined input cap"
  assert_not_contains "$out" "--id" "--help omits the removed id option"
  assert_not_contains "$out" "--min" "--help omits the removed threshold option"
  assert_not_contains "$out" "OPENROUTER_API_KEY" "--help does not advertise an OpenRouter route"
  assert_contains "$out" "FM_HOME/.env" "--help documents the direct-call home .env key source"
  assert_contains "$out" "workers use the firstmate home .env" "--help documents the worker key source"
  assert_contains "$out" "caller must pass only task facts, never personal data or private-vault content" "--help states the caller's data policy"
  assert_contains "$out" "safety net only" "--help limits the refusal to a safety net"
  assert_contains "$out" "same OS user with full file access" "--help explains worker filesystem access"
  assert_not_contains "$out" "typesafe-key" "--help does not advertise a persistent key cache"
  pass "fm-jev.sh: --help is the whole interface in under 15 lines"
}

test_pick_answers_one_line() {
  local code out err
  reset_log
  respond '{"model":"jev-1.13.0","answers":{"pick":{"type":"choice","choice":"PlacementWiki","confidence":0.94,"probabilities":{"PlacementWiki":0.96,"FinanzWiki":0.04}}},"usage":{"input_tokens":120,"output_tokens":9}}'
  run_jev code out err pick "topic: trainee hiring" "Which vault?" PlacementWiki "FinanzWiki=money and budgets"
  assert_equals "$code" 0 "a confident pick exits 0"
  assert_equals "$out" "pick: PlacementWiki p=0.96 conf=0.94" "a pick prints one TOON line"
  assert_equals "$err" "" "a confident pick prints nothing on stderr"
  assert_equals "$(jq -c '.questions.pick' "$LOG/body")" \
    '{"type":"choice","instructions":"Which vault?","criteria":{"PlacementWiki":"PlacementWiki","FinanzWiki":"money and budgets"}}' \
    "a pick becomes one choice question with label=meaning criteria"
  assert_equals "$(jq -r '.state' "$LOG/body")" "topic: trainee hiring" "the state is sent as a string"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY" "the key travels only as the fd 3 header"
  pass "fm-jev.sh: pick sends one choice question and prints one line"
}

test_key_stays_out_of_child_environments() {
  local code out err real_jq openrouter_key
  real_jq=$(command -v jq)
  export FM_JEV_TEST_REAL_JQ=$real_jq
  cat > "$FAKEBIN/jq" <<'SH'
#!/usr/bin/env bash
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY+x}" ] \
  || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ]; then
  printf 'provider-key-present\n' >> "${FAKE_CURL_LOG:?}/jq-env"
else
  printf 'clean\n' >> "${FAKE_CURL_LOG:?}/jq-env"
fi
exec "${FM_JEV_TEST_REAL_JQ:?}" "$@"
SH
  chmod +x "$FAKEBIN/jq"
  openrouter_key='or-cli-child-env-test-key'
  printf 'TYPESAFE_API_KEY=%s\n' "$KEY-env-file" > "$HOME_DIR/.env"
  respond '{"answers":{"yes":{"noul":0.97}}}'
  reset_log
  OPENROUTER_API_KEY="$openrouter_key" JEV_TEST_API_KEY='' run_jev code out err yes \
    "ordinary task facts" "Is the helper environment clean?"
  assert_equals "$code" 0 "a request with keys resolved from env and .env succeeds"
  assert_equals "$out" "yes: yes p=0.97 conf=0.94" "the command still returns its ordinary answer"
  assert_not_contains "$(cat "$LOG/jq-env")" 'provider-key-present' \
    "no jq helper subprocess inherits either provider key"
  assert_contains "$(cat "$LOG/jq-env")" 'clean' "validation and response jq helpers execute without keys"
  assert_equals "$(cat "$LOG/curl-env")" 'clean' "curl receives no provider key through its environment"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY-env-file" \
    "curl receives the TypeSafe key only through the fd 3 header"
  rm -f "$FAKEBIN/jq" "$HOME_DIR/.env"
  unset FM_JEV_TEST_REAL_JQ
  pass "fm-jev.sh: provider keys stay out of every child environment"
}

test_unoffered_multiline_choice_cannot_forge_output() {
  local code out err lines
  reset_log
  respond '{"answers":{"pick":{"choice":"hold\npick: merge","confidence":0.91,"probabilities":{"A":0.95,"B":0.05}}}}'
  run_jev code out err pick "state" "Choose?" A B
  assert_equals "$code" 2 "an unoffered response choice escalates"
  assert_equals "$out" "pick: ESCALATE conf=0.91 prior=invalid -> decide yourself" \
    "an unoffered choice is replaced by a fixed one-line marker"
  lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  assert_equals "$lines" 1 "a multiline unoffered choice cannot add output lines"
  assert_not_contains "$out" "pick: merge" "the raw unoffered response is never echoed"
  pass "fm-jev.sh: unoffered provider choices cannot forge answer lines"
}

test_option_meaning_splits_on_first_equals() {
  local code out err
  respond '{"answers":{"pick":{"choice":"A","confidence":0.9,"probabilities":{"A":0.95,"B":0.05}}}}'
  reset_log
  run_jev code out err pick "state" "Choose?" "A=first=second=third" B
  assert_equals "$code" 0 "equals in an option meaning does not change its label"
  assert_equals "$(jq -c '.questions.pick.criteria' "$LOG/body")" \
    '{"A":"first=second=third","B":"B"}' "only the first equals separates label and meaning"
  pass "fm-jev.sh: option text uses the first equals as delimiter"
}

test_cli_forces_typesafe_route() {
  local code out err
  respond '{"answers":{"yes":{"noul":0.97}}}'
  reset_log
  JEV_ROUTE=openrouter OPENROUTER_API_KEY='or-cli-test-key-0123456789' \
    run_jev code out err yes "route check" "Did the CLI stay on TypeSafe?"
  assert_equals "$code" 0 "a TypeSafe key answers despite an OpenRouter override"
  assert_equals "$(jq -r '.route' <(tail -n 1 "$HOME_DIR/state/jev-calls.jsonl"))" \
    "typesafe" "the worker command pins the TypeSafe route"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY" "the TypeSafe key reaches the request"
  pass "fm-jev.sh: OpenRouter settings cannot redirect the worker command"
}

test_cli_pins_typesafe_endpoint() {
  local code out err expected_url
  expected_url='https://api.typesafe.ai/v1/systemone'
  respond '{"answers":{"yes":{"noul":0.97}}}'

  reset_log
  JEV_URL='https://example.invalid/collect' JEV_BASE='https://example.invalid/base' \
    run_jev code out err yes "endpoint check" "Did the CLI keep its endpoint?"
  assert_equals "$code" 0 "a caller URL override does not block the request"
  assert_equals "$(cat "$LOG/url")" "$expected_url" "the CLI pins JEV_URL to the TypeSafe production endpoint"

  reset_log
  JEV_BASE='https://example.invalid/base' \
    run_jev code out err yes "endpoint check" "Did the CLI ignore JEV_BASE?"
  assert_equals "$code" 0 "a caller base override does not block the request"
  assert_equals "$(cat "$LOG/url")" "$expected_url" "the CLI ignores an environment JEV_BASE"

  printf 'JEV_URL=https://example.invalid/env-file\nJEV_BASE=https://example.invalid/env-file-base\n' > "$HOME_DIR/.env"
  reset_log
  run_jev code out err yes "endpoint check" "Did the CLI ignore .env endpoints?"
  assert_equals "$code" 0 "home .env endpoint overrides do not block the request"
  assert_equals "$(cat "$LOG/url")" "$expected_url" "the CLI ignores JEV_URL and JEV_BASE in the home .env"
  rm -f "$HOME_DIR/.env"
  pass "fm-jev.sh: destination settings cannot redirect the TypeSafe credential"
}

test_yes_and_score_lines() {
  local code out err
  respond '{"answers":{"yes":{"noul":0.97}}}'
  reset_log
  run_jev code out err yes s q
  assert_equals "$code" 0 "plain yes input passes the privacy guard"
  assert_equals "$(jq -r '.state' "$LOG/body")" "s" "plain yes input reaches the mock transport"

  respond '{"answers":{"yes":{"type":"noul","noul":0.02}}}'
  run_jev code out err yes "diff touches docs only" "Does the diff change runtime code?"
  assert_equals "$code" 0 "a clear yes/no exits 0"
  assert_equals "$out" "yes: no p=0.02 conf=0.96" "yes/no confidence is estimated as 2*|p-0.5|"
  assert_equals "$(jq -c '.questions.yes' "$LOG/body")" \
    '{"type":"noul","instructions":"Does the diff change runtime code?"}' "yes becomes a noul question"

  respond '{"answers":{"score":{"type":"score","score":1,"confidence":0.81,"probabilities":{"0":0.1,"1":0.8,"2":0.1}}}}'
  run_jev code out err score "one flaky test quarantined" "How risky is merging?" routine "worth a look" incident
  assert_equals "$code" 0 "a confident score exits 0"
  assert_equals "$out" "score: worth a look s=1 p=0.8 conf=0.81" "a score names its most probable level"
  assert_equals "$(jq -c '.questions.score.criteria' "$LOG/body")" '["routine","worth a look","incident"]' \
    "score levels are sent in order"

  respond '{"answers":{"score":{"type":"score","score":1.43,"confidence":0.6}}}'
  run_jev code out err score "one issue blocks progress" "How severe is it?" Cosmetic Workaround Blocking
  assert_equals "$code" 2 "a score without probabilities escalates"
  assert_equals "$out" "score: ESCALATE conf=na prior=unknown -> decide yourself" \
    "a probability-free score never guesses a label"
  pass "fm-jev.sh: yes and score print one line each"
}

test_batch_state_json_text_remains_a_string() {
  local code out err state batch_json
  for state in '{"topic":"task facts"}' '["task facts"]'; do
    batch_json=$(jq -cn --arg state "$state" \
      '{state:$state,questions:[{id:"state-json",type:"yes",q:"Is this preserved?"}]}')
    respond '{"answers":{"state-json":{"noul":0.97}}}'
    reset_log
    run_jev code out err batch <<<"$batch_json"
    assert_equals "$code" 0 "JSON-looking state text is answered as a string"
    assert_equals "$(jq -r '.state | type' "$LOG/body")" string \
      "object or array text remains a JSON string"
    assert_equals "$(jq -r '.state' "$LOG/body")" "$state" \
      "JSON-looking state text is not reparsed"
  done
  pass "fm-jev.sh: JSON-looking state remains a JSON string"
}

test_batch_state_preserves_trailing_newlines() {
  local code out err state batch_json expected_state
  state=$'task facts with trailing newlines\n\n'
  batch_json=$(jq -cn --arg state "$state" \
    '{state:$state,questions:[{id:"newline",type:"yes",q:"Is this preserved?"}]}')
  respond '{"answers":{"newline":{"noul":0.97}}}'
  reset_log
  run_jev code out err batch <<<"$batch_json"
  assert_equals "$code" 0 "a batch with trailing state newlines is answered"
  expected_state=$(printf '%s' "$state" | base64 | tr -d '\n')
  assert_equals "$(jq -r '.state | @base64' "$LOG/body")" "$expected_state" \
    "the request state preserves every trailing newline"
  pass "fm-jev.sh: request construction preserves trailing state newlines"
}

test_batch_one_call_many_lines() {
  local code out err
  reset_log
  respond '{"answers":{"vault":{"choice":"A","confidence":0.9,"probabilities":{"A":0.95,"B":0.04}},"private":{"noul":0.9},"q3":{"score":0.1,"confidence":0.7,"probabilities":{"0":0.85,"1":0.15}}}}'
  run_jev code out err batch <<'JSON'
{"state":"s","questions":[
  {"id":"vault","type":"pick","q":"Which?","opts":["A=first","B=second"]},
  {"id":"private","type":"yes","q":"Private?"},
  {"type":"score","q":"How big?","opts":["small","large"]}]}
JSON
  assert_equals "$code" 0 "a confident batch exits 0"
  assert_equals "$out" "$(printf '%s\n' 'vault: A p=0.95 conf=0.9' 'private: yes p=0.9 conf=0.8' 'q3: small s=0.1 p=0.85 conf=0.7')" \
    "a batch prints one line per question in input order"
  assert_equals "$(jq -c '.questions | keys_unsorted' "$LOG/body")" '["vault","private","q3"]' \
    "a batch sends every question in one request"
  assert_equals "$(jq -c '.questions.vault.criteria' "$LOG/body")" '{"A":"first","B":"second"}' \
    "batch options accept label=meaning strings"
  pass "fm-jev.sh: batch asks several questions in one call"
}

test_option_limits_refuse_before_sending() {
  local code out err batch_json i
  local -a pick_opts=() score_opts=()
  for ((i = 0; i < 256; i++)); do pick_opts+=("option$i"); done
  for ((i = 0; i < 11; i++)); do score_opts+=("level$i"); done

  reset_log
  run_jev code out err score "s" "How large?" "${score_opts[@]}"
  assert_equals "$code" 1 "a single score with eleven levels is refused"
  assert_contains "$err" "at most 10 levels" "the single score limit is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "the single score limit prints one stderr line"
  assert_equals "$out" "" "the single score limit prints no answer"
  assert_absent "$LOG/body" "an over-limit single score is never sent"

  reset_log
  run_jev code out err batch <<'JSON'
{"state":"s","questions":[{"id":"levels","type":"score","q":"How large?","opts":["L0","L1","L2","L3","L4","L5","L6","L7","L8","L9","L10"]}]}
JSON
  assert_equals "$code" 1 "a batch score with eleven levels is refused"
  assert_contains "$err" "at most 10 levels" "the batch score limit is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "the batch score limit prints one stderr line"
  assert_equals "$out" "" "the batch score limit prints no answer"
  assert_absent "$LOG/body" "an over-limit batch score is never sent"

  reset_log
  run_jev code out err pick "s" "Choose?" "${pick_opts[@]}"
  assert_equals "$code" 1 "a single pick with 256 options is refused"
  assert_contains "$err" "at most 255 options" "the single pick limit is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "the single pick limit prints one stderr line"
  assert_equals "$out" "" "the single pick limit prints no answer"
  assert_absent "$LOG/body" "an over-limit single pick is never sent"

  batch_json=$(jq -cn '{state:"s",questions:[{id:"choices",type:"pick",q:"Choose?",opts:[range(0;256) | "option" + tostring]}]}')
  reset_log
  run_jev code out err batch <<<"$batch_json"
  assert_equals "$code" 1 "a batch pick with 256 options is refused"
  assert_contains "$err" "at most 255 options" "the batch pick limit is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "the batch pick limit prints one stderr line"
  assert_equals "$out" "" "the batch pick limit prints no answer"
  assert_absent "$LOG/body" "an over-limit batch pick is never sent"
  pass "fm-jev.sh: TypeSafe option limits apply to single and batch requests"
}

test_escalation_exits_two() {
  local code out err
  respond '{"answers":{"pick":{"choice":"A","confidence":0.9}}}'
  run_jev code out err pick "state" "Next?" A B
  assert_equals "$code" 2 "a pick without probabilities escalates"
  assert_equals "$out" "pick: ESCALATE conf=0.9 prior=unknown -> decide yourself" \
    "a probability-free pick never returns its choice"
  assert_equals "$err" "" "a probability-free pick escalates without an error"

  respond '{"answers":{"pick":{"choice":"merge","confidence":0.31,"probabilities":{"merge":0.55,"hold":0.45}}}}'
  run_jev code out err pick "state" "Next?" merge hold
  assert_equals "$code" 2 "a low-confidence verdict exits 2"
  assert_equals "$out" "pick: ESCALATE conf=0.31 prior=merge -> decide yourself" "an escalation names its prior"

  respond '{"answers":{"yes":{"noul":0.6}}}'
  run_jev code out err yes "state" "Done?"
  assert_equals "$code" 2 "a near-even yes/no escalates"
  assert_equals "$out" "yes: ESCALATE conf=0.2 prior=yes -> decide yourself" "a yes/no escalation reports its estimate"
  pass "fm-jev.sh: low confidence escalates with exit 2"
}

test_batch_nul_values_are_refused() {
  local code out err batch_json
  for batch_json in \
    '{"state":"task\u0000facts","questions":[{"id":"n","type":"yes","q":"Done?"}]}' \
    '{"state":"task facts","questions":[{"id":"n","type":"yes","q":"Done?\u0000"}]}' \
    '{"state":"task facts","questions":[{"id":"n","type":"pick","q":"Choose?","opts":["A\u0000=first","B"]}]}' \
    '{"state":"task facts","questions":[{"id":"n\u0000","type":"yes","q":"Done?"}]}'; do
    reset_log
    run_jev code out err batch <<<"$batch_json"
    assert_equals "$code" 1 "NUL in any batch text field is refused"
    assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
      "NUL refusal prints exactly one stderr line"
    assert_equals "$out" "" "NUL refusal produces no answer"
    assert_absent "$LOG/body" "NUL input is never sent"
  done
  pass "fm-jev.sh: NUL in state, questions, options, and IDs is refused"
}

test_tied_top_probabilities_escalate() {
  local code out err
  respond '{"answers":{"pick":{"choice":"A","confidence":0.9,"probabilities":{"A":0.5,"B":0.5}}}}'
  run_jev code out err pick "state" "Choose?" A B
  assert_equals "$code" 2 "a pick with tied top probabilities escalates"
  assert_contains "$out" "ESCALATE" "a tied pick prints the escalation marker"
  assert_equals "$err" "" "a tied pick escalates without an error"

  respond '{"answers":{"score":{"score":0.5,"confidence":0.9,"probabilities":{"0":0.5,"1":0.5}}}}'
  run_jev code out err score "state" "How severe?" low high
  assert_equals "$code" 2 "a score with tied top probabilities escalates"
  assert_contains "$out" "ESCALATE" "a tied score prints the escalation marker"
  assert_equals "$err" "" "a tied score escalates without an error"
  pass "fm-jev.sh: tied top probabilities escalate for picks and scores"
}

test_split_score_distribution_escalates_by_design() {
  local code out err
  respond '{"answers":{"score":{"score":4.08,"confidence":0.9,"probabilities":{"0":0.49,"1":0,"2":0,"3":0,"4":0,"5":0,"6":0,"7":0,"8":0.51}}}}'
  run_jev code out err score "split distribution" "How severe?" \
    level0 level1 level2 level3 level4 level5 level6 level7 level8
  assert_equals "$code" 2 "a split score distribution escalates by design"
  assert_equals "$out" "score: ESCALATE conf=0.9 prior=level8 -> decide yourself" \
    "a weighted mean between distant peaks escalates by design"
  assert_equals "$err" "" "a split score distribution escalates without an error"
  pass "fm-jev.sh: a split score distribution escalates by design"
}

test_json_prints_raw_response() {
  local code out err raw
  raw='{"model":"jev-1.13.0","answers":{"yes":{"type":"noul","noul":0.97}},"usage":{"input_tokens":5,"output_tokens":2}}'
  respond "$raw"
  run_jev code out err yes --json "state" "Done?"
  assert_equals "$code" 0 "--json keeps the exit contract"
  assert_equals "$(printf '%s' "$out" | jq -c .)" "$raw" "--json prints the full response"
  pass "fm-jev.sh: --json prints the raw response"
}

test_errors_exit_one_with_one_line() {
  local code out err
  respond '{"error":"overloaded"}'
  FAKE_CURL_HTTP=529 run_jev code out err yes "state" "Done?"
  assert_equals "$code" 1 "a transport failure exits 1"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 "a transport failure prints one stderr line"
  assert_contains "$err" "http 529" "the reason names the failure"
  assert_contains "$err" "decide yourself" "the reason says what to do"
  assert_equals "$out" "" "a failure prints nothing on stdout"

  respond '{"answers":{}}'
  run_jev code out err yes "state" "Done?"
  assert_equals "$code" 1 "a missing answer is an error, never a silent low confidence"
  assert_contains "$err" "missing answer for yes" "the missing answer is named"

  respond '{"answers":{"pick":{"choice":"C","confidence":0.9}}}'
  run_jev code out err pick "state" "Choose?" A B
  assert_equals "$code" 2 "a pick outside the offered options escalates"
  assert_equals "$out" "pick: ESCALATE conf=0.9 prior=invalid -> decide yourself" \
    "an unoffered pick is never returned as a success"
  assert_equals "$err" "" "an unoffered pick escalates without an error"

  respond '{"answers":{"pick":{"choice":"A","confidence":0.9,"probabilities":{"A":0.05,"B":0.95}}}}'
  run_jev code out err pick "state" "Choose?" A B
  assert_equals "$code" 2 "a pick below the maximum probability escalates"
  assert_equals "$out" "pick: ESCALATE conf=0.9 prior=A -> decide yourself" \
    "a lower-probability pick is not returned as a success"
  assert_equals "$err" "" "a probability mismatch escalates without an error"

  respond '{"answers":{"score":{"score":1,"confidence":0.9,"probabilities":{"0":0.05,"9":0.95}}}}'
  run_jev code out err score "state" "How severe?" low medium high
  assert_equals "$code" 1 "a score distribution with an out-of-range index is rejected"
  assert_contains "$err" "probability keys do not match offered levels" "the malformed score map is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 "an invalid score map prints one stderr line"
  assert_equals "$out" "" "a malformed score prints no answer"

  respond '{"answers":{"pick":{"choice":"A","confidence":0.9,"probabilities":{"A":0.1,"B":0.1,"unexpected":0.8}}}}'
  run_jev code out err pick "state" "Choose?" A B C
  assert_equals "$code" 1 "a pick map with an unoffered label is rejected"
  assert_contains "$err" "probability keys do not match offered options" "the malformed pick map is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 "an invalid pick map prints one stderr line"
  assert_equals "$out" "" "an invalid pick map prints no answer"

  respond '{"answers":{"pick":{"choice":"A","confidence":0.9,"probabilities":{"A":0.1,"B":0.1}}}}'
  run_jev code out err pick "state" "Choose?" A B
  assert_equals "$code" 1 "a pick map that does not sum to one is rejected"
  assert_contains "$err" "must sum to approximately 1" "the malformed pick sum is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 "an invalid pick sum prints one stderr line"
  assert_equals "$out" "" "an invalid pick sum prints no answer"

  respond '{"answers":{"score":{"score":1,"confidence":0.9,"probabilities":{"0":0.8,"1":0.1,"2":0.0}}}}'
  run_jev code out err score "state" "How severe?" low medium high
  assert_equals "$code" 1 "a score map that does not sum to one is rejected"
  assert_contains "$err" "must sum to approximately 1" "the malformed score sum is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 "an invalid score sum prints one stderr line"
  assert_equals "$out" "" "an invalid score sum prints no answer"

  respond '{"answers":{"score":{"score":9,"confidence":0.9}}}'
  run_jev code out err score "state" "How severe?" low medium high
  assert_equals "$code" 2 "a probability-free score outside the offered range escalates"
  assert_equals "$out" "score: ESCALATE conf=na prior=unknown -> decide yourself" \
    "an out-of-range score without probabilities never guesses a label"
  assert_equals "$err" "" "a probability-free out-of-range score escalates without an error"

  respond '{"answers":{"score":{"score":9,"confidence":0.9,"probabilities":{"0":0.05,"1":0.05,"2":0.9}}}}'
  run_jev code out err score "state" "How severe?" low medium high
  assert_equals "$code" 2 "an out-of-range score with valid probabilities escalates"
  assert_equals "$out" "score: ESCALATE conf=0.9 prior=high -> decide yourself" \
    "an out-of-range score is not reported as a success"
  assert_equals "$err" "" "an out-of-range score escalates without an error"

  respond '{"answers":{"score":{"score":0.2,"confidence":0.9,"probabilities":{"0":0.05,"1":0.9,"2":0.05}}}}'
  run_jev code out err score "state" "How severe?" low medium high
  assert_equals "$code" 2 "a score that rounds away from the probability maximum escalates"
  assert_equals "$out" "score: ESCALATE conf=0.9 prior=medium -> decide yourself" \
    "an inconsistent score is not reported as a success"
  assert_equals "$err" "" "an inconsistent score escalates without an error"

  respond '{"answers":{"score":{"score":1.4,"confidence":0.9,"probabilities":{"0":0.1,"1":0.8,"2":0.1}}}}'
  run_jev code out err score "state" "How severe?" low medium high
  assert_equals "$code" 2 "a score inconsistent with its weighted value escalates"
  assert_equals "$out" "score: ESCALATE conf=0.9 prior=medium -> decide yourself" \
    "a score inconsistent with its weighted value is not returned as a success"
  assert_equals "$err" "" "a weighted-value mismatch escalates without an error"

  respond '{"answers":{"yes":{"noul":1.5}}}'
  run_jev code out err yes "state" "Is the value in range?"
  assert_equals "$code" 1 "a yes probability above one is rejected"
  assert_contains "$err" "probability must be within 0..1" "the malformed probability is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "an invalid yes probability prints one stderr line"
  assert_equals "$out" "" "an invalid yes probability prints no answer"

  respond '{"answers":{"pick":{"choice":"A","confidence":1.2}}}'
  run_jev code out err pick "state" "Choose?" A B
  assert_equals "$code" 1 "a confidence above one is rejected"
  assert_contains "$err" "confidence must be within 0..1" "the malformed confidence is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "an invalid confidence prints one stderr line"
  assert_equals "$out" "" "an invalid confidence prints no answer"

  respond '{"answers":{"score":{"score":1,"confidence":0.9,"probabilities":{"0":0.05,"1":1.2,"2":0.0}}}}'
  run_jev code out err score "state" "How severe?" low medium high
  assert_equals "$code" 1 "a probability above one is rejected"
  assert_contains "$err" "probability outside 0..1" "the malformed probability is explained"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "an invalid score probability prints one stderr line"
  assert_equals "$out" "" "an invalid score probability prints no answer"

  for args in "frob" "-h" "pick s q only" "yes s" "--min 2 yes s q" "--id x pick s q A B" \
    "--json yes s q" "yes --min 0.7 s q" "yes s --json q"; do
    # shellcheck disable=SC2086 # Deliberate word splitting of the case args.
    run_jev code out err $args
    assert_equals "$code" 1 "usage error '$args' exits 1"
    assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 "usage error '$args' is one line"
  done
  run_jev code out err batch <<'JSON'
{"state":"s","questions":[{"id":"a","type":"yes","q":"x"},{"id":"a","type":"yes","q":"y"}]}
JSON
  assert_equals "$code" 1 "duplicate batch ids exit 1"
  assert_contains "$err" "ids must be unique" "the duplicate is explained"

  reset_log
  run_jev code out err batch <<'JSON'
{"state":"s","questions":[{"id":false,"type":"yes","q":"x"}]}
JSON
  assert_equals "$code" 1 "a non-string batch id exits 1"
  assert_contains "$err" "question 1 id must match" "the invalid batch id is explained without echoing the ID"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "a non-string batch id prints one stderr line"
  assert_absent "$LOG/body" "a non-string batch id is never sent"

  reset_log
  run_jev code out err batch <<'JSON'
{"state":"s","questions":[{"id":"q","type":"pick","q":"Choose?","opts":{"A":"first","B":"second"}}]}
JSON
  assert_equals "$code" 1 "batch object-map options are rejected"
  assert_contains "$err" "opts must be an array of strings" "the batch option format is explained"
  assert_absent "$LOG/body" "invalid batch options are never sent"
  pass "fm-jev.sh: errors exit 1 with one line"
}

test_option_control_characters_are_refused() {
  local code out err esc del c1 batch_json
  esc=$'\033'
  del=$'\177'
  c1=$'\u009B'

  reset_log
  run_jev code out err pick "state" "Choose?" "${esc}[2J=clear screen" B
  assert_equals "$code" 1 "an ESC control in a pick label is refused"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "a pick-label control refusal prints one stderr line"
  assert_contains "$err" "option labels and meanings must not contain control characters" \
    "the pick-label control refusal is explained"
  assert_absent "$LOG/body" "a pick label with terminal control is never sent"

  reset_log
  run_jev code out err score "state" "How severe?" low "high=${del}meaning"
  assert_equals "$code" 1 "a DEL control in a score meaning is refused"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "a score-meaning control refusal prints one stderr line"
  assert_contains "$err" "option labels and meanings must not contain control characters" \
    "the score-meaning control refusal is explained"
  assert_absent "$LOG/body" "a score meaning with terminal control is never sent"

  reset_log
  run_jev code out err batch <<'JSON'
{"state":"s","questions":[{"id":"pick","type":"pick","q":"Choose?","opts":["A\u0000=meaning","B"]}]}
JSON
  assert_equals "$code" 1 "a NUL control in a batch label is refused"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "a batch-label control refusal prints one stderr line"
  assert_contains "$err" "option labels and meanings must not contain control characters" \
    "the batch-label control refusal is explained"
  assert_absent "$LOG/body" "a batch label with NUL is never sent"

  reset_log
  run_jev code out err pick "state" "Choose?" "A${c1}=meaning" B
  assert_equals "$code" 1 "a C1 control in a pick label is refused"
  assert_contains "$err" "option labels and meanings must not contain control characters" \
    "the C1 pick-label refusal is explained"
  assert_absent "$LOG/body" "a C1 pick label is never sent"

  reset_log
  run_jev code out err score "state" "How severe?" low "high=${c1}meaning"
  assert_equals "$code" 1 "a C1 control in a score meaning is refused"
  assert_contains "$err" "option labels and meanings must not contain control characters" \
    "the C1 score-meaning refusal is explained"
  assert_absent "$LOG/body" "a C1 score meaning is never sent"

  batch_json=$(jq -cn --arg id "control${c1}" \
    '{state:"s",questions:[{id:$id,type:"yes",q:"Done?"}]}')
  reset_log
  run_jev code out err batch <<<"$batch_json"
  assert_equals "$code" 1 "a C1 control in a batch ID is refused"
  assert_contains "$err" "question 1 id must match" "the C1 ID refusal uses its position"
  assert_absent "$LOG/body" "a C1 batch ID is never sent"
  pass "fm-jev.sh: option labels, meanings, and IDs reject C0, DEL, and C1 controls"
}

test_privacy_guard_refuses_before_sending() {
  local code out err big openrouter_key large_state large_question large_meaning private_key boundary_state batch_json credential configured_state yaml_state json_credential nested_secret_state nested_yaml
  respond '{"answers":{"yes":{"noul":0.9}}}'
  reset_log
  big=$(head -c 4097 /dev/zero | tr '\0' a)
  run_jev code out err yes "$big" "Done?"
  assert_equals "$code" 1 "state over 4096 bytes is refused"
  assert_contains "$err" "4096-byte cap" "the cap is named"
  assert_absent "$LOG/body" "an oversized state is never sent"

  large_state=$(head -c 1000 /dev/zero | tr '\0' s)
  large_question=$(head -c 1000 /dev/zero | tr '\0' q)
  large_meaning=$(head -c 1100 /dev/zero | tr '\0' m)
  reset_log
  run_jev code out err pick "$large_state" "$large_question" "A=$large_meaning" "B=$large_meaning"
  assert_equals "$code" 1 "combined state, question, and option text over 4096 bytes is refused"
  assert_contains "$err" "4096-byte cap" "the aggregate cap is named"
  assert_absent "$LOG/body" "oversized combined input is never sent"

  configured_state=$(head -c 129 /dev/zero | tr '\0' s)
  reset_log
  JEV_STATE_MAX_BYTES=128 run_jev code out err yes "$configured_state" "Done?"
  assert_equals "$code" 1 "a caller-configured 128-byte state cap is enforced"
  assert_contains "$err" "could not screen the input" "the configured state cap refuses input"
  assert_absent "$LOG/body" "state over the caller-configured cap is never sent"

  boundary_state=$(head -c 4095 /dev/zero | tr '\0' s)
  batch_json=$(jq -cn --arg state "$boundary_state" '{state:$state,questions:[{id:"i",type:"yes",q:"q"}]}')
  reset_log
  run_jev code out err batch <<<"$batch_json"
  assert_equals "$code" 1 "batch ids count toward the aggregate input cap"
  assert_contains "$err" "4096-byte cap" "the batch id cap is named"
  assert_absent "$LOG/body" "an oversized batch including its id is never sent"

  private_key=$(printf '%s\n' \
    '-----BEGIN RSA PRIVATE KEY-----' \
    'MIIEpAIBAAKCAQEA7VhY5V2Qe9yJx7u4UmP9zT0qkQmN5Z8bV2hV8xH6TgH8' \
    'dQ7aY6Jm4Vxg9pWq3Nf2cK8rL1sT5uB0eH6iO9mZ2aC4dF7gJ1kL5pR8vX3w' \
    'q2M5nB8cD1fG4hJ7kL0pS3uV6xY9aC2dE5gH8jK1mN4pQ7sT0vW3yZ6bC9d' \
    '-----END RSA PRIVATE KEY-----')
  reset_log
  run_jev code out err yes "$private_key" "Done?"
  assert_equals "$code" 1 "a multiline PEM key in state is refused"
  assert_contains "$err" "secret" "the PEM state refusal names the privacy issue"
  assert_absent "$LOG/body" "a multiline PEM key in state is never sent"

  reset_log
  run_jev code out err pick "state" "Choose?" "A=$private_key" B
  assert_equals "$code" 1 "a multiline PEM key in option text is refused"
  assert_contains "$err" "option labels and meanings must not contain control characters" \
    "the PEM option is rejected before the privacy screen"
  assert_absent "$LOG/body" "a multiline PEM key in option text is never sent"

  reset_log
  run_jev code out err yes 'DATABASE_URL=postgres://svc:db-secret@db.internal/app' "Done?"
  assert_equals "$code" 1 "a credential-bearing database URL is refused"
  assert_contains "$err" "secret" "the database URL refusal names the privacy issue"
  assert_absent "$LOG/body" "a credential-bearing database URL is never sent"

  reset_log
  run_jev code out err yes 'redis://:opaque-pass@db.internal/0' "Done?"
  assert_equals "$code" 1 "a credential-bearing URL with an empty username is refused"
  assert_contains "$err" "secret" "the empty-username URL refusal names the privacy issue"
  assert_absent "$LOG/body" "an empty-username credential URL is never sent"

  yaml_state=$'config:\n  API_TOKEN: |\n    opaque-secret\n    second line\n  next: preserved'
  reset_log
  run_jev code out err yes "$yaml_state" "Done?"
  assert_equals "$code" 1 "a sensitive YAML block scalar is refused"
  assert_contains "$err" "secret" "the YAML block-scalar refusal names the privacy issue"
  assert_absent "$LOG/body" "a YAML block-scalar secret is never sent"

  reset_log
  run_jev code out err yes 'https://example.com/path' "Done?"
  assert_equals "$code" 0 "a URL without user-and-password credentials is accepted"
  assert_equals "$(jq -r '.state' "$LOG/body")" 'https://example.com/path' \
    "an ordinary URL is sent unchanged"

  reset_log
  run_jev code out err yes "task summary" "Contact alice@example.com."
  assert_equals "$code" 1 "an email address in question text is refused"
  assert_contains "$err" "personal data" "the email refusal identifies the privacy category"
  assert_absent "$LOG/body" "an email address in question text is never sent"

  reset_log
  run_jev code out err pick "task summary" "Which option?" \
    "A=Call +1 (212) 555-0199" B
  assert_equals "$code" 1 "a grouped phone number in an option meaning is refused"
  assert_contains "$err" "personal data" "the phone refusal identifies the privacy category"
  assert_absent "$LOG/body" "a grouped phone number in option text is never sent"

  reset_log
  run_jev code out err yes "task summary" "Call 212 555 0199?"
  assert_equals "$code" 1 "a phone number grouped with spaces in question text is refused"
  assert_contains "$err" "personal data" "the spaced phone refusal identifies the privacy category"
  assert_absent "$LOG/body" "a space-grouped phone number is never sent"

  for safe_state in "Version 1.2.3" "Date 2025-03-08" "Date 2025 03 08" "Timestamp 2025-03-08T14:32:10Z" "Count 123456789"; do
    reset_log
    run_jev code out err yes "$safe_state" "Is this accepted?"
    assert_equals "$code" 0 "non-phone numeric text is accepted: $safe_state"
    assert_equals "$(jq -r '.state' "$LOG/body")" "$safe_state" \
      "accepted version, date, timestamp, or ordinary number stays unchanged"
  done

  respond '{"answers":{"yes":{"noul":0.97}}}'
  reset_log
  run_jev code out err yes "worktree for task-execution-receipt-retry is clean" "Done?"
  assert_equals "$code" 0 "a hyphenated task slug is accepted"
  assert_equals "$(jq -r '.state' "$LOG/body")" "worktree for task-execution-receipt-retry is clean" \
    "the complete task slug is sent unchanged"

  for token in sk-abcdefghijklmnop sk-or-abcdefghijklmnop sk_live_51AbCdEfGhIjKlMnOp sk_test_51AbCdEfGhIjKlMnOp ghp_abcdefghijklmnop github_pat_abcdefghijklmnop glpat-12345678901234567890 gho_abcdefghijklmnop ghu_abcdefghijklmnop ghs_abcdefghijklmnop ghr_abcdefghijklmnop xoxb-1234-5678-abcdef xoxp-1234-5678-abcdef xoxa-1234-5678-abcdef xoxr-1234-5678-abcdef xoxs-1234-5678-abcdef; do
    reset_log
    run_jev code out err yes "credential ($token)" "Done?"
    assert_equals "$code" 1 "a token boundary before $token is refused"
    assert_contains "$err" "secret" "the token refusal says why"
    assert_absent "$LOG/body" "a secret-looking token is never sent"
  done

  run_jev code out err yes "GITHUB_TOKEN=ghp_abcdefghijklmnopqrst" "Done?"
  assert_equals "$code" 1 "secret-shaped state is refused"
  assert_contains "$err" "secret" "the refusal says why"
  assert_absent "$LOG/body" "a secret-shaped state is never sent"

  for credential in \
    'aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY' \
    'aWs_AcCeSs_KeY_Id : AKIAIOSFODNN7EXAMPLE'; do
    reset_log
    run_jev code out err yes "$credential" "Done?"
    assert_equals "$code" 1 "an AWS credential assignment is refused"
    assert_contains "$err" "secret" "the AWS credential refusal says why"
    assert_absent "$LOG/body" "an AWS credential assignment is never sent"
  done

  for credential in \
    'DB_PASSWORD = cleartext value' \
    'API_token : opaque-value' \
    'db_PWD=another-value' \
    'SERVICE_SECRET = "two word value"' \
    'STRIPE_SECRET_KEY=opaque-stripe-secret' \
    'vendor_API_KEY : opaque-vendor-key'; do
    reset_log
    run_jev code out err yes "$credential" "Done?"
    assert_equals "$code" 1 "a sensitive assignment is refused: $credential"
    assert_contains "$err" "secret" "the sensitive assignment refusal says why"
    assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
      "a sensitive assignment refusal prints one stderr line"
    assert_absent "$LOG/body" "a sensitive assignment is never sent"
  done

  batch_json=$(jq -cn --arg state '{"password": "ordinary-user-password"}' \
    '{state:$state,questions:[{id:"json-password",type:"yes",q:"Done?"}]}')
  reset_log
  run_jev code out err batch <<<"$batch_json"
  assert_equals "$code" 1 "a quoted password key in JSON state is refused"
  assert_contains "$err" "secret" "the JSON state refusal names the privacy issue"
  assert_absent "$LOG/body" "a JSON password value is never sent"

  nested_yaml=$'clientSecret:\n value:\n text: opaque-vendor-secret'
  reset_log
  run_jev code out err yes "$nested_yaml" "Done?"
  assert_equals "$code" 1 "a sensitive YAML key is refused regardless of its nested value shape"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "a sensitive YAML key refusal prints one stderr line"
  assert_absent "$LOG/body" "a sensitive YAML key never reaches TypeSafe"

  nested_secret_state=$'{\n  "clientSecret": {\n    "value": "opaque-vendor-secret"\n  }\n}'
  batch_json=$(jq -cn --arg state "$nested_secret_state" \
    '{state:$state,questions:[{id:"nested-secret",type:"yes",q:"Done?"}]}')
  reset_log
  run_jev code out err batch <<<"$batch_json"
  assert_equals "$code" 1 "a nested sensitive object in state is refused"
  assert_contains "$err" "secret" "the nested sensitive object refusal names the privacy issue"
  assert_absent "$LOG/body" "a nested sensitive value never reaches TypeSafe"

  for json_credential in \
    '{"api-key":"opaque-vendor-secret"}' \
    '{"apiKey":"opaque-vendor-secret"}' \
    '{"clientSecret":"opaque-vendor-secret"}'; do
    batch_json=$(jq -cn --arg state "$json_credential" \
      '{state:$state,questions:[{id:"json-alias",type:"yes",q:"Done?"}]}')
    reset_log
    run_jev code out err batch <<<"$batch_json"
    assert_equals "$code" 1 "a normalized sensitive key in JSON state is refused: $json_credential"
    assert_contains "$err" "secret" "the normalized JSON-key refusal names the privacy issue"
    assert_absent "$LOG/body" "a normalized JSON credential value is never sent"
  done

  reset_log
  run_jev code out err yes "task summary" '{"api_key":"ordinary-user-api-key"}'
  assert_equals "$code" 1 "a quoted API key in question text is refused"
  assert_contains "$err" "secret" "the JSON question refusal names the privacy issue"
  assert_absent "$LOG/body" "a JSON API key in question text is never sent"

  reset_log
  run_jev code out err pick "task summary" "Choose?" '{"token":"ordinary-user-token"}' Safe
  assert_equals "$code" 1 "a quoted token key in an option label is refused"
  assert_contains "$err" "secret" "the JSON option-label refusal names the privacy issue"
  assert_absent "$LOG/body" "a JSON token in an option label is never sent"

  reset_log
  run_jev code out err pick "task summary" "Choose?" 'A={"secret_key":"ordinary-user-secret"}' Safe
  assert_equals "$code" 1 "a quoted secret key in an option meaning is refused"
  assert_contains "$err" "secret" "the JSON option-meaning refusal names the privacy issue"
  assert_absent "$LOG/body" "a JSON secret in an option meaning is never sent"

  reset_log
  run_jev code out err yes "The password is required for deployment." "Done?"
  assert_equals "$code" 0 "ordinary prose mentioning password remains usable"
  assert_equals "$(jq -r '.state' "$LOG/body")" "The password is required for deployment." \
    "ordinary prose is sent unchanged"

  reset_log
  run_jev code out err pick "state" "Which?" "a=Bearer abcdef123456" b
  assert_equals "$code" 1 "secret-shaped option text is refused"
  assert_absent "$LOG/body" "secret-shaped option text is never sent"

  reset_log
  run_jev code out err yes "state" "Question includes $KEY"
  assert_equals "$code" 1 "the live key value in a question is refused"
  assert_absent "$LOG/body" "the question key is never sent"

  reset_log
  run_jev code out err pick "state" "Which?" "A=meaning includes $KEY" B
  assert_equals "$code" 1 "the live key value in an option meaning is refused"
  assert_absent "$LOG/body" "the option key is never sent"

  reset_log
  run_jev code out err pick "state" "Which?" "$KEY=meaning" B
  assert_equals "$code" 1 "the live key value in an option label is refused"
  assert_absent "$LOG/body" "the option label key is never sent"

  reset_log
  run_jev code out err pick "state" "Which?" "sk-or-v1-abcdefghijklmnop=meaning" B
  assert_equals "$code" 1 "a secret-shaped option label is refused"
  assert_absent "$LOG/body" "the secret-shaped option label is never sent"

  local pgp_key
  pgp_key=$'-----BEGIN PGP PRIVATE KEY BLOCK-----\nComment: test fixture\n\nmQINBGV8Y2QBEAC7Y3NhbXBsZUJhc2U2NEJsb2Nr\n-----END PGP PRIVATE KEY BLOCK-----'
  reset_log
  run_jev code out err yes "encrypted payload: $pgp_key" "Is the state safe?"
  assert_equals "$code" 1 "a multiline PGP private-key block in state is refused"
  assert_absent "$LOG/body" "a PGP private-key state never reaches TypeSafe"

  reset_log
  run_jev code out err pick "state" "Which?" "A=$pgp_key" B
  assert_equals "$code" 1 "a multiline PGP private-key block in option text is refused"
  assert_absent "$LOG/body" "a PGP private-key option never reaches TypeSafe"

  reset_log
  run_jev code out err pick "state" "Which?" $'A\nB' C
  assert_equals "$code" 1 "an option label containing a newline is refused"
  assert_equals "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1 \
    "the multiline label refusal prints one stderr line"
  assert_contains "$err" "option labels and meanings must not contain control characters" "the invalid label is explained"
  assert_absent "$LOG/body" "a multiline option label is never sent"

  run_jev code out err yes "the key is $KEY" "Done?"
  assert_equals "$code" 1 "the live key value is refused"
  assert_not_contains "$err" "$KEY" "the refusal never echoes the key"
  assert_absent "$LOG/body" "the live key is never sent"

  openrouter_key='or-cli-test-key-9876543210'
  reset_log
  OPENROUTER_API_KEY="$openrouter_key" run_jev code out err yes \
    "provider credential $openrouter_key" "Done?"
  assert_equals "$code" 1 "an OpenRouter key value is refused even on the TypeSafe route"
  assert_not_contains "$err" "$openrouter_key" "the OpenRouter key is never echoed"
  assert_absent "$LOG/body" "the OpenRouter key is never sent to TypeSafe"

  printf 'OPENROUTER_API_KEY=%s\n' "$openrouter_key" > "$HOME_DIR/.env"
  reset_log
  OPENROUTER_API_KEY='' run_jev code out err yes \
    "provider credential $openrouter_key" "Done?"
  assert_equals "$code" 1 "an OpenRouter key from the resolved .env is refused"
  assert_not_contains "$err" "$openrouter_key" "the .env OpenRouter key is never echoed"
  assert_absent "$LOG/body" "the .env OpenRouter key is never sent to TypeSafe"

  batch_json=$(jq -cn --arg id "$openrouter_key" '{state:"safe",questions:[{id:$id,type:"yes",q:"Done?"}]}')
  reset_log
  OPENROUTER_API_KEY='' run_jev code out err batch <<<"$batch_json"
  assert_equals "$code" 1 "an OpenRouter key used as a batch id is refused"
  assert_contains "$err" "Jev API key itself" "a secret batch id is refused by the privacy guard"
  assert_not_contains "$err" "$openrouter_key" "the secret batch id is never echoed"
  assert_absent "$LOG/body" "a secret batch id is never sent to TypeSafe"

  batch_json=$(jq -cn --arg id "$KEY" \
    '{state:"safe",questions:[{id:$id,type:"yes",q:""}]}')
  reset_log
  run_jev code out err batch <<<"$batch_json"
  assert_equals "$code" 1 "an empty question with an ID equal to the live key is rejected"
  assert_contains "$err" "question 1: q must be a non-empty string" \
    "validation identifies the question by position"
  assert_not_contains "$err" "$KEY" "pre-guard validation never echoes the live-key ID to stderr"
  assert_not_contains "$out" "$KEY" "pre-guard validation never echoes the live-key ID to stdout"
  assert_absent "$LOG/body" "invalid input with the live-key ID is never sent"
  rm -f "$HOME_DIR/.env"
  pass "fm-jev.sh: privacy guard refuses before anything is sent"
}

# The guard must screen the selected key from the same .env fallback as the
# library, even when the environment carries only the other route's key.
test_privacy_guard_screens_checkout_env_without_fm_home() {
  local code main home openrouter_key
  respond '{"answers":{"yes":{"noul":0.97}}}'
  main="$TMP_ROOT/guard-checkout"
  make_checkout "$main"
  printf 'TYPESAFE_API_KEY=%s\n' "$KEY-checkout" > "$main/.env"
  reset_log
  env -u FM_HOME -u TYPESAFE_API_KEY OPENROUTER_API_KEY="$KEY-or" PATH="$FAKEBIN:$PATH" \
    "$main/bin/fm-jev.sh" yes "the key is $KEY-checkout" "Done?" \
    > "$TMP_ROOT/guard.out" 2> "$TMP_ROOT/guard.err"
  code=$?
  assert_equals "$code" 1 "the checkout .env key is refused with FM_HOME unset"
  assert_contains "$(cat "$TMP_ROOT/guard.err")" "Jev API key itself" "the refusal names the live key"
  assert_not_contains "$(cat "$TMP_ROOT/guard.err")" "$KEY-checkout" "the refusal never echoes the key"
  assert_absent "$LOG/body" "the checkout .env key is never sent"

  home="$TMP_ROOT/router-home"
  openrouter_key='opaque-home-router-credential-918273'
  mkdir -p "$home"
  printf 'OPENROUTER_API_KEY=%s\n' "$openrouter_key" > "$home/.env"
  reset_log
  env -u TYPESAFE_API_KEY -u OPENROUTER_API_KEY FM_HOME="$home" PATH="$FAKEBIN:$PATH" \
    "$main/bin/fm-jev.sh" yes "provider credential $openrouter_key" "Done?" \
    > "$TMP_ROOT/home-router.out" 2> "$TMP_ROOT/home-router.err"
  code=$?
  assert_equals "$code" 1 "the FM_HOME OpenRouter key is refused when the TypeSafe key comes from checkout config"
  assert_contains "$(cat "$TMP_ROOT/home-router.err")" "Jev API key itself" \
    "the FM_HOME OpenRouter key refusal is explained"
  assert_equals "$(wc -l < "$TMP_ROOT/home-router.err" | tr -d ' ')" 1 \
    "the FM_HOME OpenRouter key refusal prints one stderr line"
  assert_not_contains "$(cat "$TMP_ROOT/home-router.err")" "$openrouter_key" \
    "the FM_HOME OpenRouter key is never echoed"
  assert_absent "$LOG/body" "the FM_HOME OpenRouter key is never sent"
  pass "fm-jev.sh: the guard screens provider keys from resolved home"
}

test_log_records_metadata_only() {
  local code out err line
  rm -f "$HOME_DIR/state/jev-calls.jsonl"
  respond '{"answers":{"yes":{"noul":0.97}},"usage":{"input_tokens":274,"output_tokens":20}}'
  run_jev code out err yes "secret-free state text" "Unique question text?"
  line=$(tail -n 1 "$HOME_DIR/state/jev-calls.jsonl")
  assert_equals "$(printf '%s' "$line" | jq -c '{purpose, http, usage, questions, escalated, exit}')" \
    '{"purpose":"worker-cli","http":"200","usage":{"in":274,"out":20},"questions":1,"escalated":0,"exit":0}' \
    "the call is logged with usage and outcome"
  assert_not_contains "$line" "secret-free state text" "the log never holds the state"
  assert_not_contains "$line" "Unique question text" "the log never holds the question"
  assert_not_contains "$line" "$KEY" "the log never holds the key"
  assert_equals "$(printf '%s' "$line" | jq -r 'has("cwd")')" false \
    "the metadata record does not store the working directory"
  pass "fm-jev.sh: every call is logged as metadata only"
}

# make_checkout <dir> - a disposable copy of the command and its libraries.
make_checkout() {
  mkdir -p "$1/bin"
  cp "$ROOT/bin/fm-jev.sh" "$ROOT/bin/fm-jev-lib.sh" "$ROOT/bin/fm-env-lib.sh" "$1/bin/"
}

test_key_discovery_needs_no_env_setup() {
  local main wt nokey code out err
  respond '{"answers":{"yes":{"noul":0.97}}}'

  # A checkout-local .env works from an unrelated directory.
  main="$TMP_ROOT/own-checkout"
  make_checkout "$main"
  printf 'TYPESAFE_API_KEY=%s\n' "$KEY-own" > "$main/.env"
  reset_log
  out=$(cd "$TMP_ROOT" && env -u FM_HOME -u TYPESAFE_API_KEY -u OPENROUTER_API_KEY PATH="$FAKEBIN:$PATH" \
    "$main/bin/fm-jev.sh" yes s q)
  assert_equals "$out" "yes: yes p=0.97 conf=0.94" "the checkout .env answers with no env setup"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY-own" "the checkout .env supplies the request key"

  # A pooled worktree call with no env key reads the main checkout's .env.
  git -C "$main" init -q
  git -C "$main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  wt="$TMP_ROOT/pooled-worktree"
  git -C "$main" worktree add -q --detach "$wt"
  make_checkout "$wt"
  reset_log
  out=$(cd "$TMP_ROOT" && env -u FM_HOME -u TYPESAFE_API_KEY -u OPENROUTER_API_KEY PATH="$FAKEBIN:$PATH" \
    "$wt/bin/fm-jev.sh" yes s q)
  assert_equals "$out" "yes: yes p=0.97 conf=0.94" "a pooled worktree copy finds the main checkout .env without an env key"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY-own" "the main checkout .env key is used"

  # FM_HOME .env wins over the owning checkout .env; the process environment
  # still takes precedence over both.
  JEV="$main/bin/fm-jev.sh"
  printf 'TYPESAFE_API_KEY=%s\n' "$KEY-home" > "$HOME_DIR/.env"
  reset_log
  JEV_TEST_API_KEY='' JEV_TEST_HOME="$HOME_DIR" run_jev code out err yes s q
  assert_equals "$code" 0 "an FM_HOME .env key is accepted"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY-home" "FM_HOME .env wins over checkout .env"
  reset_log
  JEV_TEST_API_KEY="$KEY-env-wins" JEV_TEST_HOME="$HOME_DIR" run_jev code out err yes s q
  assert_equals "$code" 0 "the environment key remains supported"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY-env-wins" "the environment key wins over .env files"

  printf 'OTHER_SETTING=value\n' > "$HOME_DIR/.env"
  reset_log
  JEV_TEST_API_KEY='' JEV_TEST_HOME="$HOME_DIR" run_jev code out err yes s q
  assert_equals "$code" 0 "an empty FM_HOME key falls back to the owning checkout .env"
  assert_equals "$(cat "$LOG/header")" "Authorization: Bearer $KEY-own" "the owning checkout .env is the final fallback"

  # OpenRouter-only configuration cannot authorize this TypeSafe-only command.
  nokey="$TMP_ROOT/no-key-checkout"
  make_checkout "$nokey"
  printf 'OTHER_SETTING=value\n' > "$nokey/.env"
  reset_log
  env -u TYPESAFE_API_KEY -u OPENROUTER_API_KEY FM_HOME="$nokey" PATH="$FAKEBIN:$PATH" \
    "$nokey/bin/fm-jev.sh" yes s q > "$TMP_ROOT/nokey.out" 2> "$TMP_ROOT/nokey.err"
  code=$?
  assert_equals "$code" 1 "a missing TypeSafe key is refused"
  assert_contains "$(cat "$TMP_ROOT/nokey.err")" "TYPESAFE_API_KEY missing" "the missing key is named"
  assert_equals "$(wc -l < "$TMP_ROOT/nokey.err" | tr -d ' ')" 1 "a missing key prints one stderr line"
  assert_absent "$LOG/body" "a missing TypeSafe key never triggers a request"

  printf 'OPENROUTER_API_KEY=%s\nJEV_ROUTE=openrouter\n' "$KEY-or" > "$nokey/.env"
  reset_log
  env -u TYPESAFE_API_KEY FM_HOME="$nokey" OPENROUTER_API_KEY="$KEY-or" JEV_ROUTE=openrouter PATH="$FAKEBIN:$PATH" \
    "$nokey/bin/fm-jev.sh" yes s q > "$TMP_ROOT/openrouter-only.out" 2> "$TMP_ROOT/openrouter-only.err"
  code=$?
  assert_equals "$code" 1 "an OpenRouter key alone cannot authorize the worker command"
  assert_contains "$(cat "$TMP_ROOT/openrouter-only.err")" "TYPESAFE_API_KEY missing" \
    "the missing TypeSafe key is named"
  assert_equals "$(wc -l < "$TMP_ROOT/openrouter-only.err" | tr -d ' ')" 1 \
    "a missing TypeSafe key prints one stderr line"
  assert_not_contains "$(cat "$TMP_ROOT/openrouter-only.err")" "$KEY-or" "the OpenRouter key is never echoed"
  assert_absent "$LOG/body" "OpenRouter credentials never trigger a request"
  pass "fm-jev.sh: key discovery works from any directory without env setup"
}

test_help_is_short_and_complete
test_pick_answers_one_line
test_key_stays_out_of_child_environments
test_unoffered_multiline_choice_cannot_forge_output
test_option_meaning_splits_on_first_equals
test_cli_forces_typesafe_route
test_cli_pins_typesafe_endpoint
test_yes_and_score_lines
test_batch_one_call_many_lines
test_batch_state_json_text_remains_a_string
test_batch_state_preserves_trailing_newlines
test_option_limits_refuse_before_sending
test_escalation_exits_two
test_tied_top_probabilities_escalate
test_batch_nul_values_are_refused
test_split_score_distribution_escalates_by_design
test_json_prints_raw_response
test_errors_exit_one_with_one_line
test_option_control_characters_are_refused
test_privacy_guard_refuses_before_sending
test_privacy_guard_screens_checkout_env_without_fm_home
test_log_records_metadata_only
test_key_discovery_needs_no_env_setup
