#!/usr/bin/env bash
# One real-status pass of the Miko cockpit. Read-only on GitHub. Safe to run every 5 minutes.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I "$here/refresh-cockpit.py"
