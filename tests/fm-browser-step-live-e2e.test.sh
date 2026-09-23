#!/usr/bin/env bash
# Live browser guard for compact, isolated, redacted browser steps.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_BROWSER_STEPS_LIVE chrome-devtools-axi node

SESSION="fm-browser-steps-$$-${RANDOM}"
FIXTURE="$ROOT/tests/fixtures/browser-steps/index.html"
STARTED=0
ARGS_SESSION=""
ARGS_ROOT=""

cleanup() {
  if [ "$STARTED" -eq 1 ]; then
    CHROME_DEVTOOLS_AXI_SESSION="$SESSION" chrome-devtools-axi stop >/dev/null 2>&1 || true
  fi
  if [ -n "$ARGS_SESSION" ]; then
    CHROME_DEVTOOLS_AXI_SESSION="$ARGS_SESSION" chrome-devtools-axi stop >/dev/null 2>&1 || true
  fi
  [ -z "$ARGS_ROOT" ] || rm -rf "$ARGS_ROOT"
  fm_test_cleanup
}
fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }
trap cleanup EXIT

unset CHROME_DEVTOOLS_AXI_AUTO_CONNECT CHROME_DEVTOOLS_AXI_BROWSER_URL \
  CHROME_DEVTOOLS_AXI_WS_HEADERS CHROME_DEVTOOLS_AXI_USER_DATA_DIR \
  CHROME_DEVTOOLS_AXI_PORT CHROME_DEVTOOLS_AXI_CHROME_ARGS
export CHROME_DEVTOOLS_AXI_SESSION="$SESSION"

chrome-devtools-axi start >/dev/null 2>&1 || fail 'could not start the named isolated browser session'
STARTED=1
FIXTURE_URL=$(node -e 'process.stdout.write(JSON.stringify(require("node:url").pathToFileURL(process.argv[1]).href))' "$FIXTURE") \
  || fail 'could not encode fixture URL'
printf 'await page.open(%s);\nconsole.log("fixture-opened");\n' "$FIXTURE_URL" |
  chrome-devtools-axi run >/dev/null 2>&1 || fail 'could not open the local fixture'

if OUT=$("$ROOT/bin/fm-browser.sh" step --click 'button=Use' --within '' --session "$SESSION" 2>&1); then
  fail 'an empty within scope was accepted'
else
  RC=$?
fi
[ "$RC" -eq 2 ] || fail 'an empty within scope must be rejected by the public command'
case "$OUT" in *'--within needs a non-empty target'*) ;; *) fail 'empty scope rejection was not specific' ;; esac
pass 'an empty within scope is rejected instead of widening the target search'

OUT=$("$ROOT/bin/fm-browser.sh" step --click 'button=Settings') || fail 'the missing-target step failed to return a result'
node -e 'const result = JSON.parse(process.argv[1]); if (result.ok || result.error !== "TARGET_NOT_FOUND" || Object.hasOwn(result, "candidates")) process.exit(1)' "$OUT" \
  || fail "the absent control did not return only not-found: $OUT"
pass 'a missing target reports not-found without fuzzy suggestions'

OUT=$("$ROOT/bin/fm-browser.sh" step --click 'button=Use#2') || fail 'the literal ordinal-like target step failed to return a result'
node -e 'const result = JSON.parse(process.argv[1]); if (result.ok || result.error !== "TARGET_NOT_FOUND") process.exit(1)' "$OUT" \
  || fail "an ordinal-like label unexpectedly selected a duplicate: $OUT"
pass 'an ordinal-like suffix remains literal and does not select a duplicate'

OUT=$("$ROOT/bin/fm-browser.sh" step \
  --click 'button=Reveal token' \
  --expect 'heading~API token created' \
  --timeout 5000) || fail 'the reveal-token step failed'
node -e '
  const result = JSON.parse(process.argv[1]);
  if (!result.ok || !result.verified || result.step !== "click") process.exit(1);
  const text = JSON.stringify(result);
  if (text.includes("cfut_Zx9Kq2Lm8Rt4Vw6Yb1Nc3Hd5Jf7Gs0PaQe8Ui2Ok4") || text.includes("StaticText")) process.exit(1);
