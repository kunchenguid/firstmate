#!/usr/bin/env bash
# tests/fm-backend-herdr-server-env-e2e.test.sh - isolated real-herdr
# regression for a Firstmate-birthed Herdr server keeping its launcher's
# environment (bin/fm-backend-server-env-lib.sh).
#
# Reproduces the observed shape: after a restart, the session-start fleet
# snapshot's per-task bin/fm-crew-state.sh read was the first Herdr caller, so
# it birthed the server while carrying its one-task overrides into a temporary
# folder and the launching Claude Code session's identity markers. The server
# handed both to every later pane, so fm-crew-state.sh run from any pane read
# the deleted override path and answered "no metadata", and every Claude
# session started in a pane inherited the child-session marker that turns
# transcript saving off. This drives the real fm_backend_herdr_server_ensure
# birth from that polluted environment, deletes the temporary folder, and
# asserts a later pane sees neither while keeping the operator's own
# environment.
#
# Safety (tests/herdr-test-safety.sh): everything runs on a private throwaway
# lab session and cleanup uses ONLY herdr_safe_stop_and_delete.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane

SESSION="fm-lab-server-env-e2e-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-server-env.XXXXXX")
cleanup_all() {
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$SCRATCH"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
fm_backend_herdr_version_check || fail "version_check failed against the real installed herdr"

# A real home with one real task record, read later from inside a pane.
TASK_HOME="$SCRATCH/home"
mkdir -p "$TASK_HOME/state"
printf 'window=fm-envleak\nharness=claude\n' > "$TASK_HOME/state/envleak.meta"

# --- 1. birth the server from the fleet snapshot's per-call environment -----
GONE="$SCRATCH/snapshot-tmp"
mkdir -p "$GONE"
(
  export FM_CREW_STATE_META_OVERRIDE="$GONE/envleak.meta" FM_CREW_STATE_STATUS_OVERRIDE="$GONE/envleak.status" \
    FM_SESSION_START_STAGE_FILE="$GONE/stage" FM_HOME_SUMMARY_IF_IDLE=1 FM_HOME_SUMMARY_WORKER_BEST_EFFORT=1 \
    CLAUDECODE=1 CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_SESSION_ID=launcher-session \
    CLAUDE_CODE_MESSAGING_SOCKET="$GONE/messaging.sock" CLAUDE_CODE_MESSAGING_TOKEN=launcher-token \
    CLAUDE_ENV_FILE="$GONE/claude-env" CLAUDE_PID=4242 CLAUDE_PROJECT_DIR="$GONE" AI_AGENT=claude-code \
    CLAUDE_CONFIG_DIR="$SCRATCH/claude-config" FM_ENV_E2E_UNRELATED_KEEP=no ENV_E2E_OPERATOR_SETTING=kept
  fm_backend_herdr_server_ensure "$SESSION"
) || fail "fm_backend_herdr_server_ensure could not birth the isolated server"
# The snapshot's temporary folder is gone once the read finishes.
rm -rf "$GONE"
pass "repro setup: a per-call Firstmate read inside a Claude session birthed the server, then its temporary folder was removed"

# --- 2. a later pane sees only the operator's environment -------------------
CREATE_OUT=$(fm_backend_herdr_cli "$SESSION" workspace create --cwd "$SCRATCH" --label envleak --no-focus) \
  || fail "could not create a workspace in the isolated session"
PANE_ID=$(printf '%s' "$CREATE_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE_ID" ] || fail "could not parse the new workspace's pane id: $CREATE_OUT"

ENV_OUT="$SCRATCH/pane.env"
CREW_OUT="$SCRATCH/crew-state.out"
DONE="$SCRATCH/pane.done"
fm_backend_herdr_cli "$SESSION" pane run "$PANE_ID" \
  "env > '$ENV_OUT'; FM_HOME='$TASK_HOME' '$ROOT/bin/fm-crew-state.sh' envleak > '$CREW_OUT' 2>&1; : > '$DONE'" >/dev/null \
  || fail "could not run the probe in the new pane"
i=0
while [ ! -e "$DONE" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -e "$DONE" ] || fail "the pane probe did not finish"

for name in FM_CREW_STATE_META_OVERRIDE FM_CREW_STATE_STATUS_OVERRIDE FM_SESSION_START_STAGE_FILE \
  FM_HOME_SUMMARY_IF_IDLE FM_HOME_SUMMARY_WORKER_BEST_EFFORT FM_ENV_E2E_UNRELATED_KEEP \
  CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET \
  CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_ENV_FILE CLAUDE_PID CLAUDE_PROJECT_DIR AI_AGENT; do
  ! grep -q "^$name=" "$ENV_OUT" || fail "a later pane inherited the launcher's $name from the long-lived server"
done
pass "real herdr: a later pane inherits neither the launcher's per-call Firstmate settings nor its Claude session markers"

grep -qx 'ENV_E2E_OPERATOR_SETTING=kept' "$ENV_OUT" \
  || fail "a later pane lost the operator's unrelated environment"
grep -qx "CLAUDE_CONFIG_DIR=$SCRATCH/claude-config" "$ENV_OUT" \
  || fail "a later pane lost the operator's Claude account selection"
grep -q '^PATH=' "$ENV_OUT" || fail "a later pane lost PATH"
pass "real herdr: a later pane keeps the operator's own environment and Claude account selection"

if grep -q 'no metadata for envleak' "$CREW_OUT"; then
  fail "fm-crew-state.sh in a later pane read the launcher's deleted override path: $(cat "$CREW_OUT")"
fi
grep -q 'state:' "$CREW_OUT" || fail "fm-crew-state.sh in a later pane gave no state line: $(cat "$CREW_OUT")"
pass "real herdr: fm-crew-state.sh in a later pane reads the task's real record"

cleanup_all
trap - EXIT
