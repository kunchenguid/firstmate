#!/usr/bin/env bash
# Behavior tests for the fail-closed Markdown preview helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-markdown-preview.py"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-markdown-preview.XXXXXX")

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

OPENER="$TMP_ROOT/opener.py"
cat >"$OPENER" <<'PY'
#!/usr/bin/env python3
import os
import sys
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
try:
    with urllib.request.urlopen(request, timeout=2) as response:
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
PY
chmod +x "$OPENER"

assert_present "$HELPER" "Markdown preview helper is missing"
[ -x "$HELPER" ] || fail "Markdown preview helper must be executable"

test_safe_render_and_cleanup() {
  local source="$TMP_ROOT/safe.md" capture="$TMP_ROOT/safe-capture"
  cat >"$source" <<'MD'
# Safety preview

<script>window.bad = true</script>
<img src="https://raw-image.example.invalid/raw.png" onerror="window.bad = true">

![Remote pixel](https://pixel.example.invalid/pixel.png)

[Safe remote link](https://example.invalid/read)
[Unsafe link](javascript:alert(1))

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

test_safe_render_and_cleanup
test_changed_source_fails_closed
test_server_wait_is_bounded