' "$OUT" || fail 'the result was not compact, successful, and free of the revealed token'
pass 'a one-call click verifies the revealed heading without exposing page text'

OUT=$("$ROOT/bin/fm-browser.sh" step \
  --fill 'textbox=Token name' \
  --value 'scout-fixture' \
  --expect 'heading=Token name updated') || fail 'the fill step failed'
node -e '
  const result = JSON.parse(process.argv[1]);
  if (!result.ok || !result.verified || JSON.stringify(result).includes("scout-fixture")) process.exit(1);
' "$OUT" || fail 'the fill result was not verified or a typed value escaped'
pass 'typed values are not returned'

OUT=$("$ROOT/bin/fm-browser.sh" step \
  --select 'combobox=Permission' \
  --option 'DNS Edit' \
  --expect 'heading=Permission updated') || fail 'the select step failed'
node -e 'const result = JSON.parse(process.argv[1]); if (!result.ok || !result.verified) process.exit(1)' "$OUT" \
  || fail "the combobox option was not verified: $OUT"
pass 'a combobox option can be selected in one step'

OUT=$("$ROOT/bin/fm-browser.sh" step \
  --click 'button=Use' \
  --within 'region=Token 8' \
  --expect-gone 'region=Token 8') || fail 'the scoped control step failed'
node -e 'const result = JSON.parse(process.argv[1]); if (!result.ok || !result.verified) process.exit(1)' "$OUT" \
  || fail "the scoped control did not verify removal: $OUT"
pass 'within scoping selects and verifies the intended duplicate control'

OUT=$("$ROOT/bin/fm-browser.sh" step --press Enter --expect-title 'Firstmate browser-step fixture') \
  || fail 'the title expectation failed'
node -e 'const result = JSON.parse(process.argv[1]); if (!result.ok || !result.verified) process.exit(1)' "$OUT" \
  || fail "the live title postcondition was not verified: $OUT"
pass 'a live title postcondition is verified'

FIXTURE_PATH=$(node -e 'process.stdout.write(require("node:url").pathToFileURL(process.argv[1]).pathname)' "$FIXTURE") \
  || fail 'could not derive the fixture URL path'
OUT=$("$ROOT/bin/fm-browser.sh" step --press Enter --expect-url-path "$FIXTURE_PATH") \
  || fail 'the URL-path expectation failed'
node -e 'const result = JSON.parse(process.argv[1]); if (!result.ok || !result.verified) process.exit(1)' "$OUT" \
  || fail "the live URL-path postcondition was not verified: $OUT"
pass 'a live URL-path postcondition is verified'

ARGS_ROOT=$(mktemp -d "$ROOT/.fm-browser-step-args.XXXXXX") || fail 'could not create isolated Chrome-args probe'
ARGS_PROFILE="$ARGS_ROOT/should-not-be-used"
ARGS_SESSION="fm-browser-step-args-$$-${RANDOM}"
OUT=$(CHROME_DEVTOOLS_AXI_SESSION="$ARGS_SESSION" \
  CHROME_DEVTOOLS_AXI_CHROME_ARGS="--user-data-dir=$ARGS_PROFILE" \
  "$ROOT/bin/fm-browser.sh" step --press Enter) || fail 'the isolated Chrome-args probe failed'
node -e 'const result = JSON.parse(process.argv[1]); if (!result.ok || result.verified) process.exit(1)' "$OUT" \
  || fail "the unverified safe step result was unexpected: $OUT"
[ ! -e "$ARGS_PROFILE" ] || fail 'a caller-supplied Chrome profile argument escaped the isolation boundary'
CHROME_DEVTOOLS_AXI_SESSION="$ARGS_SESSION" chrome-devtools-axi stop >/dev/null 2>&1 || fail 'could not stop the isolated Chrome-args probe'
ARGS_SESSION=""
rm -rf "$ARGS_ROOT"
ARGS_ROOT=""
pass 'caller-supplied Chrome profile arguments are cleared before browser startup'

printf 'live browser-step checks passed\n'
