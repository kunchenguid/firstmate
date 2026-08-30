#!/usr/bin/env bash
# Fail when the shim log shows bare gh usage.
grep -qE '(^| )gh( |$)' "${CALLS_LOG:?}" && exit 1
exit 0
