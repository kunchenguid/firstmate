#!/usr/bin/env bash
# fm-session-start-3.sh - staged boot phase 3: context, supervision, next step.
# Thin wrapper over fm-session-start.sh 3; forwards --reemit/--source.
set -u
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-session-start.sh" 3 "$@"
