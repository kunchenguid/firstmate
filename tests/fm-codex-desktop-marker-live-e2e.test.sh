#!/usr/bin/env bash
# Opt-in live guard for the paired identity marker exposed by a managed Codex
# Desktop thread whose process ancestry does not itself name Codex.
set -u

if [ "${FM_CODEX_DESKTOP_MARKER_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_DESKTOP_MARKER_LIVE_E2E=1 to run the Codex Desktop marker guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v codex >/dev/null 2>&1 || fail "codex not found"
[ "${CODEX_CI:-}" = 1 ] || fail "managed Codex session did not expose CODEX_CI=1"
[ -n "${CODEX_THREAD_ID:-}" ] || fail "managed Codex session did not expose CODEX_THREAD_ID"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-desktop-marker.XXXXXX") || fail "could not create scratch lab"
cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB/fakebin" "$LAB/home/state"
cat > "$LAB/fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  "${FM_TEST_SESSION_PID}:comm=") printf '%s\n' Electron ;;
  "${FM_TEST_SESSION_PID}:args=") printf '%s\n' '/Applications/Codex.app/Contents/MacOS/Electron' ;;
  "${FM_TEST_SESSION_PID}:ppid=") printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  *:ppid=) printf '%s\n' "$FM_TEST_SESSION_PID" ;;
esac
SH
chmod +x "$LAB/fakebin/ps"

out=$(FM_TEST_SESSION_PID=$$ PATH="$LAB/fakebin:$PATH" "$ROOT/bin/fm-harness.sh")
[ "$out" = codex ] || fail "paired live markers reported '$out', expected codex"

dead_pid=999999
while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
printf '%s\n' "$dead_pid" > "$LAB/home/state/.lock"
out=$(FM_TEST_SESSION_PID=$$ PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB/home" \
  FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-lock.sh" 2>&1) \
  || fail "marker-identified live session did not reclaim the dead owner: $out"
first_owner=$(cat "$LAB/home/state/.lock")
case "$first_owner" in
  ''|*[!0-9]*) fail "marker-identified live session did not preserve the numeric lock format" ;;
esac
[ "$(cat "$LAB/home/state/.lock.codex-thread")" = "$CODEX_THREAD_ID" ] \
  || fail "marker-identified live session did not publish its thread sidecar"

out=$(FM_TEST_SESSION_PID=$$ PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB/home" \
  FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-lock.sh" 2>&1) \
  || fail "same live thread did not retain the lock after its tool pid exited: $out"
[ "$(cat "$LAB/home/state/.lock")" != "$first_owner" ] \
  || fail "same live thread did not refresh its short-lived numeric owner pid"

printf 'ok - %s live paired UUID markers identified Codex and retained the lock across short-lived tools\n' \
  "$(codex --version)"
