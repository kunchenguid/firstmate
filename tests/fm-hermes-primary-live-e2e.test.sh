#!/usr/bin/env bash
# Opt-in live guard for the installed Hermes primary plugin and process identity.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

if [ "${FM_HERMES_PRIMARY_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_HERMES_PRIMARY_LIVE_E2E=1 to test the installed Hermes primary"
  exit 0
fi

command -v hermes >/dev/null 2>&1 || fail "Hermes is not installed"
command -v script >/dev/null 2>&1 || fail "script(1) is required for the Hermes PTY smoke test"

TMP_ROOT=$(fm_test_tmproot fm-hermes-primary-live-e2e)
STATE="$TMP_ROOT/state"
TRANSCRIPT="$TMP_ROOT/hermes.typescript"
mkdir -p "$STATE"
launcher_pid=
hermes_pid=

cleanup() {
  if [ -n "$hermes_pid" ]; then
    kill -TERM "$hermes_pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$hermes_pid" 2>/dev/null || true
  fi
  if [ -n "$launcher_pid" ]; then
    child_pids=$(ps -eo pid=,ppid= 2>/dev/null | awk -v parent="$launcher_pid" '$2 == parent { print $1 }')
    while IFS= read -r child_pid; do
      [ -z "$child_pid" ] || kill -TERM "$child_pid" 2>/dev/null || true
    done <<EOF
$child_pids
EOF
    kill -TERM "$launcher_pid" 2>/dev/null || true
    wait "$launcher_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

"$ROOT/bin/fm-hermes-primary.sh" --check >/dev/null ||
  fail "Hermes primary plugin is not enabled; run bin/fm-hermes-primary.sh --setup"

(
  cd "$ROOT" || exit 1
  FM_HOME="$ROOT" FM_STATE_OVERRIDE="$STATE" \
    script -qefc "$ROOT/bin/fm-hermes-primary.sh" "$TRANSCRIPT" >/dev/null 2>&1
) &
launcher_pid=$!

marker="$STATE/.hermes-primary-plugin-loaded"
i=0
while [ "$i" -lt 100 ] && [ ! -s "$marker" ]; do
  kill -0 "$launcher_pid" 2>/dev/null || break
  sleep 0.1
  i=$((i + 1))
done
[ -s "$marker" ] || {
  printf '%s\n' "Hermes transcript:" >&2
  tail -80 "$TRANSCRIPT" >&2 2>/dev/null || true
  fail "the real Hermes process did not publish its primary-plugin marker"
}

version=$(sed -n '1p' "$marker")
hermes_pid=$(sed -n '2p' "$marker")
expected=$(fm_adapter_file_version "$ROOT/.hermes/plugins/firstmate-primary/__init__.py")
[ "$version" = "$expected" ] || fail "Hermes loaded a different primary plugin build"
case "$hermes_pid" in
  ''|*[!0-9]*) fail "Hermes primary marker has an invalid process id" ;;
esac
kill -0 "$hermes_pid" 2>/dev/null || fail "Hermes primary marker names a dead process"

args=$(ps -o args= -p "$hermes_pid" 2>/dev/null || true)
# shellcheck source=bin/fm-harness-process-lib.sh
. "$ROOT/bin/fm-harness-process-lib.sh"
fm_process_is_hermes_primary "$args" || fail "the live Hermes process does not match the primary identity contract"

printf '%s\n' "$hermes_pid" > "$STATE/.lock"
fm_adapter_loaded_marker_matches "$marker" "$expected" "$STATE/.lock" ||
  fail "Hermes marker and session-lock identity do not agree"

version_line=$(hermes --version | sed -n '1p')
pass "live Hermes primary loaded the tracked plugin and matched session identity ($version_line)"
