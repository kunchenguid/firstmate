#!/usr/bin/env bash
# bin/fm-hermes-plugin-install.sh - install the firstmate Hermes plugin.
#
# Copies the plugin source from bin/hermes-plugin/firstmate/ into
# ~/.hermes/plugins/firstmate/ so Hermes loads it on next session.
# Safe to re-run (overwrites existing plugin files).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/hermes-plugin/firstmate"
DEST_DIR="${HOME}/.hermes/plugins/firstmate"

if [ ! -d "$SRC_DIR" ]; then
  echo "error: plugin source not found at $SRC_DIR" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp -f "${SRC_DIR}/__init__.py" "${SRC_DIR}/hooks.py" "${SRC_DIR}/plugin.yaml" "$DEST_DIR/"

echo "firstmate Hermes plugin installed to $DEST_DIR"
echo "Enable it with: hermes plugins enable firstmate"
