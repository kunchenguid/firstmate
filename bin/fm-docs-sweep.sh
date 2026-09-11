#!/usr/bin/env bash
# fm-docs-sweep.sh - read-only, model-free documentation hygiene scan.
#
# Usage:
#   bin/fm-docs-sweep.sh --root <path> [options...]
#   bin/fm-docs-sweep.sh --help
#
# Thin wrapper around bin/fm-docs-sweep.py, which owns all flags, defaults,
# and the JSON output schema (`fm-docs-sweep.v1`) - run with --help for the
# full flag list. The default operation is entirely read-only and model-free:
# scoped file inventory with byte/token estimates, exact-duplicate groups,
# near-duplicate candidates (same-basename files across repos), conflict
# candidates (canonical instruction files in different repos that share a
# section heading with diverging bodies), broken local links, stale inline code-path references, and open TODO/
# checklist extraction, all as bounded JSON to stdout (or --out <path>).
#
# It never calls a model, never touches the network, never deletes or writes
# a file (unless --out names one), never mutates a Beads store, and never
# routes anything into a backlog. Any apply/task-routing/external-link/
# semantic-model stage is out of scope for this command by design; wire it
# up as a separate, explicitly-invoked step that consumes this output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "fm-docs-sweep: python3 required" >&2
  exit 1
fi

exec "$PY" "$SCRIPT_DIR/fm-docs-sweep.py" "$@"
