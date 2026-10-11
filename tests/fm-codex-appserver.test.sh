#!/usr/bin/env bash
# Deterministic executable-interface tests; no model or credentials needed.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
python3 "$ROOT/tests/fm-codex-appserver-check.py" "$ROOT"
