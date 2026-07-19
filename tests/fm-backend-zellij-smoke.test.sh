#!/usr/bin/env bash
# tests/fm-backend-zellij-smoke.test.sh - real zellij smoke test for the
# zellij session-provider adapter (bin/backends/zellij.sh), P3 of
# data/fm-backend-design-d7 (report.md "Zellij Backend"). Mirrors
# tests/fm-backend-herdr-smoke.test.sh's structure: every other suite fakes
# the CLI, this one talks to a REAL zellij server - but ALWAYS on a private,
# named, throwaway session (via FM_ZELLIJ_SESSION, never the real "firstmate"
# session name), so it never touches a captain's real zellij usage. Skips
# cleanly when zellij (or jq) is not installed, so CI/dev machines without
# zellij are unaffected.
#
# Safety: cleanup uses ONLY zellij_safe_delete (tests/zellij-test-safety.sh),
# never a bare kill-session/delete-session and never kill-all-sessions /
# delete-all-sessions - the same fleet-safety discipline PR #199 established
# for herdr.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v zellij >/dev/null 2>&1 || { echo "skip: zellij not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the zellij adapter)"; exit 0; }

# shellcheck source=tests/zellij-test-safety.sh
. "$ROOT/tests/zellij-test-safety.sh"

SESSION="fm-backend-smoke-$$"
export FM_ZELLIJ_SESSION="$SESSION"
trap cleanup_all EXIT

cleanup_all() {
  zellij_safe_delete "$SESSION"
}

TMP_CWD="${TMPDIR:-/tmp}"
[ -d "$TMP_CWD" ] || fail "temporary directory does not exist: $TMP_CWD"
TMP_CWD=$(cd "$TMP_CWD" && pwd -P) || fail "could not resolve temporary directory: $TMP_CWD"
printf -v TMP_CWD_Q '%q' "$TMP_CWD"
LONG_CWD="$TMP_CWD/fm-zellij-wrap-$$/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/cccccccccccccccccccccccccccccccccccccccc/dddddddddddddddddddddddddddddddddddddddd"
mkdir -p "$LONG_CWD" || fail "could not create long cwd fixture: $LONG_CWD"
LONG_CWD=$(cd "$LONG_CWD" && pwd -P) || fail "could not resolve long cwd fixture: $LONG_CWD"
printf -v LONG_CWD_Q '%q' "$LONG_CWD"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source zellij || fail "fm_backend_source zellij failed"

# --- version gate + container ensure -----------------------------------------

fm_backend_zellij_version_check || fail "version_check failed against the real installed zellij"
pass "real zellij: version_check accepts the installed binary's version"

CONTAINER=$(fm_backend_zellij_container_ensure) || fail "container_ensure failed"
[ "$CONTAINER" = "$SESSION" ] || fail "container_ensure should echo the isolated session name, got '$CONTAINER'"
pass "real zellij: container_ensure starts the isolated background session ($CONTAINER)"

# A second container_ensure must reuse the same session (idempotent, no error).
CONTAINER2=$(fm_backend_zellij_container_ensure) || fail "second container_ensure failed"
[ "$CONTAINER2" = "$CONTAINER" ] || fail "container_ensure is not idempotent: '$CONTAINER' vs '$CONTAINER2'"
pass "real zellij: container_ensure is idempotent (reuses the existing session)"

# --- create_task + duplicate refusal -----------------------------------------

LABEL="fm-smoke1"
TASK_IDS=$(fm_backend_zellij_create_task "$SESSION" "$LABEL" /tmp) || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
if [ -z "$TAB_ID" ] || [ -z "$PANE_ID" ]; then
  fail "create_task did not return tab/pane ids"
fi
TARGET="$SESSION:$PANE_ID"

if fm_backend_zellij_create_task "$SESSION" "$LABEL" /tmp >/dev/null 2>&1; then
  fail "create_task should refuse a duplicate tab name (zellij itself does not enforce uniqueness)"
fi
pass "real zellij: create_task creates a tab/pane and refuses a duplicate name"

fm_backend_zellij_send_key "$TARGET" Escape "$LABEL" \
  || fail "send_key with a matching expected task label should succeed"
if fm_backend_zellij_send_key "$TARGET" Escape "fm-not-$LABEL" >/dev/null 2>&1; then
  fail "send_key with a mismatched expected task label should fail"
fi
pass "real zellij: expected task label verification accepts the matching tab and rejects a mismatch"

# --- send_literal + send_key(Enter), the two-step submit form ---------------

fm_backend_zellij_send_literal "$TARGET" 'echo literal-then-key-captain' \
  || fail "send_literal failed"
sleep 0.3
fm_backend_zellij_send_key "$TARGET" Enter || fail "send_key Enter failed"
sleep 0.5
out=$(fm_backend_zellij_capture "$TARGET" 20) || fail "capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real zellij: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real zellij: send_literal (paste) + send_key Enter submit as two steps and the output is capturable"

# --- send_text_line (the composed atomic-run form) ---------------------------

fm_backend_zellij_send_text_line "$TARGET" "echo captain-on-deck-line" \
  || fail "send_text_line failed"
sleep 0.5
out=$(fm_backend_zellij_capture "$TARGET" 20) || fail "capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real zellij: send_text_line did not run and echo the line"$'\n'"$out" ;;
esac
pass "real zellij: send_text_line composes paste+Enter and its output is capturable"

