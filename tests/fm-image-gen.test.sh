#!/usr/bin/env bash
# tests/fm-image-gen.test.sh - behavior tests for bin/fm-image-gen.sh.
#
# EVERY real call to this tool spends the captain's money, and there is no free
# tier for any Nano Banana model. So the network is faked here without exception:
# a stub `curl` on PATH answers both endpoints, and no test in this file may ever
# reach generativelanguage.googleapis.com. The single live end-to-end call is a
# MANUAL step recorded in the skill, deliberately not automated.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GEN="$ROOT/bin/fm-image-gen.sh"
TMP_ROOT=$(fm_test_tmproot fm-image-gen)

# A stub curl that speaks the two shapes the tool uses. It records the config it
# received on stdin (which carries the credential) and the request body, so the
# tests can assert on both without the tool ever touching the network.
make_fake_curl() {  # <bin-dir> <models-response-mode>
  local bin=$1 mode=$2
  mkdir -p "$bin"
  cat > "$bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -u
cfg=$(cat)
printf '%s' "$cfg" > "$FAKE_CURL_CFG"
url=; body=; outfile=
while [ $# -gt 0 ]; do
  case "$1" in
    --config) shift 2 2>/dev/null || shift ;;
    --data-binary) body=${2#@}; shift 2 ;;
    --output) outfile=$2; shift 2 ;;
    --header) shift 2 ;;
    --silent|--show-error) shift ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
[ -z "$body" ] || cp "$body" "$FAKE_CURL_BODY"
case "$url" in
  */models)
    if [ "${FAKE_CURL_MODELS_EMPTY:-0}" = 1 ]; then
      printf '{"models":[]}'
    else
      printf '{"models":[{"name":"models/gemini-3.1-flash-image","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-2.5-flash-image","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent"]}]}'
    fi
    ;;
  *:generateContent)
    if [ -n "${FAKE_CURL_ERROR_STATUS:-}" ]; then
      printf '{"error":{"status":"%s","message":"Your prepayment credits are depleted."}}' \
        "$FAKE_CURL_ERROR_STATUS" > "$outfile"
    else
      # Realistic shape: these models cannot return image-only, so a real
      # response carries a text part ALONGSIDE the image. The stub mirrors that
      # so the reader is exercised against what the API actually sends.
      payload=$(printf 'PNGDATA' | base64)
      printf '{"candidates":[{"content":{"parts":[{"text":"Here is the illustration you asked for."},{"inlineData":{"mimeType":"image/png","data":"%s"}}]}}]}' "$payload" > "$outfile"
    fi
    ;;
esac
exit 0
FAKE
  chmod +x "$bin/curl"
  : "$mode"
}

# The credential must never reach argv. A stub curl records what it was given, so
# this is checked against the real invocation rather than by reading the source.
test_key_never_enters_argv_or_url() {
  local d bin home out
  d="$TMP_ROOT/argv"; bin="$d/bin"; home="$d/home"; out="$d/out"
  mkdir -p "$home" "$out"
  make_fake_curl "$bin" normal
  printf 'GEMINI_IMAGE_API_KEY=SECRET-DO-NOT-LEAK\n' > "$home/.env"
  printf 'a hero image\n' > "$d/prompt.txt"

  FAKE_CURL_CFG="$d/cfg.txt" FAKE_CURL_BODY="$d/body.json" \
    PATH="$bin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$d/config" \
    "$GEN" --prompt-file "$d/prompt.txt" --out "$out" > "$d/stdout.txt" 2> "$d/stderr.txt"
  expect_code 0 $? "a faked successful generation should exit 0"$'\n'"$(cat "$d/stderr.txt")"

  # The key belongs in the stdin config and nowhere else.
  assert_grep 'SECRET-DO-NOT-LEAK' "$d/cfg.txt" \
    "the credential must be delivered through the curl stdin config"
  assert_no_grep 'SECRET-DO-NOT-LEAK' "$d/stdout.txt" \
    "the credential must never appear on stdout"
  assert_no_grep 'SECRET-DO-NOT-LEAK' "$d/stderr.txt" \
    "the credential must never appear on stderr, including in the cost line"
  pass "fm-image-gen.sh: the API key travels in the stdin config, never in argv, the URL, or either output stream"
}

