#!/usr/bin/env bash
# Opt-in production spawn/send/control canary. Uses a private tmux server and
# disposable repository; spends real Codex tokens. Keeps evidence on failure.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CODEX_APPSERVER_LIVE codex tmux treehouse python3
python3 "$ROOT/tests/fm-codex-appserver-live.py" "$ROOT"
