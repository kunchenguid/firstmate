#!/usr/bin/env bash
# Real Codex / Herdr recovery guard: an unknown registration cannot hide a
# running harness or a shell-only exit. The normal guard spends no tokens.
# FM_HERDR_CODEX_TURN_LIVE=1 additionally submits a 90-second tool wait and
# checks native busy through fm_busy_classify; this token-spending path is opt-in.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ "${FM_HERDR_CODEX_TURN_LIVE:-0}" = 1 ]; then
  fm_live_gate opt-in FM_HERDR_CODEX_TURN_LIVE herdr codex jq
else
  fm_live_gate default-on FM_HERDR_CODEX_STATE_LIVE herdr codex jq
fi
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name codex-state)
cleanup() {
  local rc=$?
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
CODEX_VERSION=$(codex --version)
HERDR_VERSION=$(lab status --json | jq -r '.server.version')
version_fail() { fail "$1 [Codex $CODEX_VERSION, Herdr $HERDR_VERSION]"; }
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# All adapter probes share the same isolation helper as the test's own calls.
fm_backend_herdr_cli() { local session=$1; shift; "$HERDR_LAB_HELPER" run "$session" "$@"; }
PANE=$(lab workspace create --label codex-state --cwd "$ROOT" | jq -r '.result.root_pane.pane_id')
TARGET="$HERDR_LAB_SESSION:$PANE"
wait_endpoint() {
  local expected=$1 i
  for i in $(seq 1 100); do
    [ "$(fm_backend_herdr_agent_state "$TARGET")" != "$expected" ] || return 0
    sleep 0.2
  done
  version_fail "endpoint did not converge to $expected"
}
lab pane run "$PANE" bash >/dev/null
sleep 1
lab pane run "$PANE" 'codex --disable hooks' >/dev/null
wait_endpoint alive
if [ "${FM_HERDR_CODEX_TURN_LIVE:-0}" = 1 ]; then
  lab pane send-text "$PANE" 'You are a bounded lab worker. Do not read repository instructions or run fleet commands. Use your shell tool to run exactly sleep 90, wait until it finishes, then reply LAB_COMPLETE. Do not modify files.' >/dev/null
  sleep 1
  lab pane send-keys "$PANE" Enter >/dev/null
  busy_seen=0
  for i in $(seq 1 140); do
    [ "$(fm_backend_herdr_agent_state "$TARGET")" = alive ] || version_fail 'Codex exited during the long command'
    [ "$(fm_busy_classify herdr "$TARGET" codex lab /nonexistent)" != 'busy herdr-native' ] || busy_seen=1
    screen=$(lab pane read "$PANE" --lines 40)
    if [ "$i" -ge 90 ] && printf '%s' "$screen" | grep -qE '^[[:space:]]*(•[[:space:]]*)?LAB_COMPLETE[[:space:]]*$'; then break; fi
    sleep 1
  done
  [ "$busy_seen" = 1 ] || version_fail 'no positive native busy verdict during the turn'
  [ "$i" -lt 140 ] || version_fail 'long-command turn did not finish'
  pass "Codex $CODEX_VERSION / Herdr $HERDR_VERSION survived sleep 90 with native busy evidence"
fi
# This is a valid Herdr API state, imposed deliberately to separate semantic
# availability from liveness. It does not claim Codex emits this state itself.
lab pane report-agent "$PANE" --source fm-lab-codex --agent codex --state unknown >/dev/null
[ "$(fm_backend_herdr_agent_state "$TARGET")" = alive ] || version_fail 'unknown registration hid a live Codex'
pid=$(lab pane process-info --pane "$PANE" | jq -er '.result.process_info.foreground_processes[] | select(.name == "codex") | .pid')
kill -KILL "$pid"
wait_endpoint dead
[ "$(fm_backend_herdr_pane_process_state "$HERDR_LAB_SESSION" "$PANE")" = shell ] || version_fail 'exit was not a shell-only pane'
lab pane run "$PANE" 'codex --disable hooks' >/dev/null
wait_endpoint alive
pass "Codex $CODEX_VERSION / Herdr $HERDR_VERSION: unknown registration reads alive, shell-only exit reads dead, replacement reads alive"
