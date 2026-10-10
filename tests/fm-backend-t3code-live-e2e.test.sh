#!/usr/bin/env bash
# Token-free live guard for the t3code backend's `/mcp` transport against the
# real T3 server a home is signed in to. It spends no model tokens and changes
# nothing on the server: the capability gate and environment identity
# (status), the project catalog the adapter matches by real path, and a typed
# thread-not-found read (state). Default-on wherever node is installed;
# FM_T3CODE_LIVE_E2E=0 or FM_LIVE=0 turns it off, and FM_T3CODE_LIVE_E2E=1 or
# FM_LIVE=1 makes a missing credential or unreachable server a failure.
# The credential is FM_T3CODE_LIVE_TOKEN_FILE, else FM_CONFIG_OVERRIDE's, else
# this checkout's own config/t3code-token; none present is a clean skip.
# Refresh: FM_CONFIG_OVERRIDE=<home>/config bin/fm-test-run.sh tests/fm-backend-t3code-live-e2e.test.sh
# docs/verification/runtime-backends.md "T3 Code" records its result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_T3CODE_LIVE_E2E node

REQUESTED=0
[ "${FM_T3CODE_LIVE_E2E:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ] && REQUESTED=1
TOKEN=${FM_T3CODE_LIVE_TOKEN_FILE:-${FM_CONFIG_OVERRIDE:-$ROOT/config}/t3code-token}
HELPER="$ROOT/bin/fm-t3-mcp.mjs"

skip_or_fail() {  # <reason>
  if [ "$REQUESTED" = 1 ]; then
    fail "FM_T3CODE_LIVE_E2E was requested but $1"
  fi
  printf 'skip: live: %s\n' "$1"
  exit 0
}

[ -f "$TOKEN" ] || skip_or_fail "no T3 credential at $TOKEN"

field() {  # <json> <key>
  node -e 'const d=JSON.parse(process.argv[1]); const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k], d); process.stdout.write(v==null?"":typeof v==="object"?JSON.stringify(v):String(v))' "$1" "$2"
}

status=$(node "$HELPER" status --token-file "$TOKEN" 2>/dev/null)
rc=$?
case "$rc" in
  0) ;;
  1) skip_or_fail "the T3 server named by $TOKEN is unreachable" ;;
  *) fail "T3 status refused (exit $rc): $status" ;;
esac
version=$(field "$status" serverVersion)
env_id=$(field "$status" environmentId)
[ -n "$version" ] && [ -n "$env_id" ] || fail "T3 status lacked a version or environment id: $status"

TMP_ROOT=$(fm_test_tmproot fm-t3code-live)
trap fm_test_cleanup EXIT
out=$(node "$HELPER" project-read --project "fm-live-guard-$$-absent" --token-file "$TOKEN" 2>/dev/null)
expect_code 3 $? "T3 $version: an absent project must read as a typed not-found"
assert_equals project_not_found "$(field "$out" error.code)" "T3 $version: t3_project_list must parse into the project catalog"

missing=$(node "$HELPER" state --thread "mcp:fm-live-guard-$$-absent" --token-file "$TOKEN" 2>/dev/null) \
  || fail "T3 $version: a read of an absent thread should succeed as exists:false: $missing"
assert_equals false "$(field "$missing" exists)" "T3 $version: an absent thread must read exists:false"

node "$HELPER" thread-for-root --root "$TMP_ROOT" --token-file "$TOKEN" >/dev/null 2>&1
expect_code 5 $? "T3 $version: a root no project uses must find no supervisor thread"

pass "t3code live transport: T3 $version environment $env_id passes the gate (telemetry=$(field "$status" telemetry))"
