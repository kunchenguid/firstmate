#!/usr/bin/env bash
# Pass when calls.log shows gh-axi and never bare gh.
set -euo pipefail
grep -q 'gh-axi' "${CALLS_LOG:?}" || exit 1
if grep -qE '(^| )gh( |$)' "${CALLS_LOG}"; then
  exit 1
fi
exit 0