# Creative briefs routinely contain quotes, apostrophes, $, backticks, and
# newlines. All of it must survive as DATA. This is the injection test.
test_prompt_metacharacters_survive_intact() {
  local d bin home out prompt got
  d="$TMP_ROOT/meta"; bin="$d/bin"; home="$d/home"; out="$d/out"
  mkdir -p "$home" "$out"
  make_fake_curl "$bin" normal
  printf 'GEMINI_IMAGE_API_KEY=k\n' > "$home/.env"
  prompt='Постер "Parlino" за $5; `rm -rf /`; 50% off
вторая строка с '"'"'кавычками'"'"' и \backslash'
  printf '%s' "$prompt" > "$d/prompt.txt"

  FAKE_CURL_CFG="$d/cfg.txt" FAKE_CURL_BODY="$d/body.json" \
    PATH="$bin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$d/config" \
    "$GEN" --prompt-file "$d/prompt.txt" --out "$out" >/dev/null 2>&1
  expect_code 0 $? "a prompt full of metacharacters must not break the call"

  got=$(jq -r '.contents[0].parts[0].text' "$d/body.json")
  [ "$got" = "$prompt" ] \
    || fail "the prompt was altered in transit"$'\n'"sent: $got"$'\n'"want: $prompt"
  pass "fm-image-gen.sh: quotes, \$, backticks, newlines and backslashes reach the request body byte-for-byte"
}

# The agy defect, encoded as a test: an unavailable model is an error, never a
# quiet substitution with something cheaper.
test_unknown_model_fails_loudly_without_substituting() {
  local d bin home out
  d="$TMP_ROOT/model"; bin="$d/bin"; home="$d/home"; out="$d/out"
  mkdir -p "$home" "$out"
  make_fake_curl "$bin" normal
  printf 'GEMINI_IMAGE_API_KEY=k\n' > "$home/.env"
  printf 'x\n' > "$d/prompt.txt"

  FAKE_CURL_CFG="$d/cfg.txt" FAKE_CURL_BODY="$d/body.json" \
    PATH="$bin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$d/config" \
    "$GEN" --prompt-file "$d/prompt.txt" --out "$out" --model gemini-9-imaginary \
    > "$d/stdout.txt" 2> "$d/stderr.txt"
  expect_code 4 $? "an unavailable model must exit 4"

  assert_contains "$(cat "$d/stderr.txt")" "gemini-9-imaginary" \
    "the refusal must name the model that was refused"
  assert_contains "$(cat "$d/stderr.txt")" "refusing to substitute" \
    "the refusal must state that no substitution was made"
  [ ! -f "$d/body.json" ] \
    || fail "an unavailable model must be caught BEFORE any billable generateContent call"
  pass "fm-image-gen.sh: an unavailable model exits 4 before spending anything and never falls back"
}

# The configured model is used when no flag overrides it, and config/ is the
# captain-private home for that choice.
test_model_comes_from_config() {
  local d bin home out url
  d="$TMP_ROOT/config"; bin="$d/bin"; home="$d/home"; out="$d/out"
  mkdir -p "$home" "$out" "$d/config"
  make_fake_curl "$bin" normal
  printf 'GEMINI_IMAGE_API_KEY=k\n' > "$home/.env"
  printf 'x\n' > "$d/prompt.txt"
  printf 'gemini-2.5-flash-image\n' > "$d/config/image-model"

  FAKE_CURL_CFG="$d/cfg.txt" FAKE_CURL_BODY="$d/body.json" \
    PATH="$bin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$d/config" \
    "$GEN" --prompt-file "$d/prompt.txt" --out "$out" >/dev/null 2> "$d/stderr.txt"
  expect_code 0 $? "a configured model that the API lists must be accepted"
  assert_contains "$(cat "$d/stderr.txt")" "model=gemini-2.5-flash-image" \
    "the cost line must name the model actually used, read from config/image-model"
  pass "fm-image-gen.sh: config/image-model selects the model and the cost line names it"
}

# Spend must be visible at the moment it happens, not in next month's bill.
test_cost_line_is_emitted() {
  local d bin home out
  d="$TMP_ROOT/cost"; bin="$d/bin"; home="$d/home"; out="$d/out"
  mkdir -p "$home" "$out"
  make_fake_curl "$bin" normal
  printf 'GEMINI_IMAGE_API_KEY=k\n' > "$home/.env"
  printf 'x\n' > "$d/prompt.txt"

  FAKE_CURL_CFG="$d/cfg.txt" FAKE_CURL_BODY="$d/body.json" \
    PATH="$bin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$d/config" \
    "$GEN" --prompt-file "$d/prompt.txt" --out "$out" > "$d/stdout.txt" 2> "$d/stderr.txt"
  expect_code 0 $? "generation should succeed against the stub"
  assert_contains "$(cat "$d/stderr.txt")" "cost=" "every call must report its spend"
  assert_contains "$(cat "$d/stderr.txt")" "images=1" "the cost line must count the images written"
  [ -s "$(head -1 "$d/stdout.txt")" ] || fail "stdout must name a non-empty written image"
  pass "fm-image-gen.sh: writes the image, prints its path, and reports estimated spend"
}

