#!/usr/bin/env bash
# Manual terminal observer; never auto-started. Use -h for every verb and flag.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/../modules/moiras/src/adapters/cli.mjs" "$@"
