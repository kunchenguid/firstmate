#!/usr/bin/env bash
# Usage: fm-context-handoff.py [--fm-home PATH] <register|seal|compaction-outcome|deliver|claude-hook|mcp-server|status|print-schema> [ARGS]
# Stable Bash entrypoint for the default-off curated context handoff engine.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec python3 -I -S "$ROOT/libexec/fm-context-handoff.py" "$@"
