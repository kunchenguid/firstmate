#!/usr/bin/env bash
# fm-vigie.sh - bounded, read-only daily/event recommendation digest.
#
# fm_vigie.py owns the producer, normalization, delta, and rendering contract.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_vigie.py" "$@"
