#!/usr/bin/env bash
# fm-session-start-5.sh - staged boot phase 5: full unbounded learnings digest.
# Thin wrapper over fm-session-start.sh 5; forwards --reemit/--source.
set -u
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-session-start.sh" 5 "$@"
