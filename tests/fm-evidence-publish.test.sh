#!/usr/bin/env bash
# Behavior tests for bin/fm-evidence-publish.sh.
#
# The script is a no-mistakes `test.evidence.upload_cmd` hook, so the properties
# that matter are contract properties: exactly one URL on stdout on success, a
# non-zero exit and NO url on any failure, and a secret gate that refuses rather
# than best-efforts. html-preview is stubbed via FM_HTML_PREVIEW: these tests
# must never publish anything to the corporate network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PUBLISH="$ROOT/bin/fm-evidence-publish.sh"
TMP_ROOT=$(fm_test_tmproot fm-evidence-publish)
export TMPDIR="$TMP_ROOT/stage" # keep the deterministic staging dir inside the test root
mkdir -p "$TMPDIR"

# Stub html-preview: echoes a URL derived from the staged file it was handed, and
# records every call so the tests can assert what was (and was not) published.
STUB="$TMP_ROOT/html-preview"
CALLS="$TMP_ROOT/calls.log"
cat >"$STUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$CALLS"
echo "publishing..." >&2
echo "https://stub.example.invalid/$(basename "$1")"
SH
chmod +x "$STUB"
export FM_HTML_PREVIEW="$STUB" CALLS

EV="$TMP_ROOT/evidence/fm-branch"
mkdir -p "$EV/ev-1" "$EV/ev-2"

# --- image evidence: wrapped as a data: URI page, one URL on stdout ----------
printf '\x89PNG\r\n\x1a\nfakepngbytes' >"$EV/ev-1/shot.png"
out=$(NM_EVIDENCE_LABEL='before: the buggy row' "$PUBLISH" "$EV/ev-1/shot.png" 2>/dev/null)
code=$?
expect_code 0 "$code" "image evidence publishes"
[ "$(printf '%s\n' "$out" | grep -c .)" = "1" ] || fail "image publish printed more than one stdout line: $out"
assert_contains "$out" "https://stub.example.invalid/shot.html" "image publish prints the html-preview URL"
staged=$(tail -1 "$CALLS")
assert_grep 'data:image/png;base64,' "$staged" "image is inlined as a data: URI"
assert_grep 'before: the buggy row' "$staged" "the evidence label titles the page"

# Republishing the same file stages the same path, so html-preview reuses its alias.
out2=$("$PUBLISH" "$EV/ev-1/shot.png" 2>/dev/null)
[ "$out2" = "$out" ] || fail "republish did not reuse the URL: '$out' vs '$out2'"

# --- html evidence: published as-is, with sibling assets resolved ------------
# no-mistakes files each artifact in its own ev-<id>/ dir, which breaks the
# relative image refs an agent wrote next to its page.
cat >"$EV/ev-2/report.html" <<'HTML'
<!doctype html><html><body><img src="./shot.png" /></body></html>
HTML
out=$("$PUBLISH" "$EV/ev-2/report.html" 2>/dev/null)
expect_code 0 "$?" "html evidence publishes"
assert_contains "$out" "https://stub.example.invalid/report.html" "html publish prints the URL"
staged=$(tail -1 "$CALLS")
assert_present "$(dirname "$staged")/shot.png" "sibling asset was staged next to the page"

# A self-contained page with no src/href at all is the normal artifact shape, not a
# failure: grep finds nothing, and under pipefail that used to exit 1 silently.
cat >"$EV/ev-2/selfcontained.html" <<'HTML'
<!doctype html><html><body><h1>all inlined</h1><p>no refs here</p></body></html>
HTML
out=$("$PUBLISH" "$EV/ev-2/selfcontained.html" 2>/dev/null)
expect_code 0 "$?" "html with no src/href publishes"
assert_contains "$out" "https://stub.example.invalid/selfcontained.html" "self-contained html prints the URL"

# --- text evidence: wrapped in a <pre>, html-escaped -------------------------
printf '<not-a-tag> & done\n' >"$EV/ev-1/stdout.txt"
out=$("$PUBLISH" "$EV/ev-1/stdout.txt" 2>/dev/null)
expect_code 0 "$?" "text evidence publishes"
staged=$(tail -1 "$CALLS")
assert_grep '&lt;not-a-tag&gt; &amp; done' "$staged" "text evidence is html-escaped into the page"

# An empty file still publishes: skipping would look like an upload failure to
# no-mistakes and put a false warning in the PR description.
: >"$EV/ev-1/stderr.txt"
out=$("$PUBLISH" "$EV/ev-1/stderr.txt" 2>/dev/null)
expect_code 0 "$?" "empty text evidence still publishes"

# --- secret gate: refuse, exit non-zero, publish nothing ---------------------
before_calls=$(wc -l <"$CALLS")
i=0
while IFS= read -r secret; do
  i=$((i + 1))
  printf '%s\n' "$secret" >"$EV/ev-1/leak-$i.txt"
  out=$("$PUBLISH" "$EV/ev-1/leak-$i.txt" 2>/dev/null)
  expect_code 1 "$?" "secret gate refuses fixture $i"
  assert_not_contains "$out" "http" "secret gate printed a URL for fixture $i"
