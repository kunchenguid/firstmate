#!/usr/bin/env bash
# Behavior tests for bin/fm-axi-isolated.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-axi-isolated-tests)

make_fake_axi() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_AXI_VERSION:-0.1.26}"
  exit 0
fi
printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
  "${CHROME_DEVTOOLS_AXI_SESSION-}" \
  "${CHROME_DEVTOOLS_AXI_AUTO_CONNECT-}" \
  "${CHROME_DEVTOOLS_AXI_BROWSER_URL-}" \
  "${CHROME_DEVTOOLS_AXI_USER_DATA_DIR-}" \
  "${CHROME_DEVTOOLS_AXI_CHROME_ARGS-}" \
  "${CHROME_DEVTOOLS_AXI_PORT-}" \
  "${CHROME_DEVTOOLS_AXI_WS_HEADERS-}" \
  "${CHROME_DEVTOOLS_AXI_MCP_PATH-}" \
  "$*" >> "${FM_AXI_LOG:?}"
SH
  chmod +x "$fakebin/chrome-devtools-axi"
  printf '%s\n' "$fakebin"
}

run_axi() {
  local fakebin=$1 log=$2 session_file=$3
  shift 3
  PATH="$fakebin:$PATH" FM_AXI_LOG="$log" \
    FM_AXI_VERSION="${FM_AXI_VERSION:-0.1.26}" \
    CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1 \
    CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:9222 \
    CHROME_DEVTOOLS_AXI_USER_DATA_DIR=/tmp/profile \
    CHROME_DEVTOOLS_AXI_CHROME_ARGS=--user-data-dir=/tmp/other-profile \
    CHROME_DEVTOOLS_AXI_PORT=9222 \
    CHROME_DEVTOOLS_AXI_SESSION=default \
    CHROME_DEVTOOLS_AXI_WS_HEADERS='{"Authorization":"Bearer token"}' \
    CHROME_DEVTOOLS_AXI_MCP_PATH=/tmp/mcp.js \
    "$ROOT/bin/fm-axi-isolated.sh" "$session_file" "$@"
}

test_durable_session_sanitizes_every_command() {
  local case_dir fakebin log session_file first second third session auto browser profile args port headers mcp command
  case_dir="$TMP_ROOT/durable-session"
  fakebin=$(make_fake_axi "$case_dir")
  log="$case_dir/axi.log"
  session_file="$case_dir/state/axi-session"

  run_axi "$fakebin" "$log" "$session_file" open https://example.test
  assert_present "$session_file" "AXI session record was not created"
  run_axi "$fakebin" "$log" "$session_file" snapshot
  run_axi "$fakebin" "$log" "$session_file" stop
  assert_absent "$session_file" "AXI session record survived a successful stop"

  first=$(sed -n '1p' "$log")
  second=$(sed -n '2p' "$log")
  third=$(sed -n '3p' "$log")
  [ -n "$first" ] && [ -n "$second" ] && [ -n "$third" ] || fail "AXI wrapper did not run every command"
  IFS='|' read -r session auto browser profile args port headers mcp command <<< "$first"
  case "$session" in
    firstmate-isolated-*) ;;
    *) fail "AXI wrapper selected an unsafe session: $session" ;;
  esac
  [ -z "$auto$browser$profile$args$port$headers$mcp" ] || fail "AXI wrapper retained inherited attachment state"
  [ -n "$command" ] || fail "AXI wrapper did not forward its command"
  for line in "$second" "$third"; do
    IFS='|' read -r session auto browser profile args port headers mcp command <<< "$line"
    [ "$session" = "${first%%|*}" ] || fail "AXI wrapper changed sessions during one task"
    [ -z "$auto$browser$profile$args$port$headers$mcp" ] || fail "AXI wrapper retained inherited attachment state"
    [ -n "$command" ] || fail "AXI wrapper did not forward its command"
  done
  pass "fm-axi-isolated.sh persists one sanitized session through stop"
}

test_legacy_axi_cannot_create_an_isolated_session() {
  local case_dir fakebin log session_file rc
  case_dir="$TMP_ROOT/legacy-version"
  fakebin=$(make_fake_axi "$case_dir")
  log="$case_dir/axi.log"
  session_file="$case_dir/state/axi-session"

  set +e
  FM_AXI_VERSION=0.1.25 run_axi "$fakebin" "$log" "$session_file" open https://example.test > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy AXI should be rejected before use"
  assert_absent "$session_file" "legacy AXI created an unsafe session record"
  assert_absent "$log" "legacy AXI received a browser command"
  grep -F '0.1.26 or newer' "$case_dir/stderr" >/dev/null || fail "legacy AXI rejection did not explain the session requirement"
  pass "fm-axi-isolated.sh rejects AXI without named sessions"
}

test_durable_session_sanitizes_every_command
test_legacy_axi_cannot_create_an_isolated_session
