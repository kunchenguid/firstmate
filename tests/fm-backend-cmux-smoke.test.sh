#!/usr/bin/env bash
# tests/fm-backend-cmux-smoke.test.sh - real cmux smoke test for the cmux
# session-provider adapter (bin/backends/cmux.sh), verified against the real
# cmux 0.64.17 binary (docs/cmux-backend.md). Mirrors
# tests/fm-backend-zellij-smoke.test.sh's/fm-backend-herdr-smoke.test.sh's
# structure: every other suite fakes the CLI, this one talks to the REAL app -
# but unlike herdr/zellij there is no isolated throwaway SESSION to spin up:
# cmux is one shared, GUI-first, macOS-only instance (the same posture as
# Orca). So this test creates ONLY `fm-test-`-prefixed task labels, touches and
# closes ONLY what it created, never enumerates-and-closes, never quits or
# relaunches the app, and cleans up every artifact via
# tests/cmux-test-safety.sh's guarded close. The adapter turns those plain
# labels into home-scoped cmux workspace titles internally.
#
# Skips cleanly when cmux (or jq) is not installed/reachable, so CI/dev
# machines without cmux, or without the one-time password-mode setup
# (docs/cmux-backend.md "Setup"), are unaffected.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the cmux adapter)"; exit 0; }

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source cmux || { echo "skip: could not source the cmux adapter"; exit 0; }

fm_backend_cmux_tool_check >/dev/null 2>&1 || { echo "skip: cmux CLI not found on PATH or at the bundle path"; exit 0; }
fm_backend_cmux_version_check >/dev/null 2>&1 || { echo "skip: installed cmux is older than the verified minimum"; exit 0; }
PING_STATE=$(fm_backend_cmux_ping_state)
[ "$PING_STATE" = ok ] || { echo "skip: cmux socket not reachable/authenticated (state=$PING_STATE) - see docs/cmux-backend.md 'Setup'"; exit 0; }

# shellcheck source=tests/cmux-test-safety.sh
. "$ROOT/tests/cmux-test-safety.sh"

WS1=""
WS2=""
cleanup_all() {
  [ -z "$WS1" ] || cmux_safe_close_workspace "$WS1" "fm-test-smoke1"
  [ -z "$WS2" ] || cmux_safe_close_workspace "$WS2" "fm-test-smoke2"
}
trap cleanup_all EXIT

# --- create_task + duplicate refusal -----------------------------------------

LABEL="fm-test-smoke1"
TASK_IDS=$(fm_backend_cmux_create_task "$LABEL" /tmp) || fail "create_task failed"
read -r WS1 SF1 <<EOF
$TASK_IDS
EOF
if [ -z "$WS1" ] || [ -z "$SF1" ]; then
  fail "create_task did not return workspace/surface ids"
fi
TARGET="$WS1:$SF1"

if fm_backend_cmux_create_task "$LABEL" /tmp >/dev/null 2>&1; then
  fail "create_task should refuse a duplicate workspace title (cmux itself does not enforce uniqueness)"
fi
pass "real cmux: create_task creates a workspace/surface and refuses a duplicate title"

fm_backend_cmux_send_key "$TARGET" Escape "$LABEL" \
  || fail "send_key with a matching expected task label should succeed"
if fm_backend_cmux_send_key "$TARGET" Escape "fm-test-not-$LABEL" >/dev/null 2>&1; then
  fail "send_key with a mismatched expected task label should fail"
fi
pass "real cmux: expected task label verification accepts the matching workspace and rejects a mismatch"

# --- send_literal + send_key(Enter), the two-step submit form ---------------

fm_backend_cmux_send_literal "$TARGET" 'echo literal-then-key-captain' \
  || fail "send_literal failed"
sleep 0.3
fm_backend_cmux_send_key "$TARGET" Enter || fail "send_key Enter failed"
sleep 0.5
out=$(fm_backend_cmux_capture "$TARGET" 20) || fail "capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real cmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real cmux: send_literal (unsubmitted) + send_key Enter submit as two steps and the output is capturable"

# --- send_text_line (the composed form) --------------------------------------

fm_backend_cmux_send_text_line "$TARGET" "echo captain-on-deck-line" \
  || fail "send_text_line failed"
sleep 0.5
out=$(fm_backend_cmux_capture "$TARGET" 20) || fail "capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real cmux: send_text_line did not run and echo the line"$'\n'"$out" ;;
esac
pass "real cmux: send_text_line composes send+Enter and its output is capturable"

# --- current_path: verified zellij-shape frozen cwd --------------------------

fm_backend_cmux_send_text_line "$TARGET" "cd /tmp"
sleep 0.3
p=$(fm_backend_cmux_current_path "$TARGET") || fail "current_path failed"
case "$p" in
  */tmp) : ;;
  *) fail "real cmux: current_path did not report the surface's cwd after a direct cd, got '$p'" ;;
