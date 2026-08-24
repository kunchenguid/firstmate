#!/usr/bin/env bash
# Opt-in live guard for omp primary session_stop and watcher extensions.
set -u

if [ "${FM_OMP_PRIMARY_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_PRIMARY_LIVE_E2E=1 to run the installed omp primary supervision guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OMP_BIN=$(command -v omp 2>/dev/null || true)
if [ -z "$OMP_BIN" ] || [ ! -x "$OMP_BIN" ]; then
  echo "skip: omp is not installed; no live supervision verdict was possible"
  exit 0
fi

VERSION=$($OMP_BIN --version 2>/dev/null | sed -n '1p' | tr -d '\r')
[ -n "$VERSION" ] || VERSION=unknown
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-primary-live.XXXXXX")
OMP_PID=
cleanup() {
  if [ -n "${OMP_PID:-}" ]; then kill "$OMP_PID" >/dev/null 2>&1 || true; wait "$OMP_PID" >/dev/null 2>&1 || true; fi
  rm -rf "$LAB"
}
trap cleanup EXIT

fail() {
  printf 'not ok - omp %s: %s\n' "$VERSION" "$1" >&2
  [ -f "$LAB/output" ] && sed -n '1,120p' "$LAB/output" >&2
  [ -f "$LAB/error" ] && sed -n '1,120p' "$LAB/error" >&2
  exit 1
}
pass() { printf 'ok - omp %s: %s\n' "$VERSION" "$1"; }

mkdir -p "$LAB/.omp/extensions" "$LAB/.pi/extensions/lib" "$LAB/bin" "$LAB/home/state" "$LAB/home/config"
cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$LAB/.omp/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$LAB/.omp/extensions/fm-primary-omp-watch.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$LAB/.pi/extensions/lib/fm-operational-input.ts"
cp "$ROOT/bin/fm-operational-input.sh" "$LAB/bin/fm-operational-input.sh"
chmod +x "$LAB/bin/fm-operational-input.sh"

cat > "$LAB/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'call\n' >> "${FM_GUARD_LOG:?}"
count=$(wc -l < "$FM_GUARD_LOG")
if [ "$count" -eq 1 ]; then
  printf 'OMP_TURNEND_CONTINUED\n' >&2
  exit 2
fi
exit 0
SH
chmod +x "$LAB/bin/fm-turnend-guard.sh"

cat > "$LAB/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$LAB/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$LAB/bin/fm-cd-pretool-check.sh" "$LAB/bin/fm-arm-pretool-check.sh"

cat > "$LAB/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$" >> "${FM_ARM_LOG:?}"
trap 'printf "term\n" >> "${FM_ARM_LOG:?}"; exit 0' TERM INT
while :; do sleep 0.05; done
SH
chmod +x "$LAB/bin/fm-watch-arm.sh"

FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$LAB" FM_GUARD_LOG="$LAB/guard.log" FM_ARM_LOG="$LAB/arm.log" \
  "$OMP_BIN" -p --cwd "$LAB" --no-session --no-skills --no-rules --no-extensions --auto-approve --tools=fm_watch_arm_omp \
  --extension "$LAB/.omp/extensions/fm-primary-turnend-guard.ts" \
  --extension "$LAB/.omp/extensions/fm-primary-omp-watch.ts" \
  --max-time 120 \
  'Use the fm_watch_arm_omp tool now, exactly once, and do not use bash for watcher setup. After it returns, reply exactly OMP_LIVE_READY. If a supervision continuation asks for a marker, reply exactly OMP_TURNEND_CONTINUED.' \
  > "$LAB/output" 2> "$LAB/error" &
OMP_PID=$!
printf '%s\n' "$OMP_PID" > "$LAB/home/state/.lock"
wait "$OMP_PID"
STATUS=$?
[ "$STATUS" -eq 0 ] || fail "omp exited with status $STATUS"

OUTPUT=$(cat "$LAB/output")
[ -f "$LAB/arm.log" ] || fail "fm_watch_arm_omp was not called by the model"
printf '%s\n' "$(cat "$LAB/arm.log")" | grep -F 'watcher: started' >/dev/null 2>&1 || fail "fm_watch_arm_omp did not start bin/fm-watch-arm.sh"
printf '%s\n' "$OUTPUT" | grep -F 'OMP_TURNEND_CONTINUED' >/dev/null 2>&1 || fail "session_stop did not force the native continuation marker"
[ -f "$LAB/guard.log" ] || fail "turn-end guard script was never invoked"
[ "$(wc -l < "$LAB/guard.log")" -ge 2 ] || fail "session_stop did not invoke the guard for the initial and continued turns"
[ -f "$LAB/arm.log" ] || fail "fm_watch_arm_omp was not called by the model"
printf '%s\n' "$(cat "$LAB/arm.log")" | grep -F 'watcher: started' >/dev/null 2>&1 || fail "fm_watch_arm_omp did not start bin/fm-watch-arm.sh"
printf '%s\n' "$(cat "$LAB/arm.log")" | grep -F 'term' >/dev/null 2>&1 || fail "session_shutdown did not retire the omp arm child"
pass "session_stop blocked and continued natively, and fm_watch_arm_omp was discoverable and callable"
