#!/usr/bin/env bash
# Render one bounded post-turn operational summary from the canonical snapshot.
# Read-only. Adapters call this only after supervision recovery has been checked.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/fm-worker-summary.sh"
