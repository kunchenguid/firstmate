#!/usr/bin/env bash
# tests/fm-backend-hc-smoke.test.sh - real herdr-core smoke test for the hc
# session-provider adapter (bin/backends/hc.sh, docs/hc-backend.md).
# Every other hc suite fakes the CLI; this one drives the REAL hc binary, but
# only inside a lab session provisioned by bin/fm-hc-lab.sh: a unique
# fm-hclab-* HC_SESSION, scratch XDG roots, a pinned FM_HC_SOCKET, a
# real-fleet tripwire, and a teardown that sweeps the session's serve/hold
# daemons by their HC_SESSION env marker. tests/hc-test-safety.sh owns the
# only sanctioned teardown path and teardown failures propagate through the
# EXIT trap.
#
# Covers one task lifecycle through the bin/fm-backend.sh dispatcher: binary
# and generation gates, container ensure, create, submitted input, cwd
# tracking, capture, agent state for a shell and for an agent-named process,
# and a proven close.
#
# Skips cleanly (exit 0, "skip: hc not found ...") when no herdr-core binary
# is installed (optional-binary gate); to pin a specific binary run
# `FM_HC_BIN=/path/to/hc bash tests/fm-backend-hc-smoke.test.sh`. Once the
# binary is present, a provisioning or teardown failure is a FAIL, not a
# skip.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# Binary resolution identical to the adapter, installer, and lab: FM_HC_BIN
# wins, then herdr-core, then the hc alias.
HC_BIN=${FM_HC_BIN:-}
[ -n "$HC_BIN" ] || HC_BIN=$(command -v herdr-core 2>/dev/null || true)
[ -n "$HC_BIN" ] || HC_BIN=$(command -v hc 2>/dev/null || true)
if [ -z "$HC_BIN" ] || [ ! -x "$HC_BIN" ]; then
  echo "skip: hc not found (install via bin/fm-install-hc.sh or set FM_HC_BIN)"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the hc adapter)"; exit 0; }
export FM_HC_BIN=$HC_BIN

# shellcheck source=tests/hc-test-safety.sh
. "$ROOT/tests/hc-test-safety.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-hc-smoke)

HC_TEST_SES=$("$ROOT/bin/fm-hc-lab.sh" name smoke)

# The teardown's own result propagates: a fleet-tripwire failure or surviving
# session processes keep this run nonzero even on an otherwise-clean pass.
# Armed before provision so a half-provisioned session is still swept when
# the lab helper left a tripwire behind.
cleanup_lab() {
  local rc=$?
  trap - EXIT
  hc_test_safe_teardown "$ROOT" "$HC_TEST_SES" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_lab EXIT

"$ROOT/bin/fm-hc-lab.sh" provision "$HC_TEST_SES" \
  || fail "hc lab could not provision with $HC_BIN"
HC_TEST_SOCK=$("$ROOT/bin/fm-hc-lab.sh" socket "$HC_TEST_SES")
[ -n "$HC_TEST_SOCK" ] || fail "hc lab provisioned without a socket"

hc_test_refuse_if_unsafe "$HC_TEST_SES" \
  || fail "provisioned session '$HC_TEST_SES' does not satisfy the lab safety contract"

HC_LAB_DIR=$(hc_test_lab_dir)/$HC_TEST_SES
export HC_SESSION=$HC_TEST_SES FM_HC_SOCKET=$HC_TEST_SOCK
export XDG_STATE_HOME="$HC_LAB_DIR/env/xdg-state" \
  XDG_CONFIG_HOME="$HC_LAB_DIR/env/xdg-config" \
  XDG_DATA_HOME="$HC_LAB_DIR/env/xdg-data"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET

FM_HOME_DIR=$TMP_ROOT/home
WORK_DIR=$TMP_ROOT/work
mkdir -p "$FM_HOME_DIR" "$WORK_DIR"
WORK_DIR=$(cd "$WORK_DIR" && pwd -P)
export FM_HOME=$FM_HOME_DIR FM_ROOT_OVERRIDE=$FM_HOME_DIR

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc || fail "could not source the hc adapter"

# wait_for <seconds> <cmd...>: poll a condition without a fixed sleep budget.
wait_for() {
  local tries=$(( $1 * 10 ))
  shift
  while [ "$tries" -gt 0 ]; do
    "$@" && return 0
    tries=$((tries - 1))
    sleep 0.1
  done
  return 1
}

LABEL=fm-smoke1
SES=$(fm_backend_hc_container_ensure) || fail "container_ensure failed"
assert_equals "$SES" "$HC_TEST_SES" "container_ensure names the lab session"
ADDR=$(fm_backend_hc_create_task "$SES" "$LABEL" "$WORK_DIR") || fail "create_task failed"
T="$SES:$ADDR"
fm_backend_target_exists hc "$T" "$LABEL" || fail "the new terminal must exist under its label"
pass "hc smoke: create_task started $T"

mkdir -p "$WORK_DIR/sub"
fm_backend_hc_send_text_line "$T" "cd sub" "$LABEL" || fail "send_text_line failed"
path_is_sub() { [ "$(fm_backend_hc_current_path "$T" "$LABEL")" = "$WORK_DIR/sub" ]; }
wait_for 10 path_is_sub || fail "current_path did not follow cd (got $(fm_backend_hc_current_path "$T" "$LABEL"))"
pass "hc smoke: current_path follows the shell's cwd"

fm_backend_hc_send_text_line "$T" "echo Smoke-Line-42" "$LABEL" || fail "send_text_line failed"
captured() { fm_backend_capture hc "$T" 50 "$LABEL" | grep -qx 'Smoke-Line-42'; }
wait_for 10 captured || fail "capture did not show the submitted command's output"
pass "hc smoke: send_text_line ran the command and capture shows its output"

verdict=$(fm_backend_hc_send_text_submit "$T" "echo Sub-Line-7" 1 0.4 0 "$LABEL")
case "$verdict" in
  empty|pending|pending-unproven|unknown) ;;
  *) fail "send_text_submit returned '$verdict', outside its vocabulary" ;;
esac
sub_captured() { fm_backend_capture hc "$T" 50 "$LABEL" | grep -qx 'Sub-Line-7'; }
wait_for 10 sub_captured || fail "send_text_submit's text never reached the terminal (verdict $verdict)"
pass "hc smoke: send_text_submit delivers through send --wait (verdict $verdict)"

assert_equals "$(fm_backend_agent_state hc "$T")" dead "an idle shell is dead"
STANDIN=$(fm_agent_standin "$TMP_ROOT/standin") || fail "no agent stand-in survives a foreign name here"
mkdir -p "$TMP_ROOT/bin/claude"
cp "$STANDIN" "$TMP_ROOT/bin/claude/claude"
fm_backend_hc_send_text_line "$T" "exec $TMP_ROOT/bin/claude/claude 600" "$LABEL" || fail "agent launch send failed"
is_alive() { [ "$(fm_backend_agent_state hc "$T")" = alive ]; }
wait_for 10 is_alive || fail "agent_state did not report the agent-named foreground (got $(fm_backend_agent_state hc "$T"))"
pass "hc smoke: agent_state reads dead for a shell and alive for an agent-named foreground"

fm_backend_kill hc "$T" || fail "kill failed"
assert_equals "$(fm_backend_agent_state hc "$T")" missing "a closed terminal is missing"
fm_backend_kill hc "$T" || fail "closing an already-closed terminal must be a silent success"
pass "hc smoke: kill closes and removes the terminal"
echo FM_TEST_COMPLETE