out=$(fm_backend_zellij_capture "$TARGET" 40) || fail "viewport capture failed"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real zellij: viewport-sized capture did not include recent output"$'\n'"$out" ;;
esac
out=$(fm_backend_zellij_capture "$TARGET" 80) || fail "full-scrollback capture failed"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real zellij: full-scrollback capture did not include recent output"$'\n'"$out" ;;
esac
pass "real zellij: capture supports viewport-sized reads and larger full-scrollback reads"

# --- current_path -------------------------------------------------------------

fm_backend_zellij_send_text_line "$TARGET" "cd /tmp"
sleep 0.3
p=$(fm_backend_zellij_current_path "$TARGET") || fail "current_path failed"
case "$p" in
  */tmp) : ;;
  *) fail "real zellij: current_path did not report the pane's cwd after cd /tmp, got '$p'" ;;
esac
pass "real zellij: current_path reads the pane's live cwd after a direct cd"

fm_backend_zellij_send_text_line "$TARGET" "cd $LONG_CWD_Q"
sleep 0.3
p_wrap=$(fm_backend_zellij_current_path "$TARGET") || fail "current_path failed for a long wrapped path"
[ "$p_wrap" = "$LONG_CWD" ] || fail "real zellij: current_path did not reconstruct a long wrapped cwd, got '$p_wrap'"
pass "real zellij: current_path reconstructs a long cwd that can wrap in the terminal"

# The load-bearing case: a NESTED SUBSHELL's own cd (exactly what `treehouse
# get` does). Verified real bug: zellij's `pane_cwd` JSON field stays frozen
# at wherever the pane's shell was when it launched the subshell as a
# foreground command - it never follows the subshell's own cd, even once
# that subshell is fully interactive. fm_backend_zellij_current_path's active
# pwd-probe (docs/zellij-backend.md) is what fm-spawn.sh's worktree-discovery
# poll actually depends on, so this must be proven against a real subshell,
# not just a plain cd in the pane's own top-level shell (the case above).
fm_backend_zellij_send_text_line "$TARGET" 'cd / && bash'
sleep 0.5
fm_backend_zellij_send_text_line "$TARGET" "cd $TMP_CWD_Q"
sleep 0.3
p2=$(fm_backend_zellij_current_path "$TARGET") || fail "current_path failed inside a nested subshell"
[ "$p2" = "$TMP_CWD" ] || fail "real zellij: current_path did not track a nested subshell's own cd (the treehouse-get-shaped case), got '$p2'"
pass "real zellij: current_path tracks a NESTED SUBSHELL's own cd (the treehouse-get-shaped case a bare pane_cwd read cannot see)"
fm_backend_zellij_send_text_line "$TARGET" 'exit'
sleep 0.3

# --- key names: Escape and Ctrl-C, verified names --------------------------

fm_backend_zellij_send_key "$TARGET" Escape || fail "send_key Escape (normalized to 'Esc') failed"
pass "real zellij: send_key Escape (normalized to the verified 'Esc' name) succeeds"

fm_backend_zellij_send_key "$TARGET" C-c || fail "send_key C-c (normalized to 'Ctrl c') failed"
pass "real zellij: send_key C-c (normalized to the verified 'Ctrl c' name) succeeds"

# --- busy_state: always unknown (D5 - no native agent-state primitive) ------
# zellij has no native agent-state adapter function; fm_backend_busy_state's
# dispatcher (bin/fm-backend.sh) falls through to "unknown" for any backend
# without one via its wildcard case - verified against the real session here,
# not just the fake-CLI suite's dispatch-only assertion.

bs=$(fm_backend_busy_state zellij "$TARGET")
[ "$bs" = unknown ] || fail "fm_backend_busy_state should report unknown for zellij (D5: no native primitive), got '$bs'"
pass "real zellij: fm_backend_busy_state reports unknown (D5 - watcher falls back to pane-regex, same as tmux)"

# --- kill -----------------------------------------------------------------

fm_backend_zellij_kill "$TARGET"
sleep 0.3
LIVE_AFTER_KILL=$(fm_backend_zellij_cli "$SESSION" action list-panes --json 2>/dev/null \
  | jq -e --argjson p "$PANE_ID" '[.[]? | select(.id == $p and .is_plugin == false)] | length > 0' 2>/dev/null)
[ "$LIVE_AFTER_KILL" != "true" ] || fail "kill did not remove the pane"
# Best-effort contract: killing an already-gone target must not error.
fm_backend_zellij_kill "$TARGET" || fail "kill on an already-dead target must stay best-effort (never fail)"
pass "real zellij: kill removes the pane+tab and is idempotent/best-effort"

# --- list_live (name-based recovery discovery) --------------------------------

LABEL2="fm-smoke2"
TASK_IDS2=$(fm_backend_zellij_create_task "$SESSION" "$LABEL2" /tmp) || fail "second create_task failed"
read -r _TAB_ID2 PANE_ID2 <<EOF
$TASK_IDS2
EOF
live=$(fm_backend_zellij_list_live "$SESSION")
assert_contains_local() { case "$1" in *"$2"*) : ;; *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;; esac; }
assert_contains_local "$live" "$LABEL2" "list_live did not report the freshly created task tab by name"
pass "real zellij: list_live discovers a live task tab by fm-<id> name"

fm_backend_zellij_kill "$SESSION:$PANE_ID2"

cleanup_all
trap - EXIT
