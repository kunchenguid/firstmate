#!/usr/bin/env bash
# Behavior tests for the fail-closed Markdown preview helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-markdown-preview.py"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-markdown-preview.XXXXXX")
LONG_LIVED_PID=

cleanup() {
  if [ -n "$LONG_LIVED_PID" ]; then
    kill "$LONG_LIVED_PID" 2>/dev/null || true
    kill -9 "$LONG_LIVED_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

OPENER="$TMP_ROOT/opener.py"
cat >"$OPENER" <<'PY'
#!/usr/bin/env python3
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

capture = Path(os.environ["FM_PREVIEW_TEST_CAPTURE"])
capture.mkdir(parents=True, exist_ok=True)
url = sys.argv[1]
(capture / "url").write_text(url, encoding="utf-8")

source = os.environ.get("FM_PREVIEW_TEST_MUTATE")
if source:
    Path(source).write_text("# Replaced after launch\n", encoding="utf-8")

if os.environ.get("FM_PREVIEW_TEST_SKIP_FETCH"):
    raise SystemExit(0)

request = urllib.request.Request(url, headers={"User-Agent": "fm-preview-test"})
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
try:
    with opener.open(request, timeout=2) as response:
        (capture / "status").write_text(str(response.status), encoding="utf-8")
        (capture / "headers").write_text(
            "".join(f"{key}: {value}\n" for key, value in response.headers.items()),
            encoding="utf-8",
        )
        (capture / "body").write_bytes(response.read())
except urllib.error.HTTPError as error:
    (capture / "status").write_text(str(error.code), encoding="utf-8")
    (capture / "body").write_bytes(error.read())
    raise SystemExit(4)

if os.environ.get("FM_PREVIEW_TEST_STAY_OPEN"):
    (capture / "pid").write_text(str(os.getpid()), encoding="utf-8")
    while True:
        time.sleep(1)
PY
chmod +x "$OPENER"

assert_present "$HELPER" "Markdown preview helper is missing"
[ -x "$HELPER" ] || fail "Markdown preview helper must be executable"

wait_for_file() {
  local path=$1 attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -e "$path" ] && return 0
    sleep 0.05
  done
  fail "timed out waiting for test artifact $path"
}

