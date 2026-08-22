#!/usr/bin/env bash
# Opt-in interactive smoke for the real WSL-to-Windows Lavish lifecycle.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_LAVISH_WINDOWS_LIVE:-0}" != 1 ]; then
  printf 'skip: set FM_LAVISH_WINDOWS_LIVE=1 under WSL to open the real Windows Lavish review\n'
  exit 0
fi

[ "$("$ROOT/bin/fm-lavish.sh" runtime)" = windows ] \
  || fail "the live Windows Lavish smoke requires WSL routing"

TMP_ROOT=$(fm_test_tmproot fm-lavish-windows-live)
ARTIFACT="$TMP_ROOT/review with spaces # live.html"
RESULT="$TMP_ROOT/poll.out"
printf '%s\n' '<!doctype html><html><body><h1>Firstmate WSL Lavish smoke</h1><p>Submit any feedback, then choose Send &amp; End.</p></body></html>' > "$ARTIFACT"

cleanup() {
  "$ROOT/bin/fm-lavish.sh" end "$ARTIFACT" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

"$ROOT/bin/fm-lavish.sh" doctor 0.1.46 \
  || fail "the Windows Lavish prerequisite check failed"
"$ROOT/bin/fm-lavish.sh" open "$ARTIFACT" \
  || fail "the Windows Lavish session did not open"
printf 'action: submit feedback in the opened Windows browser and choose Send & End; this smoke now waits for that real session\n' >&2
"$ROOT/bin/fm-lavish.sh" poll "$ARTIFACT" > "$RESULT" \
  || fail "poll did not resolve against the opened Windows session"
grep -F 'session:' "$RESULT" >/dev/null \
  || fail "the real Windows poll returned no Lavish session envelope"

cleanup
trap - EXIT HUP INT TERM
pass "real WSL open and poll used the Windows Lavish session; Send & End closed it"
