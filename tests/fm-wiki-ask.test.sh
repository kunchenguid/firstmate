#!/usr/bin/env bash
# Behavior tests for bin/fm-wiki-ask.sh, including its miss-classifier caller.
#
# Uses a fake wiki-tool on PATH and a fake curl. No case touches the network
# or a real wiki vault.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TYPESAFE_API_KEY OPENROUTER_API_KEY FM_WIKI_ENGINE FM_WIKI_CATALOG \
  JEV_ROUTE JEV_MODEL JEV_TIMEOUT

TMP_ROOT=$(fm_test_tmproot fm-wiki-ask)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'
QUERY='How can I protect my hands against burns?'
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$LOG"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
cat > "$FAKE_CURL_LOG/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || true
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

cat > "$FAKEBIN/wiki-tool" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" >> "${WIKI_ARGV_LOG:?}"
status=${FAKE_WIKI_STATUS:-no-match}
case "$status" in
  ok)
    printf '%s\n' '{"status":"ok","citations":[{"path":"wiki/x.md","excerpts":[{"excerpt":"Wear insulated gauntlets"}]}],"retrieval":{"status":"disabled","mode":"full-corpus-bm25","pages_searched":1}}'
    exit 0
    ;;
  missing-source)
    printf '%s\n' '{"status":"missing-source","query":"q","citations":[],"text":"Catalog matched, but no sufficiently relevant readable page evidence was found.","retrieval":{"status":"disabled","mode":"full-corpus-bm25","pages_searched":2}}'
    exit 2
    ;;
  *)
    printf '%s\n' '{"status":"no-match","query":"q","citations":[],"text":"No authorized wiki matched.","retrieval":{"status":"disabled","mode":"full-corpus-bm25","pages_searched":0}}'
    exit 2
    ;;
esac
SH
chmod +x "$FAKEBIN/wiki-tool"

RESPONSE="$TMP_ROOT/response.json"
cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": {
    "miss": { "type": "choice", "choice": "true_miss", "confidence": 0.8,
      "probabilities": { "true_miss": 0.8, "vocab_divergence": 0.1, "consent_blocked": 0.05, "need_human": 0.05 } } },
  "usage": { "input_tokens": 40, "output_tokens": 12 } }
JSON
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" WIKI_ARGV_LOG="$LOG/wiki-argv"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
  : > "$WIKI_ARGV_LOG"
}

run_ask() {
  local __exit=$1 __out=$2 __err=$3
  shift 3
  local _out _errfile _code
  _errfile="$TMP_ROOT/stderr"
  reset_log
  rm -f "$HOME_DIR/state/jev-retrieval-miss.jsonl"
  _code=0
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-wiki-ask.sh" "$@" 2> "$_errfile") || _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$_errfile")"
}

write_catalog() {
  cat > "$HOME_DIR/catalog.json" <<'JSON'
{"version":1,"mounts":[],"embeddings":{"enabled":false},"openviking":{"enabled":false}}
JSON
  printf '%s\n' "$HOME_DIR/catalog.json" > "$HOME_DIR/config/wiki-catalog"
}

test_unconfigured_engine_does_nothing() {
  local code out err
  rm -f "$HOME_DIR/config/wiki-engine" "$HOME_DIR/config/wiki-catalog"
  unset FM_WIKI_ENGINE FM_WIKI_CATALOG
  run_ask code out err "$QUERY"
  expect_code 0 "$code" "unconfigured engine exits 0"
  assert_contains "$err" 'wiki-ask: no engine configured' "says no engine"
  [ -z "$out" ] || fail "unconfigured engine must print nothing on stdout"
  assert_absent "$HOME_DIR/state/jev-retrieval-miss.jsonl" "unconfigured does not classify"
  [ ! -s "$WIKI_ARGV_LOG" ] || fail "unconfigured must not invoke the engine"
  pass "no engine configured says so and does nothing"
}

test_unconfigured_catalog_does_nothing() {
  local code out err
  printf '%s\n' "$FAKEBIN/wiki-tool" > "$HOME_DIR/config/wiki-engine"
  rm -f "$HOME_DIR/config/wiki-catalog"
  unset FM_WIKI_CATALOG
  run_ask code out err "$QUERY"
  expect_code 0 "$code" "unconfigured catalog exits 0"
  assert_contains "$err" 'wiki-ask: no private catalog configured' "says no catalog"
  [ -z "$out" ] || fail "unconfigured catalog must print nothing on stdout"
  assert_absent "$HOME_DIR/state/jev-retrieval-miss.jsonl" "unconfigured catalog does not classify"
  [ ! -s "$WIKI_ARGV_LOG" ] || fail "unconfigured catalog must not invoke the engine"
  pass "no private catalog configured says so and does nothing"
}

test_miss_calls_classifier_and_prints_envelope() {
  local code out err line body
  printf '%s\n' "$FAKEBIN/wiki-tool" > "$HOME_DIR/config/wiki-engine"
  write_catalog
  FAKE_WIKI_STATUS=no-match TYPESAFE_API_KEY=$TS_KEY \
    run_ask code out err "$QUERY"
  expect_code 0 "$code" "miss ask exits 0"
  assert_contains "$out" '"status":"no-match"' "prints the engine envelope"
  [ -f "$HOME_DIR/state/jev-retrieval-miss.jsonl" ] \
    || fail "a no-match must record a miss classification"
  line=$(cat "$HOME_DIR/state/jev-retrieval-miss.jsonl")
  assert_contains "$line" '"purpose":"retrieval-miss"' "classifier wrote its record"
  assert_contains "$line" '"verdict":"true_miss"' "classifier recorded the choice"
  assert_contains "$line" '"retry":false' "caller did not retry"
  assert_grep "$QUERY" "$WIKI_ARGV_LOG" "engine received the query"
  [ -f "$LOG/argv" ] || fail "classifier should have called fake curl on a miss"
  body=$(cat "$LOG/body")
  assert_not_contains "$body" 'Wear insulated' "miss path does not send excerpts"
  pass "no-match prints the envelope and records a miss classification"
}

test_missing_source_also_classifies() {
  local code out err
  printf '%s\n' "$FAKEBIN/wiki-tool" > "$HOME_DIR/config/wiki-engine"
  write_catalog
  FAKE_WIKI_STATUS=missing-source TYPESAFE_API_KEY=$TS_KEY \
    run_ask code out err "$QUERY"
  expect_code 0 "$code" "missing-source ask exits 0"
  assert_contains "$out" '"status":"missing-source"' "prints missing-source"
  [ -f "$HOME_DIR/state/jev-retrieval-miss.jsonl" ] \
    || fail "missing-source must record a miss classification"
  pass "missing-source records a miss classification"
}

test_hit_does_not_classify() {
  local code out err
  printf '%s\n' "$FAKEBIN/wiki-tool" > "$HOME_DIR/config/wiki-engine"
  write_catalog
  FAKE_WIKI_STATUS=ok TYPESAFE_API_KEY=$TS_KEY \
    run_ask code out err "$QUERY"
  expect_code 0 "$code" "hit ask exits 0"
  assert_contains "$out" '"status":"ok"' "prints the hit envelope"
  assert_absent "$HOME_DIR/state/jev-retrieval-miss.jsonl" "a hit is not classified"
  [ ! -f "$LOG/argv" ] || fail "a hit must not call Jev"
  pass "an engine hit is printed and not classified"
}

test_unconfigured_engine_does_nothing
test_unconfigured_catalog_does_nothing
test_miss_calls_classifier_and_prints_envelope
test_missing_source_also_classifies
test_hit_does_not_classify

printf '# all fm-wiki-ask tests passed\n'
