#!/usr/bin/env bash
# fm-browser.sh public command contract, disabled defaults, mocked happy path.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=${TMPDIR:-/tmp}/fm-browser-test-$$
mkdir -p "$TMP_ROOT"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

json_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
obj=json.loads(sys.argv[1])
cur=obj
for part in sys.argv[2].split('.'):
    cur=cur[part]
print(cur)
PY
}

setup_home() {
  local home=$1 enabled=${2:-false}
  mkdir -p "$home/config" "$home/state" "$home/data"
  cat > "$home/config/browser-policy.json" <<EOF
{"schema":"fm-browser-policy.v1","enabled":$enabled,"maxActiveSessions":1,"allowedAuthClasses":["anonymous"]}
EOF
}

test_disabled_capabilities_and_plan() {
  local home="$TMP_ROOT/disabled" out rc
  setup_home "$home" false
  out=$(FM_HOME="$home" "$ROOT/bin/fm-browser.sh" capabilities --json) || fail "capabilities failed"
  [ "$(json_field "$out" enabled)" = False ] || fail "disabled policy did not report disabled"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-browser.sh" plan --task t1 --origin https://example.com --json) \
    || fail "public plan failed while disabled"
  [ "$(json_field "$out" operation)" = plan ] || fail "plan receipt missing"
  set +e
  out=$(FM_HOME="$home" "$ROOT/bin/fm-browser.sh" open --task t1 --plan "$(json_field "$out" receipt)" --json 2>/dev/null)
  rc=$?
  set -e 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "open unexpectedly succeeded while disabled"
  [ "$(json_field "$out" code)" = browser-disabled ] || fail "disabled open did not return browser-disabled"
  pass "disabled default still permits value-safe planning and refuses open"
}

test_public_origin_refusals() {
  local home="$TMP_ROOT/origins" out rc
  setup_home "$home" false
  set +e
  out=$(FM_HOME="$home" "$ROOT/bin/fm-browser.sh" plan --task t2 --origin http://127.0.0.1 --json 2>/dev/null)
  rc=$?
  set -e 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "private origin unexpectedly planned"
  [ "$(json_field "$out" code)" = private-address ] || fail "private address was not refused before engine"
  set +e
  out=$(FM_HOME="$home" "$ROOT/bin/fm-browser.sh" plan --task t3 --origin 'https://user@example.com' --json 2>/dev/null)
  rc=$?
  set -e 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "userinfo origin unexpectedly planned"
  [ "$(json_field "$out" code)" = userinfo-forbidden ] || fail "userinfo URL was not refused"
  pass "origin policy refuses private and credential-bearing URLs before engine execution"
}

test_mock_lifecycle() {
  local home="$TMP_ROOT/mock" runtime="$TMP_ROOT/runtime" out receipt handle
  setup_home "$home" true
  out=$(FM_HOME="$home" "$ROOT/bin/fm-browser.sh" plan --task t4 --origin https://example.com --allow-origin https://www.iana.org --json) \
    || fail "mock plan failed"
  receipt=$(json_field "$out" receipt)
  out=$(FM_HOME="$home" FM_BROWSER_MOCK_ENGINE=1 FM_BROWSER_RUNTIME_OVERRIDE="$runtime" \
    "$ROOT/bin/fm-browser.sh" open --task t4 --plan "$receipt" --json) || fail "mock open failed"
  handle=$(json_field "$out" handle)
  [ -n "$handle" ] || fail "mock open did not return handle"
  FM_HOME="$home" FM_BROWSER_MOCK_ENGINE=1 "$ROOT/bin/fm-browser.sh" navigate --handle "$handle" --url https://www.iana.org/help/example-domains --json >/dev/null \
    || fail "allowed mock navigation failed"
  out=$(FM_HOME="$home" FM_BROWSER_MOCK_ENGINE=1 "$ROOT/bin/fm-browser.sh" snapshot --handle "$handle" --json) \
    || fail "snapshot failed"
  [ "$(json_field "$out" redacted)" = True ] || fail "snapshot was not redacted"
  FM_HOME="$home" FM_BROWSER_MOCK_ENGINE=1 "$ROOT/bin/fm-browser.sh" interact --handle "$handle" --kind click --target '@e1' --json >/dev/null \
    || fail "mock click failed"
  set +e
  out=$(FM_HOME="$home" FM_BROWSER_MOCK_ENGINE=1 "$ROOT/bin/fm-browser.sh" request-action --handle "$handle" --kind publish --effect publish --json 2>/dev/null)
  rc=$?
  set -e 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "write action unexpectedly allowed"
  [ "$(json_field "$out" code)" = action-tier-disabled ] || fail "write action did not return tier refusal"
  FM_HOME="$home" FM_BROWSER_MOCK_ENGINE=1 FM_BROWSER_RUNTIME_OVERRIDE="$runtime" \
    "$ROOT/bin/fm-browser.sh" close --handle "$handle" --json >/dev/null || fail "mock close failed"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-browser.sh" status --task t4 --json) || fail "status after close failed"
  [ "$(json_field "$out" cleaned)" = True ] || fail "closed session not cleaned"
  pass "mock lifecycle records navigation, redaction, denied writes, and cleanup"
}

trap 'rm -rf "$TMP_ROOT"' EXIT

test_disabled_capabilities_and_plan
test_public_origin_refusals
test_mock_lifecycle