# A missing credential is a distinct, actionable failure - not a generic error.
test_missing_credential_is_named() {
  local d bin out
  d="$TMP_ROOT/nokey"; bin="$d/bin"; out="$d/out"
  mkdir -p "$d/home" "$out"
  make_fake_curl "$bin" normal
  printf 'x\n' > "$d/prompt.txt"

  ( unset GEMINI_IMAGE_API_KEY
    PATH="$bin:$PATH" FM_HOME="$d/home" FM_CONFIG_OVERRIDE="$d/config" \
      "$GEN" --prompt-file "$d/prompt.txt" --out "$out" ) > "$d/stdout.txt" 2> "$d/stderr.txt"
  expect_code 3 $? "a missing credential must exit 3"
  assert_contains "$(cat "$d/stderr.txt")" "GEMINI_IMAGE_API_KEY" \
    "the error must name the variable the captain has to set"
  pass "fm-image-gen.sh: a missing credential exits 3 and names what is missing"
}

# The prompt must never be passable in argv, where it would land in `ps` and
# shell history and could carry shell metacharacters into a command line.
test_prompt_text_in_argv_is_refused() {
  local d out
  d="$TMP_ROOT/argvprompt"; out="$d/out"; mkdir -p "$out"
  "$GEN" --prompt 'a literal prompt' --out "$out" >/dev/null 2> "$d/stderr.txt"
  expect_code 2 $? "prompt text in argv must be refused"
  assert_contains "$(cat "$d/stderr.txt")" "never enters argv" \
    "the refusal must explain why argv is not an accepted prompt channel"
  pass "fm-image-gen.sh: prompt text in argv is refused; only a file or stdin is accepted"
}

# Google Cloud budgets only ALERT; they never stop spend. The local cap is the
# only thing that actually halts a runaway loop, so it must hold before the
# billable call, not after it.
test_daily_cap_blocks_before_spending() {
  local d bin home out state
  d="$TMP_ROOT/cap"; bin="$d/bin"; home="$d/home"; out="$d/out"; state="$d/state"
  mkdir -p "$home" "$out" "$state" "$d/config"
  make_fake_curl "$bin" normal
  printf 'GEMINI_IMAGE_API_KEY=k\n' > "$home/.env"
  printf 'x\n' > "$d/prompt.txt"
  printf '5\n' > "$d/config/image-daily-usd-cap"
  # $4.99 of $5 already spent today; one more flash image at $0.067 would cross.
  printf '%s\tgemini-3.1-flash-image\t74\t4.9900\n' "$(date -u +%Y-%m-%d)" > "$state/image-gen-spend.tsv"

  FAKE_CURL_CFG="$d/cfg.txt" FAKE_CURL_BODY="$d/body.json" \
    PATH="$bin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$d/config" FM_STATE_OVERRIDE="$state" \
    "$GEN" --prompt-file "$d/prompt.txt" --out "$out" > "$d/stdout.txt" 2> "$d/stderr.txt"
  expect_code 7 $? "a call that would cross the dollar cap must exit 7"

  assert_contains "$(cat "$d/stderr.txt")" "4.9900" \
    "the refusal must show the dollars already spent today"
  assert_contains "$(cat "$d/stderr.txt")" "cap is \$5" \
    "the refusal must name the cap it is protecting"
  [ ! -f "$d/body.json" ] \
    || fail "the cap must be enforced BEFORE any billable generateContent call"
  pass "fm-image-gen.sh: a call that would cross the dollar cap exits 7 before spending anything"
}

