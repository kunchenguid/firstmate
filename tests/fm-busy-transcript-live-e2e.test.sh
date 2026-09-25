#!/usr/bin/env bash
# Real default Codex/TraeX TUI lifecycle against a local simulated provider.
# Linux/bwrap only: private mount, PID and network namespaces hide the real
# home, sockets, credentials and services. No --no-daemon / exec substitution.
# Refresh after either vendor upgrade. A schema drift fails with exact versions.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_BUSY_TRANSCRIPT_LIVE_E2E herdr codex traex bwrap python3 jq
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_ROOT=$(fm_test_tmproot fm-busy-live)
export FM_HERDR_LAB_STATE_DIR="$LAB_ROOT/herdr-state"
SESSION=$("$HELPER" name busy-transcript)
cleanup() {
  local result=$?
  "$HELPER" teardown "$SESSION" || result=1
  fm_test_cleanup
  exit "$result"
}
trap cleanup EXIT
"$HELPER" provision "$SESSION"
python3 "$ROOT/tests/busy-transcript-live.py" drive "$ROOT" "$LAB_ROOT" "$HELPER" "$SESSION"
