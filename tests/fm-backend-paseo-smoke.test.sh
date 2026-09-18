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

# The test owns a throwaway project directory so the shared `firstmate`
# workspace it creates (and the Paseo project registered for that path) can
# be reclaimed without touching any real project in the captain's sidebar.
PROJ_DIR=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-paseo-smoke.XXXXXX")" && pwd)
WS1=""
cleanup_all() {
  local prj
  [ -z "$WS1" ] || {
    fm_backend_paseo_cli workspace archive "$WS1" >/dev/null 2>&1 || true
  }
  # Paseo stores the project path normalized but not symlink-resolved, so
  # look it up by the logical path first and the physical one second.
  prj=$(fm_backend_paseo_cli project ls --json 2>/dev/null |
    jq -r --arg p "$PROJ_DIR" --arg r "$(cd "$PROJ_DIR" 2>/dev/null && pwd -P)" \
      '.[]? | select(.path == $p or .path == $r) | .projectId' 2>/dev/null | head -1)
  [ -z "$prj" ] || fm_backend_paseo_cli project delete "$prj" >/dev/null 2>&1 || true
  rm -rf "$PROJ_DIR"
}
trap cleanup_all EXIT

# --- create_task + duplicate refusal -----------------------------------------

LABEL="fm-test-smoke1"
TASK_IDS=$(fm_backend_paseo_create_task "$LABEL" "$PROJ_DIR") || fail "create_task failed"
read -r TID1 WS1 <<EOF
$TASK_IDS
EOF
if [ -z "$TID1" ] || [ -z "$WS1" ]; then
  fail "create_task did not return terminal/workspace ids"
fi
TARGET="$TID1:$WS1"

if fm_backend_paseo_create_task "$LABEL" "$PROJ_DIR" >/dev/null 2>&1; then
  fail "create_task should refuse a duplicate terminal name (paseo itself does not enforce uniqueness)"
fi
pass "real paseo: create_task creates a terminal/workspace and refuses a duplicate name"

WS_NAME=$(fm_backend_paseo_cli workspace ls --json 2>/dev/null | jq -r --arg id "$WS1" '.[]? | select(.workspaceId == $id) | .name' 2>/dev/null)
[ "$WS_NAME" = firstmate ] || fail "the task's workspace should be the shared 'firstmate' workspace, got title '$WS_NAME'"
PROJECT_COUNT=$(fm_backend_paseo_cli project ls --json 2>/dev/null | jq -r 'length' 2>/dev/null)
pass "real paseo: the task tab lives in the project's shared 'firstmate' workspace"

# Label verification sends Enter (a no-op on an empty prompt), not Escape: a
# bare Escape has no binding of its own in zsh's emacs keymap, so the shell
# holds it as a pending prefix and fuses it with the NEXT key whatever the
# gap (seen live: the following `echo` became `cho`). Escape itself is
# exercised last, right before C-c.
fm_backend_paseo_send_key "$TARGET" Enter "$LABEL" \
  || fail "send_key with a matching expected task label should succeed"
if fm_backend_paseo_send_key "$TARGET" Enter "fm-test-not-$LABEL" >/dev/null 2>&1; then
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

# --- second task: a sibling tab in the SAME workspace, no new project --------

LABEL2="fm-test-smoke2"
TASK_IDS2=$(fm_backend_paseo_create_task "$LABEL2" "$PROJ_DIR") || fail "second create_task failed"
read -r TID2 WS2 <<EOF
$TASK_IDS2
EOF
[ "$WS2" = "$WS1" ] || fail "a second task on the same project must open a tab in the same shared workspace (got $WS2, expected $WS1)"
PROJECT_COUNT2=$(fm_backend_paseo_cli project ls --json 2>/dev/null | jq -r 'length' 2>/dev/null)
[ "$PROJECT_COUNT2" = "$PROJECT_COUNT" ] || fail "a second task must not register another Paseo project ($PROJECT_COUNT -> $PROJECT_COUNT2)"
pass "real paseo: a second task on the same project is a sibling tab in the same workspace and registers no new project"

# --- kill: tab-only close -------------------------------------------------------

fm_backend_paseo_kill "$TARGET"
sleep 0.5
STILL_LIVE=$(fm_backend_paseo_cli terminal ls --all --json 2>/dev/null | jq -r --arg id "$TID1" '.[]? | select(.id == $id) | .id' 2>/dev/null)
[ -z "$STILL_LIVE" ] || fail "kill did not remove the task terminal"
SIBLING=$(fm_backend_paseo_cli terminal ls --all --json 2>/dev/null | jq -r --arg id "$TID2" '.[]? | select(.id == $id) | .id' 2>/dev/null)
[ -n "$SIBLING" ] || fail "kill must not take the sibling task's tab down with it"
WS_STILL=$(fm_backend_paseo_cli workspace ls --json 2>/dev/null | jq -r --arg id "$WS1" '.[]? | select(.workspaceId == $id) | .workspaceId' 2>/dev/null)
[ -n "$WS_STILL" ] || fail "kill must not archive the shared workspace"
# Best-effort contract: killing an already-gone target must not error.
fm_backend_paseo_kill "$TARGET" || fail "kill on an already-dead target must stay best-effort (never fail)"
pass "real paseo: kill closes only the task's tab, leaves the sibling tab and the shared workspace alive, and is idempotent/best-effort"

# --- list_live (name-based recovery discovery) -------------------------------

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
