#!/usr/bin/env bash
# fm-browser.sh cleanup postconditions and quarantine on ambiguous profile identity.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=${TMPDIR:-/tmp}/fm-browser-cleanup-$$
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
  local home=$1
  mkdir -p "$home/config" "$home/state" "$home/data"
  printf '%s\n' '{"schema":"fm-browser-policy.v1","enabled":true,"maxActiveSessions":1,"allowedAuthClasses":["anonymous"]}' > "$home/config/browser-policy.json"
}

open_mock() {
  local home=$1 runtime=$2 task=$3 out receipt
  out=$(FM_HOME="$home" "$ROOT/bin/fm-browser.sh" plan --task "$task" --origin https://example.com --json) || return 1
  receipt=$(json_field "$out" receipt)
  FM_HOME="$home" FM_BROWSER_MOCK_ENGINE=1 FM_BROWSER_RUNTIME_OVERRIDE="$runtime" \
    "$ROOT/bin/fm-browser.sh" open --task "$task" --plan "$receipt" --json
}

test_profile_removed_on_clean_close() {
  local home="$TMP_ROOT/clean-home" runtime="$TMP_ROOT/runtime-clean" out handle profile
  setup_home "$home"
  out=$(open_mock "$home" "$runtime" clean-task) || fail "open failed"
  handle=$(json_field "$out" handle)
  profile=$(python3 - "$home/state/browser/v1/sessions/$handle.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    print(json.load(fh)['profile']['path'])
PY
)
  [ -d "$profile" ] || fail "mock profile not created"
  FM_HOME="$home" FM_BROWSER_MOCK_ENGINE=1 FM_BROWSER_RUNTIME_OVERRIDE="$runtime" \
    "$ROOT/bin/fm-browser.sh" close --handle "$handle" --json >/dev/null || fail "close failed"
  [ ! -e "$profile" ] || fail "profile still exists after clean close"
  pass "clean close removes only the exact owned runtime profile"
}

test_profile_escape_quarantines() {
  local home="$TMP_ROOT/escape-home" runtime="$TMP_ROOT/runtime-escape" out handle session outside rc
  setup_home "$home"
  out=$(open_mock "$home" "$runtime" escape-task) || fail "open failed"
  handle=$(json_field "$out" handle)
  session="$home/state/browser/v1/sessions/$handle.json"
  outside="$TMP_ROOT/outside-profile"
  mkdir -p "$outside"
  python3 - "$session" "$outside" <<'PY'
import json, sys
path, outside = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8') as fh:
    obj=json.load(fh)
obj['profile']['path']=outside
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(obj, fh, sort_keys=True, indent=2)
    fh.write('\n')
PY
  set +e
  out=$(FM_HOME="$home" FM_BROWSER_MOCK_ENGINE=1 FM_BROWSER_RUNTIME_OVERRIDE="$runtime" \
    "$ROOT/bin/fm-browser.sh" close --handle "$handle" --json 2>/dev/null)
  rc=$?
  set -e 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "escaped profile unexpectedly cleaned"
  [ "$(json_field "$out" code)" = cleanup-quarantined ] || fail "escaped profile did not quarantine"
  [ -d "$outside" ] || fail "outside profile was removed despite escaping runtime root"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-browser.sh" status --task escape-task --json) || fail "status failed"
  [ "$(json_field "$out" state)" = quarantined ] || fail "session did not enter quarantine"
  pass "cleanup refuses path escape and preserves ambiguous profile"
}

test_empty_profile_path_quarantines() {
  local home="$TMP_ROOT/empty-home" runtime="$TMP_ROOT/runtime-empty" out handle session rc
  setup_home "$home"
  out=$(open_mock "$home" "$runtime" empty-task) || fail "open failed"
  handle=$(json_field "$out" handle)
  session="$home/state/browser/v1/sessions/$handle.json"
  python3 - "$session" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding='utf-8') as fh:
    obj = json.load(fh)
obj['profile']['path'] = ''
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(obj, fh, sort_keys=True, indent=2)
    fh.write('\n')
PY
  set +e
  out=$(FM_HOME="$home" FM_BROWSER_MOCK_ENGINE=1 FM_BROWSER_RUNTIME_OVERRIDE="$runtime" \
    "$ROOT/bin/fm-browser.sh" close --handle "$handle" --json 2>/dev/null)
  rc=$?
  set -e 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "session with no recorded profile path unexpectedly reported clean"
  [ "$(json_field "$out" code)" = cleanup-quarantined ] || fail "empty profile path did not quarantine"
  [ "$(json_field "$out" profileOutcome)" = missing-profile-path ] || fail "quarantine reason was not reported"
  case "$out" in *"$TMP_ROOT"*) fail "close output leaked a filesystem path" ;; esac
  pass "a session without a recorded profile path quarantines instead of resolving to the working directory"
}

trap 'rm -rf "$TMP_ROOT"' EXIT

test_profile_removed_on_clean_close
test_profile_escape_quarantines
test_empty_profile_path_quarantines
