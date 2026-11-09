#!/usr/bin/env bash
# tests/fm-backend-tern-smoke.test.sh - real Tern smoke test for the tern
# session-provider adapter (bin/backends/tern.sh, docs/tern-backend.md).
# Mirrors tests/fm-backend-cmux-smoke.test.sh's/tests/fm-backend-zellij-smoke.test.sh's
# structure: every other suite fakes the CLI, this one talks to the REAL tern
# binary - but there is no throwaway daemon to spin up: Tern is one running
# window whose sessions, tabs and blocks are the captain's live work (a
# firstmate primary hosted in a Tern block lives in one of them). So this test
# creates ONLY a session named `fm-test-smoke-<pid>` (via FM_TERN_SESSION),
# touches and closes ONLY what it created, never enumerates-and-closes, never
# touches another session (the user's Default session in particular), and
# cleans up through tests/tern-test-safety.sh's guarded kill.
#
# Skips cleanly (exit 0, "skip: ...") unless EVERYTHING it needs is present:
#   - tern and jq installed;
#   - a reachable Tern session daemon (`tern ls --json` succeeds);
#   - a Tern window control endpoint (`tern ctl state` succeeds). A remote
#     host or headless daemon can list and capture yet have no window, and
#     the adapter's native-state path cannot be proven there, so the whole
#     smoke skips rather than claim live coverage it did not get.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SESSION_NAME="fm-test-smoke-$$"
SID=""

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tern >/dev/null 2>&1 || { echo "skip: tern not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the tern adapter)"; exit 0; }

# shellcheck source=tests/tern-test-safety.sh
. "$ROOT/tests/tern-test-safety.sh"

# Bounded probes: a wedged daemon must skip, not hang the lane.
probe() {  # <seconds> <cmd...>
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    "$@"
  fi
}

probe 15 tern ls --json >/dev/null 2>&1 \
  || { echo "skip: no reachable Tern session daemon (tern ls --json failed)"; exit 0; }
probe 15 tern ctl state >/dev/null 2>&1 \
  || { echo "skip: no Tern window control endpoint (tern ctl state failed) - native agent state cannot be exercised here"; exit 0; }

# The throwaway session name must be unused: a pre-existing session of that name
# is not ours and is never adopted or closed.
if tern_test_ls_json | jq -e --arg n "$SESSION_NAME" '.sessions[]? | select(.name == $n)' >/dev/null 2>&1; then
  echo "skip: a Tern session named $SESSION_NAME already exists and is not ours"
  exit 0
fi

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tern || { echo "skip: could not source the tern adapter"; exit 0; }
export FM_TERN_SESSION="$SESSION_NAME"

# cleanup_all: the ONLY teardown. It resolves the id of the session THIS RUN
# named (never trusts a stale variable alone) and kills exactly that one
# session through the guarded helper, which itself refuses anything that is
# not an fm-test- session listed under that exact name.
cleanup_all() {
  local id=$SID
  if [ -z "$id" ]; then
    id=$(tern_test_ls_json 2>/dev/null | jq -r --arg n "$SESSION_NAME" '.sessions[]? | select(.name == $n) | .id' 2>/dev/null | head -1)
  fi
  [ -n "$id" ] || return 0
  tern_safe_kill_session "$id" "$SESSION_NAME" || true
}
trap cleanup_all EXIT

# --- container_ensure --------------------------------------------------------

SID=$(fm_backend_tern_container_ensure) || fail "container_ensure failed against the real tern"
case "$SID" in ''|*[!0-9]*) fail "container_ensure should print a numeric session id, got '$SID'" ;; esac
listed=$(tern_test_ls_json | jq -r --arg n "$SESSION_NAME" '.sessions[]? | select(.name == $n) | .id')
[ "$listed" = "$SID" ] || fail "container_ensure's id '$SID' is not the id tern lists for $SESSION_NAME ('$listed')"
tern_refuse_if_unsafe "$SID" "$SESSION_NAME" || fail "the safety guard should accept the session this test just created"
SID2=$(fm_backend_tern_container_ensure) || fail "second container_ensure failed"
[ "$SID2" = "$SID" ] || fail "container_ensure is not idempotent: '$SID' vs '$SID2'"
pass "real tern: container_ensure creates the fm-test- session, returns its exact id, and is idempotent"

# The safety guard must refuse everything that is not this session.
tern_refuse_if_unsafe "$SID" Default 2>/dev/null && fail "the safety guard accepted a non-fm-test- name"
tern_refuse_if_unsafe "$SID" "fm-test-not-$SESSION_NAME" 2>/dev/null && fail "the safety guard accepted a name that does not match the live session"
tern_refuse_if_unsafe "" "$SESSION_NAME" 2>/dev/null && fail "the safety guard accepted an empty id"
tern_refuse_if_unsafe "$SID" "" 2>/dev/null && fail "the safety guard accepted an empty name"
pass "real tern: the safety guard refuses non-fm-test names, mismatched names and empty ids"

# --- create_task -----------------------------------------------------------------

LABEL="fm-test-smoke1"
TASK_IDS=$(fm_backend_tern_create_task "$LABEL" /tmp) || fail "create_task failed"
read -r TAB_ID BLOCK_ID <<EOF
$TASK_IDS
EOF
case "$TAB_ID$BLOCK_ID" in ''|*[!0-9]*) fail "create_task should print '<tab-id> <block-id>' as integers, got '$TASK_IDS'" ;; esac
[ -n "$TAB_ID" ] && [ -n "$BLOCK_ID" ] || fail "create_task did not return tab and block ids"
TARGET="$SID:$BLOCK_ID"
in_session=$(tern_test_ls_json | jq -r --arg s "$SID" --arg b "$BLOCK_ID" '.sessions[]? | select(.id == $s) | .tabs[]?.blocks[]? | select(.id == $b) | .id')
[ "$in_session" = "$BLOCK_ID" ] || fail "the created block $BLOCK_ID is not listed in session $SID"
fm_backend_target_exists tern "$TARGET" "$LABEL" || fail "target_exists should be true for the task block with its label"
if fm_backend_target_exists tern "$TARGET" "fm-test-not-$LABEL" >/dev/null 2>&1; then
  fail "target_exists with a mismatched expected label should fail"
