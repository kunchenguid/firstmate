#!/usr/bin/env bash
# tests/fm-backend-herdr-smoke.test.sh - real herdr smoke test for the herdr
# session-provider adapter (bin/backends/herdr.sh), P2 of
# data/fm-backend-design-d7 (herdr-addendum.md). Mirrors
# tests/fm-backend-tmux-smoke.test.sh's structure: every other suite fakes the
# CLI, this one talks to a REAL herdr server - but ALWAYS on a private, named,
# throwaway HERDR_SESSION (never the default session), so it never touches a
# captain's real herdr usage. Skips cleanly when herdr (or jq) is not
# installed, so CI/dev machines without herdr are unaffected.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

SESSION="fm-backend-smoke-$$"
export HERDR_SESSION="$SESSION"
trap cleanup_all EXIT

cleanup_all() {
  herdr server stop >/dev/null 2>&1 || true
  sleep 0.5
  herdr session delete "$SESSION" --json >/dev/null 2>&1 || true
}

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- version gate + container ensure -----------------------------------------

fm_backend_herdr_version_check || fail "version_check failed against the real installed herdr"
pass "real herdr: version_check accepts the installed binary's protocol"

CONTAINER=$(fm_backend_herdr_container_ensure /tmp) || fail "container_ensure failed"
case "$CONTAINER" in
  "$SESSION":w*) : ;;
  *) fail "container_ensure returned an unexpected shape: $CONTAINER" ;;
esac
pass "real herdr: container_ensure starts the isolated session's server and ensures the firstmate workspace ($CONTAINER)"

# A second container_ensure must reuse the same workspace (idempotent).
CONTAINER2=$(fm_backend_herdr_container_ensure /tmp) || fail "second container_ensure failed"
[ "$CONTAINER2" = "$CONTAINER" ] || fail "container_ensure is not idempotent: '$CONTAINER' vs '$CONTAINER2'"
pass "real herdr: container_ensure is idempotent (reuses the existing firstmate workspace)"

# --- create_task + duplicate refusal -----------------------------------------

LABEL="fm-smoke1"
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "$LABEL" /tmp) || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
if [ -z "$TAB_ID" ] || [ -z "$PANE_ID" ]; then
  fail "create_task did not return tab/pane ids"
fi
TARGET="$SESSION:$PANE_ID"

if fm_backend_herdr_create_task "$CONTAINER" "$LABEL" /tmp >/dev/null 2>&1; then
  fail "create_task should refuse a duplicate label (herdr itself does not enforce uniqueness)"
fi
pass "real herdr: create_task creates a tab/pane and refuses a duplicate label"

# --- send_text_line (atomic run) ---------------------------------------------

fm_backend_herdr_send_text_line "$TARGET" "echo captain-on-deck-line" \
  || fail "send_text_line failed"
sleep 0.5
out=$(fm_backend_herdr_capture "$TARGET" 20) || fail "capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real herdr: send_text_line did not run and echo the line"$'\n'"$out" ;;
esac
pass "real herdr: send_text_line runs a command atomically (pane run) and its output is capturable"

# --- send_literal + send_key(Enter), the two-step launch-command form -------

fm_backend_herdr_send_literal "$TARGET" 'echo literal-then-key-captain' \
  || fail "send_literal failed"
sleep 0.2
fm_backend_herdr_send_key "$TARGET" Enter || fail "send_key Enter failed"
sleep 0.5
out=$(fm_backend_herdr_capture "$TARGET" 20) || fail "capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real herdr: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real herdr: send_literal + send_key Enter submit as two separate steps (verified: send-text does NOT auto-submit)"

# --- current_path -------------------------------------------------------------

fm_backend_herdr_send_text_line "$TARGET" "cd /tmp"
sleep 0.3
p=$(fm_backend_herdr_current_path "$TARGET") || fail "current_path failed"
case "$p" in
  */tmp) : ;;
  *) fail "real herdr: current_path did not report the pane's cwd after cd /tmp, got '$p'" ;;
esac
pass "real herdr: current_path reads the pane's live cwd"

# --- busy_state on a real claude harness (verified in herdr-verification-p2.md) ---

if [ "${FM_HERDR_SMOKE_REAL_CLAUDE:-0}" = 1 ] && command -v claude >/dev/null 2>&1; then
  fm_backend_herdr_send_literal "$TARGET" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --print 'say the word HERDRSMOKEOK and nothing else'"
  sleep 0.2
  fm_backend_herdr_send_key "$TARGET" Enter
  found_working=0
  for _ in $(seq 1 20); do
    bs=$(fm_backend_herdr_busy_state "$TARGET" 2>/dev/null)
    [ "$bs" = busy ] && { found_working=1; break; }
    [ "$bs" = idle ] && break
    sleep 0.5
  done
  [ "$found_working" -eq 1 ] || echo "note: never observed agent_status=working for the real claude run (timing-dependent, not fatal)" >&2
  # Wait for completion regardless, bounded.
  for _ in $(seq 1 40); do
    bs=$(fm_backend_herdr_busy_state "$TARGET" 2>/dev/null)
    [ "$bs" = idle ] && break
    sleep 0.5
  done
  out=$(fm_backend_herdr_capture "$TARGET" 30)
  case "$out" in
    *HERDRSMOKEOK*) pass "real herdr: agent_status busy/idle detection tracks a real claude turn, and capture shows its output" ;;
    *) echo "note: claude output marker not observed within the bound (timing-dependent, not fatal to this smoke suite)" >&2 ;;
  esac
elif [ "${FM_HERDR_SMOKE_REAL_CLAUDE:-0}" != 1 ]; then
  echo "note: FM_HERDR_SMOKE_REAL_CLAUDE=1 not set; skipping the real-agent busy_state check" >&2
else
  echo "note: claude not installed; skipping the real-agent busy_state check" >&2
fi

# --- kill -----------------------------------------------------------------

fm_backend_herdr_kill "$TARGET"
if HERDR_SESSION="$SESSION" herdr pane get "$PANE_ID" >/dev/null 2>&1; then
  fail "kill did not remove the pane"
fi
# Best-effort contract: killing an already-gone pane must not error.
fm_backend_herdr_kill "$TARGET" || fail "kill on an already-dead target must stay best-effort (never fail)"
pass "real herdr: kill removes the pane and is idempotent/best-effort"

# --- list_live (label-based recovery discovery) ------------------------------

LABEL2="fm-smoke2"
TASK_IDS2=$(fm_backend_herdr_create_task "$CONTAINER" "$LABEL2" /tmp) || fail "second create_task failed"
read -r _TAB_ID2 PANE_ID2 <<EOF
$TASK_IDS2
EOF
live=$(fm_backend_herdr_list_live "$SESSION")
assert_contains_local() { case "$1" in *"$2"*) : ;; *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;; esac; }
assert_contains_local "$live" "$LABEL2" "list_live did not report the freshly created task tab by label"
pass "real herdr: list_live discovers a live task tab by fm-<id> label"

fm_backend_herdr_kill "$SESSION:$PANE_ID2"

cleanup_all
trap - EXIT
