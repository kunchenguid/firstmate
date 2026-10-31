#!/usr/bin/env bash
# tests/fm-backend-hc-smoke.test.sh - real herdr-core smoke test for the hc
# session-provider adapter (bin/backends/hc.sh, docs/hc-backend.md).
# Every other hc suite fakes the CLI; this one drives the REAL hc binary, but
# only against a private core it starts itself: a unique HC_SESSION plus
# scratch XDG state and runtime directories, with every inherited HC_TERMINAL_*
# routing variable removed, so the captain's own core and its terminals are
# never listed, typed into, or closed. The private core is stopped on exit,
# and the stop itself runs only after re-checking that the state directory is
# the one this run created.
#
# Covers one task lifecycle through the bin/fm-backend.sh dispatcher: container
# ensure, create, submitted input, cwd tracking, capture, agent state
# for a shell and for an agent-named process, and a proven close.
#
# Skips cleanly (exit 0, "skip: ...") when hc or jq is missing or a private
# core cannot start.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

command -v hc >/dev/null 2>&1 || { echo "skip: hc not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the hc adapter)"; exit 0; }

# hc's socket lives under XDG_RUNTIME_DIR and must fit a unix socket path, so
# the private root sits directly under /tmp rather than a deep temp folder.
HC_ROOT=$(mktemp -d /tmp/fmhc.XXXXXX) || { echo "skip: no scratch directory"; exit 0; }
FM_HOME_DIR="$HC_ROOT/home"
WORK_DIR="$HC_ROOT/work"
mkdir -p "$FM_HOME_DIR" "$WORK_DIR" "$HC_ROOT/config" "$HC_ROOT/data" "$HC_ROOT/cache"
WORK_DIR=$(cd "$WORK_DIR" && pwd -P)

unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET
export HC_SESSION="fmt$$"
export XDG_STATE_HOME="$HC_ROOT" XDG_RUNTIME_DIR="$HC_ROOT" XDG_CONFIG_HOME="$HC_ROOT/config"
export XDG_DATA_HOME="$HC_ROOT/data" XDG_CACHE_HOME="$HC_ROOT/cache"
export FM_HOME="$FM_HOME_DIR" FM_ROOT_OVERRIDE="$FM_HOME_DIR"

cleanup_all() {
  if [ "${XDG_STATE_HOME:-}" = "$HC_ROOT" ] && [ "${HC_SESSION:-}" = "fmt$$" ]; then
    hc server stop --json >/dev/null 2>&1 || true
  fi
  rm -rf "$HC_ROOT"
}
trap cleanup_all EXIT

hc server status --json >/dev/null 2>&1 || { echo "skip: a private hc core could not start"; exit 0; }

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
assert_equals "$SES" "fmt$$" "container_ensure names the private session"
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

assert_equals "$(fm_backend_agent_state hc "$T")" dead "an idle shell is dead"
STANDIN=$(fm_agent_standin "$HC_ROOT/standin") || { echo "skip: no agent stand-in survives a foreign name here"; exit 0; }
mkdir -p "$HC_ROOT/bin/claude"
cp "$STANDIN" "$HC_ROOT/bin/claude/claude"
fm_backend_hc_send_text_line "$T" "exec $HC_ROOT/bin/claude/claude 600" "$LABEL" || fail "agent launch send failed"
is_alive() { [ "$(fm_backend_agent_state hc "$T")" = alive ]; }
wait_for 10 is_alive || fail "agent_state did not report the agent-named foreground (got $(fm_backend_agent_state hc "$T"))"
pass "hc smoke: agent_state reads dead for a shell and alive for an agent-named foreground"

fm_backend_kill hc "$T" || fail "kill failed"
assert_equals "$(fm_backend_agent_state hc "$T")" missing "a closed terminal is missing"
fm_backend_kill hc "$T" || fail "closing an already-closed terminal must be a silent success"
pass "hc smoke: kill closes and removes the terminal"
echo FM_TEST_COMPLETE
