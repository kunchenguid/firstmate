#!/usr/bin/env bash
# Credentialed native Pi inbox delivery guard. Uses one disposable home and
# the real Pi CLI, lock helper, watcher, extension and model; no WhatsApp API.
# FM_PI_INBOX_EVIDENCE optionally retains the synthetic event timeline.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_PI_INBOX_LIVE_E2E pi python3
unset NO_MISTAKES_GATE
python3 "$ROOT/tests/fm_inbox_pi_live.py"