fi
pass "real tern: create_task opens a keep-open tab in the fm-test- session, and target_exists verifies block and label"

# --- literal + key (two-step submit form) ------------------------------------------

sleep 1
fm_backend_tern_send_literal "$TARGET" 'echo literal-then-key-tern' || fail "send_literal failed"
sleep 0.3
fm_backend_tern_send_key "$TARGET" Enter "$LABEL" || fail "send_key Enter failed"
sleep 0.7
out=$(fm_backend_tern_capture "$TARGET" 30 "$LABEL") || fail "capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-tern*) : ;;
  *) fail "capture did not contain the text sent via send_literal+Enter: $out" ;;
esac
pass "real tern: send_literal + send_key Enter submit as two steps and the output is capturable with --surfaces"

fm_backend_tern_send_text_line "$TARGET" 'echo composed-line-tern' || fail "send_text_line failed"
sleep 0.7
out=$(fm_backend_tern_capture "$TARGET" 30) || fail "capture failed after send_text_line"
case "$out" in
  *composed-line-tern*) : ;;
  *) fail "capture did not contain the text sent via send_text_line: $out" ;;
esac
pass "real tern: send_text_line (tern run) composes text and Enter in one call"

out=$(fm_backend_tern_visible_capture "$TARGET") || fail "visible_capture failed"
case "$out" in
  *composed-line-tern*) : ;;
  *) fail "visible_capture did not show the freshly written line: $out" ;;
esac
pass "real tern: visible_capture reads the viewport"

# --- key names: verify the chords the adapter normalizes to -----------------------------

for key in Escape C-c C-u Enter; do
  fm_backend_tern_send_key "$TARGET" "$key" "$LABEL" || fail "send_key $key was rejected by the real tern (chord name not accepted)"
done
pass "real tern: send_key Escape, C-c, C-u and Enter are all accepted chords"

# --- current_path ------------------------------------------------------------------------

fm_backend_tern_send_text_line "$TARGET" 'cd /tmp'
sleep 0.5
p=$(fm_backend_tern_current_path "$TARGET")
case "$p" in
  /tmp|/private/tmp) : ;;
  *) fail "current_path should read the foreground process cwd /tmp after a cd, got '$p'" ;;
esac
pass "real tern: current_path reads the foreground process cwd"

# --- agent_state / busy_state / native_state -----------------------------------------------

as=$(fm_backend_agent_state tern "$TARGET")
[ "$as" = dead ] || fail "a block running only an interactive shell should classify as dead, got '$as'"
pass "real tern: agent_state classifies a shell-only block as dead"

bs=$(fm_backend_busy_state tern "$TARGET")
case "$bs" in
  busy|idle|blocked|unknown) : ;;
  *) fail "busy_state must print busy|idle|blocked|unknown, got '$bs'" ;;
esac
[ "$bs" != busy ] || fail "a shell-only block must never read busy"
ns=$(fm_backend_tern_native_state "$TARGET")
case "$ns" in
  working|idle|waiting_input|unknown) : ;;
  *) fail "native_state must print working|idle|waiting_input|unknown, got '$ns'" ;;
esac
pass "real tern: busy_state/native_state answer in the shared vocabulary through the live control endpoint (busy=$bs native=$ns)"

# --- kill: one block, idempotent --------------------------------------------------------------

fm_backend_tern_kill "$TARGET" "" "$LABEL" || fail "kill failed"
sleep 0.5
still=$(tern_test_ls_json | jq -r --arg s "$SID" --arg b "$BLOCK_ID" '.sessions[]? | select(.id == $s) | .tabs[]?.blocks[]? | select(.id == $b) | .id')
[ -z "$still" ] || fail "kill did not close the task block"
if fm_backend_target_exists tern "$TARGET"; then
  fail "target_exists should be false after kill"
fi
[ "$(fm_backend_agent_state tern "$TARGET")" = missing ] || fail "agent_state should read missing after kill"
fm_backend_tern_kill "$TARGET" || fail "kill on an already-gone block must stay a success"
pass "real tern: kill closes exactly the task block, then target_exists is false, agent_state is missing, and a repeat kill succeeds"

# --- list_live ----------------------------------------------------------------------------------

LABEL2="fm-test-smoke2"
TASK_IDS2=$(fm_backend_tern_create_task "$LABEL2" /tmp) || fail "second create_task failed"
read -r _TAB2 BLOCK2 <<EOF
$TASK_IDS2
EOF
live=$(fm_backend_tern_list_live)
case "$live" in
  *"$SID:$BLOCK2"*"$LABEL2"*) : ;;
  *) fail "list_live did not discover the live task block by its fm-<id> title: $live" ;;
esac
pass "real tern: list_live discovers a live task block by its fm-<id> title"

cleanup_all
SID=""
if tern_test_ls_json | jq -e --arg n "$SESSION_NAME" '.sessions[]? | select(.name == $n)' >/dev/null 2>&1; then
  fail "the guarded cleanup left the fm-test- session behind"
fi
trap - EXIT
pass "real tern: the guarded cleanup removed the whole fm-test- session"
