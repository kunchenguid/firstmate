#!/usr/bin/env bash
# Run the bounded research command; never starts automatically.
# Usage: fm-robin.sh start|status|stats|view|demo [options]
# Run fm-robin.sh --help for every verb, flag and example.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec node "$ROOT/modules/fm-robin/src/adapters/cli.mjs" "$@"
