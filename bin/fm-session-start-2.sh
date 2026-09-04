#!/usr/bin/env bash
# fm-session-start-2.sh - staged boot phase 2: wake drain, fleet state, network harvest.
# Thin wrapper over fm-session-start.sh 2; forwards --reemit/--source.
set -u
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-session-start.sh" 2 "$@"
