#!/usr/bin/env bash
# Pass when the session-start script ran (repo marker) or the PATH shim logged it.
set -euo pipefail
if [ -s "${RUN_DIR:?}/.session-started" ]; then
  exit 0
fi
if [ -f "${CALLS_LOG:?}" ] && grep -q 'fm-session-start' "$CALLS_LOG"; then
  exit 0
fi
exit 1
