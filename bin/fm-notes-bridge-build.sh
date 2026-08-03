#!/usr/bin/env bash
# Build or inspect the dedicated Firstmate Notes Bridge app.
#
# Usage:
#   fm-notes-bridge-build.sh inspect [--json]
#   fm-notes-bridge-build.sh fixture --output PATH
#   fm-notes-bridge-build.sh release --output PATH
#
# inspect performs static local checks only: it reads Notes.sdef, the installed
# code-signing identity catalog, and build tools without launching Notes, sending
# an Apple Event, requesting TCC, or printing an identity label/private material.
# fixture builds the dedicated app and ad-hoc signs it with hardened runtime plus
# App Sandbox but no Apple Events entitlement.  It is suitable only for status
# and invalid-operation fixture tests and must never be used for a live pilot.
# release refuses before compilation/signing while Notes account/folder/note CRUD
# lacks a Notes scripting access group.  On this Notes version App Sandbox would
# require the target-wide com.apple.security.temporary-exception.apple-events
# entitlement for com.apple.Notes; that exceeds the reviewed operation-level
# design and must not be added silently.  A suitable Apple Development or
# Developer ID Application identity is also required after that blocker receives
# a new security review.  The identity is supplied through
# FIRSTMATE_NOTES_SIGNING_IDENTITY, never written by this script.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$ROOT/libexec/FirstmateNotesBridge/Sources/main.swift"
INFO="$ROOT/libexec/FirstmateNotesBridge/Info.plist"
FIXTURE_ENTITLEMENTS="$ROOT/libexec/FirstmateNotesBridge/Entitlements.fixture.plist"
NOTES_SDEF="/System/Applications/Notes.app/Contents/Resources/Notes.sdef"
COMMAND=${1:-}
shift || true
OUTPUT=
JSON=0

usage() {
  sed -n '2,25{s/^# \{0,1\}//;p;}' "$0" >&2
}

fail() {
  printf 'fm-notes-bridge-build: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || fail "--output requires a path"
      OUTPUT=$2
      shift 2
      ;;
    --json)
      JSON=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

case "$COMMAND" in
  inspect|fixture|release) ;;
  -h|--help|help|'') usage; exit 0 ;;
  *) fail "unknown command: $COMMAND" ;;
esac

[ "$(uname)" = Darwin ] || fail "the dedicated macOS bridge can be inspected or built only on macOS"
[ -f "$NOTES_SDEF" ] || fail "installed Notes scripting definition is unavailable"
[ -f "$SOURCE" ] && [ -f "$INFO" ] && [ -f "$FIXTURE_ENTITLEMENTS" ] \
  || fail "bridge sources are incomplete"

crud_access_groups=$(python3 - "$NOTES_SDEF" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
needed = {"account", "folder", "note", "attachment"}
groups = set()
for element in root.iter():
    if element.tag == "access-group" and element.get("identifier"):
        groups.add(element.get("identifier"))
# Notes 4.13 declares only com.apple.Notes.openlocation.  That group covers
# the URL-opening command prohibited by this bridge, not account/folder/note
# CRUD.  A future group is only a candidate when its identifier is not that
# known navigation-only group.
print(",".join(sorted(g for g in groups if g != "com.apple.Notes.openlocation")))
PY
)
all_access_groups=$(python3 - "$NOTES_SDEF" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
print(",".join(sorted({e.get("identifier") for e in root.iter("access-group") if e.get("identifier")})))
PY
)
identity_summary=$(python3 - <<'PY'
import re
import subprocess
text = subprocess.run(
    ["security", "find-identity", "-v", "-p", "codesigning"],
    capture_output=True,
    text=True,
    check=False,
).stdout
classes = []
for line in text.splitlines():
    match = re.match(r'\s*\d+\)\s+[0-9A-F]{40}\s+"(.*)"', line)
    if not match:
        continue
    label = match.group(1)
    if label.startswith("Developer ID Application:"):
        classes.append("developer-id-application")
    elif label.startswith("Apple Development:"):
        classes.append("apple-development")
    else:
        classes.append("unrecognized")
print(",".join(sorted(classes)) if classes else "none")
PY
)
if [ -n "$crud_access_groups" ]; then
  sandbox_status=access-group-candidate
