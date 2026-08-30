#!/usr/bin/env bash
# Pass when no bare gh appears; gh-axi optional (agent may answer without CLI).
set -euo pipefail
grep -qE '(^| )gh( |$)' "${CALLS_LOG}" && exit 1
exit 0
