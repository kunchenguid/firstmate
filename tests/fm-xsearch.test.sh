#!/usr/bin/env bash
# Behavior tests for bin/fm-xsearch.sh: xAI Responses web_search / x_search
# client using SuperGrok OAuth stores or XAI_API_KEY.
#
# Network is stubbed with a fakebin curl. Real jq is used. No live tokens and no
# secrets are committed. Covers dry-run body shape, auth resolution, OAuth
# refresh write-back, tool filters, and API error mapping.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
# date +%s%3N and mktemp need coreutils/busybox on PATH
TMP_ROOT=$(fm_test_tmproot fm-xsearch-tests)

make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" method=GET url="" data="" auth="" content_type=""
argv=$*
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -X) method=$2; shift 2 ;;
    --data|--data-binary)
      case "$2" in
        @-) data=$(cat) ;;
        @*) data=$(cat -- "${2#@}") ;;
        *) data=$2 ;;
      esac
      shift 2
      ;;
    -H)
      case "$2" in
        @*)
          while IFS= read -r header; do
            case "$header" in
              Authorization:*) auth=$header ;;
              Content-Type:*) content_type=$header ;;
            esac
          done < "${2#@}"
          ;;
        Authorization:*) auth=$2 ;;
        Content-Type:*) content_type=$2 ;;
      esac
      shift 2
      ;;
    -m|-w) shift 2 ;;
    -s|-sS) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  # Never log Authorization values in full for accidental capture in CI logs.
  auth_kind=none
  case "$auth" in
    Authorization:\ Bearer\ *) auth_kind=bearer ;;
    Authorization:*) auth_kind=other ;;
  esac
  {
    echo "method=$method"
    echo "url=$url"
    echo "auth_kind=$auth_kind"
    echo "content_type=$content_type"
    echo "data=$data"
  } >> "$FAKE_CURL_LOG"
fi
case "$url" in
  */oauth2/token)
    [ -n "$ofile" ] && printf '%s' "${FAKE_TOKEN_BODY:-}" > "$ofile"
    printf '%s' "${FAKE_TOKEN_CODE:-200}"
    ;;
  */responses)
    [ -n "$ofile" ] && printf '%s' "${FAKE_RESP_BODY:-}" > "$ofile"
    printf '%s' "${FAKE_RESP_CODE:-200}"
    ;;
  *)
    [ -n "$ofile" ] && printf '%s' '{"error":"unknown url"}' > "$ofile"
    printf '%s' "${FAKE_UNKNOWN_CODE:-500}"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

sample_response() {
  cat <<'JSON'
{
  "id": "resp_test",
  "output": [
    {
      "type": "message",
      "role": "assistant",
      "content": [
        {"type": "output_text", "text": "hello from x search"}
      ]
    }
  ],
  "usage": {
    "input_tokens": 10,
    "output_tokens": 5,
    "num_server_side_tools_used": 2,
    "server_side_tool_usage_details": {
      "web_search_calls": 1,
      "x_search_calls": 1
    }
  }
}
JSON
}

write_oauth_store() {
  local path=$1 access=$2 refresh=$3 expires=$4
  mkdir -p "$(dirname "$path")"
  jq -cn \
    --arg access "$access" \
    --arg refresh "$refresh" \
    --argjson expires "$expires" \
    '{xai:{type:"oauth",access:$access,refresh:$refresh,expires:$expires},other:{type:"api",key:"keep-me"}}' \
    > "$path"
  chmod 600 "$path"
}

run_xsearch() {
  env -u XAI_API_KEY "$ROOT/bin/fm-xsearch.sh" "$@"
}

# ---------------------------------------------------------------------------

test_help_exits_zero() {
  local out rc
  out=$("$ROOT/bin/fm-xsearch.sh" --help 2>&1); rc=$?
  expect_code 0 "$rc" "help exit"
  printf '%s' "$out" | grep -q 'x_search' || fail "help should mention x_search"
  pass "fm-xsearch --help"
}

test_usage_requires_prompt() {
  local rc
  "$ROOT/bin/fm-xsearch.sh" --dry-run >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "missing prompt"
  pass "fm-xsearch refuses missing prompt"
}

test_dry_run_both_tools_default() {
  local out
  out=$("$ROOT/bin/fm-xsearch.sh" --dry-run 'what is trending on x about grok')
  printf '%s' "$out" | jq -e '
    .model == "grok-4.5"
    and .max_tool_calls == 3
    and (.tools | length) == 2
    and (.tools | map(.type) | index("web_search") != null)
    and (.tools | map(.type) | index("x_search") != null)
    and .input[0].content == "what is trending on x about grok"
  ' >/dev/null || fail "dry-run body shape: $out"
  pass "fm-xsearch dry-run default both tools"
}