done <<'EOF'
-----BEGIN RSA PRIVATE KEY-----
export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123
Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdefghijklmnop
api_key = "abcdefghijklmnopqrstuvwx"
密级：机密
EOF
[ "$(wc -l <"$CALLS")" = "$before_calls" ] || fail "secret gate let html-preview run"

# The keyword rule is spelled lowercase, but an env dump is UPPERCASE - and that is
# the single most common way a credential reaches an evidence file. A case-sensitive
# gate published these (an internal page really did get built from the first one).
before_calls=$(wc -l <"$CALLS")
i=0
while IFS= read -r secret; do
  i=$((i + 1))
  printf '%s\n' "$secret" >"$EV/ev-1/upper-$i.txt"
  out=$("$PUBLISH" "$EV/ev-1/upper-$i.txt" 2>/dev/null)
  expect_code 1 "$?" "secret gate refuses uppercase fixture $i"
  assert_not_contains "$out" "http" "uppercase secret gate printed a URL for fixture $i"
done <<'EOF'
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
AWS_SESSION_TOKEN=FwoGZXIvYXdzEBYaDHNlc3Npb25leGFtcGxlVE9LRU4x
ANTHROPIC_AUTH_TOKEN=abcdefghijklmnopqrstuvwx
DB_PASSWORD=hunter2hunter2hunter2
Authorization: Basic YWxhZGRpbjpvcGVuc2VzYW1lMTIzNDU2
EOF
[ "$(wc -l <"$CALLS")" = "$before_calls" ] || fail "uppercase secret gate let html-preview run"

# ...and the lowercase forms the gate already caught must keep being caught.
printf 'aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n' >"$EV/ev-1/lower.txt"
out=$("$PUBLISH" "$EV/ev-1/lower.txt" 2>/dev/null)
expect_code 1 "$?" "lowercase secret is still refused"
assert_not_contains "$out" "http" "lowercase secret gate printed a URL"

# Over-refusal is the wrong failure too: a gate that eats ordinary evidence just
# teaches people to route around it. Prose that merely mentions the keywords, with
# no `key = <16+ chars of value>`, must still publish.
cat >"$EV/ev-2/prose.html" <<'HTML'
<!doctype html><html><body>
<p>Repro: the login form rejects the password before the api key is even read.</p>
<pre>GET /v1/session -> 401 (no Authorization header)</pre>
</body></html>
HTML
out=$("$PUBLISH" "$EV/ev-2/prose.html" 2>/dev/null)
expect_code 0 "$?" "evidence that only mentions the keywords still publishes"
assert_contains "$out" "https://stub.example.invalid/prose.html" "non-secret prose prints the URL"

# The label is interpolated into the page, so it is gated too.
out=$(NM_EVIDENCE_LABEL='token=ghp_abcdefghijklmnopqrstuvwxyz0123' "$PUBLISH" "$EV/ev-1/shot.png" 2>/dev/null)
expect_code 1 "$?" "secret in NM_EVIDENCE_LABEL is refused"
assert_not_contains "$out" "http" "label gate printed a URL"

# --- failure paths never print a URL ----------------------------------------
printf 'x' >"$EV/ev-1/clip.mp4"
out=$("$PUBLISH" "$EV/ev-1/clip.mp4" 2>/dev/null)
expect_code 1 "$?" "unsupported evidence type fails"
assert_not_contains "$out" "http" "unsupported type printed a URL"

out=$("$PUBLISH" "$EV/ev-1/missing.png" 2>/dev/null)
expect_code 1 "$?" "missing file fails"

cat >"$TMP_ROOT/bad-preview" <<'SH'
#!/usr/bin/env bash
echo "boom" >&2
exit 3
SH
chmod +x "$TMP_ROOT/bad-preview"
out=$(FM_HTML_PREVIEW="$TMP_ROOT/bad-preview" "$PUBLISH" "$EV/ev-1/stdout.txt" 2>/dev/null)
expect_code 1 "$?" "html-preview failure propagates"
assert_not_contains "$out" "http" "html-preview failure printed a URL anyway"

cat >"$TMP_ROOT/chatty-preview" <<'SH'
#!/usr/bin/env bash
echo "uploaded 3 files"
SH
chmod +x "$TMP_ROOT/chatty-preview"
out=$(FM_HTML_PREVIEW="$TMP_ROOT/chatty-preview" "$PUBLISH" "$EV/ev-1/stdout.txt" 2>/dev/null)
expect_code 1 "$?" "non-URL html-preview output is a failure, not a fake URL"

# --- invocation shape no-mistakes actually uses ------------------------------
# `sh -c '<upload_cmd> "$@"' sh <abs-path>`: the path arrives as the LAST arg.
out=$(sh -c "$PUBLISH"' "$@"' sh "$EV/ev-1/shot.png" 2>/dev/null)
expect_code 0 "$?" "hook-shaped invocation works"
assert_contains "$out" "https://stub.example.invalid/shot.html" "hook-shaped invocation prints the URL"

pass "fm-evidence-publish.sh: publishes html/image/text, refuses secrets, never fakes a URL"
