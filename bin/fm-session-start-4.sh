#!/usr/bin/env bash
# fm-session-start-4.sh - staged boot phase 4: context digest (projects, secondmates, captain preferences, full learnings), closing next-step.
# Thin wrapper over fm-session-start.sh 4; forwards --reemit/--source.
set -u
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-session-start.sh" 4 "$@"