test_dry_run_x_search_filters() {
  local out
  out=$("$ROOT/bin/fm-xsearch.sh" --dry-run --tool x_search \
    --allowed-handle elonmusk --allowed-handle xai \
    --from-date 2026-01-01 --to-date 2026-01-31 \
    --max-tool-calls 2 \
    --model grok-4.5 \
    'status of xAI')
  printf '%s' "$out" | jq -e '
    .max_tool_calls == 2
    and (.tools | length) == 1
    and .tools[0].type == "x_search"
    and (.tools[0].allowed_x_handles | length) == 2
    and .tools[0].from_date == "2026-01-01"
    and .tools[0].to_date == "2026-01-31"
    and (.tools[0] | has("enable_image_understanding") | not)
  ' >/dev/null || fail "filter body: $out"
  pass "fm-xsearch dry-run x_search filters"
}

test_dry_run_rejects_mixed_handle_filters() {
  local rc
  "$ROOT/bin/fm-xsearch.sh" --dry-run --tool x_search \
    --allowed-handle a --excluded-handle b 'q' >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "mixed handles"
  pass "fm-xsearch rejects mixed allow/exclude handles"
}

test_no_auth_exits_3() {
  local home fakebin rc err
  home="$TMP_ROOT/no-auth"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  err=$(HOME="$home" XDG_DATA_HOME="$home/xdg" PATH="$fakebin:$BASE_PATH" \
    run_xsearch --tool web_search 'hi' 2>&1 >/dev/null); rc=$?
  expect_code 3 "$rc" "no auth exit"
  printf '%s' "$err" | grep -qi 'no xAI auth' || fail "expected no-auth message: $err"
  pass "fm-xsearch exits 3 without auth"
}

test_api_key_env_posts_responses() {
  local home fakebin log out err rc
  home="$TMP_ROOT/api-key"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  out=$(HOME="$home" XDG_DATA_HOME="$home/xdg" PATH="$fakebin:$BASE_PATH" \
    XAI_API_KEY='test-key-not-real' \
    FAKE_CURL_LOG="$log" \
    FAKE_RESP_CODE=200 \
    FAKE_RESP_BODY="$(sample_response)" \
    "$ROOT/bin/fm-xsearch.sh" --tool web_search 'hello world' 2>"$home/err"); rc=$?
  err=$(cat "$home/err")
  expect_code 0 "$rc" "api key path"
  printf '%s' "$out" | grep -q 'hello from x search' || fail "missing text: $out"
  printf '%s' "$err" | grep -q 'x_search_calls' || fail "missing usage on stderr: $err"
  grep -q 'url=https://api.x.ai/v1/responses' "$log" || fail "did not POST /responses: $(cat "$log")"
  grep -q 'auth_kind=bearer' "$log" || fail "missing bearer auth"
  # Ensure the raw key never appears in stdout/stderr.
  printf '%s\n%s\n' "$out" "$err" | grep -q 'test-key-not-real' && fail "api key leaked to output"
  pass "fm-xsearch XAI_API_KEY posts /responses"
}

test_oauth_store_via_fm_xai_auth_file() {
  local home fakebin log store out rc
  home="$TMP_ROOT/oauth-file"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  store="$home/auth.json"
  # Far-future expiry so no refresh.
  write_oauth_store "$store" 'access-token-aaa' 'refresh-token-bbb' 9999999999999
  out=$(HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_XAI_AUTH_FILE="$store" \
    FAKE_CURL_LOG="$log" \
    FAKE_RESP_CODE=200 \
    FAKE_RESP_BODY="$(sample_response)" \
    run_xsearch --json --tool x_search 'query' 2>/dev/null); rc=$?
  expect_code 0 "$rc" "oauth file"
  printf '%s' "$out" | jq -e '.id == "resp_test"' >/dev/null || fail "json out: $out"
  grep -q 'auth_kind=bearer' "$log" || fail "oauth bearer missing"
  # No token URL hit when unexpired.
  if grep -q 'oauth2/token' "$log"; then
    fail "unexpected refresh for unexpired token"
  fi
  pass "fm-xsearch loads OAuth from FM_XAI_AUTH_FILE"
}

test_oauth_refresh_when_expired() {
  local home fakebin log store out rc new_access
  home="$TMP_ROOT/oauth-refresh"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  store="$home/auth.json"
  write_oauth_store "$store" 'old-access' 'refresh-token-ccc' 1
  out=$(HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_XAI_AUTH_FILE="$store" \
    FAKE_CURL_LOG="$log" \
    FAKE_TOKEN_CODE=200 \
    FAKE_TOKEN_BODY='{"access_token":"new-access-ddd","refresh_token":"refresh-token-eee","expires_in":3600}' \
    FAKE_RESP_CODE=200 \
    FAKE_RESP_BODY="$(sample_response)" \
    run_xsearch --tool both 'refresh me' 2>/dev/null); rc=$?
  expect_code 0 "$rc" "refresh path"
  printf '%s' "$out" | grep -q 'hello from x search' || fail "text after refresh: $out"
  grep -q 'oauth2/token' "$log" || fail "expected token refresh call"
  grep -q 'responses' "$log" || fail "expected responses call after refresh"
  new_access=$(jq -r '.xai.access' "$store")
  [ "$new_access" = 'new-access-ddd' ] || fail "store not updated: $(cat "$store")"
  jq -e '.other.key == "keep-me"' "$store" >/dev/null || fail "sibling providers clobbered"
  jq -e '.xai.refresh == "refresh-token-eee"' "$store" >/dev/null || fail "refresh token not rotated"
  pass "fm-xsearch refreshes expired OAuth and writes store back"
}

