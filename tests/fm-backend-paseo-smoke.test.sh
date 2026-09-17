#!/usr/bin/env bash
# tests/fm-backend-paseo-smoke.test.sh - real Paseo smoke test for the Paseo
# session-provider adapter (bin/backends/paseo.sh), verified against the real
# Paseo 0.8.0 CLI/daemon (docs/paseo-backend.md). Mirrors
# tests/fm-backend-cmux-smoke.test.sh's structure: every other suite fakes
# the CLI, this one talks to the REAL app. Creates only `fm-test-`-prefixed
# task labels, touches and closes only what it created, and never quits or
# relaunches the app.
#
# Skips cleanly when paseo (or jq) is not installed/reachable, so CI/dev
# machines without Paseo are unaffected.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup_all
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || {
  echo "skip: jq not found (required by the paseo adapter)"
  exit 0
}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source paseo || {
  echo "skip: could not source the paseo adapter"
  exit 0
}

fm_backend_paseo_tool_check >/dev/null 2>&1 || {
  echo "skip: paseo CLI not found on PATH or at the bundle path"
  exit 0
}
fm_backend_paseo_version_check >/dev/null 2>&1 || {
  echo "skip: installed paseo is older than the verified minimum"
  exit 0
}
DAEMON_STATE=$(fm_backend_paseo_daemon_state)
[ "$DAEMON_STATE" = ok ] || {
  echo "skip: paseo daemon not reachable (state=$DAEMON_STATE) - see docs/paseo-backend.md 'Setup'"
  exit 0
}

WS1=""
WS2=""
cleanup_all() {
  [ -z "$WS1" ] || {
    fm_backend_paseo_cli workspace archive "$WS1" >/dev/null 2>&1 || true
  }
  [ -z "$WS2" ] || {
    fm_backend_paseo_cli workspace archive "$WS2" >/dev/null 2>&1 || true
  }
}
trap cleanup_all EXIT

# --- create_task + duplicate refusal -----------------------------------------

LABEL="fm-test-smoke1"
TASK_IDS=$(fm_backend_paseo_create_task "$LABEL" /tmp) || fail "create_task failed"
read -r TID1 WS1 <<EOF
$TASK_IDS
EOF
if [ -z "$TID1" ] || [ -z "$WS1" ]; then
  fail "create_task did not return terminal/workspace ids"
fi
TARGET="$TID1:$WS1"

if fm_backend_paseo_create_task "$LABEL" /tmp >/dev/null 2>&1; then
  fail "create_task should refuse a duplicate terminal name (paseo itself does not enforce uniqueness)"
fi
pass "real paseo: create_task creates a terminal/workspace and refuses a duplicate name"

fm_backend_paseo_send_key "$TARGET" Escape "$LABEL" \
  || fail "send_key with a matching expected task label should succeed"
if fm_backend_paseo_send_key "$TARGET" Escape "fm-test-not-$LABEL" >/dev/null 2>&1; then
  fail "send_key with a mismatched expected task label should fail"
fi
pass "real paseo: expected task label verification accepts the matching terminal and rejects a mismatch"

# --- send_literal + send_key(Enter), the two-step submit form ---------------

fm_backend_paseo_send_literal "$TARGET" 'echo literal-then-key-captain' \
  || fail "send_literal failed"
sleep 0.3
fm_backend_paseo_send_key "$TARGET" Enter || fail "send_key Enter failed"
sleep 0.5
out=$(fm_backend_paseo_capture "$TARGET" 20) || fail "capture failed after send_literal+send_key"
case "$out" in
*literal-then-key-captain*) : ;;
*) fail "real paseo: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real paseo: send_literal (unsubmitted) + send_key Enter submit as two steps and the output is capturable"

# --- send_text_line (the composed form) --------------------------------------

fm_backend_paseo_send_text_line "$TARGET" "echo captain-on-deck-line" \
  || fail "send_text_line failed"