esac
pass "real cmux: current_path reads the surface's live cwd after a direct cd"

# The load-bearing case: a NESTED SUBSHELL's own cd (exactly what `treehouse
# get` does). Verified real finding (docs/cmux-backend.md finding #2):
# current_directory stays frozen at wherever the surface's shell was when it
# launched the subshell as a foreground command - it never follows the
# subshell's own cd. fm_backend_cmux_current_path's active pwd-probe is what
# fm-spawn.sh's worktree-discovery poll actually depends on, so this must be
# proven against a real subshell, not just a plain cd in the top-level shell.
fm_backend_cmux_send_text_line "$TARGET" 'cd / && bash'
sleep 0.5
fm_backend_cmux_send_text_line "$TARGET" "cd /private/tmp"
sleep 0.3
p2=$(fm_backend_cmux_current_path "$TARGET") || fail "current_path failed inside a nested subshell"
case "$p2" in
  */private/tmp|*/tmp) : ;;
  *) fail "real cmux: current_path did not track a nested subshell's own cd (the treehouse-get-shaped case), got '$p2'" ;;
esac
pass "real cmux: current_path tracks a NESTED SUBSHELL's own cd (the treehouse-get-shaped case a bare cwd read cannot see)"
fm_backend_cmux_send_text_line "$TARGET" 'exit'
sleep 0.3

# --- key names: Escape and Ctrl-C, verified names --------------------------

fm_backend_cmux_send_key "$TARGET" Escape || fail "send_key Escape failed"
pass "real cmux: send_key Escape (natively supported, unlike Orca) succeeds"

fm_backend_cmux_send_key "$TARGET" C-c || fail "send_key C-c (normalized to 'ctrl-c') failed"
pass "real cmux: send_key C-c (normalized to the verified 'ctrl-c' name) succeeds"

# --- busy_state: always unknown (no native agent-state primitive) -----------

bs=$(fm_backend_busy_state cmux "$TARGET")
[ "$bs" = unknown ] || fail "fm_backend_busy_state should report unknown for cmux (no native primitive), got '$bs'"
pass "real cmux: fm_backend_busy_state reports unknown (watcher falls back to pane-regex, same as tmux/zellij/orca)"

# --- window_of_workspace: real-cmux window/count detection -------------------
# The last-workspace-in-a-window teardown fix (docs/cmux-backend.md "Closing the
# last workspace in a window") pivots on window_of_workspace reading the live
# `list-windows` / `workspace list --window` JSON correctly (the version-fragile
# part the fake-CLI suite cannot prove). This task workspace shares its window
# with at least the app's own workspace, so it reports "<window_id> <count>"
# with a count of two or more. The last-in-window branch itself is proven end to
# end in the fake-CLI suite and in this document's manual verification record;
# it is not driven live here because closing the last workspace inherently
# leaves a window cmux cannot close over the control socket.
WININFO=$(fm_backend_cmux_window_of_workspace "$WS1")
case "$WININFO" in
  *' '[0-9]*) : ;;
  *) fail "window_of_workspace did not report '<window_id> <count>' for a live task workspace, got '$WININFO'" ;;
esac
WCOUNT=${WININFO##* }
[ "$WCOUNT" -ge 2 ] 2>/dev/null \
  || fail "task workspace shares its window with the app default, so the count should be >= 2, got '$WININFO'"
pass "real cmux: window_of_workspace locates a task workspace's window and counts its workspaces"

# --- kill: whole-workspace close ----------------------------------------------

fm_backend_cmux_kill "$TARGET"
sleep 0.5
STILL_LIVE=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null | jq -r --arg id "$WS1" '.workspaces[]? | select(.id == $id) | .id' 2>/dev/null)
[ -z "$STILL_LIVE" ] || fail "kill did not remove the whole task workspace"
WS1=""
# Best-effort contract: killing an already-gone target must not error.
fm_backend_cmux_kill "$TARGET" || fail "kill on an already-dead target must stay best-effort (never fail)"
pass "real cmux: kill removes the whole workspace and is idempotent/best-effort"

# --- list_live (title-based recovery discovery) ------------------------------

LABEL2="fm-test-smoke2"
TASK_IDS2=$(fm_backend_cmux_create_task "$LABEL2" /tmp) || fail "second create_task failed"
read -r WS2 _SF2 <<EOF
$TASK_IDS2
EOF
live=$(fm_backend_cmux_list_live)
case "$live" in
  *"$LABEL2"*) : ;;
  *) fail "list_live did not report the freshly created task workspace by title"$'\n'"--- got ---"$'\n'"$live" ;;
esac
pass "real cmux: list_live discovers a live task workspace by fm-<id> title"

cleanup_all
trap - EXIT
