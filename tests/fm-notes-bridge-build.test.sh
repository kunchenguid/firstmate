#!/usr/bin/env bash
# Behavior tests for the dedicated macOS Notes bridge build boundary.
# The suite performs static inspection and a fixture-only app build.
# It never launches Notes, sends an Apple Event, asks for TCC, or uses live data.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "$(uname)" != Darwin ]; then
  pass "Notes bridge build: macOS-only fixture build is not applicable on this platform"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-notes-bridge-build.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
BUILD="$ROOT/bin/fm-notes-bridge-build.sh"

inspection=$($BUILD inspect --json) || fail "static bridge inspection failed"
python3 - "$inspection" <<'PY' || fail "static bridge inspection did not report the reviewed blocker"
import json,sys
v=json.loads(sys.argv[1])
assert v["apple_events_sent"] == 0
assert v["notes_launched"] is False
assert v["tcc_requested"] is False
assert v["release_build_allowed"] is False
assert v["sandbox_status"] == "blocked-target-wide-temporary-exception-required"
assert "com.apple.Notes.openlocation" in v["notes_declared_access_groups"]
assert v["signing_status"] in {"no-suitable-apple-identity", "suitable-identity-present"}
PY
pass "Notes bridge inspect: static facts report zero Apple Events and the sandbox release blocker"

release_out="$TMP/release.out"
if $BUILD release --output "$TMP/Release.app" >"$release_out" 2>&1; then
  fail "release build must refuse the target-wide temporary Apple Events exception"
fi
assert_grep "release blocked: Notes.sdef has no CRUD scripting access group" "$release_out" \
  "release refusal must name the missing operation-level sandbox access group"
assert_absent "$TMP/Release.app" "refused release must not leave an app bundle"
pass "Notes bridge release: refuses before compilation or signing rather than weakening App Sandbox"

app="$TMP/FirstmateNotesBridge.app"
build_json=$($BUILD fixture --output "$app") || fail "fixture bridge build failed"
python3 - "$build_json" <<'PY' || fail "fixture build receipt is invalid"
import json,sys
v=json.loads(sys.argv[1])
assert v["bundle_id"] == "dev.firstmate.notes-bridge"
assert v["signature"] == "ad-hoc-fixture-only"
assert v["hardened_runtime"] is True
assert v["app_sandbox"] is True
assert v["apple_events_entitlement"] is False
assert v["live_pilot_allowed"] is False
assert len(v["executable_sha256"]) == 64
PY
/usr/bin/codesign --verify --deep --strict "$app" || fail "fixture app signature did not verify"
pass "Notes bridge fixture: compiles as a dedicated hardened sandboxed app with no live entitlement"

status=$(printf '%s' '{"schema":"firstmate.apple-notes.bridge/v1","operation":"status"}' \
  | "$app/Contents/MacOS/FirstmateNotesBridge" status) || fail "fixture status operation failed"
python3 - "$status" <<'PY' || fail "fixture status response is invalid"
import json,sys
v=json.loads(sys.argv[1])
assert v["ok"] is True
assert v["result"]["bundle_id"] == "dev.firstmate.notes-bridge"
assert v["result"]["notes_target"] == "com.apple.Notes"
assert v["result"]["provider_calls"] == 0
PY
pass "Notes bridge typed API: status succeeds without Notes or TCC"

unknown_out="$TMP/unknown.out"
if printf '%s' '{"schema":"firstmate.apple-notes.bridge/v1","operation":"eval"}' \
  | "$app/Contents/MacOS/FirstmateNotesBridge" eval >"$unknown_out"; then
  fail "fixture bridge must reject a non-typed eval operation"
fi
python3 - "$unknown_out" <<'PY' || fail "unknown-operation refusal is invalid"
import json,sys
v=json.load(open(sys.argv[1]))
assert v["ok"] is False
assert v["error"]["code"] == "unknown-operation"
PY
pass "Notes bridge typed API: arbitrary eval is not an operation"

printf '# fm-notes-bridge-build.test.sh: all assertions passed\n'
