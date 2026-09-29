#!/usr/bin/env bash
# Token-free guard for the real Codex app-server process shape used by the
# session-lock classifier. A fake ps cannot verify the vendor's actual argv.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_CODEX_APP_SERVER_LOCK_LIVE codex

TMP_ROOT=$(fm_test_tmproot fm-codex-app-server-lock-live)
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/state"
FIFO="$TMP_ROOT/transport.fifo"
mkfifo "$FIFO"
exec 9<>"$FIFO"
SERVER_PID=
cleanup_server() {
  if [ -n "$SERVER_PID" ]; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  exec 9>&-
  fm_test_cleanup
}
trap cleanup_server EXIT

CODEX_HOME="$TMP_ROOT/home" codex app-server --stdio <&9 >"$TMP_ROOT/server.out" 2>"$TMP_ROOT/server.err" &
SERVER_PID=$!
i=0
while [ "$i" -lt 50 ]; do
  kill -0 "$SERVER_PID" 2>/dev/null || fail "Codex app-server exited before its process identity could be checked: $(cat "$TMP_ROOT/server.err")"
  args=$(ps -o args= -p "$SERVER_PID" 2>/dev/null || true)
  case "$args" in *'app-server --stdio'*) break ;; esac
  sleep 0.1
  i=$((i + 1))
done
[ "$i" -lt 50 ] || fail "Codex app-server did not expose its argv within the bound"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
fm_codex_app_server_pid "$SERVER_PID" \
  || fail "the installed Codex app-server was not identified from its real process table"
if fm_harness_pid_alive "$SERVER_PID"; then
  fail "the installed Codex app-server was accepted as a session harness"
fi
printf '%s\n' "$SERVER_PID" > "$TMP_ROOT/state/.lock"
fm_session_lock_inspect "$TMP_ROOT/state"
[ "$FM_LOCK_INSPECT_STATE" = stale ] \
  || fail "a legacy lock naming the installed app-server was '$FM_LOCK_INSPECT_STATE', expected stale"
pass "Codex $(codex --version): the real app-server is stale without a session lease"
