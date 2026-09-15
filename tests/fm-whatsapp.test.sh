#!/usr/bin/env bash
# Offline WhatsApp contract suite; all homes, harness processes and sends are fixtures.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/fm_whatsapp_test.py"
