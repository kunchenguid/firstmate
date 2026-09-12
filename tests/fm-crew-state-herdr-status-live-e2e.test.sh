#!/usr/bin/env bash
# tests/fm-crew-state-herdr-status-live-e2e.test.sh - opt-in live guard for
# current-state reads backed by Herdr's native agent_status.
#
# The guard uses only an already-running, explicitly named Herdr endpoint. It
# launches no harness and performs no Herdr lifecycle operation, so the status
# source is measured without replacing or disturbing the worker under test.
# Set FM_CREW_STATE_HERDR_TARGET to a target in <session>:<workspace>:<pane>
# form, and run it while that endpoint reports agent_status=working.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_CREW_STATE_HERDR_STATUS_LIVE_E2E herdr jq

HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
version_fail() {  # <message>
  fail "$1 [backend=herdr version=$HERDR_VERSION]"
}

TARGET=${FM_CREW_STATE_HERDR_TARGET:-}
[ -n "$TARGET" ] || version_fail "no live Herdr target was supplied; set FM_CREW_STATE_HERDR_TARGET to session:workspace:pane"
case "$TARGET" in
  *:*:*) ;;
  *) version_fail "live Herdr target '$TARGET' is not session:workspace:pane" ;;
esac

SESSION=${TARGET%%:*}
PANE=${TARGET#*:}
RAW=$(bash -c '
  . "$0/bin/fm-backend.sh"
  fm_backend_source herdr || exit 1
  fm_backend_herdr_agent_status_raw "$1" "$2"
' "$ROOT" "$SESSION" "$PANE" 2>/dev/null) \
  || version_fail "the live Herdr agent_status probe failed for $TARGET"
[ "$RAW" = working ] \
  || version_fail "the live Herdr endpoint reports agent_status=${RAW:-unreadable}, expected working"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-state-herdr-status.XXXXXX")
cleanup() {
  local status=$?
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/state"
printf 'window=%s\nworktree=%s\nkind=scout\nbackend=herdr\nharness=codex\n' \
  "$TARGET" "$ROOT" > "$TMP_ROOT/state/live.meta"
OUT=$(FM_STATE_OVERRIDE="$TMP_ROOT/state" "$ROOT/bin/fm-crew-state.sh" live 2>&1) \
  || version_fail "fm-crew-state failed for the live Herdr endpoint: $OUT"
case "$OUT" in
  *"state: working"*) ;;
  *) version_fail "fm-crew-state did not report a live worker as working: $OUT" ;;
esac
case "$OUT" in
  *"source: herdr-agent-status"*) ;;
  *) version_fail "fm-crew-state did not name the Herdr backend source: $OUT" ;;
esac
case "$OUT" in
  *"agent_status=working"*) ;;
  *) version_fail "fm-crew-state did not preserve Herdr's agent_status evidence: $OUT" ;;
esac
case "$OUT" in
  *"source: none"*) version_fail "fm-crew-state still reported no source for a live Herdr worker: $OUT" ;;
esac
pass "real herdr $HERDR_VERSION: agent_status=working supplies current state through fm-crew-state"
