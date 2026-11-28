#!/usr/bin/env bash
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot telemetry)
unset FM_TELEMETRY

run_cycle() {
  local mode=$1 dir state arm i rc
  dir=$(make_case "$mode")
  state="$dir/state"
  if [ "$mode" = blocked ]; then
    mkdir "$state/telemetry.jsonl"
  fi
  if [ "$mode" = disabled ]; then
    export FM_TELEMETRY=0
  else
    unset FM_TELEMETRY
  fi
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-arm.sh" > "$dir/arm.out" 2> "$dir/arm.err" &
  arm=$!
  for ((i=0; i<200; i++)); do
    [ -f "$state/.last-watcher-beat" ] && break
    sleep 0.1
  done
  printf 'done: telemetry regression finished\n' > "$state/demo.status"
  for ((i=0; i<200; i++)); do
    if ! kill -0 "$arm" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if kill -0 "$arm" 2>/dev/null; then
    kill -TERM "$arm" 2>/dev/null || true
    wait "$arm" 2>/dev/null || true
    fail "watcher did not complete: $mode"
  fi
  rc=0
  wait "$arm" || rc=$?
  [ "$rc" -eq 0 ] || fail "watcher failed: $mode: $(cat "$dir/arm.err")"
  grep -q '^signal:' "$dir/arm.out" || fail "watcher did not deliver signal: $mode"
  grep -q 'demo.status' "$state/.wake-queue" || fail "watcher did not persist wake: $mode"
  case "$mode" in
    enabled)
      jq -se 'length == 1 and (.[0] | .schema == "fm-telemetry.v1" and .event == "watch_cycle" and .signal == "actionable-signal" and .source == "watch-arm" and (keys | length == 5))' \
        "$state/telemetry.jsonl" >/dev/null || fail "real watcher telemetry missing"
      ;;
    disabled) [ ! -e "$state/telemetry.jsonl" ] || fail "disabled telemetry emitted" ;;
    blocked) [ -d "$state/telemetry.jsonl" ] || fail "blocked destination changed" ;;
  esac
}

run_cycle enabled
run_cycle disabled
run_cycle blocked
unset FM_TELEMETRY
pass "real watcher emits by default and delivers the same wake when telemetry is disabled or blocked"

STATE="$TMP_ROOT/enabled/state"
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-telemetry-lib.sh
. "$ROOT/bin/fm-telemetry-lib.sh"
for round in 1 2 3 4; do
  python3 - "$STATE/telemetry.jsonl" <<'PY'
import os
import sys
path = sys.argv[1]
record = open(path).readline()
with open(path, 'w') as stream:
    stream.write(record * (1048576 // len(record)))
os.chmod(path, 0o644)
PY
  for segment in "$STATE"/telemetry.jsonl.*; do
    [ ! -f "$segment" ] || chmod 644 "$segment"
  done
  fm_telemetry_emit actionable-signal || fail "emission failed"
done
python3 - "$STATE" <<'PY'
import json
from pathlib import Path
import stat
import sys
files = sorted(Path(sys.argv[1]).glob('telemetry.jsonl*'))
assert len(files) == 4, files
for path in files:
    assert stat.S_IMODE(path.stat().st_mode) == 0o600, path
    assert 0 < path.stat().st_size <= 1048576, path
    for line in path.open():
        assert json.loads(line)['event'] == 'watch_cycle'
PY
[ "$?" -eq 0 ] || fail "retention, permissions, or JSONL contract failed"
pass "telemetry repairs existing permissions and retains three private bounded segments"

STATE="$TMP_ROOT/lock-recovery/state"
mkdir -p "$STATE"
FM_STATE_OVERRIDE="$STATE" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$STATE/telemetry.jsonl.lock" || exit 1
  printf ready > "$STATE/ready"
  exec sleep 30
' _ "$ROOT" &
holder=$!
for ((i=0; i<100; i++)); do
  [ -f "$STATE/ready" ] && break
  sleep 0.01
done
if [ ! -f "$STATE/ready" ]; then
  kill -KILL "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  fail "telemetry lock holder did not start"
fi
fm_telemetry_emit contended
contended=0
[ ! -e "$STATE/telemetry.jsonl" ] || contended=1
kill -KILL "$holder"
wait "$holder" 2>/dev/null || true
[ "$contended" -eq 0 ] || fail "telemetry bypassed live lock holder"
fm_telemetry_emit recovered
jq -se 'length == 1 and .[0].signal == "recovered"' "$STATE/telemetry.jsonl" >/dev/null \
  || fail "telemetry did not recover killed lock holder"
[ ! -e "$STATE/telemetry.jsonl.lock" ] && [ ! -L "$STATE/telemetry.jsonl.lock" ] \
  || fail "telemetry did not release its lock"
pass "telemetry respects live holders and recovers locks after owner termination"
