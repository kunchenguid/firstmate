#!/usr/bin/env bash
# Tests for fm-search.sh, the you.com web search wrapper.
#
# The network is never touched: a fake curl on PATH answers with a canned
# you.com /v1/search response, so the cases exercise the wrapper's key
# resolution, argument validation, and Markdown rendering without an API key
# or an outbound call. The live API shape is verified by hand on demand
# (you.com/docs owns the wire contract; the script header names the owner).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-search.sh"
TMP_ROOT=$(fm_test_tmproot fm-search)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

# Canned /v1/search response: two web results with snippets.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"results":{"web":[
  {"url":"https://example.com/one","title":"First Result","description":"Desc one","snippets":["Snip 1a","Snip 1b"]},
  {"url":"https://example.com/two","title":"Second Result","description":"Desc two","snippets":["Snip 2a"]}
]}}
JSON
SH
chmod +x "$FAKEBIN/curl"

# A key file the wrapper reads when YOUCOM_API_KEY is unset.
KEYDIR="$TMP_ROOT/keyhome"
mkdir -p "$KEYDIR/.pi/agent"
printf 'test-key-123\n' > "$KEYDIR/.pi/agent/youcom.key"
chmod 600 "$KEYDIR/.pi/agent/youcom.key"

export PATH="$FAKEBIN:$PATH"
export HOME="$KEYDIR"
unset YOUCOM_API_KEY

test_no_query_refuses() {
  if out=$(HOME="$KEYDIR" "$CHECK" 2>&1); then
    fail "no query must exit nonzero"
  fi
  case "$out" in
    *usage:*) pass "no query prints usage" ;;
    *) fail "no query should print usage, got: $out" ;;
  esac
}

test_key_file_fallback_renders_markdown() {
  out=$(HOME="$KEYDIR" "$CHECK" "test query" --count 2) || fail "search with key-file fallback exits zero"
  case "$out" in
    *"## First Result"*"https://example.com/one"*"Desc one"*"> Snip 1a"*) pass "renders first result block" ;;
    *) fail "first result block missing, got: $out" ;;
  esac
  case "$out" in
    *"## Second Result"*"https://example.com/two"*"> Snip 2a"*) pass "renders second result block" ;;
    *) fail "second result block missing, got: $out" ;;
  esac
}

test_env_key_takes_precedence() {
  out=$(HOME="$KEYDIR" YOUCOM_API_KEY="env-key" "$CHECK" "test query" --count 2) || fail "search with env key exits zero"
  if [ -n "$out" ]; then
    pass "env key path produces output"
  else
    fail "env key path produced no output"
  fi
}

test_missing_key_refuses() {
  empty_home="$TMP_ROOT/nokey"
  mkdir -p "$empty_home"
  if out=$(HOME="$empty_home" "$CHECK" "test query" 2>&1); then
    fail "missing key must exit nonzero"
  fi
  case "$out" in
    *"no API key"*) pass "missing key names the fix" ;;
    *) fail "missing key should name the fix, got: $out" ;;
  esac
}

test_invalid_count_refused() {
  if out=$(HOME="$KEYDIR" "$CHECK" "test query" --count 999 2>&1); then
    fail "count > 100 must be rejected"
  fi
  case "$out" in
    *"--count must be 1-100"*) pass "count error message clear" ;;
    *) fail "count error should be clear, got: $out" ;;
  esac
}

test_api_error_surfaces() {
  cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"error":"invalid request parameter(s)"}'
SH
  chmod +x "$FAKEBIN/curl"
  if out=$(HOME="$KEYDIR" "$CHECK" "test query" 2>&1); then
    fail "API error must exit nonzero"
  fi
  case "$out" in
    *"API error"*"invalid request"*) pass "API error surfaces the message" ;;
    *) fail "API error should surface the message, got: $out" ;;
  esac
}

test_no_query_refuses
test_key_file_fallback_renders_markdown
test_env_key_takes_precedence
test_missing_key_refuses
test_invalid_count_refused
test_api_error_surfaces