# The cap must stop the call that would CROSS it, not only one made after the
# cap is already exceeded - otherwise the last call always overshoots.
test_cap_admits_a_call_that_still_fits() {
  local d bin home out state
  d="$TMP_ROOT/fits"; bin="$d/bin"; home="$d/home"; out="$d/out"; state="$d/state"
  mkdir -p "$home" "$out" "$state" "$d/config"
  make_fake_curl "$bin" normal
  printf 'GEMINI_IMAGE_API_KEY=k\n' > "$home/.env"
  printf 'x\n' > "$d/prompt.txt"
  printf '5\n' > "$d/config/image-daily-usd-cap"
  # $4.90 spent: $0.067 still fits under $5.
  printf '%s\tgemini-3.1-flash-image\t73\t4.9000\n' "$(date -u +%Y-%m-%d)" > "$state/image-gen-spend.tsv"

  FAKE_CURL_CFG="$d/cfg.txt" FAKE_CURL_BODY="$d/body.json" \
    PATH="$bin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$d/config" FM_STATE_OVERRIDE="$state" \
    "$GEN" --prompt-file "$d/prompt.txt" --out "$out" >/dev/null 2> "$d/stderr.txt"
  expect_code 0 $? "a call that still fits under the cap must proceed"$'\n'"$(cat "$d/stderr.txt")"
  assert_contains "$(cat "$d/stderr.txt")" "today=\$4.9670/\$5" \
    "the cost line must report the running dollar total against the cap"
  pass "fm-image-gen.sh: a call that still fits under the dollar cap proceeds and reports the new total"
}

# Yesterday's spend must not count against today, or the tool would wedge itself
# permanently after one busy day.
test_cap_counts_only_today_and_records_dollars() {
  local d bin home out state total
  d="$TMP_ROOT/ledger"; bin="$d/bin"; home="$d/home"; out="$d/out"; state="$d/state"
  mkdir -p "$home" "$out" "$state" "$d/config"
  make_fake_curl "$bin" normal
  printf 'GEMINI_IMAGE_API_KEY=k\n' > "$home/.env"
  printf 'x\n' > "$d/prompt.txt"
  printf '5\n' > "$d/config/image-daily-usd-cap"
  # A long-exhausted old day, plus a legacy 3-column line from before the cap
  # moved to dollars: neither may block today, and the legacy line must not
  # break the sum.
  printf '2020-01-01\tgemini-3.1-flash-image\t99\t6.6330\n2020-01-02\tgemini-3.1-flash-image\t5\n' \
    > "$state/image-gen-spend.tsv"

  FAKE_CURL_CFG="$d/cfg.txt" FAKE_CURL_BODY="$d/body.json" \
    PATH="$bin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$d/config" FM_STATE_OVERRIDE="$state" \
    "$GEN" --prompt-file "$d/prompt.txt" --out "$out" >/dev/null 2> "$d/stderr.txt"
  expect_code 0 $? "an old day's spend must not block today"$'\n'"$(cat "$d/stderr.txt")"

  assert_contains "$(cat "$d/stderr.txt")" "today=\$0.0670/\$5" \
    "today's total must start from zero regardless of older days"
  total=$(awk -F'\t' -v d="$(date -u +%Y-%m-%d)" '$1 == d { s += $4 } END { printf "%.4f", s + 0 }' "$state/image-gen-spend.tsv")
  [ "$total" = "0.0670" ] || fail "the ledger should record today's dollars, got '$total'"
  pass "fm-image-gen.sh: the cap counts only today's dollars, and legacy 3-column lines do not break the sum"
}

# Paid for by the first live call on 2026-08-06: this surface bills from AI
# Studio PREPAYMENT credits, not the Cloud billing account, so an empty balance
# answers RESOURCE_EXHAUSTED even with billing enabled on the project. Reporting
# that as a credential fault would send the captain to regenerate a good key.
test_exhausted_balance_is_not_reported_as_a_credential_fault() {
  local d bin home out
  d="$TMP_ROOT/exhausted"; bin="$d/bin"; home="$d/home"; out="$d/out"
  mkdir -p "$home" "$out"
  make_fake_curl "$bin" normal
  printf 'GEMINI_IMAGE_API_KEY=k\n' > "$home/.env"
  printf 'x\n' > "$d/prompt.txt"

  FAKE_CURL_CFG="$d/cfg.txt" FAKE_CURL_BODY="$d/body.json" FAKE_CURL_ERROR_STATUS=RESOURCE_EXHAUSTED \
    PATH="$bin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$d/config" FM_STATE_OVERRIDE="$d/state" \
    "$GEN" --prompt-file "$d/prompt.txt" --out "$out" >/dev/null 2> "$d/stderr.txt"
  expect_code 8 $? "an exhausted balance must exit 8, not 3"

  assert_contains "$(cat "$d/stderr.txt")" "not credentials" \
    "the message must say plainly that the key is not the problem"
  assert_contains "$(cat "$d/stderr.txt")" "do not regenerate" \
    "the message must stop the captain from replacing a working key"
  [ ! -f "$d/state/image-gen-spend.tsv" ] \
    || fail "a refused call must not consume any of the daily budget"
  pass "fm-image-gen.sh: an exhausted balance exits 8, keeps the key's good name, and consumes no budget"
}

