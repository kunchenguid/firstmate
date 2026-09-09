#!/usr/bin/env bash
# Behavioral regression for bin/fm-verify-page.sh, the real-browser page
# verification helper that replaces chrome-devtools-axi (docs/known-tool-defects.md).
#
# Self-skips (optional-binary style, matching tests/fm-backend-cmux-smoke.test.sh)
# when the vendored playwright-core dependency has not been installed with
# `npm install --prefix bin/fm-verify-page`. Once that dependency is present,
# every assertion below must actually pass - this suite never treats an
# environment gap in the browser itself (missing native libraries, a missing
# executable) as a reason to skip, because that is exactly the failure class
# this tool exists to report loudly instead of hiding.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFY="$ROOT/bin/fm-verify-page.sh"
TMP_ROOT=$(fm_test_tmproot fm-verify-page)

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
[ -d "$ROOT/bin/fm-verify-page/node_modules/playwright-core" ] || {
  echo "skip: playwright-core not installed (run: npm install --prefix $ROOT/bin/fm-verify-page)"
  exit 0
}

# --- hermetic local fixtures -------------------------------------------------
#
# A local HTTP server gives a real page (real status, real rendered title and
# text, real screenshot) without depending on internet access in CI, matching
# this repo's hermetic-test convention (see AGENTS.md section 3 on CI).

SERVER_LOG="$TMP_ROOT/server.log"
node -e '
const http = require("node:http");
const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/html" });
  res.end("<html><head><title>FM Verify Test Page</title></head><body>Hello from fm-verify-page test</body></html>");
});
server.listen(0, "127.0.0.1", () => { console.log(server.address().port); });
' > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

cleanup_server() {
  kill "$SERVER_PID" >/dev/null 2>&1
  wait "$SERVER_PID" 2>/dev/null
}
trap cleanup_server EXIT INT TERM

PORT=""
for _ in $(seq 1 50); do
  PORT=$(head -n1 "$SERVER_LOG" 2>/dev/null)
  [ -n "$PORT" ] && break
  sleep 0.1
done
[ -n "$PORT" ] || fail "local test server never printed a port ($(cat "$SERVER_LOG" 2>/dev/null))"

# A high ephemeral port that is opened and immediately closed, so a connection
# to it is deterministically refused without depending on Chromium's blocked
# low-port list (ERR_UNSAFE_PORT) or on any real external host.
DEAD_PORT=$(node -e '
const net = require("node:net");
const s = net.createServer();
s.listen(0, "127.0.0.1", () => {
  const p = s.address().port;
  s.close(() => console.log(p));
});
')

test_real_page_returns_200_and_title() {
  local out code
  out=$("$VERIFY" "http://127.0.0.1:$PORT/" 2>&1)
  code=$?
  expect_code 0 "$code" "verifying the local test page"
  assert_contains "$out" '"status": 200' "did not report HTTP 200 for the local test page"
  assert_contains "$out" '"title": "FM Verify Test Page"' "did not report the rendered page title"
  assert_contains "$out" "Hello from fm-verify-page test" "did not report rendered visible text"
  pass "a real page reports 200 and the rendered title/text"
}

test_screenshot_written_and_nonempty() {
  local shot out size
  shot="$TMP_ROOT/shot.png"
  out=$("$VERIFY" "http://127.0.0.1:$PORT/" --screenshot "$shot" 2>&1)
  expect_code 0 "$?" "verifying with --screenshot"
  assert_present "$shot" "screenshot file was not created"
  size=$(wc -c < "$shot")
  [ "$size" -gt 0 ] || fail "screenshot file is empty (0 bytes) - exactly the chrome-devtools-axi failure this replaces"
  assert_contains "$out" "\"screenshot\": \"$shot\"" "success output did not report the screenshot path"
  pass "a screenshot path is created and non-empty, and only reported after being verified on disk"
}

test_bad_url_fails_loudly() {
  local out code
  out=$("$VERIFY" "http://127.0.0.1:$DEAD_PORT/" 2>&1)
  code=$?
  [ "$code" -ne 0 ] || fail "a connection-refused URL exited 0"
  assert_contains "$out" "fm-verify-page:" "failure output missing the tool's error prefix"
  assert_not_contains "$out" '"status": 200' "reported success for a URL nothing is listening on"
  pass "a bad URL fails loudly with a non-zero exit and a real error on stderr"
}

test_missing_browser_fails_loudly_never_silently() {
  local out code
  out=$(PLAYWRIGHT_BROWSERS_PATH="$TMP_ROOT/no-such-browsers-dir" "$VERIFY" "http://127.0.0.1:$PORT/" 2>&1)
  code=$?
  [ "$code" -ne 0 ] || fail "a missing browser install exited 0"
  assert_contains "$out" "fm-verify-page:" "failure output missing the tool's error prefix"
  assert_not_contains "$out" '"status": 200' "reported success despite the browser never starting"
  pass "an unstartable browser fails loudly instead of reporting false success"
}

test_real_page_returns_200_and_title
test_screenshot_written_and_nonempty
test_bad_url_fails_loudly
test_missing_browser_fails_loudly_never_silently
