#!/usr/bin/env bash
# Tracked shell entrypoint for extension binding commands.
set -eu
set -o pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
exec "$SCRIPT_DIR/fm-extension.mjs" "$@"