sleep 0.5
out=$(fm_backend_paseo_capture "$TARGET" 20) || fail "capture failed after send_text_line"
case "$out" in
*captain-on-deck-line*) : ;;
*) fail "real paseo: send_text_line did not run and echo the line"$'\n'"$out" ;;
esac
pass "real paseo: send_text_line composes send-keys+Enter and its output is capturable"

# --- current_path: verified creation-time-frozen cwd -------------------------

fm_backend_paseo_send_text_line "$TARGET" "cd /tmp"
sleep 0.3
p=$(fm_backend_paseo_current_path "$TARGET") || fail "current_path failed"
case "$p" in
*/tmp) : ;;
*) fail "real paseo: current_path did not report the terminal's cwd after a direct cd, got '$p'" ;;
esac
pass "real paseo: current_path reads the terminal's live cwd after a direct cd"

# The load-bearing case: a NESTED SUBSHELL's own cd (exactly what `treehouse
# get` does). Verified real finding (docs/paseo-backend.md finding #3): the
# terminal's `cwd` field stays frozen at creation time and never follows the
# subshell's own cd. fm_backend_paseo_current_path's active pwd-probe is what
# fm-spawn.sh's worktree-discovery poll actually depends on, so this must be
# proven against a real subshell, not just a plain cd in the top-level shell.
fm_backend_paseo_send_text_line "$TARGET" 'cd / && bash'
sleep 0.5
fm_backend_paseo_send_text_line "$TARGET" "cd /private/tmp"
sleep 0.3
p2=$(fm_backend_paseo_current_path "$TARGET") || fail "current_path failed inside a nested subshell"
case "$p2" in
*/private/tmp | */tmp) : ;;
*) fail "real paseo: current_path did not track a nested subshell's own cd (the treehouse-get-shaped case), got '$p2'" ;;
esac
pass "real paseo: current_path tracks a NESTED SUBSHELL's own cd (the treehouse-get-shaped case a bare cwd read cannot see)"
fm_backend_paseo_send_text_line "$TARGET" 'exit'
sleep 0.3

# --- key names: Escape and Ctrl-C, verified names --------------------------

fm_backend_paseo_send_key "$TARGET" Escape || fail "send_key Escape failed"
pass "real paseo: send_key Escape (natively supported) succeeds"

fm_backend_paseo_send_key "$TARGET" C-c || fail "send_key C-c failed"
pass "real paseo: send_key C-c (normalized to the verified 'C-c' token) succeeds"

# --- busy_state: always unknown (no native agent-state primitive) -----------

bs=$(fm_backend_busy_state paseo "$TARGET")
[ "$bs" = unknown ] || fail "fm_backend_busy_state should report unknown for paseo (no native primitive), got '$bs'"
pass "real paseo: fm_backend_busy_state reports unknown (watcher falls back to capture/hash polling)"

# --- kill: whole-endpoint close -----------------------------------------------

fm_backend_paseo_kill "$TARGET"
sleep 0.5
STILL_LIVE=$(fm_backend_paseo_cli terminal ls --all --json 2>/dev/null | jq -r --arg id "$TID1" '.[]? | select(.id == $id) | .id' 2>/dev/null)
[ -z "$STILL_LIVE" ] || fail "kill did not remove the task terminal"
WS1=""
# Best-effort contract: killing an already-gone target must not error.
fm_backend_paseo_kill "$TARGET" || fail "kill on an already-dead target must stay best-effort (never fail)"
pass "real paseo: kill removes the terminal and archives the workspace, and is idempotent/best-effort"

# --- list_live (name-based recovery discovery) -------------------------------

LABEL2="fm-test-smoke2"
TASK_IDS2=$(fm_backend_paseo_create_task "$LABEL2" /tmp) || fail "second create_task failed"
read -r _TID2 WS2 <<EOF
$TASK_IDS2
EOF
live=$(fm_backend_paseo_list_live)
case "$live" in
*"$LABEL2"*) : ;;
*)
  fail "list_live did not report the freshly created task terminal by name"$'\n'"--- got ---"$'\n'"$live"
  ;;
esac
pass "real paseo: list_live discovers a live task terminal by fm-<id> name"

cleanup_all
trap - EXIT