test_safe_render_and_cleanup() {
  local source="$TMP_ROOT/safe.md" capture="$TMP_ROOT/safe-capture"
  cat >"$source" <<'MD'
# Safety preview

<script>window.bad = true</script>
<img src="https://raw-image.example.invalid/raw.png" onerror="window.bad = true">

![Remote pixel](https://pixel.example.invalid/pixel.png)

[Safe remote link](https://example.invalid/read)
[Unsafe link](javascript:alert(1))
[Malformed link](https://[invalid)

```html
<iframe src="https://frames.example.invalid/"></iframe>
```

```
bare fenced code
```
MD

  FM_PREVIEW_TEST_CAPTURE="$capture" \
    "$HELPER" --opener "$OPENER" --timeout 2 "$source" \
    >"$TMP_ROOT/safe.out" 2>"$TMP_ROOT/safe.err" \
    || fail "safe Markdown preview failed: $(cat "$TMP_ROOT/safe.err")"

  wait_for_file "$capture/body"
  assert_grep "http://127.0.0.1:" "$capture/url" \
    "preview did not bind to loopback"
  [ "$(cat "$capture/status")" = 200 ] \
    || fail "preview opener did not receive HTTP 200"
  assert_grep "Content-Security-Policy: default-src 'none'" "$capture/headers" \
    "preview response is missing its fail-closed CSP"
  assert_grep "&lt;script&gt;window.bad = true&lt;/script&gt;" "$capture/body" \
    "raw HTML was not escaped"
  assert_no_grep "<script>" "$capture/body" \
    "preview emitted an executable script element"
  assert_no_grep "pixel.example.invalid" "$capture/body" \
    "preview retained a remote image subresource"
  assert_no_grep "<img" "$capture/body" \
    "preview emitted an image element"
  assert_no_grep "<iframe" "$capture/body" \
    "preview emitted a frame element"
  assert_grep "<pre><code>bare fenced code</code></pre>" "$capture/body" \
    "preview did not render a bare fenced code block"
  assert_no_grep 'href="javascript:' "$capture/body" \
    "preview retained an unsafe link scheme"
  assert_grep 'href="https://example.invalid/read"' "$capture/body" \
    "preview dropped an ordinary remote hyperlink"
  assert_grep "Malformed link" "$capture/body" \
    "preview dropped the label for a malformed link"
  assert_no_grep 'href="https://[invalid"' "$capture/body" \
    "preview retained a malformed link target"

  if python3 - "$(cat "$capture/url")" >/dev/null 2>&1 <<'PY'
import sys
import urllib.request

urllib.request.urlopen(sys.argv[1], timeout=0.5)
PY
  then
    fail "preview server remained reachable after the helper exited"
  fi

  pass "Markdown preview escapes HTML, blocks subresources, and cleans up"
}

test_changed_source_fails_closed() {
  local source="$TMP_ROOT/changed.md" capture="$TMP_ROOT/changed-capture" rc=0
  printf '# Original snapshot\n' >"$source"

  FM_PREVIEW_TEST_CAPTURE="$capture" \
    FM_PREVIEW_TEST_MUTATE="$source" \
    "$HELPER" --opener "$OPENER" --timeout 2 "$source" \
    >"$TMP_ROOT/changed.out" 2>"$TMP_ROOT/changed.err" || rc=$?

  [ "$rc" -ne 0 ] || fail "preview served a stale snapshot after the source changed"
  [ "$(cat "$capture/status")" = 409 ] \
    || fail "changed source did not receive HTTP 409"
  assert_no_grep "Original snapshot" "$capture/body" \
    "changed source response leaked stale rendered content"
  assert_grep "source changed before preview delivery" "$TMP_ROOT/changed.err" \
    "changed source failure was not explained"
  pass "Markdown preview refuses stale source snapshots"
}

test_server_wait_is_bounded() {
  local source="$TMP_ROOT/bounded.md" capture="$TMP_ROOT/bounded-capture" rc=0
  printf '# Bounded server\n' >"$source"

  FM_PREVIEW_TEST_CAPTURE="$capture" \
    FM_PREVIEW_TEST_SKIP_FETCH=1 \
    "$HELPER" --opener "$OPENER" --timeout 0.2 "$source" \
    >"$TMP_ROOT/bounded.out" 2>"$TMP_ROOT/bounded.err" || rc=$?

  [ "$rc" -ne 0 ] || fail "preview succeeded without a browser fetch"
  assert_grep "timed out waiting for the browser" "$TMP_ROOT/bounded.err" \
    "bounded wait failure was not explained"
  if python3 - "$(cat "$capture/url")" >/dev/null 2>&1 <<'PY'
import sys
import urllib.request

urllib.request.urlopen(sys.argv[1], timeout=0.5)
PY
  then
    fail "timed-out preview server remained reachable"
  fi
  pass "Markdown preview bounds serving time and cleans up on timeout"
}

test_verified_delivery_detaches_long_lived_opener() {
  local source="$TMP_ROOT/long-lived.md" capture="$TMP_ROOT/long-lived-capture"
  local attempt
  printf '# Foreground browser handler\n' >"$source"

  FM_PREVIEW_TEST_CAPTURE="$capture" \
    FM_PREVIEW_TEST_STAY_OPEN=1 \
    "$HELPER" --opener "$OPENER" --timeout 2 "$source" \
    >"$TMP_ROOT/long-lived.out" 2>"$TMP_ROOT/long-lived.err" \
    || fail "verified delivery waited for or terminated its opener: $(cat "$TMP_ROOT/long-lived.err")"

  wait_for_file "$capture/pid"
  assert_present "$capture/pid" "long-lived opener did not record its pid"
  LONG_LIVED_PID=$(cat "$capture/pid")
  kill -0 "$LONG_LIVED_PID" 2>/dev/null \
    || fail "verified delivery terminated the foreground browser handler"

  kill "$LONG_LIVED_PID" 2>/dev/null || true
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$LONG_LIVED_PID" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$LONG_LIVED_PID" 2>/dev/null; then
    kill -9 "$LONG_LIVED_PID" 2>/dev/null || true
  fi
  LONG_LIVED_PID=
  pass "verified delivery succeeds independently of opener lifetime"
}

test_verification_bypasses_proxy_environment() {
  local source="$TMP_ROOT/proxy.md" capture="$TMP_ROOT/proxy-capture"
  printf '# Direct loopback verification\n' >"$source"

  http_proxy=http://127.0.0.1:9 \
    HTTP_PROXY=http://127.0.0.1:9 \
    https_proxy=http://127.0.0.1:9 \
    HTTPS_PROXY=http://127.0.0.1:9 \
    ALL_PROXY=http://127.0.0.1:9 \
    no_proxy= \
    NO_PROXY= \
    FM_PREVIEW_TEST_CAPTURE="$capture" \
    "$HELPER" --opener "$OPENER" --timeout 2 "$source" \
    >"$TMP_ROOT/proxy.out" 2>"$TMP_ROOT/proxy.err" \
    || fail "proxy environment intercepted loopback verification: $(cat "$TMP_ROOT/proxy.err")"

  wait_for_file "$capture/body"
  pass "loopback verification bypasses proxy configuration"
}

test_unstarted_server_thread_cleans_up_without_deadlock() {
  local source="$TMP_ROOT/thread-start.md"
  printf '# Thread start failure\n' >"$source"

  if ! python3 - "$HELPER" "$OPENER" "$source" <<'PY'
import subprocess
import sys

code = r'''
import importlib.util
import sys
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("fm_markdown_preview", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def fail_start(_thread):
    raise RuntimeError("injected start failure")

module.threading.Thread.start = fail_start
args = SimpleNamespace(file=sys.argv[3], opener=sys.argv[2], timeout=0.2)
try:
    module.run(args)
except module.PreviewError as error:
    if "server thread" not in str(error):
        raise
else:
    raise SystemExit("thread start failure unexpectedly succeeded")
'''

try:
    result = subprocess.run(
        [sys.executable, "-c", code, *sys.argv[1:]],
        capture_output=True,
        text=True,
        timeout=3,
    )
except subprocess.TimeoutExpired:
    raise SystemExit(124)
if result.returncode != 0:
    sys.stderr.write(result.stderr)
    raise SystemExit(result.returncode)
PY
  then
    fail "server cleanup deadlocked when its thread never started"
  fi
  pass "unstarted server thread closes without shutdown deadlock"
}

test_inline_delimiter_scan_is_bounded() {
  local source="$TMP_ROOT/delimiters.md" capture="$TMP_ROOT/delimiters-capture"
  python3 - "$source" <<'PY'
import sys
from pathlib import Path

size = 2 * 1024 * 1024
Path(sys.argv[1]).write_bytes(
    b"# Delimiter load\n\n"
    + b"[" * size
    + b"\n\nx"
    + b"`" * size
    + b"\n\n~~~"
    + b" " * size
    + b"`\n"
)
PY

  if ! FM_PREVIEW_TEST_CAPTURE="$capture" \
    python3 - "$HELPER" "$OPENER" "$source" <<'PY'
import os
import subprocess
import sys

try:
    result = subprocess.run(
        [sys.argv[1], "--opener", sys.argv[2], "--timeout", "2", sys.argv[3]],
        capture_output=True,
        env=os.environ.copy(),
        text=True,
        timeout=20,
    )
except subprocess.TimeoutExpired:
    raise SystemExit(124)
if result.returncode != 0:
    sys.stderr.write(result.stderr)
    raise SystemExit(result.returncode)
PY
  then
    fail "delimiter-heavy Markdown exceeded its bounded render time"
  fi
  pass "inline delimiter scanning remains bounded"
}

test_block_parser_scans_are_bounded() {
  local source="$TMP_ROOT/block-scans.md" capture="$TMP_ROOT/block-scans-capture"
  python3 - "$source" <<'PY'
import sys
from pathlib import Path

marker = b"~" * (2 * 1024 * 1024)
heading = b"# title" + b" " * (2 * 1024 * 1024) + b"x\n"
Path(sys.argv[1]).write_bytes(
    marker + b"\n" + b"body\n" * 512 + marker + b"\n\n" + heading
)
PY

  if ! FM_PREVIEW_TEST_CAPTURE="$capture" \
    python3 - "$HELPER" "$OPENER" "$source" <<'PY'
import os
import subprocess
import sys

try:
    result = subprocess.run(
        [sys.argv[1], "--opener", sys.argv[2], "--timeout", "2", sys.argv[3]],
        capture_output=True,
        env=os.environ.copy(),
        text=True,
        timeout=20,
    )
except subprocess.TimeoutExpired:
    raise SystemExit(124)
if result.returncode != 0:
    sys.stderr.write(result.stderr)
    raise SystemExit(result.returncode)
PY
  then
    fail "block delimiter-heavy Markdown exceeded its bounded render time"
  fi
  pass "fence and heading parsing remain bounded"
}

test_render_object_budgets_fail_before_accumulation() {
  local lines="$TMP_ROOT/too-many-lines.md" parts="$TMP_ROOT/too-many-parts.md" rc=0
  python3 - "$lines" "$parts" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(b"x\n\n" * 100001)
Path(sys.argv[2]).write_bytes(
    b"|a|b|\n|---|---|\n" + b"|x|x|\n" * 40000
)
PY

  "$HELPER" --opener "$OPENER" --timeout 2 "$lines" \
    >"$TMP_ROOT/too-many-lines.out" 2>"$TMP_ROOT/too-many-lines.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "excessive source lines were accepted"
  assert_grep "source exceeds" "$TMP_ROOT/too-many-lines.err" \
    "source line budget failure was not explained"

  rc=0
  "$HELPER" --opener "$OPENER" --timeout 2 "$parts" \
    >"$TMP_ROOT/too-many-parts.out" 2>"$TMP_ROOT/too-many-parts.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "excessive render parts were accepted"
  assert_grep "rendered preview exceeds" "$TMP_ROOT/too-many-parts.err" \
    "render part budget failure was not explained"
  pass "source line and render part budgets fail before accumulation"
}

test_non_table_delimiters_do_not_trigger_table_limits() {
  local source="$TMP_ROOT/non-table.md" capture="$TMP_ROOT/non-table-capture"
  python3 - "$source" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(
    "Ordinary | prose\n" + "value|" * 2048 + "\n",
    encoding="utf-8",
)
PY

  FM_PREVIEW_TEST_CAPTURE="$capture" \
    "$HELPER" --opener "$OPENER" --timeout 2 "$source" \
    >"$TMP_ROOT/non-table.out" 2>"$TMP_ROOT/non-table.err" \
    || fail "non-table delimiters triggered table limits: $(cat "$TMP_ROOT/non-table.err")"

  wait_for_file "$capture/body"
  assert_grep "Ordinary | prose" "$capture/body" \
    "non-table prose was not rendered"
  pass "table limits apply only after divider recognition"
}

test_blockquote_nesting_is_bounded() {
  local source="$TMP_ROOT/blockquote-depth.md" rc=0
  python3 - "$source" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_text("> " * 128 + "nested\n", encoding="utf-8")
PY

  "$HELPER" --opener "$OPENER" --timeout 2 "$source" \
    >"$TMP_ROOT/blockquote-depth.out" 2>"$TMP_ROOT/blockquote-depth.err" || rc=$?

  [ "$rc" -ne 0 ] || fail "excessive blockquote nesting was accepted"
  assert_grep "blockquote nesting exceeds" "$TMP_ROOT/blockquote-depth.err" \
    "blockquote depth failure was not explained"
  pass "blockquote nesting fails closed at its configured bound"
}

test_blockquote_copy_budget_fails_before_amplification() {
  local source="$TMP_ROOT/blockquote-copy.md" rc=0
  python3 - "$source" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(b"> " * 64 + b"x" * (6 * 1024 * 1024) + b"\n")
PY

  "$HELPER" --opener "$OPENER" --timeout 2 "$source" \
    >"$TMP_ROOT/blockquote-copy.out" 2>"$TMP_ROOT/blockquote-copy.err" || rc=$?

  [ "$rc" -ne 0 ] || fail "amplifying blockquote input was accepted"
  assert_grep "blockquote input exceeds" "$TMP_ROOT/blockquote-copy.err" \
    "blockquote copy budget failure was not explained"
  pass "blockquote copies fail before input amplification"
}

test_table_cell_budget_fails_before_wide_render() {
  local source="$TMP_ROOT/wide-table.md" rc=0
  python3 - "$source" <<'PY'
import sys
from pathlib import Path

columns = 2048
header = "|" + "x|" * columns
divider = "|" + "---|" * columns
Path(sys.argv[1]).write_text(header + "\n" + divider + "\n", encoding="utf-8")
PY

  "$HELPER" --opener "$OPENER" --timeout 2 "$source" \
    >"$TMP_ROOT/wide-table.out" 2>"$TMP_ROOT/wide-table.err" || rc=$?

  [ "$rc" -ne 0 ] || fail "wide table exceeded the render budget without refusal"
  assert_grep "table exceeds" "$TMP_ROOT/wide-table.err" \
    "wide table budget failure was not explained"
  pass "table cell budgets reject wide renders before accumulation"
}

test_expanded_render_verifies_in_full() {
  local source="$TMP_ROOT/expanded.md" capture="$TMP_ROOT/expanded-capture"
  local rendered_size
  python3 - "$source" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(b"# Expanded body\n\n" + b"&" * (2 * 1024 * 1024) + b"\n")
PY

  FM_PREVIEW_TEST_CAPTURE="$capture" \
    "$HELPER" --opener "$OPENER" --timeout 2 "$source" \
    >"$TMP_ROOT/expanded.out" 2>"$TMP_ROOT/expanded.err" \
    || fail "expanded rendered body was not verified in full: $(cat "$TMP_ROOT/expanded.err")"

  wait_for_file "$capture/body"
  rendered_size=$(wc -c <"$capture/body" | tr -d ' ')
  [ "$rendered_size" -gt $((8 * 1024 * 1024)) ] \
    || fail "expanded render fixture did not exceed the source-byte verification bound"
  pass "expanded rendered bodies verify against their own bounded length"
}

test_safe_render_and_cleanup
test_changed_source_fails_closed
test_server_wait_is_bounded
test_verified_delivery_detaches_long_lived_opener
test_verification_bypasses_proxy_environment
test_unstarted_server_thread_cleans_up_without_deadlock
test_inline_delimiter_scan_is_bounded
test_block_parser_scans_are_bounded
test_render_object_budgets_fail_before_accumulation
test_non_table_delimiters_do_not_trigger_table_limits
test_blockquote_nesting_is_bounded
test_blockquote_copy_budget_fails_before_amplification
test_table_cell_budget_fails_before_wide_render
test_expanded_render_verifies_in_full
