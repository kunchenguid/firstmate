#!/usr/bin/env bash
# Native adapter behavioral coverage through the public CLI, real file
# transport and real fixture processes. No harness credentials or backend.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v node >/dev/null || { echo 'skip: node unavailable'; exit 0; }
command -v python3 >/dev/null || { echo 'skip: python3 unavailable'; exit 0; }
python3 "$ROOT/tests/fixtures/native-control/portable.py" "$ROOT"
