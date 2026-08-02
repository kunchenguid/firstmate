#!/usr/bin/env bash
# fm-browser.sh capacity and expiry behavior stays alert-only unless explicitly eligible.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=${TMPDIR:-/tmp}/fm-browser-capacity-$$
mkdir -p "$TMP_ROOT"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

json_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
obj=json.loads(sys.argv[1])
cur=obj
for part in sys.argv[2].split('.'):
    if part.endswith(']'):
        name, idx = part[:-1].split('[')
        if name:
            cur = cur[name]
        cur = cur[int(idx)]
    else:
        cur=cur[part]
print(cur)
PY
}

setup_home() {
  local home=$1 max=${2:-1}
  mkdir -p "$home/config" "$home/state" "$home/data"
  cat > "$home/config/browser-policy.json" <<EOF
{"schema":"fm-browser-policy.v1","enabled":true,"maxActiveSessions":$max,"allowedAuthClasses":["anonymous"]}
EOF
}

plan_and_open() {
  local home=$1 runtime=$2 task=$3 out receipt
  out=$(FM_HOME="$home" "$ROOT/bin/fm-browser.sh" plan --task "$task" --origin https://example.com --ttl 1 --expiry-action close-exact --json) || return 1
  receipt=$(json_field "$out" receipt)
  FM_HOME="$home" FM_BROWSER_MOCK_ENGINE=1 FM_BROWSER_RUNTIME_OVERRIDE="$runtime" \
    "$ROOT/bin/fm-browser.sh" open --task "$task" --plan "$receipt" --json
}

test_capacity_refuses_second_active_session() {
  local home="$TMP_ROOT/cap-home" runtime="$TMP_ROOT/cap-runtime" out receipt rc
  setup_home "$home" 1
  plan_and_open "$home" "$runtime" t1 >/dev/null || fail "first open failed"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-browser.sh" plan --task t2 --origin https://example.com --json) || fail "second plan failed"
  receipt=$(json_field "$out" receipt)
  set +e
  out=$(FM_HOME="$home" FM_BROWSER_MOCK_ENGINE=1 FM_BROWSER_RUNTIME_OVERRIDE="$runtime" \
    "$ROOT/bin/fm-browser.sh" open --task t2 --plan "$receipt" --json 2>/dev/null)
  rc=$?
  set -e 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "second active session unexpectedly opened"
  [ "$(json_field "$out" code)" = capacity-reached ] || fail "capacity refusal code mismatch"
  pass "capacity refuses a new session instead of closing an existing one"
}

test_expiry_is_report_only() {
  local home="$TMP_ROOT/expire-home" runtime="$TMP_ROOT/expire-runtime" out handle session
  setup_home "$home" 1
  out=$(plan_and_open "$home" "$runtime" due1) || fail "open failed"
  handle=$(json_field "$out" handle)
  session="$home/state/browser/v1/sessions/$handle.json"
  python3 - "$session" <<'PY'
import json, sys, time
path=sys.argv[1]
with open(path, encoding='utf-8') as fh:
    obj=json.load(fh)
obj['hardDeadlineEpoch']=int(time.time())-1
obj['idleDeadlineEpoch']=int(time.time())-1
with open(path,'w',encoding='utf-8') as fh:
    json.dump(obj, fh, sort_keys=True, indent=2)
    fh.write('\n')
PY
  out=$(FM_HOME="$home" "$ROOT/bin/fm-browser.sh" expire --due --json) || fail "expire failed"
  [ "$(json_field "$out" actionTaken)" = none-alert-only ] || fail "expiry took action unexpectedly"
  [ "$(json_field "$out" due[0].eligible)" = True ] || fail "due session eligibility not reported"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-browser.sh" status --task due1 --json) || fail "status failed"
  [ "$(json_field "$out" state)" = active ] || fail "expiry changed session state"
  pass "expiry reports eligible sessions without closing them in alert-only core"
}

trap 'rm -rf "$TMP_ROOT"' EXIT

test_capacity_refuses_second_active_session
test_expiry_is_report_only
