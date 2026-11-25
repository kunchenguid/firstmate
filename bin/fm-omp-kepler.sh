#!/usr/bin/env bash
# fm-omp-kepler.sh - manual, worker-only Kepler Terminal controller.
# Usage: fm-omp-kepler.sh handoff|launch|status|interrupt|registration <task-id>
#        fm-omp-kepler.sh template
# Host authority lives at /etc/firstmate/omp-kepler/host.json, root-owned and
# not writable by the worker. Capsules are signed, immutable task records.
# registration prints a fixed Kepler agent.customServers terminal record;
# it does not edit Kepler settings. launch refuses implementation-only grants.
# handoff uses fixed runuser/fm-omp-worker when the Kepler Terminal runs as root.
# No text steering, login, installation, resume, TUI, or supervisor entrypoint.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [ "${1:-}" = --help ]; then
  sed -n '2,10p' "$0"
  exit 0
fi
exec /usr/bin/python3 -I "$SCRIPT_DIR/omp-kepler/controller.py" "$@"