else
  sandbox_status=blocked-target-wide-temporary-exception-required
fi
case ",$identity_summary," in
  *,developer-id-application,*|*,apple-development,*) signing_status=suitable-identity-present ;;
  *) signing_status=no-suitable-apple-identity ;;
esac

emit_inspection() {
  if [ "$JSON" -eq 1 ]; then
    python3 - "$sandbox_status" "$signing_status" "$all_access_groups" <<'PY'
import json,sys
print(json.dumps({
  "schema":"firstmate.apple-notes.bridge-build-inspection/v1",
  "notes_launched":False,
  "apple_events_sent":0,
  "tcc_requested":False,
  "sandbox_status":sys.argv[1],
  "signing_status":sys.argv[2],
  "notes_declared_access_groups":sys.argv[3].split(",") if sys.argv[3] else [],
  "release_build_allowed":False,
},sort_keys=True,separators=(",",":")))
PY
  else
    printf 'sandbox_status=%s\n' "$sandbox_status"
    printf 'signing_status=%s\n' "$signing_status"
    printf 'notes_declared_access_groups=%s\n' "${all_access_groups:-none}"
    printf 'release_build_allowed=false\n'
    printf 'apple_events_sent=0\n'
  fi
}

if [ "$COMMAND" = inspect ]; then
  emit_inspection
  exit 0
fi

[ -n "$OUTPUT" ] || fail "$COMMAND requires --output PATH"
case "$OUTPUT" in
  /*) ;;
  *) OUTPUT="$(pwd)/$OUTPUT" ;;
esac

if [ "$COMMAND" = release ]; then
  emit_inspection >&2
  [ "$sandbox_status" != blocked-target-wide-temporary-exception-required ] \
    || fail "release blocked: Notes.sdef has no CRUD scripting access group; App Sandbox would require a target-wide temporary Apple Events exception for com.apple.Notes"
  [ "$signing_status" = suitable-identity-present ] \
    || fail "release blocked: no suitable Apple Development or Developer ID Application signing identity is installed"
  fail "release signing remains disabled until a reviewed operation-level Notes sandbox access group is available"
fi

command -v swiftc >/dev/null 2>&1 || fail "swiftc is required"
command -v codesign >/dev/null 2>&1 || fail "codesign is required"
case "$OUTPUT" in
  *.app) ;;
  *) fail "fixture output must end in .app" ;;
esac
[ ! -e "$OUTPUT" ] && [ ! -L "$OUTPUT" ] || fail "fixture output already exists"

mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"
cp "$INFO" "$OUTPUT/Contents/Info.plist"
xcrun swiftc -parse-as-library -O \
  -framework ApplicationServices -framework CryptoKit -framework Foundation -framework ScriptingBridge \
  "$SOURCE" -o "$OUTPUT/Contents/MacOS/FirstmateNotesBridge"
chmod 0755 "$OUTPUT/Contents/MacOS/FirstmateNotesBridge"
/usr/bin/codesign --force --sign - --options runtime --entitlements "$FIXTURE_ENTITLEMENTS" "$OUTPUT" >/dev/null
/usr/bin/codesign --verify --deep --strict "$OUTPUT"

executable_sha=$(shasum -a 256 "$OUTPUT/Contents/MacOS/FirstmateNotesBridge" | awk '{print $1}')
app_sha=$(find "$OUTPUT" -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
python3 - "$OUTPUT" "$executable_sha" "$app_sha" <<'PY'
import json,sys
print(json.dumps({
  "schema":"firstmate.apple-notes.bridge-fixture-build/v1",
  "app_path":sys.argv[1],
  "bundle_id":"dev.firstmate.notes-bridge",
  "signature":"ad-hoc-fixture-only",
  "hardened_runtime":True,
  "app_sandbox":True,
  "apple_events_entitlement":False,
  "live_pilot_allowed":False,
  "executable_sha256":sys.argv[2],
  "app_inventory_sha256":sys.argv[3],
},sort_keys=True,separators=(",",":")))
PY