# Regression on a real defect, caught by the captain reading Google's quickstart
# rather than by any test here: the tool asked for responseModalities ["IMAGE"],
# but "image-only output is not supported with these models" and such a request
# is rejected. It looked like the tighter, more correct request and would have
# failed every single call - including the first live one, after paying for it.
test_request_asks_for_both_modalities() {
  local d bin home out mods
  d="$TMP_ROOT/modalities"; bin="$d/bin"; home="$d/home"; out="$d/out"
  mkdir -p "$home" "$out"
  make_fake_curl "$bin" normal
  printf 'GEMINI_IMAGE_API_KEY=k\n' > "$home/.env"
  printf 'x\n' > "$d/prompt.txt"

  FAKE_CURL_CFG="$d/cfg.txt" FAKE_CURL_BODY="$d/body.json" \
    PATH="$bin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$d/config" FM_STATE_OVERRIDE="$d/state" \
    "$GEN" --prompt-file "$d/prompt.txt" --out "$out" > "$d/stdout.txt" 2>&1
  expect_code 0 $? "generation against the stub should succeed"

  mods=$(jq -r '.generationConfig.responseModalities | sort | join(",")' "$d/body.json")
  [ "$mods" = "IMAGE,TEXT" ] \
    || fail "the request must ask for BOTH modalities; image-only is rejected by these models. got: $mods"

  # And the accompanying text part must not confuse the reader into missing the
  # image or emitting the text as if it were a file path.
  [ -s "$(head -1 "$d/stdout.txt")" ] \
    || fail "the image must still be extracted when a text part sits beside it"
  pass "fm-image-gen.sh: the request asks for TEXT and IMAGE, and the image is still extracted alongside the text part"
}

test_request_asks_for_both_modalities
test_exhausted_balance_is_not_reported_as_a_credential_fault
test_daily_cap_blocks_before_spending
test_cap_counts_only_today_and_records_dollars
test_cap_admits_a_call_that_still_fits
test_key_never_enters_argv_or_url
test_prompt_metacharacters_survive_intact
test_unknown_model_fails_loudly_without_substituting
test_model_comes_from_config
test_cost_line_is_emitted
test_missing_credential_is_named
test_prompt_text_in_argv_is_refused

# Paid for on 2026-08-06: a pro mockup came back at 4K unasked and cost $0.24
# instead of $0.134. Size is now always sent, so the default must be HD.
test_size_and_aspect_reach_the_request() {
  local d bin home out size aspect
  d="$TMP_ROOT/sizing"; bin="$d/bin"; home="$d/home"; out="$d/out"
  mkdir -p "$home" "$out"
  make_fake_curl "$bin" normal
  printf 'GEMINI_IMAGE_API_KEY=k\n' > "$home/.env"
  printf 'x\n' > "$d/prompt.txt"

  FAKE_CURL_CFG="$d/cfg.txt" FAKE_CURL_BODY="$d/body.json" \
    PATH="$bin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$d/config" FM_STATE_OVERRIDE="$d/state" \
    "$GEN" --prompt-file "$d/prompt.txt" --out "$out" --aspect 16:9 >/dev/null 2>&1
  expect_code 0 $? "a call with --aspect should succeed"
  size=$(jq -r '.generationConfig.imageConfig.imageSize' "$d/body.json")
  aspect=$(jq -r '.generationConfig.imageConfig.aspectRatio' "$d/body.json")
  [ "$size" = "1K" ] || fail "size must default to HD so 4K never happens unasked, got '$size'"
  [ "$aspect" = "16:9" ] || fail "--aspect must reach the request, got '$aspect'"

  # outputMimeType belongs to the other surface and is rejected here.
  [ "$(jq -r '.generationConfig.imageConfig.outputMimeType // "absent"' "$d/body.json")" = absent ] \
    || fail "outputMimeType must not be sent - this surface rejects it"

  "$GEN" --prompt-file "$d/prompt.txt" --size 8K >/dev/null 2>&1
  expect_code 2 $? "an unsupported --size must be refused before any call"
  pass "fm-image-gen.sh: size defaults to 1K, --aspect reaches the request, and a bad size is refused"
}

test_size_and_aspect_reach_the_request
