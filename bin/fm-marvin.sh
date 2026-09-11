#!/usr/bin/env bash
# Glanceable subscription quota and pace. Usage: fm-marvin.sh [status|watch|history|stats] [-h]
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/../modules/marvin/src/adapters/cli.mjs" "$@"
