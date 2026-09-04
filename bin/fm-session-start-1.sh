#!/usr/bin/env bash
# fm-session-start-1.sh - staged boot phase 1: lock, deferred network start, bootstrap.
# Thin wrapper over fm-session-start.sh 1; forwards --reemit/--source.
set -u
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-session-start.sh" 1 "$@"
