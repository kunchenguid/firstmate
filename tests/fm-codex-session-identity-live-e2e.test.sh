#!/usr/bin/env bash
# Live guard for native Codex session ownership on one shared app-server.
#
# The verdict comes from the installed codex, not a stub: it starts a real
# `codex app-server`, opens two real threads, and lets the installed native
# SessionStart hooks run bin/fm-sessionstart-run.sh in an isolated home. The
# first thread must acquire the lock under its codex-native: identity and the
# second must start read-only. An isolated provider points at a closed
# loopback port, so no credentials or model requests leave the fixture and
# the guard spends no model tokens; it runs by default wherever its tools are
# installed. docs/verification/runtime-backends.md records the dated result.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_CODEX_SESSION_IDENTITY_LIVE codex python3 jq
python3 "$ROOT/tests/fm-codex-session-lock-repro.py" --live \
  || fail "installed $(codex --version 2>/dev/null || echo codex): native threads sharing one app-server did not preserve one lock owner"
echo "ALL PASS"
