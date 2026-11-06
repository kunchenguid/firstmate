#!/usr/bin/env bash
# Native Codex shared-server session-lock ownership, end to end in an isolated
# primary home. Only the vendor process-table boundary is faked: the Python
# host appears as `codex app-server`, so every invocation shares its pid the
# way native threads share one server. tests/fm-codex-session-lock-repro.py
# owns the cases; tests/fm-codex-session-identity-live-e2e.test.sh replays the
# hook half against the installed Codex.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v python3 >/dev/null 2>&1 || fail "python3 is required for the native Codex lock fixture"
command -v jq >/dev/null 2>&1 || fail "jq is required for the native Codex lock fixture"
python3 "$ROOT/tests/fm-codex-session-lock-repro.py" || fail "native Codex shared-server lock regression"
echo "ALL PASS"
