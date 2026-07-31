#!/usr/bin/env bash
# tests/fm-backend-psmux-smoke.test.sh - real psmux smoke test for the psmux
# session-provider adapter (bin/backends/psmux.sh), verified against the real
# native-Windows psmux binary (docs/psmux-backend.md). Mirrors the herdr/zellij/
# cmux smoke tests' structure: every other suite fakes the CLI, this one talks to
# the REAL binary. It creates ONLY a dedicated `fm-test-psmux` session, touches
# and kills ONLY that session, and never enumerates-and-closes anything else.
#
# Skips cleanly when psmux (or bash.exe) is not resolvable, so non-Windows hosts
# and machines without psmux are unaffected.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_SES="fm-test-psmux"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
cleanup_all() {
  [ -n "${FM_TMUX_CMD:-}" ] && "$FM_TMUX_CMD" kill-session -t "$TEST_SES" 2>/dev/null || true
}
trap cleanup_all EXIT

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source psmux || { echo "skip: psmux not installed/resolvable (see docs/psmux-backend.md)"; exit 0; }
fm_backend_psmux_bash_win >/dev/null 2>&1 || { echo "skip: bash.exe could not be resolved for psmux"; exit 0; }

# Isolated session we fully own.
"$FM_TMUX_CMD" kill-session -t "$TEST_SES" 2>/dev/null || true
"$FM_TMUX_CMD" new-session -d -s "$TEST_SES" || { echo "skip: could not create a psmux test session"; exit 0; }
pass "psmux: created isolated session"

WID=$(fm_backend_psmux_create_task "$TEST_SES" "fm-test-smoke" "$ROOT") || fail "create_task returned no window id"
case "$WID" in
  @*) pass "psmux: create_task returned a window id ($WID)" ;;
  *) fail "create_task returned an unexpected window id: '$WID'" ;;
esac

# The window must have started in the requested -c directory ($ROOT): psmux gets
# the MSYS path and must launch bash there for treehouse to run in the project.
# Poll: the login shell (bash -li) takes a moment to finish initializing.
started_ok=""
for _ in 1 2 3 4 5 6 7 8; do
  fm_backend_tmux_send_text_line "$WID" 'pwd'
  sleep 1
  case "$(fm_backend_capture psmux "$WID" 25)" in
    *"$ROOT"*) started_ok=1; break ;;
  esac
done
if [ -n "$started_ok" ]; then
  pass "psmux: task window started in the requested directory"
else
  fail "task window did not start in $ROOT (the -c start dir was not honored)"
fi

# The task window must run bash, not PowerShell: a bash-only expansion proves it.
# The $BASH_VERSION below must expand in the psmux window's bash, not this shell.
# shellcheck disable=SC2016
fm_backend_tmux_send_text_line "$WID" 'echo VERDICT:${BASH_VERSION:-NONE}'
sleep 2
if fm_backend_capture psmux "$WID" 25 | grep -q 'VERDICT:[0-9]'; then
  pass "psmux: task window runs bash"
else
  fail "task window did not run bash (still PowerShell?)"
fi

fm_backend_target_exists psmux "$TEST_SES:fm-test-smoke" || fail "target_exists did not find the created window"
pass "psmux: target_exists found the window"

cleanup_all
trap - EXIT
"$FM_TMUX_CMD" has-session -t "$TEST_SES" 2>/dev/null && fail "session survived cleanup"
pass "psmux: cleanup removed the session"
echo "# psmux smoke: all checks passed"
