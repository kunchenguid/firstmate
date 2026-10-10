#!/usr/bin/env bash
# fm-jq-lib.sh - keep jq output LF-terminated on native Windows.
#
# Windows (captain-approved): native jq.exe ends every output line with CRLF, so
# a captured field, id, or path carries a trailing carriage return and silently
# fails comparisons. On a Windows host (the probe fm_win_host owns in
# bin/fm-session-lock-lib.sh) with jq installed, this shadows jq with a function
# that passes -b, which keeps LF; every jq call in the sourcing shell, including
# pipelines and command substitutions, goes through it. Every other host defines
# nothing and runs the plain jq binary. Sourcing has no other effect and is
# idempotent. A separate program, such as a written shim, must source it too.
if [ -r "/proc/$$/winpid" ] && type -P jq >/dev/null; then
  jq() { command jq -b "$@"; }
fi
