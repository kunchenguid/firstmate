#!/usr/bin/env bash
# fm-context-bundle.sh - deterministic, read-only, model-free scoped
# workspace context bundle.
#
# Usage:
#   bin/fm-context-bundle.sh --root <path> [options...]
#   bin/fm-context-bundle.sh --help
#
# Thin wrapper around bin/fm-context-bundle.py, which owns all flags,
# defaults, and the JSON output schema (`fm-context-bundle.v1`) - run with
# --help for the full flag list. It reuses bin/fm-docs-sweep.py's file scan
# and token estimate rather than a second implementation, then adds a
# bounded, deterministically sorted file tree and a deterministically
# selected file manifest (path/bytes/estimated tokens/sha256, never file
# contents) that fits an optional --budget-tokens or --max-files cap.
#
# It never calls a model, never touches the network, never writes into the
# scanned tree, and never mutates any tracked file (unless --out names one -
# keeping that path outside tracked material is the caller's job). No stage
# here is applied, routed, or packed into full content; that stays a
# separately explicit follow-up that consumes this tool's output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "fm-context-bundle: python3 required" >&2
  exit 1
fi

exec "$PY" "$SCRIPT_DIR/fm-context-bundle.py" "$@"