test_opencode_default_store_path() {
  local home fakebin store out rc
  home="$TMP_ROOT/oc-default"; mkdir -p "$home/xdg/opencode"
  fakebin=$(make_fake_curl "$home")
  store="$home/xdg/opencode/auth.json"
  write_oauth_store "$store" 'oc-access' 'oc-refresh' 9999999999999
  out=$(HOME="$home" XDG_DATA_HOME="$home/xdg" PATH="$fakebin:$BASE_PATH" \
    FAKE_RESP_BODY="$(sample_response)" \
    run_xsearch 'from opencode store' 2>/dev/null); rc=$?
  expect_code 0 "$rc" "opencode default store"
  printf '%s' "$out" | grep -q 'hello from x search' || fail "oc store text: $out"
  pass "fm-xsearch reads OpenCode default auth path"
}

test_pi_default_store_path() {
  local home fakebin store out rc
  home="$TMP_ROOT/pi-default"; mkdir -p "$home/.pi/agent"
  fakebin=$(make_fake_curl "$home")
  store="$home/.pi/agent/auth.json"
  write_oauth_store "$store" 'pi-access' 'pi-refresh' 9999999999999
  out=$(HOME="$home" XDG_DATA_HOME="$home/empty-xdg" PATH="$fakebin:$BASE_PATH" \
    FAKE_RESP_BODY="$(sample_response)" \
    run_xsearch 'from pi store' 2>/dev/null); rc=$?
  expect_code 0 "$rc" "pi default store"
  printf '%s' "$out" | grep -q 'hello from x search' || fail "pi store text: $out"
  pass "fm-xsearch reads Pi default auth path"
}

test_api_error_exit_4() {
  local home fakebin rc err
  home="$TMP_ROOT/api-err"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  err=$(HOME="$home" PATH="$fakebin:$BASE_PATH" \
    XAI_API_KEY='k' \
    FAKE_RESP_CODE=422 \
    FAKE_RESP_BODY='{"error":"bad"}' \
    "$ROOT/bin/fm-xsearch.sh" 'nope' 2>&1 >/dev/null); rc=$?
  expect_code 4 "$rc" "api error"
  printf '%s' "$err" | grep -q 'HTTP 422' || fail "expected 422 message: $err"
  pass "fm-xsearch maps API errors to exit 4"
}

test_prompt_file_and_stdin() {
  local home fakebin out rc pf
  home="$TMP_ROOT/prompt-file"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  pf="$home/prompt.txt"
  printf 'file prompt body' > "$pf"
  out=$(HOME="$home" PATH="$fakebin:$BASE_PATH" XAI_API_KEY='k' \
    FAKE_RESP_BODY="$(sample_response)" \
    "$ROOT/bin/fm-xsearch.sh" --dry-run --prompt-file "$pf")
  printf '%s' "$out" | jq -e '.input[0].content == "file prompt body"' >/dev/null \
    || fail "prompt-file: $out"
  out=$(printf 'stdin prompt' | HOME="$home" PATH="$fakebin:$BASE_PATH" XAI_API_KEY='k' \
    "$ROOT/bin/fm-xsearch.sh" --dry-run -)
  printf '%s' "$out" | jq -e '.input[0].content == "stdin prompt"' >/dev/null \
    || fail "stdin prompt: $out"
  pass "fm-xsearch --prompt-file and stdin"
}

test_custom_base_url() {
  local home fakebin log rc
  home="$TMP_ROOT/base-url"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  HOME="$home" PATH="$fakebin:$BASE_PATH" XAI_API_KEY='k' \
    FM_XAI_BASE_URL='https://example.test/v1' \
    FAKE_CURL_LOG="$log" \
    FAKE_RESP_BODY="$(sample_response)" \
    "$ROOT/bin/fm-xsearch.sh" 'ping' >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "custom base"
  grep -q 'url=https://example.test/v1/responses' "$log" || fail "base url not used: $(cat "$log")"
  pass "fm-xsearch honors FM_XAI_BASE_URL"
}

# ---------------------------------------------------------------------------

test_help_exits_zero
test_usage_requires_prompt
test_dry_run_both_tools_default
test_dry_run_x_search_filters
test_dry_run_rejects_mixed_handle_filters
test_no_auth_exits_3
test_api_key_env_posts_responses
test_oauth_store_via_fm_xai_auth_file
test_oauth_refresh_when_expired
test_opencode_default_store_path
test_pi_default_store_path
test_api_error_exit_4
test_prompt_file_and_stdin
test_custom_base_url

echo "all fm-xsearch tests passed"
