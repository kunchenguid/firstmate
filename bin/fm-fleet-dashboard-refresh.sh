#!/usr/bin/env bash
# Refresh and open the Lavish fleet dashboard.
# Usage: fm-fleet-dashboard-refresh.sh [fm-fleet-dashboard.sh options]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/fm-fleet-dashboard.sh" --open "$@"
